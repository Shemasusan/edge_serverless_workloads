#!/bin/bash
set -e

MODE=$1             # native_st or native_mt
RECORDS=$2          # records per file
PROCS=$3            # batch size or thread count

LOGFILE="run_metrics_${MODE}.log"
CSVFILE="result_native.csv"

if [[ -z "$MODE" || -z "$RECORDS" || -z "$PROCS" ]]; then
  echo "Usage: $0 {native_st|native_mt} <no_of_records> <batch_size>"
  exit 1
fi

# Configuration based on mode
if [[ "$MODE" == "native_st" ]]; then
  export MODE="sequential"
  export THREADED=false
  export CORE_COUNT=1
  export FILES_TO_GENERATE=$PROCS
  export MODE_O=native_st
elif [[ "$MODE" == "native_mt" ]]; then
  export MODE="threaded"
  export THREADED=true
  export CORE_COUNT=$PROCS
  export FILES_TO_GENERATE=1
  export MODE_O=native_mt
else
  echo "[ERROR] Invalid mode: $MODE"
  exit 1
fi

export COUNT=$RECORDS
export CORE_USED=$CORE_COUNT

mkdir -p data/input data/output
rm -f data/output/*.json

echo "[INFO] Running workload: $MODE with $CORE_COUNT processes"

start=$(date +%s%N)

/usr/bin/time -v python3 -m app.main 2>&1 | tee "$LOGFILE"

end=$(date +%s%N)
LATENCY_SEC=$(echo "scale=3; ($end - $start)/1000000000" | bc)

CPU_UTIL=$(grep "Percent of CPU this job got" "$LOGFILE" | awk '{print $NF}')
MEM_UTIL_KB=$(grep "Maximum resident set size" "$LOGFILE" | awk '{print $NF}')
MEM_UTIL_MB=$(echo "scale=2; $MEM_UTIL_KB / 1024" | bc)

echo ""
echo "===== METRICS ====="
echo "Latency (s):         $LATENCY_SEC"
echo "CPU Utilization (%): $CPU_UTIL"
echo "Memory Usage (MB):   $MEM_UTIL_MB"

if [ ! -f "$CSVFILE" ]; then
  echo "Workload,Records,Core_Count,Latency_s,CPU_Util_Percent,Memory_MB" >> "$CSVFILE"
fi

echo "$MODE_O,$RECORDS,$CORE_COUNT,$LATENCY_SEC,$CPU_UTIL,$MEM_UTIL_MB" >> "$CSVFILE"

