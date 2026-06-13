#!/usr/bin/env bash
# =============================================================================
# run_scripts/serverless_entry.sh
# Entrypoint executed INSIDE the K3s pod on the Jetson node.
#
# Environment variables injected by the Job YAML:
#   MODE            serverless
#   RUN_ID          serverless_YYYYMMDD_HHMMSS
#   VIDEO_URL       http://192.168.100.1:<port>/output.mp4
#   IMG_DIR         path to KITTI image dir (on Jetson hostPath)
#   OUTPUT_BASE_DIR /workspace/runs/<RUN_ID>
#   NSYS_INSTALL    /opt/nvidia/nsight-systems/2024.5.4
#   NCU_INSTALL     /opt/nvidia/nsight-compute/2024.3.1
#   LD_LIBRARY_PATH set by YAML env
#   GST_PLUGIN_PATH set by YAML env
#
# Host binaries volume-mounted from Jetson:
#   /usr/bin/time   — GNU time
#   /usr/bin/perf   — host perf
#   /usr/bin/strace — strace
#   /opt/nvidia/deepstream/deepstream-7.1/lib  — DS libs
#   /usr/lib/aarch64-linux-gnu                 — system libs
#   /usr/local/cuda-12.6/targets/aarch64-linux/lib — CUDA libs
# =============================================================================
set +e
set -o pipefail

cd /workspace || { echo "[ERROR] /workspace not mounted"; exit 1; }

# ---------------------------------------------------------------------------
# Identity and paths
# ---------------------------------------------------------------------------
MODE="${MODE:-serverless}"
RUN_ID="${RUN_ID:-serverless_default}"
VIDEO_URL="${VIDEO_URL:-}"
OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-/workspace/runs/${RUN_ID}}"
NSYS_INSTALL="${NSYS_INSTALL:-/opt/nvidia/nsight-systems/2024.5.4}"
NCU_INSTALL="${NCU_INSTALL:-/opt/nvidia/nsight-compute/2024.3.1}"

GIT_HASH=$(git -C /workspace rev-parse --short HEAD 2>/dev/null || echo "no-git")

LOG_DIR="${OUTPUT_BASE_DIR}/logs"
PERF_DIR="${OUTPUT_BASE_DIR}/perf"
mkdir -p "$LOG_DIR" "$PERF_DIR"

LOGFILE="${LOG_DIR}/run_${RUN_ID}.log"
CSV_SUMMARY="${OUTPUT_BASE_DIR}/results_unified.csv"

exec > >(tee "$LOGFILE") 2>&1

echo "[INFO] ============================================================"
echo "[INFO] Mode     : $MODE"
echo "[INFO] Run ID   : $RUN_ID"
echo "[INFO] Git hash : $GIT_HASH"
echo "[INFO] Video URL: ${VIDEO_URL:-<not set>}"
echo "[INFO] Output   : $OUTPUT_BASE_DIR"
echo "[INFO] LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-<not set>}"
echo "[INFO] ============================================================"

# ---------------------------------------------------------------------------
# perf paranoid
# ---------------------------------------------------------------------------
if [[ -w /proc/sys/kernel/perf_event_paranoid ]]; then
    echo 0 > /proc/sys/kernel/perf_event_paranoid
    echo "[SETUP] perf_event_paranoid set to 0"
else
    echo "[WARN] Cannot write perf_event_paranoid — perf may be restricted"
fi

# ---------------------------------------------------------------------------
# Tool binaries — all volume-mounted from Jetson host
# ---------------------------------------------------------------------------
PERF_BIN="/usr/bin/perf"
TIME_BIN="/usr/bin/time"

[[ -x "$PERF_BIN" ]] && echo "[SETUP] perf  : $PERF_BIN" \
                      || { echo "[WARN] perf not found at $PERF_BIN"; PERF_BIN=""; }
[[ -x "$TIME_BIN" ]] && echo "[SETUP] time  : $TIME_BIN" \
                      || { echo "[ERROR] /usr/bin/time not found — cannot run timing pass" >&2; TIME_BIN=""; }

