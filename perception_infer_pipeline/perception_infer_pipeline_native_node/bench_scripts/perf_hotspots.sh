#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${PID:-}" ]]; then
  PID=$(pgrep -f deepstream-app | head -n1)
  echo "[WARN] PID not provided, auto-detected DeepStream PID: $PID"
fi
OUT_DIR="${OUT_DIR:-$PWD/logs}"
sudo perf record -F 199 -g --pid "$PID" -- sleep 30
mv perf.data "$OUT_DIR/perf_${MODE:-UNKNOWN}_$(date +%Y%m%d_%H%M%S).record.data"
