#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE="com.learning.apaexperiment"
TEST_PACKAGE="com.learning.apaexperiment.test"
RUNNER="androidx.test.runner.AndroidJUnitRunner"
TEST_CLASS="com.learning.apaexperiment.AppLaunchUiAutomatorTest"
TRACE_PROCESSOR="$ROOT_DIR/trace_processor"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOCAL_CONFIG="$ROOT_DIR/perfetto/app_launch_config.pbtxt"
ARTIFACT_DIR="$ROOT_DIR/artifacts/perfetto"
TRACE_NAME="app_launch_$TIMESTAMP.perfetto-trace"
REPORT_NAME="app_launch_$TIMESTAMP.report.txt"
LOCAL_TRACE="$ARTIFACT_DIR/$TRACE_NAME"
LOCAL_REPORT="$ARTIFACT_DIR/$REPORT_NAME"

DEVICE_CONFIG="/data/misc/perfetto-configs/app_launch_config.pbtxt"
DEVICE_TRACE="/data/misc/perfetto-traces/$TRACE_NAME"

SKIP_BUILD=false
ANALYZE_ONLY=""

usage() {
  echo "Usage: $0 [--skip-build] [--analyze-only TRACE_FILE]"
  echo ""
  echo "Options:"
  echo "  --skip-build           Skip building and installing APKs"
  echo "  --analyze-only FILE    Skip capture; analyze an existing trace file"
  echo ""
  echo "Requires: adb, trace_processor (auto-downloaded if missing)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --analyze-only) ANALYZE_ONLY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

mkdir -p "$ARTIFACT_DIR"

ensure_trace_processor() {
  if [[ ! -x "$TRACE_PROCESSOR" ]]; then
    echo "Downloading trace_processor wrapper from Perfetto..."
    curl -LSso "$TRACE_PROCESSOR" https://get.perfetto.dev/trace_processor
    chmod +x "$TRACE_PROCESSOR"
  fi
}

tp_query() {
  local trace_file="$1"
  local query="$2"
  "$TRACE_PROCESSOR" --query-string "$query" "$trace_file" 2>/dev/null
}

run_analysis() {
  local trace_file="$1"

  ensure_trace_processor

  echo ""
  echo "============================================"
  echo "  TRACE ANALYSIS REPORT"
  echo "  Trace: $(basename "$trace_file")"
  echo "  Date:  $(date)"
  echo "============================================"

  # --- Android startup metrics (built-in) ---
  echo ""
  echo ">> Android Startup Metrics"
  echo "-------------------------------------------"
  "$TRACE_PROCESSOR" --run-metrics android_startup "$trace_file" 2>/dev/null || echo "(android_startup metric not available)"

  # --- App startup duration ---
  echo ""
  echo ">> App Startup Duration"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    INCLUDE PERFETTO MODULE android.startup.startups;
    SELECT
      s.package AS package,
      s.startup_type AS startup_type,
      s.ts / 1000000 AS start_ms,
      s.dur / 1000000 AS duration_ms
    FROM android_startups s
    WHERE s.package GLOB '*apaexperiment*';
  " || echo "(no startup data found)"

  # --- Janky frames ---
  echo ""
  echo ">> Frame Jank Analysis"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    SELECT
      COUNT(*) AS total_frames,
      SUM(CASE WHEN aft.jank_type != 'None' THEN 1 ELSE 0 END) AS janky_frames,
      ROUND(AVG(IIF(aft.dur = -1, trace_end() - aft.ts, aft.dur)) / 1000000.0, 2) AS avg_frame_ms,
      ROUND(MAX(IIF(aft.dur = -1, trace_end() - aft.ts, aft.dur)) / 1000000.0, 2) AS max_frame_ms
    FROM actual_frame_timeline_slice aft;
  " || echo "(no frame timeline data)"

  # --- Top longest slices in app (bottleneck detection) ---
  echo ""
  echo ">> Top 15 Longest Slices (Bottlenecks)"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    SELECT
      s.name AS slice_name,
      ROUND(IIF(s.dur = -1, trace_end() - s.ts, s.dur) / 1000000.0, 2) AS duration_ms,
      t.name AS thread_name
    FROM slice s
    JOIN thread_track tt ON s.track_id = tt.id
    JOIN thread t USING(utid)
    JOIN process p USING(upid)
    WHERE p.name GLOB '*apaexperiment*'
      AND s.dur > 0
    ORDER BY s.dur DESC
    LIMIT 15;
  " || echo "(no slice data)"

  # --- Thread state breakdown for main thread during startup ---
  echo ""
  echo ">> Main Thread State During Trace"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    SELECT
      ts.state AS thread_state,
      CASE ts.state
        WHEN 'Running' THEN 'On CPU'
        WHEN 'R' THEN 'Runnable (waiting for CPU)'
        WHEN 'R+' THEN 'Runnable (preempted)'
        WHEN 'S' THEN 'Sleeping'
        WHEN 'D' THEN 'Uninterruptible Sleep (I/O)'
        WHEN 'T' THEN 'Stopped'
        WHEN 'X' THEN 'Dead'
        ELSE ts.state
      END AS description,
      COUNT(*) AS occurrences,
      ROUND(SUM(IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur)) / 1000000.0, 2) AS total_ms
    FROM thread_state ts
    JOIN thread t USING(utid)
    JOIN process p USING(upid)
    WHERE p.name GLOB '*apaexperiment*'
      AND t.name = p.name
    GROUP BY ts.state
    ORDER BY total_ms DESC;
  " || echo "(no thread state data)"

  # --- CPU frequency distribution ---
  echo ""
  echo ">> CPU Frequency Distribution"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    INCLUDE PERFETTO MODULE linux.cpu.frequency;
    SELECT
      cfc.cpu AS cpu,
      ROUND(cfc.freq / 1000.0, 0) AS freq_mhz,
      ROUND(SUM(IIF(cfc.dur = -1, trace_end() - cfc.ts, cfc.dur)) / 1000000.0, 2) AS duration_ms
    FROM cpu_frequency_counters cfc
    GROUP BY cfc.cpu, freq_mhz
    ORDER BY cfc.cpu, freq_mhz;
  " || echo "(no CPU frequency data)"

  # --- Memory snapshots from trace ---
  echo ""
  echo ">> Memory Info From Trace"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    SELECT
      ct.name AS counter_name,
      ROUND(MIN(c.value) / 1024.0, 0) AS min_mb,
      ROUND(MAX(c.value) / 1024.0, 0) AS max_mb,
      ROUND(AVG(c.value) / 1024.0, 0) AS avg_mb
    FROM counter c
    JOIN counter_track ct ON c.track_id = ct.id
    WHERE ct.name IN ('MemTotal', 'MemAvailable', 'MemFree', 'SwapTotal', 'SwapFree')
    GROUP BY ct.name;
  " || echo "(no memory counter data)"

  # --- Binder transactions ---
  echo ""
  echo ">> Binder Transaction Summary"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    SELECT
      COUNT(*) AS total_binder_calls,
      ROUND(SUM(IIF(s.dur = -1, trace_end() - s.ts, s.dur)) / 1000000.0, 2) AS total_ms,
      ROUND(AVG(IIF(s.dur = -1, trace_end() - s.ts, s.dur)) / 1000000.0, 2) AS avg_ms,
      ROUND(MAX(IIF(s.dur = -1, trace_end() - s.ts, s.dur)) / 1000000.0, 2) AS max_ms
    FROM slice s
    JOIN thread_track tt ON s.track_id = tt.id
    JOIN thread t USING(utid)
    JOIN process p USING(upid)
    WHERE p.name GLOB '*apaexperiment*'
      AND s.name GLOB '*binder*';
  " || echo "(no binder data)"

  # --- Scheduling latency ---
  echo ""
  echo ">> Scheduling Latency (App Threads)"
  echo "-------------------------------------------"
  tp_query "$trace_file" "
    SELECT
      t.name AS thread_name,
      COUNT(*) AS runnable_count,
      ROUND(AVG(IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur)) / 1000.0, 2) AS avg_wait_us,
      ROUND(MAX(IIF(ts.dur = -1, trace_end() - ts.ts, ts.dur)) / 1000.0, 2) AS max_wait_us
    FROM thread_state ts
    JOIN thread t USING(utid)
    JOIN process p USING(upid)
    WHERE p.name GLOB '*apaexperiment*'
      AND ts.state = 'R'
    GROUP BY t.name
    ORDER BY avg_wait_us DESC
    LIMIT 10;
  " || echo "(no scheduling data)"

  # --- Device status from live device ---
  echo ""
  echo "============================================"
  echo "  DEVICE STATUS (Live)"
  echo "============================================"
  echo ""

  if adb get-state &>/dev/null 2>&1; then
    echo "Device model:      $(adb shell getprop ro.product.model 2>/dev/null || echo 'N/A')"
    echo "Android version:   $(adb shell getprop ro.build.version.release 2>/dev/null || echo 'N/A')"
    echo "SDK level:         $(adb shell getprop ro.build.version.sdk 2>/dev/null || echo 'N/A')"
    echo "Build fingerprint: $(adb shell getprop ro.build.fingerprint 2>/dev/null || echo 'N/A')"
    echo "CPU ABI:           $(adb shell getprop ro.product.cpu.abi 2>/dev/null || echo 'N/A')"
    echo "CPU cores:         $(adb shell nproc 2>/dev/null || echo 'N/A')"
    echo "Total RAM:         $(adb shell cat /proc/meminfo 2>/dev/null | grep MemTotal | awk '{printf "%.0f MB", $2/1024}' || echo 'N/A')"
    echo "Available RAM:     $(adb shell cat /proc/meminfo 2>/dev/null | grep MemAvailable | awk '{printf "%.0f MB", $2/1024}' || echo 'N/A')"
    echo "Battery level:     $(adb shell dumpsys battery 2>/dev/null | grep level | awk '{print $2}')%"
    echo "Battery temp:      $(adb shell dumpsys battery 2>/dev/null | grep temperature | awk '{printf "%.1f°C", $2/10}')"
  else
    echo "(No device connected — skipping live device info)"
  fi

  echo ""
  echo "============================================"
  echo "  NEXT STEPS: AI-Powered Deep Analysis"
  echo "============================================"
  echo ""
  echo "For deeper analysis, use the installed Perfetto skills with Claude Code:"
  echo ""
  echo "  1. perfetto-trace-analysis — ask Claude to analyze the trace:"
  echo "     \"Analyze $trace_file for startup bottlenecks\""
  echo ""
  echo "  2. perfetto-sql — ask Claude to write custom queries:"
  echo "     \"Query the trace at $trace_file for GC pauses during startup\""
  echo ""
}

