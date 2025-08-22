#!/bin/bash
set -e
set -x

# ---------- Arguments ----------
MODE=$1         # container_st or container_mt
RECORDS=$2      # number of records per file
BATCH_SIZE=$3   # files (ST) or threads (MT)

CSVFILE="result_container_res.csv"
IMAGE="shemathomas/jsontelemetry_redis_cpp_new"
CONTAINER_NAME="jsontelemetry_run_$$"
LOGFILE="log/container_${MODE}_$(date +%s).log"

# ---------- Validate arguments ----------
if [[ -z "$MODE" || -z "$RECORDS" || -z "$BATCH_SIZE" ]]; then
    echo "Usage: $0 {container_st|container_mt} <records> <batch_size>"
    exit 1
fi

# Mode config
if [[ "$MODE" == native_st || "$MODE" == container_st ]]; then
    export THREADED=false
    export CORE_COUNT=1
elif [[ "$MODE" == native_mt || "$MODE" == container_mt ]]; then
    export THREADED=true
    export CORE_COUNT=$BATCH_SIZE
else
    echo "[ERROR] Unknown mode: $MODE"
    exit 1
fi

export MODE="$MODE"
export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"

# ---------- Generate telemetry data on host ----------
echo "[INFO] Generating telemetry data on host..."
./app_generate_data/telemetry_generator $RECORDS $BATCH_SIZE

# ---------- Spin-up container ----------
echo "[INFO] Starting container... Logs will be saved to $LOGFILE"
START_SPINUP=$(date +%s%N)
docker run --name "$CONTAINER_NAME" \
    --network=host \
    --cpuset-cpus="0-1" \
    -v "$(pwd)/data:/app/data" \
    -e MODE="$MODE" \
    -e CORE_COUNT="$CORE_COUNT" \
    -e THREADED="$THREADED" \
    -e RECORDS="$RECORDS" \
    -e BATCH_SIZE="$BATCH_SIZE" \
    -e REDIS_HOST="$REDIS_HOST" \
    -e REDIS_PORT="$REDIS_PORT" \
    "$IMAGE" \
    /bin/bash -c "/app/run_local_for_container.sh" \
    > "$LOGFILE" 2>&1
EXIT_CODE=$?
END_SPINUP=$(date +%s%N)
SPINUP_TIME_SEC=$(echo "scale=3; ($END_SPINUP - $START_SPINUP)/1000000000" | bc)

# ---------- Spin-down ----------
START_SPINDOWN=$(date +%s%N)
docker rm $CONTAINER_NAME > /dev/null
END_SPINDOWN=$(date +%s%N)
SPINDOWN_TIME_SEC=$(echo "scale=3; ($END_SPINDOWN - $START_SPINDOWN)/1000000000" | bc)

# ---------- Print metrics ----------
echo ""
echo "===== CONTAINER METRICS ====="
echo "Spin-up Time (s): $SPINUP_TIME_SEC"
echo "Spin-down Time (s): $SPINDOWN_TIME_SEC"
echo "Container Exit Code: $EXIT_CODE"
echo "Container log file: $LOGFILE"

# ---------- Copy & align metrics from data/result_local.csv ----------
LOCAL_CSV="data/result_local.csv"
if [ -f "$LOCAL_CSV" ]; then
    # Ensure header in the destination CSV
    if [ ! -f "$CSVFILE" ]; then
        echo "Workload,Records,BatchSize,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used,Spinup_s,Spindown_s,LogFile" >> "$CSVFILE"
    fi

    # Append only the row matching the current run
    awk -F',' -v OFS=',' \
        -v workload="$MODE" \
        -v rec="$RECORDS" \
        -v batch="$BATCH_SIZE" \
        -v spin="$SPINUP_TIME_SEC" \
        -v spindown="$SPINDOWN_TIME_SEC" \
        -v logf="$LOGFILE" \
        'NR>1 && $1==workload && $3==rec && $4==batch {
            print $1, $3, $4, $5, $6, $7, $8, spin, spindown, logf
        }' "$LOCAL_CSV" >> "$CSVFILE"
fi

echo "[INFO] Done. Metrics saved to $CSVFILE and log saved to $LOGFILE"

