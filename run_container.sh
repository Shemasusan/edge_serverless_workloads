#!/bin/bash
set -x

MODE=$1
RECORDS=$2
BATCH_SIZE=$3
PORT=8000
LOGFILE="run_metrics_${MODE}.log"
CSVFILE="result_container.csv"
IMAGE="shemathomas/jsontelemetry_multi_proc_sep:latest"
CONTAINER_NAME="jsontelemetry_run_$$"
DEBUG_MODE=false  # set to true for verbose curl

if [[ -z "$MODE" || -z "$RECORDS" || -z "$BATCH_SIZE" ]]; then
  echo "Usage: $0 {container_st|container_mt} <no_of_records> <batch_size>"
  exit 1
fi

if [[ "$MODE" == "container_st" ]]; then
  export THREADED=false
  export CORE_COUNT=1
  export FILES_TO_GENERATE=$BATCH_SIZE
elif [[ "$MODE" == "container_mt" ]]; then
  export THREADED=true
  export CORE_COUNT=$BATCH_SIZE
  export FILES_TO_GENERATE=$BATCH_SIZE
else
  echo "[ERROR] Invalid mode: $MODE"
  exit 1
fi

export COUNT=$RECORDS

mkdir -p data/input data/output
rm -f data/output/*.json "$LOGFILE"

echo "[INFO] Generating JSON files..."
python3 -m app_generate_data.generate_data

echo "[INFO] Running processing workload..."

# Free the port if in use
BUSY_CONTAINERS=$(docker ps --filter "publish=$PORT" --format '{{.ID}}')
if [[ -n "$BUSY_CONTAINERS" ]]; then
  echo "[WARN] Port $PORT is in use by container(s): $BUSY_CONTAINERS"
  echo "[INFO] Stopping container(s) to free port..."
  docker stop $BUSY_CONTAINERS
fi

echo "[INFO] Pulling Docker image: $IMAGE"
docker pull $IMAGE

echo "[INFO] Starting container..."
START_SPINUP=$(date +%s%N)
CONTAINER_ID=$(docker run -d --name $CONTAINER_NAME -p $PORT:8000 -v "$(pwd)/data/output:/app/data/output" $IMAGE)

# Wait for container to start running
echo "[INFO] Waiting for container to start..."
until docker inspect -f '{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null | grep true > /dev/null; do
  sleep 0.5
done

# Wait for FastAPI app to be ready by checking /status returns 'idle'
echo "[INFO] Waiting for API readiness (status == idle)..."
while true; do
  STATUS=$(curl -s http://localhost:$PORT/status | jq -r '.status')
  if [[ "$STATUS" == "idle" ]]; then
    break
  fi
  sleep 0.5
done

END_SPINUP=$(date +%s%N)
SPINUP_TIME_SEC=$(echo "scale=3; ($END_SPINUP - $START_SPINUP)/1000000000" | bc)

echo "[INFO] Container is up:"
docker ps --filter "name=$CONTAINER_NAME" --format '{{.ID}} {{.Status}}'

# Start docker stats collection
echo "[INFO] Starting docker stats collection..."
: > stats.log
(
  while docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" -q | grep -q .; do
    docker stats $CONTAINER_NAME --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" >> stats.log
    sleep 0.5
  done
) &
STATS_PID=$!

# ---------- Trigger Workload ----------
echo "[INFO] Triggering workload via API..."
TRIGGER_PAYLOAD=$(printf '{"core_count": %s, "mode": "%s", "threaded": %s}' "$CORE_COUNT" "$MODE" "$THREADED")
START_LATENCY=$(date +%s%N)

if [[ "$DEBUG_MODE" == true ]]; then
  curl -v -X POST http://localhost:$PORT/run \
    -H "Content-Type: application/json" \
    -d "$TRIGGER_PAYLOAD"
else
  curl -s -X POST http://localhost:$PORT/run \
    -H "Content-Type: application/json" \
    -d "$TRIGGER_PAYLOAD" > /dev/null
fi

# ---------- Wait for Completion ----------
echo "[INFO] Waiting for workload to complete via /status polling..."
while true; do
  STATUS=$(curl -s http://localhost:$PORT/status | jq -r '.status')
  if [[ "$STATUS" == "done" ]]; then
    break
  fi
  sleep 0.5
done
END_LATENCY=$(date +%s%N)
LATENCY_SEC=$(echo "scale=3; ($END_LATENCY - $START_LATENCY)/1000000000" | bc)

# ---------- Cleanup ----------
kill $STATS_PID || true

echo "[INFO] Stopping container..."
START_SPINDOWN=$(date +%s%N)
docker stop $CONTAINER_NAME > /dev/null
END_SPINDOWN=$(date +%s%N)
SPINDOWN_TIME_SEC=$(echo "scale=3; ($END_SPINDOWN - $START_SPINDOWN)/1000000000" | bc)

docker rm $CONTAINER_NAME > /dev/null

# ---------- Collect Metrics ----------
CPU_UTIL=$(awk -F',' '{print $1}' stats.log | tr -d '%' | sort -nr | head -1)
MEM_UTIL_RAW=$(awk -F',' '{print $2}' stats.log | sort | tail -1)

MEM_UTIL_MB="N/A"
if [[ $MEM_UTIL_RAW =~ ([0-9.]+)([MG])iB ]]; then
  val=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]}
  if [[ "$unit" == "M" ]]; then
    MEM_UTIL_MB=$val
  elif [[ "$unit" == "G" ]]; then
    MEM_UTIL_MB=$(echo "$val * 1024" | bc)
  fi
fi

# ---------- Print & Save Metrics ----------
echo ""
echo "===== METRICS ====="
echo "Spin-up Time (s):    $SPINUP_TIME_SEC"
echo "Latency (s):         $LATENCY_SEC"
echo "Spin-down Time (s):  $SPINDOWN_TIME_SEC"
echo "CPU Utilization (%): $CPU_UTIL"
echo "Memory Usage (MB):   $MEM_UTIL_MB"

if [ ! -f "$CSVFILE" ]; then
  echo "Workload,Records,BatchSize,Threads,Spinup_s,Latency_s,Spindown_s,CPU_Util_Percent,Memory_MB" >> "$CSVFILE"
fi

echo "$MODE,$RECORDS,$BATCH_SIZE,$CORE_COUNT,$SPINUP_TIME_SEC,$LATENCY_SEC,$SPINDOWN_TIME_SEC,$CPU_UTIL,$MEM_UTIL_MB" >> "$CSVFILE"

echo ""
echo "[INFO] Output metric JSON files (computed stats) available in data/output/ directory."