# --- Analyze-only mode ---
if [[ -n "$ANALYZE_ONLY" ]]; then
  if [[ ! -f "$ANALYZE_ONLY" ]]; then
    echo "Error: trace file not found: $ANALYZE_ONLY"
    exit 1
  fi
  LOCAL_REPORT="${ANALYZE_ONLY%.perfetto-trace}.report.txt"
  run_analysis "$ANALYZE_ONLY" | tee "$LOCAL_REPORT"
  echo "Report saved: $LOCAL_REPORT"
  exit 0
fi

# --- Build ---
if [[ "$SKIP_BUILD" == false ]]; then
  echo "Building release app and instrumentation test APK..."
  cd "$ROOT_DIR"
  ./gradlew :androidApp:assembleRelease :androidApp:assembleReleaseAndroidTest --quiet

  echo "Installing APKs..."
  adb install -r "androidApp/build/outputs/apk/release/androidApp-release.apk"
  adb install -r -t "androidApp/build/outputs/apk/androidTest/release/androidApp-release-androidTest.apk"
else
  echo "Skipping build (--skip-build)."
fi

# --- Prepare device ---
echo "Preparing device for profiling..."
adb shell pm clear "$APP_PACKAGE" >/dev/null 2>&1 || true
adb push "$LOCAL_CONFIG" "$DEVICE_CONFIG" >/dev/null
adb shell rm -f "$DEVICE_TRACE"

