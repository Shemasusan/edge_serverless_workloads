#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Fixed paths for your setup
# ----------------------------
ROOT="$PWD"
CFG="${CFG:-$ROOT/av_app.txt}"
LOGDIR="${LOGDIR:-$ROOT/logs}"
mkdir -p "$LOGDIR"

# ----------------------------
# Launch DeepStream
# ----------------------------
TS=$(date +%Y%m%d_%H%M%S)
stdbuf -oL -eL deepstream-app -c "$CFG" \
  | while IFS= read -r line; do
      printf "%s %s\n" "$(date +%s%3N)" "$line"
    done \
  | tee "$LOGDIR/ds_NATIVE_$TS.log" &

DS_PID=$!
echo "$DS_PID" > "$LOGDIR/ds_NATIVE_$TS.pid"
echo "DeepStream PID (native): $DS_PID"
wait $DS_PID
