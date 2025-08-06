#!/bin/bash
set -e

cd "$(dirname "$0")"

MODE=$1             # native_st or native_mt
RECORDS=$2          # number of records per file
PROCS=$3            # files (ST) or threads (MT)

LOGFILE="run_metrics_${MODE}.log"
CSVFILE="result_native.csv"

if [[ -z "$MODE" || -z "$RECORDS" || -z "$PROCS" ]]; then
  echo "Usage: $0 {native_st|native_mt} <records> <batch|threads>"
  exit 1
fi

# Mode config
if [[ "$MODE" == "native_st" ]]; then
  export THREADED=false
  export CORE_COUNT=1
  export FILES_TO_GENERATE=$PROCS
  export MODE_O=native_st
elif [[ "$MODE" == "native_mt" ]]; then
  export THREADED=true
  export CORE_COUNT=$PROCS
  export FILES_TO_GENERATE=$PROCS
  export MODE_O=native_mt
else
  echo "[ERROR] Unknown mode: $MODE"
  exit 1
fi

export COUNT=$RECORDS

mkdir -p data/input data/output
rm -f data/output/*.json "$LOGFILE"

echo "[INFO] Generating JSON files..."
python3 -m app_generate_data.generate_data

echo "[INFO] Running processing workload..."

start=$(date +%s%N)
/usr/bin/time -v python3 -m app.process_data 2>&1 | tee "$LOGFILE" & PID=$!

CORE_SET=()
while ps -p $PID > /dev/null; do
  THREADS=$(ps -L -p $PID -o psr= | grep -v "PSR" | sort -u)
  for core in $THREADS; do
    if [[ ! " ${CORE_SET[*]} " =~ " $core " ]]; then
      CORE_SET+=("$core")
    fi
  done
  sleep 1
done

wait $PID
end=$(date +%s%N)

# Time and CPU metrics
LATENCY_SEC=$(echo "scale=3; ($end - $start)/1000000000" | bc)
USER_TIME=$(grep "User time" "$LOGFILE" | awk '{print $NF}')
SYS_TIME=$(grep "System time" "$LOGFILE" | awk '{print $NF}')
CPU_TIME=$(echo "$USER_TIME + $SYS_TIME" | bc)
CPU_UTIL=$(echo "scale=1; 100 * $CPU_TIME / $LATENCY_SEC" | bc)

MEM_KB=$(grep "Maximum resident set size" "$LOGFILE" | awk '{print $NF}')
MEM_MB=$(echo "scale=2; $MEM_KB / 1024" | bc)
CORE_USED=${#CORE_SET[@]}

echo ""
echo "===== METRICS ($MODE) ====="
echo "Latency (s):         $LATENCY_SEC"
echo "CPU Utilization (%): $CPU_UTIL"
echo "Memory Usage (MB):   $MEM_MB"
echo "CPU Cores Used:      $CORE_USED"

# Write CSV
if [ ! -f "$CSVFILE" ]; then
  echo "Workload,Records,Core_Count,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used" >> "$CSVFILE"
fi
echo "$MODE_O,$RECORDS,$CORE_COUNT,$LATENCY_SEC,$CPU_UTIL,$MEM_MB,$CORE_USED" >> "$CSVFILE"

