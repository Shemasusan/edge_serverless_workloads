#!/bin/bash

# Usage: ./run_serverless.sh <mode> <record_count> <batch_size>
# Example: ./run_serverless.sh serverless_st 10000 5

MODE=$1
RECORDS=$2
BATCH_SIZE=$3

KNATIVE_SERVICE_NAME="telemetry-serverless"
NAMESPACE="default"
IMAGE="shemathomas/jsontelemetry_multi_proc_sep:latest"
TMP_YAML="knative-service.yaml"
CSVFILE="result_serverless.csv"
LOGFILE="latency_samples.log"

# Validate input
if [[ -z "$MODE" || -z "$RECORDS" || -z "$BATCH_SIZE" ]]; then
  echo "[ERROR] Usage: $0 <mode> <record_count> <batch_size>"
  exit 1
fi

# Determine threading mode
if [[ "$MODE" == *_mt ]]; then
  export THREADED=true
  export CORE_COUNT=$(nproc)
else
  export THREADED=false
  export CORE_COUNT=1
fi

export FILES_TO_GENERATE=$BATCH_SIZE
export COUNT=$RECORDS

mkdir -p data/input data/output
rm -f data/output/*.json "$LOGFILE"

echo "[INFO] Generating input JSON files..."
python3 -m app_generate_data.generate_data

echo "[INFO] Deploying Knative service..."

# --- Patch YAML inline: force container to listen on 8080 while app listens on 8000 ---
cat <<EOF > "$TMP_YAML"
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: ${KNATIVE_SERVICE_NAME}
  namespace: ${NAMESPACE}
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"
        autoscaling.knative.dev/maxScale: "5"
    spec:
      containers:
        - image: ${IMAGE}
          command: ["uvicorn"]
          args: ["app.main:app", "--host", "0.0.0.0", "--port", "8080"]
          ports:
            - containerPort: 8000
          env:
            - name: MODE
              value: "burst"
            - name: SUBMODE
              value: "st"
EOF

# Measure cold start
START_COLD=$(date +%s%N)
kubectl apply -f "$TMP_YAML"

echo "[INFO] Waiting for Knative service to become ready..."
for i in {1..60}; do
  URL=$(kubectl get ksvc $KNATIVE_SERVICE_NAME -n $NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null)
  if [[ "$URL" =~ http ]]; then
    echo "[INFO] Service URL = $URL"
    break
  fi
  sleep 1
done

if [[ -z "$URL" ]]; then
  echo "[ERROR] Failed to get service URL."
  exit 1
fi

# Wait for idle
echo "[INFO] Waiting for API /status == idle..."
for i in {1..60}; do
  STATUS=$(curl -s "$URL/status" | jq -r .status)
  if [[ "$STATUS" == "idle" ]]; then
    break
  fi
  sleep 1
done

END_COLD=$(date +%s%N)
COLD_START_MS=$(( (END_COLD - START_COLD) / 1000000 ))
echo "[INFO] Cold start time = ${COLD_START_MS} ms"

# Run the workload
echo "[INFO] Triggering /run..."
START_RUN=$(date +%s%N)



# ---------- Trigger Workload ----------
echo "[INFO] Triggering workload via API..."
TRIGGER_PAYLOAD=$(printf '{"core_count": %s, "mode": "%s", "threaded": %s}' "$CORE_COUNT" "$MODE" "$THREADED")

if [[ "$DEBUG_MODE" == true ]]; then
  curl -v -X POST http://localhost:$PORT/run \
    -H "Content-Type: application/json" \
    -d "$TRIGGER_PAYLOAD"
else
  curl -s -X POST http://localhost:$PORT/run \
    -H "Content-Type: application/json" \
    -d "$TRIGGER_PAYLOAD" > /dev/null
fi


# Poll for completion
echo "[INFO] Waiting for processing to finish..."
for i in {1..180}; do
  STATUS=$(curl -s "$URL/status" | jq -r .status)
  if [[ "$STATUS" == "done" ]]; then
    break
  elif [[ "$STATUS" == "error" ]]; then
    echo "[ERROR] Workload failed."
    exit 1
  fi
  sleep 1
done

END_RUN=$(date +%s%N)
LATENCY_MS=$(( (END_RUN - START_RUN) / 1000000 ))

# Collect pod info
POD_NAME=$(kubectl get pods -n $NAMESPACE -l serving.knative.dev/service=$KNATIVE_SERVICE_NAME -o jsonpath='{.items[0].metadata.name}')
CPU_UTIL=$(kubectl top pod "$POD_NAME" --no-headers | awk '{print $2}')
MEM_UTIL=$(kubectl top pod "$POD_NAME" --no-headers | awk '{print $3}')
POD_COUNT=$(kubectl get pods -n $NAMESPACE -l serving.knative.dev/service=$KNATIVE_SERVICE_NAME | grep -c Running)

# Append result
echo "[RESULT] Mode: $MODE | Latency: ${LATENCY_MS} ms | Cold Start: ${COLD_START_MS} ms | CPU: $CPU_UTIL | Mem: $MEM_UTIL | Pods: $POD_COUNT"
echo "$MODE,$LATENCY_MS,$COLD_START_MS,$CPU_UTIL,$MEM_UTIL,$POD_COUNT" >> "$CSVFILE"


