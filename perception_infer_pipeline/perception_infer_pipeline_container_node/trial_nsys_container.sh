#!/usr/bin/env bash
# trial_nsys_container.sh — one-shot nsys trial inside privileged container
# Mirrors native: --trace=cuda,nvtx,osrt --sample=none wrapping deepstream-app directly
# Run from repo root: bash trial_nsys_container.sh <config_file>
# e.g.: bash trial_nsys_container.sh configs/av_app_runtime.txt

set -euo pipefail

DOCKER_IMG="nvcr.io/nvidia/deepstream-l4t:7.1-samples-multiarch"
NSYS_INSTALL="/opt/nvidia/nsight-systems/2024.5.4"
NSYS_BIN="${NSYS_INSTALL}/target-linux-tegra-armv8/nsys"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/perf/trial_nsys_$(date +%Y%m%d_%H%M%S)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <config_file>"
    exit 1
fi

CONFIG_FILE="$(realpath "$1")"
CONTAINER_CFG="/workspace/configs/$(basename "$CONFIG_FILE")"

echo "[TRIAL] nsys install : $NSYS_INSTALL"
echo "[TRIAL] nsys binary  : $NSYS_BIN"
echo "[TRIAL] config       : $CONFIG_FILE → $CONTAINER_CFG"
echo "[TRIAL] output       : ${OUT}.nsys-rep"
echo ""

# Sanity checks on host before launching container
[[ -f "$NSYS_BIN" ]]   || { echo "[ERROR] nsys binary not found at $NSYS_BIN"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "[ERROR] config not found: $CONFIG_FILE"; exit 1; }
mkdir -p "${ROOT}/perf"

docker run --rm \
    --runtime nvidia \
    --privileged \
    --pid=host \
    --network host \
    --cap-add SYS_ADMIN \
    --cap-add SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --log-driver=none \
    -v "${ROOT}":/workspace \
    -v "${NSYS_INSTALL}:${NSYS_INSTALL}:ro" \
    -w /workspace \
    -e LD_LIBRARY_PATH="/opt/nvidia/deepstream/deepstream-7.1/lib:/opt/nvidia/deepstream/deepstream-7.1/lib/gst-plugins" \
    -e GST_PLUGIN_PATH="/opt/nvidia/deepstream/deepstream-7.1/lib/gst-plugins" \
    "${DOCKER_IMG}" \
    bash -c "
        ${NSYS_BIN} profile \
            --trace=cuda,nvtx,osrt \
            --sample=none \
            --output /workspace/perf/$(basename "$OUT") \
            deepstream-app -c \"${CONTAINER_CFG}\"
    "

echo ""
echo "[TRIAL] Done. Checking output..."

NSYS_FILE="${OUT}.nsys-rep"
if [[ -f "$NSYS_FILE" ]]; then
    echo "[TRIAL] Found: $NSYS_FILE"
    echo "[TRIAL] Running nsys stats to check CUDA/NVTX presence..."
    nsys stats "$NSYS_FILE" 2>&1 | grep -E "SKIPPED|cuda_api_sum|nvtx_sum|Time \(%\)" | head -20
else
    echo "[ERROR] Output file not found: $NSYS_FILE"
    exit 1
fi
