#!/bin/bash
set -euo pipefail
set -x

REDIS_HOST_NODE=192.168.100.1
REDIS_PORT_NODE=30079
REDIS_HOST_DNS=redis.default.svc.cluster.local
REDIS_PORT_DNS=6379

#echo "[INFO] Testing Redis at $REDIS_HOST_NODE:$REDIS_PORT_NODE"
#redis-cli -h "$REDIS_HOST_NODE" -p "$REDIS_PORT_NODE" PING || echo "[WARN] Could not connect to $REDIS_HOST_NODE:$REDIS_PORT_NODE"

#echo "[INFO] Testing Redis at $REDIS_HOST_DNS:$REDIS_PORT_DNS"
#redis-cli -h "$REDIS_HOST_DNS" -p "$REDIS_PORT_DNS" PING || echo "[WARN] Could not connect to $REDIS_HOST_DNS:$REDIS_PORT_DNS"

#echo "[INFO] Listing first 5 keys from $REDIS_HOST_DNS"
#redis-cli -h "$REDIS_HOST_DNS" -p "$REDIS_PORT_DNS" KEYS '*' | head -n 5

# -------- Required / Optional Environment Variables --------
: "${MODE:?MODE not set}"                 # native|container_*|serverless
: "${RECORDS:?RECORDS not set}"
: "${BATCH_SIZE:?BATCH_SIZE not set}"
: "${THREAD_COUNT:?THREAD_COUNT not set}"
: "${REDIS_HOST:?REDIS_HOST not set}"
: "${REDIS_PORT:?REDIS_PORT not set}"
: "${CORE_COUNT:=2}"                      # default = 2
: "${KEY_PATTERN:=telemetry_*}"           # default pattern



echo "[INFO] MODE=$MODE THREADS=$THREAD_COUNT RECORDS=$RECORDS BATCH=$BATCH_SIZE KEY_PATTERN=$KEY_PATTERN"

# -------- Setup Paths --------
mkdir -p /app/data /app/data/strace
TS=$(date +%s)
RESULT_CSV="/app/data/result_local.csv"

CMD=(/app/processor)

# -------- Serverless Mode --------
if [[ "$MODE" == "serverless" ]]; then
  echo "[INFO] Running in serverless mode (no perf/strace)"
  exec "${CMD[@]}"
fi

# -------- Batch Profiling Mode --------
TIME_O="/app/data/time_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.txt"
PERF_O="/app/data/perf_stat_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.csv"
LOGFILE="/app/data/log_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.log"

export MODE THREAD_COUNT REDIS_HOST REDIS_PORT KEY_PATTERN

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
  echo "[WARN] perf not found, running without perf stat"
  /usr/bin/time -v -o "$TIME_O" "${CMD[@]}" 2>&1 | tee "$LOGFILE"
fi
end_ns=$(date +%s%N)
LATENCY_SEC=$(awk -v s=$start_ns -v e=$end_ns 'BEGIN{printf "%.3f",(e-s)/1e9}')

# -------- Extract Metrics --------
USER_TIME=$(grep -E "^\s*User time.*: " "$TIME_O" | awk '{print $4}' || echo 0)
SYS_TIME=$(grep -E "^\s*System time.*: " "$TIME_O" | awk '{print $4}' || echo 0)
CPU_UTIL=$(awk -v ct="$(echo "$USER_TIME + $SYS_TIME" | bc)" -v lt="$LATENCY_SEC" 'BEGIN{if(lt>0) printf "%.1f", 100*ct/lt; else print ""}')
MEM_KB=$(grep -E "^\s*Maximum resident set size.*: " "$TIME_O" | awk '{print $NF}' || echo 0)
MEM_MB=$(awk -v k="$MEM_KB" 'BEGIN{printf "%.2f", k/1024}')

# -------- Append to CSV --------
if [ ! -f "$RESULT_CSV" ]; then
  echo "Workload,Records,BatchSize,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used,LogFile,PerfFile" > "$RESULT_CSV"
fi
echo "$MODE,$RECORDS,$BATCH_SIZE,$LATENCY_SEC,$CPU_UTIL,$MEM_MB,$CORE_COUNT,$LOGFILE,$PERF_O" >> "$RESULT_CSV"

# -------- perf record / report --------
if command -v perf >/dev/null 2>&1; then
  PERF_RECORD_OUT="/app/data/perf_record_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.data"
  PERF_REPORT_OUT="/app/data/perf_report_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.txt"
  perf record -F 999 -g --call-graph=dwarf -o "$PERF_RECORD_OUT" "${CMD[@]}"
  perf report --stdio -i "$PERF_RECORD_OUT" > "$PERF_REPORT_OUT"
else
  echo "[WARN] perf record not available"
fi

# -------- strace --------
if command -v strace >/dev/null 2>&1; then
  STRACE_SUMMARY_OUT="/app/data/strace/strace_summary_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.txt"
  STRACE_DETAIL_OUT="/app/data/strace/strace_detail_${MODE}_${RECORDS}_${BATCH_SIZE}_${TS}.log"
  strace -f -c -e trace=network,process,clock_nanosleep \
    -o "$STRACE_SUMMARY_OUT" "${CMD[@]}" 2> "$STRACE_DETAIL_OUT"
else
  echo "[WARN] strace not available"
fi

echo "[DONE] Batch profiling complete."

