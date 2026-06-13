#!/usr/bin/env bash
# =============================================================================
# check_setup.sh — Pre-flight file/environment checker
# Run from the root of either repo before executing any benchmark script.
#
# Usage:
#   cd ~/perception_infer_pipeline_native_node && bash check_setup.sh
#   cd ~/perception_infer_pipeline_container_node      && bash check_setup.sh
# =============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE_HINT="unknown"
[[ "$ROOT" == *native* ]]    && MODE_HINT="native"
[[ "$ROOT" == *container* ]] && MODE_HINT="container"

PASS=0
WARN=0
FAIL=0

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; (( PASS++ )) || true; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; (( WARN++ )) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; (( FAIL++ )) || true; }

section() { echo ""; echo -e "${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"; }

chk_file() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then ok "$label"; else fail "Missing file : $path"; fi
}
chk_exec() {
    local path="$1" label="${2:-$1}"
    if [[ -x "$path" ]]; then ok "$label (executable)";
    elif [[ -f "$path" ]]; then warn "$label exists but not executable — run: chmod +x $path";
    else fail "Missing file : $path"; fi
}
chk_dir() {
    local path="$1" label="${2:-$1}"
    if [[ -d "$path" ]]; then ok "$label"; else fail "Missing dir  : $path"; fi
}
chk_cmd() {
    local cmd="$1"
    if command -v "$cmd" &>/dev/null; then ok "command: $cmd  ($(command -v "$cmd"))";
    else warn "command not found: $cmd"; fi
}
chk_cmd_req() {
    local cmd="$1"
    if command -v "$cmd" &>/dev/null; then ok "command: $cmd  ($(command -v "$cmd"))";
    else fail "command not found: $cmd  ← required"; fi
}

# =============================================================================
echo ""
echo -e "${BOLD}check_setup.sh — DeepStream benchmark pre-flight${NC}"
echo "  Root : $ROOT"
echo "  Mode : $MODE_HINT (auto-detected from path)"
echo "  Date : $(date)"

# =============================================================================
section "1. Run scripts"
chk_exec "${ROOT}/bench_scripts/bench_common.sh"   "bench_scripts/bench_common.sh"
chk_exec "${ROOT}/run_scripts/make_video_and_host.py" "run_scripts/make_video_and_host.py"
chk_file "${ROOT}/run_scripts/summarize_ncu.py"    "run_scripts/summarize_ncu.py"

if [[ "$MODE_HINT" == "native" ]]; then
    chk_exec "${ROOT}/run_native.sh" "run_native.sh"
fi
if [[ "$MODE_HINT" == "container" ]]; then
    chk_exec "${ROOT}/run_container.sh" "run_container.sh"
    chk_exec "${ROOT}/bench_scripts/run_baseline.sh" "bench_scripts/run_baseline.sh"
fi

# =============================================================================
section "2. Configs"
chk_file "${ROOT}/configs/av_app.txt"         "configs/av_app.txt"
chk_file "${ROOT}/configs/pgie_config.txt"    "configs/pgie_config.txt"
chk_file "${ROOT}/configs/msgconv_config.txt" "configs/msgconv_config.txt"

# Runtime config should NOT exist yet (created at run time, cleaned up after)
if [[ -f "${ROOT}/configs/av_app_runtime.txt" ]]; then
    warn "configs/av_app_runtime.txt exists (leftover from a previous run — safe to delete)"
fi

# Verify pgie relative paths resolve from configs/
PGIE="${ROOT}/configs/pgie_config.txt"
if [[ -f "$PGIE" ]]; then
    CFG_DIR="${ROOT}/configs"
    for KEY in model-engine-file custom-lib-path labelfile-path onnx-file; do
        VAL=$(grep "^${KEY}" "$PGIE" | cut -d= -f2 | tr -d ' ' | head -1)
        [[ -z "$VAL" ]] && continue
        ABS=$(realpath "${CFG_DIR}/${VAL}" 2>/dev/null || echo "${CFG_DIR}/${VAL}")
        if [[ -f "$ABS" ]]; then
            ok "pgie ${KEY}: $VAL"
        else
            fail "pgie ${KEY} not found: $ABS"
        fi
    done
fi

# =============================================================================
section "3. Models"
chk_dir "${ROOT}/models" "models/"
# Engine file
ENGINE=$(grep "^model-engine-file" "${ROOT}/configs/pgie_config.txt" 2>/dev/null \
         | cut -d= -f2 | tr -d ' ' | head -1)
if [[ -n "$ENGINE" ]]; then
    ABS=$(realpath "${ROOT}/configs/${ENGINE}" 2>/dev/null || echo "${ROOT}/configs/${ENGINE}")
    if [[ -f "$ABS" ]]; then
        SIZE=$(du -h "$ABS" | cut -f1)
        ok "Engine file: $ENGINE ($SIZE)"
    else
        fail "Engine file not found: $ABS"
    fi
fi

# =============================================================================
section "4. DeepStream-Yolo custom library"
CUSTOM=$(grep "^custom-lib-path" "${ROOT}/configs/pgie_config.txt" 2>/dev/null \
         | cut -d= -f2 | tr -d ' ' | head -1)
if [[ -n "$CUSTOM" ]]; then
    ABS=$(realpath "${ROOT}/configs/${CUSTOM}" 2>/dev/null || echo "${ROOT}/configs/${CUSTOM}")
    chk_file "$ABS" "libnvdsinfer_custom_impl_Yolo.so"
fi

