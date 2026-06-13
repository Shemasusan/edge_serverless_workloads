#!/bin/bash
set -euo pipefail
set -x

# ---------------------------
# Arguments
# ---------------------------
MODE=$1
RECORDS=$2
BATCHES=$3
THREADS_REQ=$4
NAMESPACE=${NAMESPACE:-default}

export REDIS_HOST=redis
export REDIS_PORT=6379

HOST_DATA_DIR=/home/sabyagup/telemetry_results
mkdir -p "$HOST_DATA_DIR" log

IMAGE="shemathomas/jsontelemetry_pi_perf_arm_new_stracetrial_serverless_n:latest"
CSVFILE="result_serverless.csv"

# ---------------------------
# Mode config
# ---------------------------
if [[ "$MODE" == "serverless_st" ]]; then
  export THREADED=false
  export THREAD_COUNT=1
  export FILES_TO_GENERATE=$BATCHES
elif [[ "$MODE" == "serverless_mt" ]]; then
  export THREADED=true
  export THREAD_COUNT=$THREADS_REQ
  export FILES_TO_GENERATE=$BATCHES
else
  echo "[ERROR] Unknown mode: $MODE"
  exit 1
fi

export TIMESTAMP=$(date +%s)
DEPLOY_NAME="telemetry-processor-${TIMESTAMP}"

REPLICAS=$THREAD_COUNT

export MODE RECORDS THREAD_COUNT NAMESPACE REDIS_HOST REDIS_PORT THREADED
# ---------- Run generator pod ----------
echo "[INFO] Running generator..."
./run_generator_pod.sh "$RECORDS" "$BATCHES" "$REDIS_HOST" "$REDIS_PORT" "$NAMESPACE" | tee -a "log/generator_${TIMESTAMP}.log"
echo "[INFO] Generator completed."

# ---------- Deploy processor as Deployment ----------
export TIMESTAMP MODE THREAD_COUNT RECORDS NAMESPACE FILES_TO_GENERATE REDIS_HOST REDIS_PORT
echo "[INFO] Creating deployment $DEPLOY_NAME..."
envsubst < telemetry_processor_dep.yaml | kubectl apply -f -



# Wait for pods ready
echo "[INFO] Waiting for pods to be Ready..."
kubectl wait --for=condition=Ready --timeout=300s deployment/$DEPLOY_NAME -n $NAMESPACE

# ---------- Collect metrics ----------
PODS=$(kubectl get pod -n $NAMESPACE -l run=$DEPLOY_NAME -o jsonpath='{.items[*].metadata.name}')

if [ ! -f "$CSVFILE" ]; then
    echo "Workload,Pod,Records,BatchSize,Threads,ColdStart_s,CPU_Util_Percent,Memory_MB,Spinup_s,Spindown_s,Latency,P50,P99,log_name" > "$CSVFILE"
fi

for POD in $PODS; do
    CREATION_TS=$(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.metadata.creationTimestamp}')
    READY_TS=$(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
    START_TIME=$(date -d "$CREATION_TS" +%s)
    READY_TIME=$(date -d "$READY_TS" +%s)
    SPINUP=$(( READY_TIME - START_TIME ))
    COLD_START=$SPINUP

    # Get CPU/memory usage
    METRICS=$(kubectl top pod $POD -n $NAMESPACE --no-headers)
    CPU_MILLICORES=$(echo $METRICS | awk '{print $2}' | sed 's/m//')
    MEM_MIB=$(echo $METRICS | awk '{print $3}' | sed 's/Mi//')
    CPU_UTIL_PERCENT=$(awk "BEGIN {printf \"%.1f\", $CPU_MILLICORES/10}")

    # Copy container latency file
    LOG_LOCAL="log/time_summary_${POD}.txt"
    kubectl cp "$NAMESPACE/$POD:/app/data/time_summary.txt" "$LOG_LOCAL"

    # Parse latency metrics
    LATENCY=$(awk '/Total_Latency/ {print $2}' "$LOG_LOCAL")
    P50=$(awk '/P50/ {print $2}' "$LOG_LOCAL")
    P99=$(awk '/P99/ {print $2}' "$LOG_LOCAL")

    # Runtime = difference between first and last record timestamps in latency file
    FIRST_TS=$(awk '/StartTime/ {print $2}' "$LOG_LOCAL")
    LAST_TS=$(awk '/EndTime/ {print $2}' "$LOG_LOCAL")
    SPINDOWN_S=$(( LAST_TS - READY_TIME ))

    # Write CSV row
    echo "$MODE,$POD,$RECORDS,$BATCHES,$THREAD_COUNT,$COLD_START,$CPU_UTIL_PERCENT,$MEM_MIB,$SPINUP,$SPINDOWN_S,$LATENCY,$P50,$P99,$LOG_LOCAL" >> "$CSVFILE"
done

echo "[INFO] Metrics collected and saved to $CSVFILE"
echo "[INFO] Deployment $DEPLOY_NAME is running. Delete it when done."

