#!/usr/bin/env bash
# =============================================================================
# run_serverless.sh — DeepStream benchmarking, K3s serverless execution
# Lives at: perception_infer_pipeline_new_iml_perf_serverless_claude/
#           (on control host plane)
#
# Usage:  ./run_serverless.sh <image_directory> [IMAGE_TAG]
#
# What this script does (runs on camsin-8):
#   1. Start HTTP video host on camsin-8 LAN IP (reachable by Jetson pod)
#   2. Generate a per-run K3s Job YAML targeting node: ubuntu (Jetson)
#   3. Submit job via kubectl, stream pod logs
#   4. Wait for job completion
#   5. Outputs land on Jetson/node at:
#          <node_mount_directory>
#       eg:/home/camsin-nano/perception_infer_pipeline_new_iml_perf_native_claude_serverless/
#            runs/<RUN_ID>/logs/
#            runs/<RUN_ID>/perf/
#            runs/<RUN_ID>/results_unified.csv
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <image_directory> [IMAGE_TAG]"
    echo "  image_directory : absolute path on Jetson to KITTI image_0N/data/"
    echo "  IMAGE_TAG       : optional Docker image (default: nvcr.io/nvidia/deepstream-l4t:7.1-samples-multiarch)"
    exit 1
fi

IMG_DIR="$1"
DOCKER_IMG="${2:-nvcr.io/nvidia/deepstream-l4t:7.1-samples-multiarch}"

# ---------------------------------------------------------------------------
# Run identity
# ---------------------------------------------------------------------------
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_ID="serverless_${RUN_TS}"
RUN_ID_K8S=$(echo "$RUN_ID" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
JOB_NAME="ds-bench-${RUN_ID_K8S}"

# ---------------------------------------------------------------------------
# Paths on control plane (camsin-8)
# ---------------------------------------------------------------------------
ROOT="$(pwd)"
K3S_DIR="${ROOT}/k3s"
LOG_DIR="${ROOT}/logs"
mkdir -p "$K3S_DIR" "$LOG_DIR"

LOGFILE="${LOG_DIR}/run_${RUN_ID}.log"
YAML_FILE="${K3S_DIR}/${JOB_NAME}.yaml"

exec > >(tee "$LOGFILE") 2>&1

# ---------------------------------------------------------------------------
# Paths on Jetson (hostPath → /workspace in pod)
# Change JETSON_WORKSPACE as <node_mount_directory>
# ---------------------------------------------------------------------------
JETSON_WORKSPACE="/home/camsin-nano/perception_infer_pipeline_new_iml_perf_native_claude_serverless"
JETSON_RUNS_DIR="${JETSON_WORKSPACE}/runs"

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
CONTROL_IP="192.168.100.1"
VIDEO_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
VIDEO_URL="http://${CONTROL_IP}:${VIDEO_PORT}/output.mp4"

echo "[INFO] ============================================================"
echo "[INFO] Mode     : serverless"
echo "[INFO] Run ID   : $RUN_ID"
echo "[INFO] Job name : $JOB_NAME"
echo "[INFO] Image    : $DOCKER_IMG"
echo "[INFO] Control  : $(hostname) (${CONTROL_IP})"
echo "[INFO] Worker   : ubuntu (Jetson node)"
echo "[INFO] Workspace: $JETSON_WORKSPACE"
echo "[INFO] ============================================================"

# ---------------------------------------------------------------------------
# perf paranoid
# ---------------------------------------------------------------------------
echo "[SETUP] Setting kernel.perf_event_paranoid=0 ..."
echo 0 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null || true

# ---------------------------------------------------------------------------
# Trap
# ---------------------------------------------------------------------------
_HOST_PID=""
# Trap — only delete job on abort, NOT video host
_cleanup() {
    echo "[CLEANUP] Deleting K3s job (if exists)..."
    kubectl delete job "$JOB_NAME" --ignore-not-found 2>/dev/null || true
    echo "[CLEANUP] Stopping video host..."
    [[ -n "$_HOST_PID" ]] && kill "$_HOST_PID" 2>/dev/null || true
    echo "[CLEANUP] Done."
}
trap '_cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# Step 0 — Start HTTP video host on camsin-8
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 0] Starting HTTP video host on ${CONTROL_IP}:${VIDEO_PORT} ..."
sudo fuser -k "${VIDEO_PORT}/tcp" 2>/dev/null || true
sleep 1