# --- Start perfetto ---
echo "Starting Perfetto trace (20s capture window)..."
adb shell perfetto --txt -c "$DEVICE_CONFIG" -o "$DEVICE_TRACE" -d
sleep 2

if ! adb shell pidof perfetto >/dev/null 2>&1; then
  echo "Error: Perfetto failed to start on device."
  exit 1
fi

# --- Run UI test ---
echo "Running app launch UI automator test..."
TEST_STATUS=0
adb shell am instrument -w -r \
  -e class "$TEST_CLASS" \
  "$TEST_PACKAGE/$RUNNER" || TEST_STATUS=$?

# --- Wait for perfetto to finish ---
echo "Waiting for Perfetto to finish capturing..."
while adb shell pidof perfetto >/dev/null 2>&1; do
  sleep 1
done

# --- Pull trace ---
echo "Pulling trace from device..."
adb pull "$DEVICE_TRACE" "$LOCAL_TRACE" >/dev/null
adb shell rm -f "$DEVICE_CONFIG" "$DEVICE_TRACE" >/dev/null 2>&1 || true

echo "Trace saved: $LOCAL_TRACE"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  echo ""
  echo "WARNING: UI test failed with status $TEST_STATUS"
  echo "The trace was still captured and can be analyzed."
fi

# --- Analyze ---
run_analysis "$LOCAL_TRACE" | tee "$LOCAL_REPORT"

echo ""
echo "============================================"
echo "  ARTIFACTS"
echo "============================================"
echo "  Trace:  $LOCAL_TRACE"
echo "  Report: $LOCAL_REPORT"
echo ""
echo "  Open in Perfetto UI: https://ui.perfetto.dev"
echo "============================================"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  exit "$TEST_STATUS"
fi
