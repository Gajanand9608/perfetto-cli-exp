#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE="com.learning.apaexperiment"
TEST_PACKAGE="com.learning.apaexperiment.test"
RUNNER="androidx.test.runner.AndroidJUnitRunner"
TEST_CLASS="com.learning.apaexperiment.CriticalFlowUiAutomatorTest"

LOCAL_CONFIG="$ROOT_DIR/perfetto/critical_flow_config.pbtxt"
ARTIFACT_DIR="$ROOT_DIR/artifacts/perfetto"
TRACE_NAME="critical_flow_$(date +%Y%m%d_%H%M%S).perfetto-trace"
LOCAL_TRACE="$ARTIFACT_DIR/$TRACE_NAME"

DEVICE_CONFIG="/data/misc/perfetto-configs/critical_flow_config.pbtxt"
DEVICE_TRACE="/data/misc/perfetto-traces/$TRACE_NAME"

mkdir -p "$ARTIFACT_DIR"

cd "$ROOT_DIR"

echo "Building release app and release instrumentation APK..."
./gradlew :androidApp:assembleRelease :androidApp:assembleReleaseAndroidTest

echo "Installing APKs..."
adb install -r "androidApp/build/outputs/apk/release/androidApp-release.apk"
adb install -r -t "androidApp/build/outputs/apk/androidTest/release/androidApp-release-androidTest.apk"

echo "Preparing Perfetto config..."
adb push "$LOCAL_CONFIG" "$DEVICE_CONFIG" >/dev/null
adb shell rm -f "$DEVICE_TRACE"
if ! adb shell pm clear "$APP_PACKAGE" >/dev/null; then
  echo "Warning: could not clear $APP_PACKAGE data. Continuing with existing app state."
fi

echo "Starting Perfetto trace..."
adb shell perfetto --txt -c "$DEVICE_CONFIG" -o "$DEVICE_TRACE" &
PERFETTO_PID=$!

sleep 2

if ! kill -0 "$PERFETTO_PID" 2>/dev/null; then
  wait "$PERFETTO_PID" || true
  echo "Perfetto failed to start. No critical flow was profiled."
  exit 1
fi

TEST_STATUS=0
PERFETTO_STATUS=0

echo "Running critical UI flow..."
adb shell am instrument -w -r \
  -e class "$TEST_CLASS" \
  "$TEST_PACKAGE/$RUNNER" || TEST_STATUS=$?

echo "Waiting for Perfetto to finish..."
wait "$PERFETTO_PID" || PERFETTO_STATUS=$?

if [[ "$PERFETTO_STATUS" -ne 0 ]]; then
  echo "Perfetto failed with status $PERFETTO_STATUS"
  exit "$PERFETTO_STATUS"
fi

echo "Pulling trace..."
adb pull "$DEVICE_TRACE" "$LOCAL_TRACE" >/dev/null
adb shell rm -f "$DEVICE_CONFIG" "$DEVICE_TRACE" >/dev/null || true

echo "Trace saved: $LOCAL_TRACE"

if [[ "$TEST_STATUS" -ne 0 ]]; then
  echo "Critical flow test failed with status $TEST_STATUS"
  exit "$TEST_STATUS"
fi
