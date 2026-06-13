#!/bin/bash
set -e

cd "$(dirname "$0")"

# ---------- Read arguments ----------
MODE=$1       # native_st, native_mt, container_st, container_mt
RECORDS=$2    # number of records per file
PROCS=$3      # files (ST) or threads (MT)

if [[ -z "$MODE" || -z "$RECORDS" || -z "$PROCS" ]]; then
    echo "Usage: $0 {native_st|native_mt|container_st|container_mt} <records> <batch|threads>"
    exit 1
fi

# ---------- Mode config ----------
if [[ "$MODE" == native_st || "$MODE" == container_st ]]; then
    export THREADED=false
    export CORE_COUNT=1
    export FILES_TO_GENERATE=$PROCS
elif [[ "$MODE" == native_mt || "$MODE" == container_mt ]]; then
    export THREADED=true
    export CORE_COUNT=$PROCS
    export FILES_TO_GENERATE=$PROCS
else
    echo "[ERROR] Unknown mode: $MODE"
    exit 1
fi

export MODE="$MODE"
export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"
BATCH_SIZE=$PROCS

# ---------- CSV and log setup ----------
TIMESTAMP=$(date +%s)
LOGFILE="log/run_metrics_${MODE}_${TIMESTAMP}.log"
CSVFILE="./result_native.csv"

echo "[INFO] Running telemetry workload ($MODE)..."
echo "[INFO] RECORDS=$RECORDS, BATCH_SIZE=$BATCH_SIZE, CORE_COUNT=$CORE_COUNT, THREADED=$THREADED"

# ---------- Generate telemetry data ----------
if [[ "$MODE" == native_* || "$MODE" == container_* ]]; then
    echo "[INFO] Generating telemetry data on host..."
    ./app_generate_data/telemetry_generator $RECORDS $BATCH_SIZE
fi

# ---------- Start timer and run processor ----------
start=$(date +%s%N)
taskset -c 0-1 /usr/bin/time -v app/processor "$RECORDS" "$BATCH_SIZE" 2>&1 | tee "$LOGFILE" &
PID=$!

# ---------- Recursive function to get all PIDs ----------
get_all_pids() {
    local p=$1
    echo $p
    for c in $(pgrep -P $p); do
        get_all_pids $c
    done
}

CORE_SET=()

# ---------- Monitor cores dynamically ----------
while ps -p $PID > /dev/null; do
    ALL_PIDS=$(get_all_pids $PID)
    for p in $ALL_PIDS; do
        THREADS=$(ps -L -p $p -o psr= 2>/dev/null | grep -v "PSR" | sort -u)
        for core in $THREADS; do
            if [[ ! " ${CORE_SET[*]} " =~ " $core " ]]; then
                CORE_SET+=("$core")
            fi
        done
    done
    sleep 0.1
done

wait $PID
end=$(date +%s%N)

# ---------- Compute metrics ----------
LATENCY_SEC=$(echo "scale=3; ($end - $start)/1000000000" | bc)
USER_TIME=$(grep "User time" "$LOGFILE" | awk '{print $NF}')
SYS_TIME=$(grep "System time" "$LOGFILE" | awk '{print $NF}')
CPU_TIME=$(echo "$USER_TIME + $SYS_TIME" | bc)
CPU_UTIL=$(echo "scale=1; 100 * $CPU_TIME / $LATENCY_SEC" | bc)
MEM_KB=$(grep "Maximum resident set size" "$LOGFILE" | awk '{print $NF}')
MEM_MB=$(echo "scale=2; $MEM_KB / 1024" | bc)
CORE_USED=${#CORE_SET[@]}

# ---------- Print metrics ----------
echo ""
echo "===== METRICS ($MODE) ====="
echo "Latency (s): $LATENCY_SEC"
echo "CPU Utilization (%): $CPU_UTIL"
echo "Memory Usage (MB): $MEM_MB"
echo "CPU Cores Used: $CORE_USED"
echo "Cores List: ${CORE_SET[*]}"

# ---------- Write CSV ----------
if [ ! -f "$CSVFILE" ]; then
    echo "Workload,Records,Core_Count,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used" >> "$CSVFILE"
fi

echo "$MODE,$RECORDS,$CORE_COUNT,$LATENCY_SEC,$CPU_UTIL,$MEM_MB,$CORE_USED" >> "$CSVFILE"

