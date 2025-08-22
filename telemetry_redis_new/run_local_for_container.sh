#!/bin/bash
set -e

# ------------------------------
# Read environment variables
# ------------------------------
MODE=${MODE:-default_mode}
CORE_COUNT=${CORE_COUNT:-1}
THREADED=${THREADED:-true}
RECORDS=${RECORDS:-100000}
BATCH_SIZE=${BATCH_SIZE:-1}

# ------------------------------
# Paths for logs and results
# ------------------------------
LOGFILE="/app/data/run_metrics_${MODE}_$(date +%s).log"
CSVFILE="/app/data/result_local.csv"

echo "[INFO] Running telemetry processing workload inside container..."
echo "[INFO] MODE=$MODE, CORE_COUNT=$CORE_COUNT, THREADED=$THREADED, RECORDS=$RECORDS, BATCH_SIZE=$BATCH_SIZE"

# ------------------------------
# Start timer
# ------------------------------
start=$(date +%s%N)

# ------------------------------
# Run processor under /usr/bin/time
# ------------------------------
/usr/bin/time -v ./processor "$RECORDS" "$BATCH_SIZE" 2>&1 | tee "$LOGFILE" &
PID=$!

# ------------------------------
# Recursive function to get all PIDs
# ------------------------------
get_all_pids() {
    local p=$1
    echo $p
    for c in $(pgrep -P $p); do
        get_all_pids $c
    done
}

CORE_SET=()

# ------------------------------
# Monitor all processes and threads
# ------------------------------
while ps -p $PID > /dev/null; do
    ALL_PIDS=$(get_all_pids $PID)
    for p in $ALL_PIDS; do
        if [ -d /proc/$p/task ]; then
            for tid_dir in /proc/$p/task/*; do
                if [ -r "$tid_dir/stat" ]; then
                    CORE=$(awk '{print $39}' "$tid_dir/stat" 2>/dev/null)
                    if [[ "$CORE" =~ ^[0-9]+$ ]]; then
                        if [[ ! " ${CORE_SET[*]} " =~ " $CORE " ]]; then
                            CORE_SET+=("$CORE")
                        fi
                    fi
                fi
            done
        fi
    done
    sleep 0.001
done

wait $PID
end=$(date +%s%N)

# ------------------------------
# Compute metrics
# ------------------------------
LATENCY_SEC=$(echo "scale=3; ($end - $start)/1000000000" | bc)

USER_TIME=$(grep "User time" "$LOGFILE" | awk '{print $NF}')
SYS_TIME=$(grep "System time" "$LOGFILE" | awk '{print $NF}')
CPU_TIME=$(echo "$USER_TIME + $SYS_TIME" | bc)

CPU_UTIL=$(echo "scale=1; 100 * $CPU_TIME / $LATENCY_SEC" | bc)

MEM_KB=$(grep "Maximum resident set size" "$LOGFILE" | awk '{print $NF}')
MEM_MB=$(echo "scale=2; $MEM_KB / 1024" | bc)

CORE_USED=${#CORE_SET[@]}

# ------------------------------
# Print metrics
# ------------------------------
echo ""
echo "===== METRICS ($MODE) ====="
echo "Latency (s): $LATENCY_SEC"
echo "CPU Utilization (%): $CPU_UTIL"
echo "Memory Usage (MB): $MEM_MB"
echo "CPU Cores Used: $CORE_USED"
echo "Cores List: ${CORE_SET[*]}"

# ------------------------------
# Write metrics to CSV
# ------------------------------
if [ ! -f "$CSVFILE" ]; then
    echo "Workload,Core_Count,Records,BatchSize,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used" >> "$CSVFILE"
fi

echo "$MODE,$CORE_COUNT,$RECORDS,$BATCH_SIZE,$LATENCY_SEC,$CPU_UTIL,$MEM_MB,$CORE_USED" >> "$CSVFILE"

