#!/usr/bin/env bash
# Launches the bundled app for a few seconds and fails if it exits early (dyld, signing or
# startup crash). Runs on the macOS CI runner.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Espazio.app}"
LOG="$(mktemp)"
"$APP/Contents/MacOS/Espazio" >"$LOG" 2>&1 &
PID=$!
sleep 10
if kill -0 "$PID" 2>/dev/null; then
    echo "Espazio is running after 10 s (pid $PID)."
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
else
    wait "$PID" || STATUS=$?
    echo "Espazio exited early (status ${STATUS:-0}). Output:" >&2
    cat "$LOG" >&2
    exit 1
fi
