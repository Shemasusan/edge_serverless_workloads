#!/bin/bash
set -euo pipefail
set -x

# ---------------------------
# Arguments
# ---------------------------
MODE=$1
RECORDS=$2
BATCHES=$3      # files (ST)
THREADS_REQ=$4  # threads (ST) or replicas (MT)
NAMESPACE=${NAMESPACE:-default}

export REDIS_HOST=redis
export REDIS_PORT=6379

HOST_DATA_DIR=/home/sabyagup/telemetry_results
mkdir -p $HOST_DATA_DIR log

export RUN_ID=$(date +%s%N)
echo "[INFO] RUN_ID = $RUN_ID"

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
  echo "Usage: $0 {serverless_st|serverless_mt} [records] [batch_size] [threads_or_replicas]"
  exit 1
fi

export TIMESTAMP=$(date +%s%N)
TAG="${MODE}_${RECORDS}_${BATCHES}_${THREAD_COUNT}_${TIMESTAMP}"
LOGFILE="log/serverless_${TAG}.log"

REPLICAS=$THREAD_COUNT

export MODE RECORDS THREAD_COUNT NAMESPACE REDIS_HOST REDIS_PORT THREADED
# ---------- Run generator pod ----------
START_GEN=$(date +%s)
echo "[INFO] Running generator script..."
./run_generator_pod.sh "$RECORDS" "$BATCHES" "$REDIS_HOST" "$REDIS_PORT" "$NAMESPACE" "$RUN_ID" | tee -a "$LOGFILE"
END_GEN=$(date +%s)
echo "[INFO] Generator script completed."

# ---------- Deploy processor as Job ----------
PROC_JOB="telemetry-processor-$TIMESTAMP"
echo "[INFO] Creating processor job $PROC_JOB with $REPLICAS parallelism..."
start=$(date +%s%N)
kubectl apply -f <(envsubst < telemetry_processor_min.yaml)

# ---------- Wait for job ----------
echo "[INFO] Waiting for processor job to complete..."
kubectl wait --for=condition=complete --timeout=600s job/$PROC_JOB -n $NAMESPACE
end=$(date +%s%N)
# ---------- Collect pod metrics ----------
PODS=$(kubectl get pod -n $NAMESPACE -l run=$PROC_JOB -o jsonpath='{.items[*].metadata.name}')

SPINDOWN_S="n/a"
# ---------- Compute metrics ----------
LATENCY_SEC=$(echo "scale=3; ($end - $start)/1000000000" | bc)
if [ ! -f "$CSVFILE" ]; then
    echo "Workload,Records,BatchSize,Threads,Latency_full,Latency,ColdStart_s,CPU_Util_Percent,Memory_MB,Spinup_s,Spindown_s,P50,P99,pod,log_name" > "$CSVFILE"
fi

for POD in $PODS; do

# ---------- Compute cold start, spinup, spindown ----------
# Get first pod ready time in seconds
FIRST_READY=$(date -d "$(kubectl get pod -n $NAMESPACE -l run=$PROC_JOB \
  -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].lastTransitionTime}' \
  | tr ' ' '\n' | sort | head -n1)" +%s)

# Get last pod ready time in seconds
LAST_READY=$(date -d "$(kubectl get pod -n $NAMESPACE -l run=$PROC_JOB \
  -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].lastTransitionTime}' \
  | tr ' ' '\n' | sort | tail -n1)" +%s)

# Get last pod finished time in seconds
LAST_FINISH=$(date -d "$(kubectl get pod -n $NAMESPACE -l run=$PROC_JOB \
  -o jsonpath='{.items[*].status.containerStatuses[0].state.terminated.finishedAt}' \
  | tr ' ' '\n' | sort | tail -n1)" +%s)

# Compute metrics
COLD_START=$(( FIRST_READY - start/1000000000 ))   # convert nanoseconds to seconds
SPINUP=$(( LAST_READY - FIRST_READY ))
SPINDOWN=$(( $(date +%s) - LAST_FINISH ))



    # ---------- Extract Latency from logs ----------

       if LOG_LINE=$(kubectl logs $POD -n $NAMESPACE 2>/dev/null | grep -E "[a-zA-Z0-9_]+,[0-9]+,[0-9]+,[0-9.]+,[0-9.]+,[0-9.]+," | head -n1); then
        LATENCY=$(echo "$LOG_LINE" | awk -F',' '{print $4}')
        CPU_UTIL_PERCENT=$(echo "$LOG_LINE" | awk -F',' '{print $5}')
        MEM_MIB=$(echo "$LOG_LINE" | awk -F',' '{print $6}')
        P50=$LATENCY
        P99=$LATENCY
    fi

    
# ---------- Write CSV row ----------
    echo "$MODE,$RECORDS,$BATCHES,$THREAD_COUNT,$LATENCY_SEC,$LATENCY,$COLD_START,$CPU_UTIL_PERCENT,$MEM_MIB,$SPINUP,$SPINDOWN_S,$P50,$P99,$POD,$LOGFILE" >> "$CSVFILE"
done

echo "[INFO] Processor metrics saved to $CSVFILE"

