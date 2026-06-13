#!/bin/bash
set -e
cd "$(dirname "$0")"

# ---------- Read arguments ----------
MODE=$1   # native_st, native_mt, container_st, container_mt
RECORDS=$2  # number of records per file
BATCHES=$3    # files (ST) 
THREADS_REQ=$4    #  threads (MT)

if [[ -z "$MODE" || -z "$RECORDS" || -z "$BATCHES" || -z "$THREADS_REQ" ]]; then
    echo "Usage: $0 {native_st|native_mt} <records> <batch> <threads>"
    exit 1
fi

# ---------- Mode config ----------
if [[ "$MODE" == native_st ]]; then
    export THREADED=false
    export THREAD_COUNT=1
    export FILES_TO_GENERATE=$BATCHES
elif [[ "$MODE" == native_mt ]]; then
    export THREADED=true
    export THREAD_COUNT=$THREADS_REQ
    export FILES_TO_GENERATE=$BATCHES
else
    echo "[ERROR] Unknown mode: $MODE"
    exit 1
fi
export MODE="$MODE"

# ---------- Redis host/port for external server ----------
#export REDIS_HOST="${REDIS_HOST:-192.168.100.1}"
#export REDIS_PORT="${REDIS_PORT:-30079}"
export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"



# ---------- CSV and log setup ----------
TIMESTAMP=$(date +%s)
TAG="${MODE}_${RECORDS}_${BATCHES}_${THREAD_COUNT}_${TIMESTAMP}"
LOGFILE="log/run_metrics_${TAG}.log"
CSVFILE="./result_native.csv"
PERF_O="perf/perf_stat_${TAG}.csv"
# Pick any 2 cores (first 2 available or random)
R_CORES=$(shuf -i 0-$(($(nproc)-1)) -n 2 | paste -sd,)
 

TASKET_CMD="taskset -c 0,1"

echo "[INFO] Running telemetry workload ($MODE)..."
echo "[INFO] RECORDS=$RECORDS, BATCH_SIZE=$BATCHES, THREAD_COUNT=$THREAD_COUNT, THREADED=$THREADED"

# ---------- Generate telemetry data ----------
if [[ "$MODE" == native_* || "$MODE" == container_* ]]; then
    echo "[INFO] Generating telemetry data on host..."
    ./app_generate_data/telemetry_generator $RECORDS $BATCHES
fi

# ---------- Start timer and run processor ----------
start=$(date +%s%N)
perf stat -x, -r 3 \
    -o "$PERF_O" \
    -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses \
    bash -c "${TASKET_CMD} /usr/bin/time -v app/processor '$RECORDS' '$THREAD_COUNT' 2>&1 | tee '$LOGFILE'" &
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
    echo "Workload,Records,Batches,Thread_Count,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used" >> "$CSVFILE"
fi
echo "$MODE,$RECORDS,$FILES_TO_GENERATE,$THREAD_COUNT,$LATENCY_SEC,$CPU_UTIL,$MEM_MB,$CORE_USED" >> "$CSVFILE"

# ---------- Extra profiling (only processor) ----------
PROF_DIR="perf"
mkdir -p "$PROF_DIR"
PERF_RECORD_OUT="$PROF_DIR/perf_record_${TAG}.data"
PERF_REPORT_OUT="$PROF_DIR/perf_report_${TAG}.txt"

export MODE THREADED THREAD_COUNT FILES_TO_GENERATE REDIS_HOST REDIS_PORT

sudo -E perf record -F 999 -g --call-graph=dwarf \
    -o "$PERF_RECORD_OUT" \
    ${TASKET_CMD} app/processor "$RECORDS" "$BATCH_SIZE"

echo "[INFO] Generating perf report..."
sudo perf report --stdio -i "$PERF_RECORD_OUT" > "$PERF_REPORT_OUT"
echo "[INFO] Perf profiling complete. Report: $PERF_REPORT_OUT"

# ---------- Extra syscall profiling with strace ----------
STRACE_DIR="strace"
mkdir -p "$STRACE_DIR"

STRACE_SUMMARY_OUT="$STRACE_DIR/strace_summary_${TAG}.txt"
STRACE_DETAIL_OUT="$STRACE_DIR/strace_detail_${TAG}.log"

echo "[INFO] Running strace syscall profiling..."
strace -f -c -e trace=network,process,clock_nanosleep \
    -o "$STRACE_SUMMARY_OUT" \
    ${TASKET_CMD} app/processor "$RECORDS" "$BATCH_SIZE" 2> "$STRACE_DETAIL_OUT"

echo "[INFO] Strace profiling complete. Summary: $STRACE_SUMMARY_OUT"

