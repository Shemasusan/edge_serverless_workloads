#!/bin/bash
set -e
set -x

# ---------- Arguments ----------
MODE=$1
RECORDS=${2:-500}
BATCH_SIZE=${3:-50}
NAMESPACE=${NAMESPACE:-default}
REDIS_HOST=${REDIS_HOST:-$(kubectl get pod redis -n $NAMESPACE -o jsonpath='{.status.podIP}')}
REDIS_PORT=${REDIS_PORT:-6379}


CSVFILE="result_serverless.csv"
LOGDIR="log"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/serverless_${MODE}_$(date +%s).log"

if [[ -z "$MODE" ]]; then
    echo "Usage: $0 {serverless_st|serverless_mt} [records] [batch_size]"
    exit 1
fi

# ---------- Determine threading mode ----------
if [[ "$MODE" == serverless_st ]]; then
    export THREADED=false
    export CORE_COUNT=1
elif [[ "$MODE" == serverless_mt ]]; then
    export THREADED=true
    export CORE_COUNT=$BATCH_SIZE
else
    echo "[ERROR] Unknown mode: $MODE"
    exit 1
fi

export MODE RECORDS BATCH_SIZE REDIS_HOST REDIS_PORT CORE_COUNT THREADED

# ---------- Run generator pod ----------
START_GEN=$(date +%s)
echo "[INFO] Running generator script..."
./run_generator_pod.sh "$RECORDS" "$BATCH_SIZE" "$REDIS_HOST" "$REDIS_PORT" "$NAMESPACE" | tee -a "$LOGFILE"
END_GEN=$(date +%s)
echo "[INFO] Generator script completed."

# ---------- Deploy processor as container ----------
PROC_POD="telemetry-processor-$(date +%s)"
echo "[INFO] Creating processor pod $PROC_POD..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $PROC_POD
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  nodeSelector:
    type: pi 
  containers:
    - name: telemetry-processor
      image: shemathomas/jsontelemetry_c_trial:latest
      command: ["./processor"]
      env:
        - name: MODE
          value: "$MODE"
        - name: RECORDS
          value: "$RECORDS"
        - name: BATCH_SIZE
          value: "$BATCH_SIZE"
        - name: REDIS_HOST
          value: "$REDIS_HOST"
        - name: REDIS_PORT
          value: "$REDIS_PORT"
        - name: CORE_COUNT
          value: "$CORE_COUNT"
        - name: THREADED
          value: "$THREADED"
EOF

# ---------- Wait for processor pod to be running ----------
echo "[INFO] Waiting for processor pod $PROC_POD to be ready..."
kubectl wait --for=condition=Ready pod/$PROC_POD -n $NAMESPACE --timeout=180s

# ---------- Measure spinup time ----------
CREATION_TIME=$(kubectl get pod $PROC_POD -n $NAMESPACE -o jsonpath='{.metadata.creationTimestamp}')
READY_TIME=$(kubectl get pod $PROC_POD -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
SPINUP_S=$(( $(date -d "$READY_TIME" +%s) - $(date -d "$CREATION_TIME" +%s) ))

# ---------- Port-forward processor pod ----------
kubectl port-forward pod/$PROC_POD 8000:8000 -n $NAMESPACE &
PF_PID=$!
trap 'kill $PF_PID' EXIT
sleep 2

# ---------- POST to trigger processing ----------
echo "[INFO] Triggering processor pod..."
START_PROC=$(date +%s.%N)
curl -s -X POST "http://localhost:8000/run" -d '{}' -H 'Content-Type: application/json' > /dev/null
# Poll until status=done
while true; do
    STATUS=$(curl -s http://localhost:8000/status | jq -r '.status // empty')
    [[ "$STATUS" == "done" ]] && break
    sleep 2
done
END_PROC=$(date +%s.%N)

LATENCY=$(awk "BEGIN {print $END_PROC - $START_PROC}")

# ---------- Collect CPU/Memory metrics ----------
METRICS=$(kubectl top pod $PROC_POD -n $NAMESPACE --no-headers 2>/dev/null || echo "0m 0Mi")
CPU_MILLICORES=$(echo $METRICS | awk '{print $2}' | sed 's/m//')
MEM_MIB=$(echo $METRICS | awk '{print $3}' | sed 's/Mi//')
CPU_UTIL_PERCENT=$((CPU_MILLICORES / 10))   # approx percent
CPU_CORES_USED=$(awk "BEGIN {print $CPU_MILLICORES/1000}")

# ---------- Spindown time (if applicable) ----------
kubectl delete pod $PROC_POD -n $NAMESPACE --wait=false
START_DELETE=$(date +%s)
SPINDOWN_S="n/a"
for i in $(seq 1 60); do
    if ! kubectl get pod $PROC_POD -n $NAMESPACE >/dev/null 2>&1; then
        END_DELETE=$(date +%s)
        SPINDOWN_S=$((END_DELETE - START_DELETE))
        break
    fi
    sleep 2
done

# ---------- Save results ----------
if [ ! -f "$CSVFILE" ]; then
    echo "Workload,Records,BatchSize,Latency_s,CPU_Util_Percent,Memory_MB,CPU_Cores_Used,Spinup_s,Spindown_s" > "$CSVFILE"
fi

echo "$MODE,$RECORDS,$BATCH_SIZE,$LATENCY,$CPU_UTIL_PERCENT,$MEM_MIB,$CPU_CORES_USED,$SPINUP_S,$SPINDOWN_S" >> "$CSVFILE"
echo "[INFO] Processor metrics saved to $CSVFILE"

