#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE="com.learning.apaexperiment"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TRACE_NAME="trace_$TIMESTAMP.perfetto-trace"
CONFIG_FILE="$ROOT_DIR/perfetto/trace_config.pbtxt"

OUTPUT_DIR="$HOME/perfetto-traces"
LOCAL_TRACE="$OUTPUT_DIR/$TRACE_NAME"

DEVICE_CONFIG="/data/misc/perfetto-configs/trace_config.pbtxt"
DEVICE_TRACE="/data/misc/perfetto-traces/$TRACE_NAME"

SKIP_BUILD=false
BUILD_TYPE="debug"

usage() {
  echo "Usage: $0 [--skip-build] [--release]"
  echo ""
  echo "  --skip-build   Skip build and install, reuse existing APK"
  echo "  --release      Use release build (default: debug)"
  echo ""
  echo "Output: $OUTPUT_DIR/<trace>.perfetto-trace"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --release) BUILD_TYPE="release"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

# --- Step 1: Build & install ---
if [[ "$SKIP_BUILD" == false ]]; then
  echo "[1/6] Building $BUILD_TYPE APK..."
  cd "$ROOT_DIR"
  if [[ "$BUILD_TYPE" == "debug" ]]; then
    ./gradlew :androidApp:assembleDebug --quiet
    APK_PATH="androidApp/build/outputs/apk/debug/androidApp-debug.apk"
  else
    ./gradlew :androidApp:assembleRelease --quiet
    APK_PATH="androidApp/build/outputs/apk/release/androidApp-release.apk"
  fi

  echo "[2/6] Installing APK..."
  adb install -r "$APK_PATH"
else
  echo "[1/6] Skipping build (--skip-build)"
  echo "[2/6] Skipping install"
fi

# --- Step 2: Force stop any existing instance ---
echo "[3/6] Force stopping $APP_PACKAGE..."
adb shell am force-stop "$APP_PACKAGE"
sleep 1

# --- Step 3: Push config and start perfetto in background ---
echo "[4/6] Starting Perfetto trace (15s capture window)..."
adb push "$CONFIG_FILE" "$DEVICE_CONFIG" >/dev/null
adb shell rm -f "$DEVICE_TRACE"
adb shell perfetto --txt -c "$DEVICE_CONFIG" -o "$DEVICE_TRACE" -d
sleep 1

if ! adb shell pidof perfetto >/dev/null 2>&1; then
  echo "ERROR: Perfetto failed to start on device."
  exit 1
fi

# --- Step 4: Launch app (triggers ANR in Application.onCreate) ---
echo "[5/6] Launching app (ANR will trigger during init)..."
adb shell am start -n "$APP_PACKAGE/.MainActivity"

# --- Step 5: Wait for perfetto to finish ---
echo "       Waiting for trace capture to complete..."
while adb shell pidof perfetto >/dev/null 2>&1; do
  sleep 1
done

# --- Step 6: Pull trace outside repo ---
echo "[6/6] Pulling trace..."
adb pull "$DEVICE_TRACE" "$LOCAL_TRACE"
adb shell rm -f "$DEVICE_CONFIG" "$DEVICE_TRACE" 2>/dev/null || true

echo ""
echo "============================================"
echo "  TRACE CAPTURED"
echo "============================================"
echo "  File: $LOCAL_TRACE"
echo "  Size: $(du -h "$LOCAL_TRACE" | cut -f1)"
echo "============================================"
echo ""
echo "Launching Claude Code for trace analysis..."
echo ""

PROMPT="Analyze the Perfetto trace at $LOCAL_TRACE

The Android app $APP_PACKAGE is experiencing ANRs during app startup. The main thread appears to be blocked in Application.onCreate().

Find the root cause:
1. What is blocking the main thread and for how long?
2. What is the full call chain to the blocking code?
3. Are there any secondary performance issues (jank, lock contention, I/O waits)?
4. What is the recommended fix?"

cd "$OUTPUT_DIR"
codex "$PROMPT"
