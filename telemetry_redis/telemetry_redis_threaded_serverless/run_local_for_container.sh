#!/bin/bash
set -euo pipefail
set -x

# ---------------------------
# Redis connectivity debug
# ---------------------------
apt-get update && apt-get install -y redis-tools

REDIS_HOST_NODE=192.168.100.1
REDIS_PORT_NODE=30079
REDIS_HOST_DNS=redis.default.svc.cluster.local
REDIS_PORT_DNS=6379

echo "[INFO] Testing Redis at $REDIS_HOST_NODE:$REDIS_PORT_NODE"
redis-cli -h "$REDIS_HOST_NODE" -p "$REDIS_PORT_NODE" PING || echo "[WARN] Could not connect to $REDIS_HOST_NODE:$REDIS_PORT_NODE"

echo "[INFO] Testing Redis at $REDIS_HOST_DNS:$REDIS_PORT_DNS"
redis-cli -h "$REDIS_HOST_DNS" -p "$REDIS_PORT_DNS" PING || echo "[WARN] Could not connect to $REDIS_HOST_DNS:$REDIS_PORT_DNS"

echo "[INFO] Listing first 5 keys from $REDIS_HOST_DNS"
redis-cli -h "$REDIS_HOST_DNS" -p "$REDIS_PORT_DNS" KEYS '*' | head -n 5


: "${MODE:?MODE not set}"
: "${THREADED:?THREADED not set}"
: "${CORE_COUNT:?CORE_COUNT not set}"
: "${RECORDS:?RECORDS not set}"
: "${BATCH_SIZE:?BATCH_SIZE not set}"
: "${REDIS_HOST:?REDIS_HOST not set}"
: "${REDIS_PORT:?REDIS_PORT not set}"





echo "[INFO] Kernel in container: $(uname -r)"
echo "[INFO] perf path: $(command -v perf || echo missing)"
if command -v perf >/dev/null 2>&1; then
  echo "[INFO] perf real: $(readlink -f "$(command -v perf)" || echo n/a)"
fi
echo "[INFO] MODE=$MODE THREADED=$THREADED CORE_COUNT=$CORE_COUNT RECORDS=$RECORDS BATCH_SIZE=$BATCH_SIZE"

mkdir -p /app/data
TS=$(date +%s)
RESULT_CSV="/app/data/result_local.csv"
TIME_O="/app/data/time_${MODE}${RECORDS}${BATCH_SIZE}_${TS}.txt"
PERF_O="/app/data/perf_stat_${MODE}${RECORDS}${BATCH_SIZE}_${TS}.csv"
LOGFILE="/app/data/log_${MODE}${RECORDS}${BATCH_SIZE}_${TS}.log"
CORES_TO_BE_USED=4

CMD=(/app/processor "$RECORDS" "$BATCH_SIZE")


start_ns=$(date +%s%N)

if command -v perf >/dev/null 2>&1; then
  /usr/bin/time -v -o "$TIME_O" \
    perf stat -x, -r 3 -o "$PERF_O" \
      -e task-clock,context-switches,cpu-migrations,page-faults,\
cycles,instructions,branches,branch-misses,\
cache-references,cache-misses,\
L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses \
      -- "${CMD[@]}" 2>&1 | tee "$LOGFILE"
else
  echo "[WARN] perf unavailable; running without HW counters"
  /usr/bin/time -v -o "$TIME_O" "${CMD[@]}" 2>&1 | tee "$LOGFILE"
fi

end_ns=$(date +%s%N)
LATENCY_SEC=$(awk -v s=$start_ns -v e=$end_ns 'BEGIN{printf "%.3f",(e-s)/1e9}')

#USER_TIME=$(grep -E "^User time .*: " "$TIME_O" | awk '{print $4}' || echo 0)
#SYS_TIME=$(grep -E "^System time .*: " "$TIME_O" | awk '{print $4}' || echo 0)
USER_TIME=$(grep -E "^\s*User time .*: " "$TIME_O" | awk '{print $4}' || echo 0)
SYS_TIME=$(grep -E "^\s*System time .*: " "$TIME_O" | awk '{print $4}' || echo 0)

CPU_TIME=$(echo "$USER_TIME + $SYS_TIME" | bc)
CPU_UTIL=$(awk -v ct="$CPU_TIME" -v lt="$LATENCY_SEC" 'BEGIN{if(lt>0) printf "%.1f", 100*ct/lt; else print ""}')

MEM_KB=$(grep -E "^\s*Maximum resident set size .*: " "$TIME_O" | awk '{print $NF}' || echo 0)


#MEM_KB=$(grep -E "^Maximum resident set size .*: " "$TIME_O" | awk '{print $NF}' || echo 0)
MEM_MB=$(awk -v k="$MEM_KB" 'BEGIN{printf "%.2f", k/1024}')


# Write metrics row
if [ ! -f "$RESULT_CSV" ]; then
  echo "Workload,Records,BatchSize,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used,LogFile,PerfFile" > "$RESULT_CSV"
fi
echo "$MODE,$RECORDS,$BATCH_SIZE,$LATENCY_SEC,$CPU_UTIL,$MEM_MB,$CORE_COUNT,$LOGFILE,$PERF_O" >> "$RESULT_CSV"

echo "===== METRICS ($MODE) ====="
echo "Latency (s): $LATENCY_SEC"
echo "CPU Utilization (%): $CPU_UTIL"
echo "Memory Usage (MB): $MEM_MB"
echo "[INFO] CSV: $RESULT_CSV"
echo "[INFO] Log: $LOGFILE"
echo "[INFO] Perf Stat: $PERF_O"


echo "[INFO] Starting Perf Profiling"


PERF_RECORD_OUT="/app/data/perf_record_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.data"
PERF_REPORT_OUT="/app/data/perf_report_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.txt"


export MODE THREADED CORE_COUNT REDIS_HOST REDIS_PORT


perf record -F 999 -g --call-graph=dwarf \
    -o "$PERF_RECORD_OUT" \
    "${CMD[@]}"
    
    

echo "[INFO] Generating perf report..."
perf report --stdio -i "$PERF_RECORD_OUT" > "$PERF_REPORT_OUT"

echo "[INFO] Perf profiling complete. Report: $PERF_REPORT_OUT"

echo "[INFO] Starting strace profiling"

STRACE_DIR="/app/data/strace"
mkdir -p "$STRACE_DIR"

STRACE_SUMMARY_OUT="$STRACE_DIR/strace_summary_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.txt"
STRACE_DETAIL_OUT="$STRACE_DIR/strace_detail_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.log"

strace -f -c -e trace=network,process,clock_nanosleep \
    -o "$STRACE_SUMMARY_OUT" \
    "${CMD[@]}" 2> "$STRACE_DETAIL_OUT"

echo "[INFO] Strace profiling complete. Summary: $STRACE_SUMMARY_OUT"
echo "[INFO] Strace detailed log: $STRACE_DETAIL_OUT"
