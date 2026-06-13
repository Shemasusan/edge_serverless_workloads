#!/bin/bash
set -euo pipefail
set -x

# ---------------------------
# Arguments
# ---------------------------
MODE=$1
RECORDS=$2
BATCHES=$3    # files (ST) 
THREADS_REQ=$4    #  threads (MT)

CSVFILE="result_container.csv"
IMAGE="shemathomas/jsontelemetry_pi_perf_arm_new_stracetrial_serverless_n:latest"
CONTAINER_NAME="jsontelemetry_run_$$"


# ---------------------------
# Mode config
# ---------------------------
if [[ "$MODE" == "container_st" ]]; then
  THREADED=false; THREAD_COUNT=1
      export FILES_TO_GENERATE=$BATCHES
elif [[ "$MODE" == "container_mt" ]]; then
  THREADED=true;  THREAD_COUNT=$THREADS_REQ
      export FILES_TO_GENERATE=$BATCHES
else
  echo "[ERROR] Unknown mode: $MODE"; exit 1
fi

#export MODE THREADED THREAD_COUNTi
TIMESTAMP=$(date +%s)
#export REDIS_HOST="${REDIS_HOST:-192.168.100.1}"
#export REDIS_PORT="${REDIS_PORT:-30079}"
export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"
TAG="${MODE}_${RECORDS}_${BATCHES}_${THREAD_COUNT}_${TIMESTAMP}"
LOGFILE="log/container_${TAG}.log"

# ---------------------------
# Generate telemetry data
# ---------------------------
echo "[INFO] Generating telemetry data on host..."
./app_generate_data/telemetry_generator "$RECORDS" "$BATCHES"

# ---------------------------
# Host perf and Redis paths
# ---------------------------
HOST_KREL="$(uname -r)"
HOST_RASPI_VER="${HOST_KREL%-raspi}"
HOST_PERF_BIN="/usr/lib/linux-raspi-tools-$HOST_RASPI_VER/perf"

HOST_LIB_REDISPP="/usr/local/lib/libredis++.so.1"
HOST_LIB_REDISPP_REAL="/usr/local/lib/libredis++.so.1.3.15"
HOST_LIB_HIREDIS="/usr/lib/aarch64-linux-gnu/libhiredis.so.1.1.0"

if [[ ! -x "$HOST_PERF_BIN" ]]; then
  echo "[ERROR] $HOST_PERF_BIN not found. On host: sudo apt install linux-raspi-tools-$HOST_KREL"
  exit 1
fi
CPU_SET="cpuset-cpus=0,1"

# ---------------------------
# Start container
# ---------------------------
echo "[INFO] Starting container... (log -> $LOGFILE)"
START_SPINUP=$(date +%s%N)

docker run --name "$CONTAINER_NAME" \
  --cap-add SYS_ADMIN --cap-add SYS_PTRACE --cap-add PERFMON \
  --security-opt seccomp=unconfined \
  --network=host \
  --$CPU_SET \
  -v /sys:/sys -v /sys/kernel/debug:/sys/kernel/debug \
  -v "$HOST_PERF_BIN":/usr/bin/perf:ro \
  -v "$HOST_LIB_REDISPP":/usr/local/lib/libredis++.so.1:ro \
  -v "$HOST_LIB_REDISPP_REAL":/usr/local/lib/libredis++.so.1.3.15:ro \
  -v "$HOST_LIB_HIREDIS":/usr/lib/aarch64-linux-gnu/libhiredis.so.1.1.0:ro \
    -v /sys:/sys -v /sys/kernel/debug:/sys/kernel/debug \
  -v "$HOST_PERF_BIN":/usr/bin/perf:ro \
  -v "$HOST_LIB_REDISPP":/usr/local/lib/libredis++.so.1:ro \
  -v "$HOST_LIB_REDISPP_REAL":/usr/local/lib/libredis++.so.1.3.15:ro \
  -v "$HOST_LIB_HIREDIS":/usr/lib/aarch64-linux-gnu/libhiredis.so.1.1.0:ro \
  -v /lib:/lib:ro \
  -v /lib64:/lib64:ro \
  -v /usr/lib:/usr/lib:ro \
  -v /usr/bin/strace:/usr/bin/strace:ro \
  -v /usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:ro \
  -v $(pwd)/app/processor:/app/processor:ro \
  -v "$(pwd)/data:/app/data" \
  -e MODE="$MODE" \
  -e THREAD_COUNT="$THREAD_COUNT" \
  -e THREADED="$THREADED" \
  -e RECORDS="$RECORDS" \
  -e BATCH_SIZE="$BATCHES" \
  -e REDIS_HOST="$REDIS_HOST" \
  -e REDIS_PORT="$REDIS_PORT" \
  -e LD_LIBRARY_PATH="/usr/local/lib:/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}" \
  "$IMAGE" \
  /bin/bash -c "/app/run_entrypoint.sh" \
  > "$LOGFILE" 2>&1

EXIT_CODE=$?
END_SPINUP=$(date +%s%N)
SPINUP_TIME_SEC=$(awk -v s=$START_SPINUP -v e=$END_SPINUP 'BEGIN{printf "%.3f",(e-s)/1e9}')
LATENCY_SEC=$(echo "scale=3; ($END_SPINUP - $START_SPINUP)/1000000000" | bc)

# ---------------------------
# Cleanup + metrics stitching
# ---------------------------
docker rm "$CONTAINER_NAME" >/dev/null || true

echo ""
echo "===== CONTAINER METRICS ====="
echo "Spin-up Time (s): $SPINUP_TIME_SEC"
echo "Container Exit Code: $EXIT_CODE"
echo "Container log file: $LOGFILE"

LOCAL_CSV="data/result_local.csv"
if [ -f "$LOCAL_CSV" ]; then
  if [ ! -f "$CSVFILE" ]; then
    echo "Workload,Records,BatchSize,Thread_count,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used,Cores_List,LogFile,PerfFile,Latency_full" > "$CSVFILE"
  fi
   LAST_LINE=$(tail -n 1 "$LOCAL_CSV")
  echo "$LAST_LINE,$LATENCY_SEC" >> "$CSVFILE"
fi

echo "[INFO] Done. Metrics -> $CSVFILE; Log -> $LOGFILE"

