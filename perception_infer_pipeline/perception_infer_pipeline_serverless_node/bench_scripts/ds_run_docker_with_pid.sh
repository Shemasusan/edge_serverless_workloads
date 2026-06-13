#!/usr/bin/env bash
set -euo pipefail
CFG_DIR="${CFG_DIR:-$PWD/}"
IMG="${DS_TAG:-nvcr.io/nvidia/deepstream-l4t:<your_tag>}"
LOGDIR="${LOGDIR:-$PWD/logs}"; mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d_%H%M%S)

CID=$(docker run -d --runtime nvidia --network host -v "$CFG_DIR":/app "$IMG"   /bin/bash -lc 'stdbuf -oL -eL deepstream-app -c /app/av_app.txt   | while IFS= read -r line; do printf "%s %s\n" "$(date +%s%3N)" "$line"; done')
echo "$CID" > "$LOGDIR/ds_DOCKER_$TS.cid"

docker logs -f "$CID" | tee "$LOGDIR/ds_DOCKER_$TS.log" &
sleep 1
DS_PID=$(docker top "$CID" -eo pid,cmd | awk '/deepstream-app/{print $1; exit}')
echo "$DS_PID" > "$LOGDIR/ds_DOCKER_$TS.pid"
echo "DeepStream PID (docker host PID): $DS_PID"
wait
