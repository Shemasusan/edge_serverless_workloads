#!/bin/bash
set -e
set -x

# ---------------- Arguments ----------------
RECORDS=${1:-100}
BATCH_SIZE=${2:-10}
REDIS_HOST=${3:-redis.default.svc.cluster.local}
REDIS_PORT=${4:-6379}
NAMESPACE=${5:-default}

if [[ -z "$RECORDS" || -z "$BATCH_SIZE" ]]; then
    echo "Usage: $0 <records> <batch_size> [redis_host] [redis_port] [namespace]"
    exit 1
fi

# Pod name with timestamp
POD_NAME="telemetry-gen-$(date +%s)"

# ---------------- Generate Pod YAML dynamically ----------------
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: telemetry-generator
      image: shemathomas/jsontelemetry_generator
      command: ["./telemetry_generator"]
      args: ["$RECORDS", "$BATCH_SIZE", "$REDIS_HOST", "$REDIS_PORT"]
      env:
        - name: REDIS_HOST
          value: "$REDIS_HOST"
        - name: REDIS_PORT
          value: "$REDIS_PORT"
EOF

echo "[INFO] Pod $POD_NAME created. Waiting for completion..."

# ---------------- Wait for pod to complete ----------------
kubectl wait --for=condition=Succeeded pod/$POD_NAME -n $NAMESPACE --timeout=-1s

# ---------------- Fetch logs ----------------
echo "[INFO] Fetching logs from $POD_NAME:"
kubectl logs $POD_NAME -n $NAMESPACE

# ---------------- Optional: delete pod after completion ----------------
# kubectl delete pod $POD_NAME -n $NAMESPACE