# ---------------------------------------------------------------------------
# DeepStream binary — in container image at /usr/bin/deepstream-app
# ---------------------------------------------------------------------------
DS_BIN="/usr/bin/deepstream-app"
[[ -x "$DS_BIN" ]] && echo "[SETUP] DS bin: $DS_BIN" \
                   || { echo "[ERROR] deepstream-app not found at $DS_BIN" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config — working copy in configs/ so relative paths resolve correctly
# ---------------------------------------------------------------------------
DS_CONFIG_SRC="/workspace/configs/av_app.txt"
DS_CONFIG="/workspace/configs/av_app_runtime_${RUN_ID}.txt"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
_preflight() {
    local fail=0

    echo "[PREFLIGHT] Checking environment..."

    [[ -f "$DS_CONFIG_SRC" ]] || \
        { echo "[PREFLIGHT FAIL] Missing: $DS_CONFIG_SRC" >&2; fail=1; }

    local CFG_DIR="/workspace/configs"
    local PGIE="${CFG_DIR}/pgie_config.txt"
    [[ -f "$PGIE" ]] || { echo "[PREFLIGHT FAIL] Missing: $PGIE" >&2; fail=1; }

    if [[ -f "$PGIE" ]]; then
        local ENGINE CUSTOM LABELS
        ENGINE=$(grep '^model-engine-file' "$PGIE" | cut -d= -f2 | tr -d ' ')
        CUSTOM=$(grep  '^custom-lib-path'  "$PGIE" | cut -d= -f2 | tr -d ' ')
        LABELS=$(grep  '^labelfile-path'   "$PGIE" | cut -d= -f2 | tr -d ' ')

        _resolve() {
            local p="$1"
            [[ "$p" = /* ]] && echo "$p" || echo "${CFG_DIR}/${p}"
        }

        local engine_abs custom_abs labels_abs
        engine_abs=$(realpath "$(_resolve "$ENGINE")" 2>/dev/null || _resolve "$ENGINE")
        custom_abs=$(realpath "$(_resolve "$CUSTOM")"  2>/dev/null || _resolve "$CUSTOM")
        labels_abs=$(realpath "$(_resolve "$LABELS")"  2>/dev/null || _resolve "$LABELS")

        [[ -f "$engine_abs" ]] || \
            { echo "[PREFLIGHT FAIL] Missing engine    : $engine_abs" >&2; fail=1; }
        [[ -f "$custom_abs" ]] || \
            { echo "[PREFLIGHT FAIL] Missing custom lib: $custom_abs" >&2; fail=1; }
        [[ -f "$labels_abs" ]] || \
            { echo "[PREFLIGHT FAIL] Missing labels    : $labels_abs" >&2; fail=1; }
    fi

    # Redis — TCP check (redis-cli not in image)
    if nc -z -w3 192.168.100.1 30079 2>/dev/null; then
        echo "[PREFLIGHT] Redis reachable at 192.168.100.1:30079"
    else
        echo "[PREFLIGHT WARN] Redis not reachable at 192.168.100.1:30079 — DS sink0 may fail"
    fi

    # Video URL
    if [[ -n "$VIDEO_URL" ]]; then
        if curl -sf --head "$VIDEO_URL" | grep -q "200 OK"; then
            echo "[PREFLIGHT] Video URL reachable: $VIDEO_URL"
        else
            echo "[PREFLIGHT FAIL] Video URL not reachable: $VIDEO_URL" >&2
            fail=1
        fi
    else
        echo "[PREFLIGHT FAIL] VIDEO_URL not set" >&2
        fail=1
    fi

    (( fail == 0 )) || { echo "[PREFLIGHT] Aborting." >&2; exit 1; }
    echo "[PREFLIGHT] All checks passed."
}

# ---------------------------------------------------------------------------
# Patch config
# ---------------------------------------------------------------------------
_patch_config() {
    cp "$DS_CONFIG_SRC" "$DS_CONFIG"
    sed -i "s|^uri=.*|uri=${VIDEO_URL}|" "$DS_CONFIG"
    sed -i "s|msg-broker-conn-str=.*|msg-broker-conn-str=192.168.100.1;30079|" "$DS_CONFIG"
    echo "[INFO] URI patched   → $DS_CONFIG  (uri=${VIDEO_URL})"
    echo "[INFO] Redis patched → 192.168.100.1:30079"
}

# ---------------------------------------------------------------------------
# CSV append
# ---------------------------------------------------------------------------
_append_csv() {
    local pass="$1"
    local lat="$2"  mem="$3"   cpu="$4"
    local ipc="$5"  cmiss="$6" bmiss="$7"
    local nsys_p="$8" pstat_p="$9" prec_p="${10}" ncu_p="${11}"

    local HDR="run_id,mode,pass,git_hash,latency_s,mem_mb,cpu_pct,ipc,cache_miss_pct,branch_misses_abs,nsys_path,perf_stat_path,perf_record_path,ncu_path"
    [[ -f "$CSV_SUMMARY" ]] || echo "$HDR" > "$CSV_SUMMARY"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$RUN_ID" "$MODE" "$pass" "$GIT_HASH" \
        "$lat" "$mem" "$cpu" \
        "$ipc" "$cmiss" "$bmiss" \
        "$nsys_p" "$pstat_p" "$prec_p" "$ncu_p" \
        >> "$CSV_SUMMARY"

    echo "[CSV] → $CSV_SUMMARY  run=$RUN_ID  pass=$pass"
}

# =============================================================================
# PASS: timing
# =============================================================================
_run_timing() {
    local TIME_LOG="${PERF_DIR}/time_${RUN_ID}.txt"
    local LOGFILE_PASS="${LOG_DIR}/run_${RUN_ID}_timing.log"
    local PERF_STAT="${PERF_DIR}/perf_stat_${RUN_ID}.csv"

    echo ""
    echo "[PASS: timing / sub-pass A] /usr/bin/time -v — single DS run..."

    local _START_NS _END_NS _DS_RC=0
    _START_NS=$(date +%s%N)

    if [[ -n "$TIME_BIN" ]]; then
        "$TIME_BIN" -v \
            bash -c 'exec "$0" -c "$1" >"$2" 2>&1' \
            "$DS_BIN" "$DS_CONFIG" "$LOGFILE_PASS" \
            2>"$TIME_LOG" || _DS_RC=$?
    else
        "$DS_BIN" -c "$DS_CONFIG" > "$LOGFILE_PASS" 2>&1 || _DS_RC=$?
    fi

    _END_NS=$(date +%s%N)

    echo "[INFO] --- DS output: first 30 lines ---"
    head -30 "$LOGFILE_PASS" 2>/dev/null || echo "(log empty)"
    echo "[INFO] --- DS output: last 30 lines ---"
    tail -30 "$LOGFILE_PASS" 2>/dev/null || true
    echo "[INFO] --- end DS output ---"

    if (( _DS_RC != 0 )); then
        echo "[WARN] deepstream-app exited code=${_DS_RC}."
        echo "[WARN]   code=1   → normal EOS pipeline drain (safe)"
        echo "[WARN]   code=255 → DS fatal error (Redis? engine? URI?)"
    fi

    if [[ -n "$PERF_BIN" ]]; then
        echo ""
        echo "[PASS: timing / sub-pass B] perf stat -r 3 — three DS runs (averaged)..."
        "$PERF_BIN" stat -x, -r 3 \
            -o "$PERF_STAT" \
            -e task-clock,context-switches,cpu-migrations,page-faults,\
cycles,instructions,branch-misses,cache-references,cache-misses \
            "$DS_BIN" -c "$DS_CONFIG" \
            >> "$LOGFILE_PASS" 2>&1 || true
    else
        echo "[PASS: timing / sub-pass B] perf not found — skipping."
        touch "$PERF_STAT"
    fi

    local _LAT_S _MEM_KB _MEM_MB _CPU_PCT
    _LAT_S=$(awk -v s="$_START_NS" -v e="$_END_NS" \
        'BEGIN {printf "%.3f", (e - s) / 1e9}')
    _MEM_KB=$(grep "Maximum resident set size" "$TIME_LOG" 2>/dev/null | awk '{print $NF}')
    _MEM_MB=$(awk "BEGIN {printf \"%.2f\", ${_MEM_KB:-0}/1024}")
    _CPU_PCT=$(grep "Percent of CPU this job got" "$TIME_LOG" 2>/dev/null | \
        awk '{print $NF}' | tr -d '%')

    local _IPC _CACHE_MISS_PCT _BRANCH_MISS_PCT
    _IPC=$(awk -F, '/instructions/ && $7 ~ /^[0-9]/ { printf "%.3f", $7+0; exit }' "$PERF_STAT" 2>/dev/null)
    _IPC="${_IPC:-N/A}"
    _CACHE_MISS_PCT=$(awk -F, '/cache-misses/ && $7 ~ /^[0-9]/ { printf "%.2f", $7+0; exit }' "$PERF_STAT" 2>/dev/null)
    _CACHE_MISS_PCT="${_CACHE_MISS_PCT:-N/A}"
    _BRANCH_MISS_PCT=$(awk -F, '/branch-misses/ && $1 ~ /^[0-9]/ { print $1+0; exit }' "$PERF_STAT" 2>/dev/null)
    _BRANCH_MISS_PCT="${_BRANCH_MISS_PCT:-N/A}"

    echo "[METRICS] Latency     : ${_LAT_S}s"
    echo "[METRICS] Memory (RSS): ${_MEM_MB} MB"
    echo "[METRICS] CPU util    : ${_CPU_PCT}%"
    echo "[METRICS] IPC         : ${_IPC}"
    echo "[METRICS] Cache miss  : ${_CACHE_MISS_PCT}%"
    echo "[METRICS] Branch misses (abs): ${_BRANCH_MISS_PCT}"
    echo "[PASS: timing] time log → $TIME_LOG  perf stat → $PERF_STAT"

    _append_csv "timing" \
        "$_LAT_S" "$_MEM_MB" "$_CPU_PCT" \
        "$_IPC" "$_CACHE_MISS_PCT" "$_BRANCH_MISS_PCT" \
        "N/A" "$PERF_STAT" "N/A" "N/A"
}

# =============================================================================
# PASS: nsys
# =============================================================================
_run_nsys() {
    local NSYS_OUT="${PERF_DIR}/nsys_${RUN_ID}"
    local LOGFILE_PASS="${LOG_DIR}/run_${RUN_ID}_nsys.log"
    local NSYS_BIN="${NSYS_INSTALL}/target-linux-tegra-armv8/nsys"

    if [[ ! -f "$NSYS_BIN" ]]; then
        echo "[PASS: nsys] nsys not found at $NSYS_BIN — skipping."
        _append_csv "nsys" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        return 0
    fi

    echo ""
    echo "[PASS: nsys] Nsight Systems profile (inside pod)..."
    "$NSYS_BIN" profile \
        --trace=cuda,nvtx,osrt \
        --sample=none \
        --output "$NSYS_OUT" \
        "$DS_BIN" -c "$DS_CONFIG" \
        > "$LOGFILE_PASS" 2>&1 \
    || echo "[WARN] nsys exited non-zero — check $LOGFILE_PASS"

    local NSYS_FILE="${NSYS_OUT}.nsys-rep"
    [[ -f "$NSYS_FILE" ]] || NSYS_FILE="${NSYS_OUT}.qdrep"
    [[ -f "$NSYS_FILE" ]] && echo "[PASS: nsys] Output: $NSYS_FILE" \
                          || echo "[WARN] nsys output file not found"

    _append_csv "nsys" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$NSYS_FILE" "N/A" "N/A" "N/A"
}

# =============================================================================
# PASS: perf_record
# =============================================================================
_run_perf_record() {
    local PERF_RECORD="${PERF_DIR}/perf_record_${RUN_ID}.data"
    local PERF_REPORT="${PERF_DIR}/perf_report_${RUN_ID}.txt"
    local LOGFILE_PASS="${LOG_DIR}/run_${RUN_ID}_perf_record.log"

    if [[ -z "$PERF_BIN" ]]; then
        echo "[PASS: perf_record] perf not found — skipping."
        _append_csv "perf_record" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        return 0
    fi

    echo ""
    echo "[PASS: perf_record] perf record..."
    "$PERF_BIN" record \
        -F 999 -g \
        --call-graph=dwarf \
        -o "$PERF_RECORD" \
        "$DS_BIN" -c "$DS_CONFIG" \
        > "$LOGFILE_PASS" 2>&1 \
    || echo "[WARN] perf record exited non-zero"

    echo "[PASS: perf_record] perf report..."
    "$PERF_BIN" report \
        --stdio \
        -i "$PERF_RECORD" \
        > "$PERF_REPORT" 2>&1 \
    || echo "[WARN] perf report failed"

    echo "[PASS: perf_record] data → $PERF_RECORD  report → $PERF_REPORT"
    _append_csv "perf_record" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$PERF_RECORD" "N/A"
}

# =============================================================================
# PASS: ncu
# =============================================================================
_run_ncu() {
    local NCU_OUT="${PERF_DIR}/ncu_${RUN_ID}.csv"
    local LOGFILE_PASS="${LOG_DIR}/run_${RUN_ID}_ncu.log"

    if [[ ! -d "$NCU_INSTALL" ]]; then
        echo "[PASS: ncu] nsight-compute not found at $NCU_INSTALL — skipping."
        _append_csv "ncu" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
        return 0
    fi

    echo ""
    echo "[PASS: ncu] Nsight Compute (slow, inside pod)..."
    "${NCU_INSTALL}/ncu" \
        --target-processes application-only \
        --launch-skip 0 \
        --launch-count 50 \
        --set full \
        --clock-control base \
        --csv \
        --log-file "$NCU_OUT" \
        "$DS_BIN" -c "$DS_CONFIG" \
        > "$LOGFILE_PASS" 2>&1 || true

    if [[ -f "$NCU_OUT" ]] && grep -q '"deepstream-app"' "$NCU_OUT" 2>/dev/null; then
        local _KERNEL_COUNT
        _KERNEL_COUNT=$(grep -c '"deepstream-app"' "$NCU_OUT" 2>/dev/null || echo 0)
        echo "[PASS: ncu] Output: $NCU_OUT  (${_KERNEL_COUNT} kernel rows)"
        _append_csv "ncu" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "$NCU_OUT"
        _summarize_ncu "$NCU_OUT"
    else
        echo "[WARN] ncu CSV empty or no kernels captured — check $LOGFILE_PASS"
        grep -i 'warn\|error' "$LOGFILE_PASS" 2>/dev/null | tail -10 || true
        _append_csv "ncu" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
    fi
}

_summarize_ncu() {
    local ncu_csv="$1"
    local summarizer="/workspace/run_scripts/summarize_ncu.py"
    local summary_out="${ncu_csv%.csv}_summary.txt"
    [[ -f "$ncu_csv" ]]    || { echo "[ncu-summary] CSV not found — skipping."; return 0; }
    [[ -f "$summarizer" ]] || { echo "[ncu-summary] summarize_ncu.py not found — skipping."; return 0; }
    echo "[ncu-summary] Generating summary → $summary_out"
    python3 "$summarizer" "$ncu_csv" "$summary_out" "$RUN_ID" || \
        echo "[ncu-summary] WARNING: summarizer exited non-zero"
    echo "[ncu-summary] Done."
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
_cleanup() {
    [[ -n "${DS_CONFIG:-}" && -f "$DS_CONFIG" ]] && rm -f "$DS_CONFIG"
    echo "[CLEANUP] Done."
}
trap '_cleanup' EXIT INT TERM

# =============================================================================
# Main
# =============================================================================
_preflight
_patch_config

echo ""
echo "===== PROFILING PASSES ============================================="
echo "  timing      : /usr/bin/time -v (1x DS) + perf stat -r3 (3x DS averaged)"
echo "  nsys        : Nsight Systems          (1x DS, inside pod)"
echo "  perf_record : perf record + report    (1x DS, inside pod)"
echo "  ncu         : Nsight Compute          (1x DS, inside pod)"
echo "===================================================================="
echo ""

_run_timing
_run_nsys
_run_perf_record
_run_ncu

echo ""
echo "===== SERVERLESS BENCHMARK COMPLETE ================================"
echo "  Mode    : $MODE"
echo "  Run ID  : $RUN_ID"
echo "  Logs    : ${LOG_DIR}/"
echo "  Perf    : ${PERF_DIR}/"
echo "  CSV     : ${CSV_SUMMARY}"
echo "===================================================================="