python3 "${ROOT}/run_scripts/make_video_and_host.py" \
    --input_dir "$IMG_DIR" \
    --fps 10 \
    --port "$VIDEO_PORT" &
_HOST_PID=$!
echo "[INFO] Video host PID: $_HOST_PID  URL: $VIDEO_URL"

echo "[WAIT] Waiting for video host..."
for i in $(seq 1 200); do
    if curl -sf --head "$VIDEO_URL" | grep -q "200 OK"; then
        echo "[READY] Video host up after ${i}s."
        break
    fi
    if ! kill -0 "$_HOST_PID" 2>/dev/null; then
        echo "[ERROR] Video host process died. Aborting." >&2
        exit 1
    fi
    if (( i == 200 )); then
        echo "[ERROR] Video host not reachable after 200s. Aborting." >&2
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Step 1 — Generate K3s Job YAML
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 1] Generating Job YAML: ${YAML_FILE} ..."

cat > "$YAML_FILE" << YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  labels:
    run-id: "${RUN_ID}"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: deepstream-bench
        job-name: ${JOB_NAME}
        run-id: "${RUN_ID}"
    spec:
      nodeName: ubuntu
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      hostPID: true
      hostIPC: true
      restartPolicy: Never
      runtimeClassName: nvidia

      containers:
      - name: deepstream
        image: ${DOCKER_IMG}
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        workingDir: /workspace
        command: ["/bin/bash", "/workspace/run_scripts/serverless_entry.sh"]

        env:
        - name: MODE
          value: "serverless"
        - name: RUN_ID
          value: "${RUN_ID}"
        - name: VIDEO_URL
          value: "${VIDEO_URL}"
        - name: IMG_DIR
          value: "${IMG_DIR}"
        - name: OUTPUT_BASE_DIR
          value: "/workspace/runs/${RUN_ID}"
        - name: NSYS_INSTALL
          value: "/opt/nvidia/nsight-systems/2024.5.4"
        - name: NCU_INSTALL
          value: "/opt/nvidia/nsight-compute/2024.3.1"
        - name: LD_LIBRARY_PATH
          value: "/usr/lib/aarch64-linux-gnu:/usr/local/cuda-12.6/targets/aarch64-linux/lib:/opt/nvidia/deepstream/deepstream-7.1/lib:/opt/nvidia/deepstream/deepstream-7.1/lib/gst-plugins"
        - name: GST_PLUGIN_PATH
          value: "/opt/nvidia/deepstream/deepstream-7.1/lib/gst-plugins"

        volumeMounts:
        - name: workspace
          mountPath: /workspace
        - name: ds-lib
          mountPath: /opt/nvidia/deepstream/deepstream-7.1/lib
        - name: aarch64-lib
          mountPath: /usr/lib/aarch64-linux-gnu
        - name: cuda-lib
          mountPath: /usr/local/cuda-12.6/targets/aarch64-linux/lib
        - name: nsight-systems
          mountPath: /opt/nvidia/nsight-systems/2024.5.4
        - name: nsight-compute
          mountPath: /opt/nvidia/nsight-compute/2024.3.1
        - name: time-bin
          mountPath: /usr/bin/time
        - name: perf-bin
          mountPath: /usr/bin/perf
        - name: strace-bin
          mountPath: /usr/bin/strace
        - name: dev-nvmap
          mountPath: /dev/nvmap
        - name: dev-nvhost-gpu
          mountPath: /dev/nvhost-gpu
        - name: dev-nvhost-as-gpu
          mountPath: /dev/nvhost-as-gpu
        - name: dev-nvhost-ctrl-gpu
          mountPath: /dev/nvhost-ctrl-gpu
        - name: dev-nvhost-prof-gpu
          mountPath: /dev/nvhost-prof-gpu

      volumes:
      - name: workspace
        hostPath:
          path: ${JETSON_WORKSPACE}
          type: Directory
      - name: ds-lib
        hostPath:
          path: /opt/nvidia/deepstream/deepstream-7.1/lib
      - name: aarch64-lib
        hostPath:
          path: /usr/lib/aarch64-linux-gnu
      - name: cuda-lib
        hostPath:
          path: /usr/local/cuda-12.6/targets/aarch64-linux/lib
      - name: nsight-systems
        hostPath:
          path: /opt/nvidia/nsight-systems/2024.5.4
          type: DirectoryOrCreate
      - name: nsight-compute
        hostPath:
          path: /opt/nvidia/nsight-compute/2024.3.1
          type: DirectoryOrCreate
      - name: time-bin
        hostPath:
          path: /usr/bin/time
          type: File
      - name: perf-bin
        hostPath:
          path: /usr/lib/linux-tools/5.15.0-160-generic/perf
          type: File
      - name: strace-bin
        hostPath:
          path: /usr/bin/strace
          type: File
      - name: dev-nvmap
        hostPath:
          path: /dev/nvmap
      - name: dev-nvhost-gpu
        hostPath:
          path: /dev/nvhost-gpu
      - name: dev-nvhost-as-gpu
        hostPath:
          path: /dev/nvhost-as-gpu
      - name: dev-nvhost-ctrl-gpu
        hostPath:
          path: /dev/nvhost-ctrl-gpu
      - name: dev-nvhost-prof-gpu
        hostPath:
          path: /dev/nvhost-prof-gpu