# =============================================================================
section "5. DeepStream native installation"
DS_BIN="/opt/nvidia/deepstream/deepstream-7.1/bin/deepstream-app"
DS_LIB="/opt/nvidia/deepstream/deepstream-7.1/lib"
chk_exec "$DS_BIN" "deepstream-app binary"
chk_dir  "$DS_LIB" "deepstream-7.1/lib"
chk_file "${DS_LIB}/libnvds_redis_proto.so" "libnvds_redis_proto.so"
chk_file "${DS_LIB}/libnvds_nvmultiobjecttracker.so" "libnvds_nvmultiobjecttracker.so"

if [[ "$MODE_HINT" == "native" ]]; then
    if "$DS_BIN" --version &>/dev/null; then
        VER=$("$DS_BIN" --version 2>&1 | head -1)
        ok "deepstream-app --version: $VER"
    else
        warn "deepstream-app --version failed (may need LD_LIBRARY_PATH set)"
    fi
fi

# =============================================================================
section "6. KITTI image directory"
if [[ "$MODE_HINT" == "native" ]]; then
    IMG_DIR="${ROOT}/data/2011_09_28/2011_09_28_drive_0001_extract/image_03/data"
else
    IMG_DIR="${ROOT}/2011_09_29/2011_09_29_drive_0071_extract/image_03/data"
fi
if [[ -d "$IMG_DIR" ]]; then
    COUNT=$(ls "$IMG_DIR"/*.png 2>/dev/null | wc -l)
    ok "KITTI image dir: $IMG_DIR ($COUNT PNG frames)"
    (( COUNT == 0 )) && warn "Directory exists but contains no .png files"
else
    fail "KITTI image dir not found: $IMG_DIR"
fi

# =============================================================================
section "7. Required system commands"
chk_cmd_req python3
chk_cmd_req perf
chk_cmd_req "/usr/bin/time"
chk_cmd_req redis-cli
chk_cmd_req curl
chk_cmd     nsys
chk_cmd     ncu
if [[ "$MODE_HINT" == "container" ]]; then
    chk_cmd_req docker
fi

# perf paranoid
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "unknown")
if [[ "$PARANOID" == "0" || "$PARANOID" == "-1" ]]; then
    ok "kernel.perf_event_paranoid=$PARANOID"
elif [[ "$PARANOID" == "1" ]]; then
    warn "kernel.perf_event_paranoid=1 — perf stat works but perf record may need sudo"
else
    warn "kernel.perf_event_paranoid=$PARANOID — run: sudo sysctl kernel.perf_event_paranoid=1"
fi

# Python deps
python3 -c "import pandas" 2>/dev/null && ok "python3: pandas available" \
    || fail "python3: pandas missing — run: pip3 install pandas --break-system-packages"

# =============================================================================
section "8. Redis"
if redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -q PONG; then
    ok "Redis reachable at 127.0.0.1:6379"
else
    fail "Redis not reachable at 127.0.0.1:6379 — run: sudo systemctl start redis-server"
fi

# =============================================================================
section "9. Output directories"
for d in logs perf bench_logs; do
    if [[ -d "${ROOT}/${d}" ]]; then
        COUNT=$(ls "${ROOT}/${d}" 2>/dev/null | wc -l)
        ok "${d}/  (exists, $COUNT files)"
    else
        warn "${d}/ does not exist — will be created at run time"
    fi
done

# gitignore check
if [[ -f "${ROOT}/.gitignore" ]]; then
    grep -q "av_app_runtime.txt" "${ROOT}/.gitignore" \
        && ok ".gitignore covers av_app_runtime.txt" \
        || warn ".gitignore missing 'configs/av_app_runtime.txt' — add it to avoid committing runtime config"
else
    warn "No .gitignore found"
fi

# =============================================================================
section "10. Container-specific checks"
if [[ "$MODE_HINT" == "container" ]]; then
    # Docker runtime
    if docker info 2>/dev/null | grep -q "nvidia"; then
        ok "Docker nvidia runtime available"
    else
        warn "nvidia runtime not visible in docker info — check /etc/docker/daemon.json"
    fi

    # Image present
    IMG="nvcr.io/nvidia/deepstream-l4t:7.1-samples-multiarch"
    if docker image inspect "$IMG" &>/dev/null; then
        ok "Docker image present: $IMG"
    else
        warn "Docker image not pulled: $IMG — run: docker pull $IMG"
    fi

    # ncu bind-mount path
    NCU_PATH="/usr/local/cuda-12.6/bin/ncu"
    chk_file "$NCU_PATH" "ncu binary for container bind-mount ($NCU_PATH)"

    # Nsight Compute dir
    chk_dir "/opt/nvidia/nsight-compute" "nsight-compute dir for container bind-mount"

    # GPU devices for privileged ncu container
    for dev in /dev/nvmap /dev/nvhost-gpu /dev/nvhost-as-gpu \
               /dev/nvhost-ctrl-gpu /dev/nvhost-prof-gpu; do
        if [[ -e "$dev" ]]; then ok "device: $dev"
        else warn "device not found: $dev (needed for privileged ncu container)"; fi
    done
else
    ok "(container checks skipped — native mode)"
fi

# =============================================================================
echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}PASS${NC} : $PASS"
echo -e "  ${YELLOW}WARN${NC} : $WARN"
echo -e "  ${RED}FAIL${NC} : $FAIL"
echo "════════════════════════════════════════════════════════════════"
if (( FAIL > 0 )); then
    echo -e "  ${RED}Fix FAIL items before running the benchmark.${NC}"
    exit 1
elif (( WARN > 0 )); then
    echo -e "  ${YELLOW}Review WARN items — benchmark may still run.${NC}"
    exit 0
else
    echo -e "  ${GREEN}All checks passed — ready to benchmark.${NC}"
    exit 0
fi
