#!/usr/bin/env bash
# =============================================================================
# run_native.sh  —  DeepStream benchmarking, native Jetson execution
# Lives at: perception_infer_pipeline_new_iml_perf_native/run_native.sh
#
# Usage:  ./run_native.sh
#
# Depends on: bench_scripts/bench_common.sh  (sourced below)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Repo root — always the directory this script lives in
# ---------------------------------------------------------------------------
export ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MODE="native"

# ---------------------------------------------------------------------------
# DeepStream binary — native path
# ---------------------------------------------------------------------------
export DS_BIN="/opt/nvidia/deepstream/deepstream-7.1/bin/deepstream-app"

# ---------------------------------------------------------------------------
# Canonical config (bench_common makes a /tmp working copy — this is never modified)
# ---------------------------------------------------------------------------
export DS_CONFIG_SRC="${ROOT}/configs/av_app.txt"

# ---------------------------------------------------------------------------
# Video host
# ---------------------------------------------------------------------------
export VIDEO_PORT=8080
export VIDEO_HOST_IP="192.168.100.12"   # Jetson LAN IP

# ---------------------------------------------------------------------------
# KITTI image directory
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# KITTI image directory (passed as first argument)
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <image_directory>"
    exit 1
fi

export IMG_DIR="$1"
#export IMG_DIR="${ROOT}/data/2011_09_28/2011_09_28_drive_0001_extract/image_03/data"
# Swap to the other drive if needed:
# export IMG_DIR="/home/camsin-nano/perception_infer_pipeline_new_iml_perf_container/2011_09_29/2011_09_29_drive_0071_extract/image_03/data"

# ---------------------------------------------------------------------------
# Source shared library
# LD_LIBRARY_PATH and GST_PLUGIN_PATH are exported inside bench_common.sh
# before any subprocess is launched.
# ---------------------------------------------------------------------------
# shellcheck source=bench_scripts/bench_common.sh
source "${ROOT}/bench_scripts/bench_common.sh"

# ---------------------------------------------------------------------------
# Trap — bench_cleanup kills the video host and removes the /tmp config copy
# even if set -e fires mid-run
# ---------------------------------------------------------------------------
trap 'bench_cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
bench_init
bench_preflight

bench_start_video          # sets VIDEO_URL
bench_patch_uri "$VIDEO_URL"  # creates DS_CONFIG in /tmp with uri= stamped

echo ""
echo "===== PROFILING PASSES ============================================="
echo "  timing      : /usr/bin/time -v (1x DS) + perf stat -r3 (3x DS averaged)"
echo "  nsys        : Nsight Systems          (1x DS)"
echo "  perf_record : perf record + report    (1x DS)"
echo "  ncu         : Nsight Compute          (1x DS, optional)"
echo "===================================================================="
echo ""

bench_run_timing
bench_run_nsys
bench_run_perf_record
bench_run_ncu

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "===== NATIVE BENCHMARK COMPLETE ===================================="
echo "  Mode    : $MODE"
echo "  Run ID  : $_RUN_ID"
echo "  Logs    : ${ROOT}/logs/"
echo "  Perf    : ${ROOT}/perf/"
echo "  CSV     : ${ROOT}/results_unified.csv"
echo "===================================================================="