YAML

echo "[INFO] YAML written."

# ---------------------------------------------------------------------------
# Step 2 — Submit job
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 2] Submitting job..."
kubectl apply -f "$YAML_FILE"

# ---------------------------------------------------------------------------
# Step 3 — Wait for pod
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 3] Waiting for pod..."
POD_NAME=""
for i in $(seq 1 120); do
    POD_NAME=$(kubectl get pods \
        --selector="job-name=${JOB_NAME}" \
        --output=jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$POD_NAME" ]]; then
        echo "[WAIT] No pod yet (${i}s)..."
        sleep 2
        continue
    fi
    PHASE=$(kubectl get pod "$POD_NAME" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "[WAIT] Pod=${POD_NAME} phase=${PHASE}"
    if [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
        break
    fi
    if (( i == 120 )); then
        echo "[ERROR] Pod did not start within 240s. Aborting." >&2
        kubectl describe pod "$POD_NAME" 2>/dev/null | tail -30 || true
        exit 1
    fi
    sleep 2
done

# ---------------------------------------------------------------------------
# Step 4 — Stream pod logs
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 4] Streaming pod logs (kubectl logs -f)..."
kubectl logs -f "$POD_NAME" || true

# ---------------------------------------------------------------------------
# Step 5 — Wait for job completion
# ---------------------------------------------------------------------------
echo ""
echo "[STEP 5] Waiting for job completion (timeout 30min)..."
if kubectl wait "job/${JOB_NAME}" \
    --for=condition=complete \
    --timeout=1800s 2>/dev/null; then
    echo "[INFO] Job completed successfully."
else
    FINAL_PHASE=$(kubectl get pod "$POD_NAME" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$FINAL_PHASE" == "Succeeded" ]]; then
        echo "[INFO] Job succeeded (detected via pod phase)."
    else
        echo "[WARN] Job did not complete cleanly (phase=${FINAL_PHASE})."
        kubectl logs "$POD_NAME" 2>/dev/null | tail -30 || true
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "===== SERVERLESS BENCHMARK COMPLETE ================================"
echo "  Mode     : serverless"
echo "  Run ID   : $RUN_ID"
echo "  Job      : $JOB_NAME"
echo "  YAML     : $YAML_FILE"
echo "  Ctrl log : $LOGFILE"
echo ""
echo "  Outputs on Jetson:"
echo "    Logs  : ${JETSON_RUNS_DIR}/${RUN_ID}/logs/"
echo "    Perf  : ${JETSON_RUNS_DIR}/${RUN_ID}/perf/"
echo "    CSV   : ${JETSON_RUNS_DIR}/${RUN_ID}/results_unified.csv"
echo "===================================================================="
