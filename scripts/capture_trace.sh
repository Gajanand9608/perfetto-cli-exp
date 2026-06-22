#!/usr/bin/env bash
set -euo pipefail

APP_PACKAGE="com.learning.apaexperiment"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/perfetto/trace_config.pbtxt"
ARTIFACT_DIR="$ROOT_DIR/artifacts/perfetto"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TRACE_NAME="trace_$TIMESTAMP.perfetto-trace"
DEVICE_CONFIG="/data/misc/perfetto-configs/trace_config.pbtxt"
DEVICE_TRACE="/data/misc/perfetto-traces/$TRACE_NAME"
LOCAL_TRACE="$ARTIFACT_DIR/$TRACE_NAME"

mkdir -p "$ARTIFACT_DIR"

echo "Pushing config to device..."
adb push "$CONFIG_FILE" "$DEVICE_CONFIG" >/dev/null

echo "Starting Perfetto trace (15s, with CPU callstacks)..."
echo "Make sure the app is already running on the device."
echo ""
adb shell perfetto --txt -c "$DEVICE_CONFIG" -o "$DEVICE_TRACE"

echo ""
echo "Pulling trace..."
adb pull "$DEVICE_TRACE" "$LOCAL_TRACE"
adb shell rm -f "$DEVICE_CONFIG" "$DEVICE_TRACE" 2>/dev/null || true

echo ""
echo "Done. Trace saved to:"
echo "  $LOCAL_TRACE"
echo ""
echo "Analyze with AI agent:"
echo "  Analyze $LOCAL_TRACE for the root cause of the ANR during app startup. Identify the exact function blocking the main thread."
