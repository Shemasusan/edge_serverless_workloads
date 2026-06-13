#!/usr/bin/env bash
# =============================================================================
# bench_scripts/bench_common.sh
# Sourced by run_native.sh / run_container.sh / run_k8s.sh (all at repo root)
#
# Callers must export before sourcing:
#   MODE            native | container | k8s
#   ROOT            absolute path to repo root  ($PWD in each run script)
#   DS_BIN          path/wrapper for deepstream-app
#   DS_CONFIG_SRC   configs/av_app.txt  (canonical, never modified)
#   VIDEO_PORT      HTTP port for video host
#   VIDEO_HOST_IP   IP deepstream-app uses to reach the video host
#   IMG_DIR         KITTI image_0N/data/ directory
# =============================================================================

# Guard: must be sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: bench_common.sh must be sourced, not executed directly." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Fixed repo-relative paths  (all callers set ROOT before sourcing)
# ---------------------------------------------------------------------------
LOG_DIR="${ROOT}/logs"
PERF_DIR="${ROOT}/perf"
CSV_SUMMARY="${ROOT}/results_unified.csv"
RUN_SCRIPTS_DIR="${ROOT}/run_scripts"

# ---------------------------------------------------------------------------
# DeepStream environment — exported here, before any subprocess is launched
# ---------------------------------------------------------------------------
DS_LIB="/opt/nvidia/deepstream/deepstream-7.1/lib"
DS_GST="${DS_LIB}/gst-plugins"
export LD_LIBRARY_PATH="${DS_LIB}:${DS_GST}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export GST_PLUGIN_PATH="${DS_GST}${GST_PLUGIN_PATH:+:${GST_PLUGIN_PATH}}"

# ---------------------------------------------------------------------------
# Internal state (set by bench_init)
# ---------------------------------------------------------------------------
_HOST_PID=""
_TS=""
_RUN_ID=""
_GIT_HASH=""
_START_NS=""
_END_NS=""
_LAT_S="N/A"; _MEM_MB="N/A"; _CPU_PCT="N/A"
_IPC="N/A"; _CACHE_MISS_PCT="N/A"; _BRANCH_MISS_PCT="N/A"
PERF_STAT=""
VIDEO_URL=""
DS_CONFIG=""   # working copy path, set by bench_patch_uri

# =============================================================================
# bench_init
# =============================================================================
bench_init() {
    mkdir -p "$LOG_DIR" "$PERF_DIR"
    _TS=$(date +%Y%m%d_%H%M%S)
    _RUN_ID="${MODE}_${_TS}"
    _GIT_HASH=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "no-git")

    echo "[INFO] ============================================================"
    echo "[INFO] Mode     : $MODE"
    echo "[INFO] Run ID   : $_RUN_ID"
    echo "[INFO] Git hash : $_GIT_HASH"
    echo "[INFO] DS binary: $DS_BIN"
    echo "[INFO] Config   : $DS_CONFIG_SRC"
    echo "[INFO] IMG dir  : $IMG_DIR"
    echo "[INFO] ============================================================"
}

# =============================================================================
# bench_preflight
# Verifies all assets before touching the pipeline.
# Aborts on any missing required asset.
# =============================================================================
bench_preflight() {
    local fail=0

    _chk_file()  { [[ -f "$1" ]] || { echo "[PREFLIGHT FAIL] Missing file    : $1" >&2; fail=1; }; }
    _chk_dir()   { [[ -d "$1" ]] || { echo "[PREFLIGHT FAIL] Missing dir     : $1" >&2; fail=1; }; }
    _chk_exec()  { [[ -x "$1" ]] || { echo "[PREFLIGHT FAIL] Not executable  : $1" >&2; fail=1; }; }
    _chk_cmd()   { command -v "$1" &>/dev/null || { echo "[PREFLIGHT FAIL] Missing command : $1" >&2; fail=1; }; }

    echo "[PREFLIGHT] Checking environment..."

    # DeepStream binary (or wrapper for container/k8s)
    _chk_exec "$DS_BIN"

    # Canonical app config
    _chk_file "$DS_CONFIG_SRC"

    # pgie config and its assets — paths in pgie_config.txt are relative to configs/
    local CFG_DIR="${ROOT}/configs"
    local PGIE="${CFG_DIR}/pgie_config.txt"
    _chk_file "$PGIE"

    if [[ -f "$PGIE" ]]; then
        local ENGINE CUSTOM LABELS
        ENGINE=$(grep '^model-engine-file' "$PGIE" | cut -d= -f2 | tr -d ' ')
        CUSTOM=$(grep '^custom-lib-path'   "$PGIE" | cut -d= -f2 | tr -d ' ')
        LABELS=$(grep '^labelfile-path'    "$PGIE" | cut -d= -f2 | tr -d ' ')
        # Resolve from configs/ (that is pgie_config.txt's own directory)
        _chk_file "$(realpath "${CFG_DIR}/${ENGINE}" 2>/dev/null || echo "${CFG_DIR}/${ENGINE}")"
        _chk_file "$(realpath "${CFG_DIR}/${CUSTOM}"  2>/dev/null || echo "${CFG_DIR}/${CUSTOM}")"
        _chk_file "$(realpath "${CFG_DIR}/${LABELS}"  2>/dev/null || echo "${CFG_DIR}/${LABELS}")"
    fi

    # KITTI image directory
    _chk_dir "$IMG_DIR"

    # Python + video host script
    _chk_cmd python3
    _chk_file "${RUN_SCRIPTS_DIR}/make_video_and_host.py"

    # Redis — required by the nvmsgbroker sink (sink0 in native, sink1 in container)
    # Both configs target 127.0.0.1:6379. With --network host this works for container too.
    if ! redis-cli -h 127.0.0.1 -p 6379 ping &>/dev/null; then
        echo "[PREFLIGHT FAIL] Redis not reachable at 127.0.0.1:6379" \
             "— required by msg-broker-conn-str in av_app.txt" >&2
        fail=1
    fi

    # Profiling tools — hard required
    for cmd in perf /usr/bin/time; do
        _chk_cmd "$cmd"
    done

    # Optional profiling tools — warn only
    for cmd in nsys ncu; do
        command -v "$cmd" &>/dev/null || \
            echo "[PREFLIGHT WARN] $cmd not found — that pass will be skipped"
    done

    # perf paranoid setting
    local paranoid
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "99")
    if (( paranoid > 1 )); then
        echo "[PREFLIGHT WARN] kernel.perf_event_paranoid=${paranoid}" \
             "— run: sudo sysctl kernel.perf_event_paranoid=1"
    fi

    (( fail == 0 )) || { echo "[PREFLIGHT] Aborting — fix the issues above first." >&2; exit 1; }
    echo "[PREFLIGHT] All required assets OK."
}

# =============================================================================
# bench_patch_uri
# Creates a runtime working copy of av_app.txt with uri= stamped to VIDEO_URL.
#
# CRITICAL: The working copy must live in the SAME directory as av_app.txt
# (i.e. configs/) so that all relative paths inside it resolve correctly:
#   config-file=../configs/pgie_config.txt   → resolves from configs/ → OK
#   msg-conv-config=../configs/msgconv_config.txt → same
#
# Copying to /tmp/ breaks this: ../configs/ from /tmp/ → /configs/ (missing).
#
# Working copy: configs/av_app_runtime.txt  (gitignored, cleaned up on exit)
# DS_CONFIG_SRC (configs/av_app.txt) is never modified.
# Sets the global DS_CONFIG variable used by all bench_run_* functions.
# =============================================================================
bench_patch_uri() {
    local url="$1"
    local CFG_DIR
    CFG_DIR=$(dirname "$DS_CONFIG_SRC")
    DS_CONFIG="${CFG_DIR}/av_app_runtime.txt"
    cp "$DS_CONFIG_SRC" "$DS_CONFIG"
    sed -i "s|^uri=.*|uri=${url}|" "$DS_CONFIG"
    echo "[INFO] URI patched → $DS_CONFIG  (uri=${url})"
}

# =============================================================================
# bench_start_video
# Launches make_video_and_host.py on VIDEO_HOST_IP:VIDEO_PORT.
# Polls up to 200 s for HTTP 200 OK. Aborts if the host process dies early.
# Sets the global VIDEO_URL variable.
# =============================================================================
bench_start_video() {
    local url="http://${VIDEO_HOST_IP}:${VIDEO_PORT}/output.mp4"

    echo "[STEP 0] Starting HTTP video host (port ${VIDEO_PORT})..."
    sudo fuser -k "${VIDEO_PORT}/tcp" 2>/dev/null || true
    sleep 1

    # Redirect HTTP server stderr to a log file — suppresses ConnectionResetError
    # noise from DS closing TCP connections at EOS. The errors are harmless
    # (DS finishes the MP4 and drops the connection) but clutter the terminal.
    local _HTTP_ERRLOG="${LOG_DIR}/http_server_${_RUN_ID}.log"
    python3 "${RUN_SCRIPTS_DIR}/make_video_and_host.py" \
        --input_dir "$IMG_DIR" \
        --fps 10 \
        --port "$VIDEO_PORT" \
        2>>"${_HTTP_ERRLOG:-/tmp/http_server.log}" &
    _HOST_PID=$!
    echo "[INFO] Video host PID: $_HOST_PID  URL: $url"

    local i
    for i in $(seq 1 200); do
        if curl -sf --head "$url" | grep -q "200 OK"; then
            echo "[READY] Video host reachable after ${i}s."
            VIDEO_URL="$url"
            return 0
        fi
        if ! kill -0 "$_HOST_PID" 2>/dev/null; then
            echo "[ERROR] Video host process (PID $_HOST_PID) died. Aborting." >&2
            exit 1
        fi
        sleep 1
    done

    echo "[ERROR] Video host not reachable after 200s. Aborting." >&2
    kill "$_HOST_PID" 2>/dev/null || true
    exit 1
}

# =============================================================================
# bench_stop_video
# =============================================================================
bench_stop_video() {
    if [[ -n "$_HOST_PID" ]]; then
        kill "$_HOST_PID" 2>/dev/null || true
        wait "$_HOST_PID" 2>/dev/null || true
        _HOST_PID=""
        echo "[INFO] Video host stopped."
    fi
}

# =============================================================================
# bench_run_timing
#
# Two independent sub-passes — both use the same DS_CONFIG working copy:
#
#   sub-pass A (/usr/bin/time -v):
#     Runs deepstream-app ONCE.
#     stderr → TIME_LOG (dedicated file, unambiguous grep).
#     stdout → LOGFILE.
#     start_ns/end_ns wraps this invocation → LAT_S.
#     RSS and CPU% extracted from TIME_LOG.
#
#   sub-pass B (perf stat -r 3):
#     Runs deepstream-app THREE TIMES and averages — intentional (user confirmed).
#     Output → PERF_STAT CSV.
#     IPC / cache-miss% / branch-miss% extracted from PERF_STAT.
#
# Both sub-passes are recorded as a single "timing" row in results_unified.csv.
# =============================================================================
bench_run_timing() {
    local TIME_LOG="${PERF_DIR}/time_${_RUN_ID}.txt"
    local LOGFILE="${LOG_DIR}/run_${_RUN_ID}_timing.log"
    PERF_STAT="${PERF_DIR}/perf_stat_${_RUN_ID}.csv"

    echo ""
    echo "[PASS: timing / sub-pass A] /usr/bin/time -v — single DS run..."
    _START_NS=$(date +%s%N)

    # /usr/bin/time stderr → TIME_LOG exclusively (no perf output mixed in).
    # DS stdout+stderr  → LOGFILE.
    # deepstream-app commonly exits 1 after EOS — capture exit code, do NOT
    # let set -e abort the script here.
    local _DS_RC=0

    # Stderr split strategy:
    #   /usr/bin/time -v reports to its own stderr.
    #   deepstream-app stdout+stderr must go to LOGFILE for DS diagnostics.
    #   We pass DS_BIN, DS_CONFIG, LOGFILE as positional args to bash -c so
    #   there are no quoting hazards with paths containing spaces.
    #     $0 = DS_BIN, $1 = DS_CONFIG, $2 = LOGFILE
    #   bash -c runs DS with its stdout+stderr → LOGFILE.
    #   /usr/bin/time wraps bash -c; time's own stderr → TIME_LOG.
    /usr/bin/time -v \
        bash -c 'exec "$0" -c "$1" >"$2" 2>&1' \
        "$DS_BIN" "$DS_CONFIG" "$LOGFILE" \
        2>"$TIME_LOG" || _DS_RC=$?

    _END_NS=$(date +%s%N)

    # Always print DS output so failures are immediately visible in terminal
    echo "[INFO] --- DS output: first 30 lines ---"
    head -30 "$LOGFILE" 2>/dev/null || echo "(log empty)"
    echo "[INFO] --- DS output: last 30 lines ---"
    tail -30 "$LOGFILE" 2>/dev/null || true
    echo "[INFO] --- end DS output ---"

    if (( _DS_RC != 0 )); then
        echo "[WARN] deepstream-app exited code=${_DS_RC}."
        echo "[WARN]   code=1   → normal EOS pipeline drain (safe to continue)"
        echo "[WARN]   code=255 → DS fatal error (Redis down? engine missing? URI wrong?)"
        echo "[WARN] Metric extraction will proceed — RSS/CPU still captured by time."
    fi

    echo "[PASS: timing / sub-pass B] perf stat -r 3 — three DS runs (averaged)..."
    perf stat -x, -r 3 \
        -o "$PERF_STAT" \
        -e task-clock,context-switches,cpu-migrations,page-faults,\
cycles,instructions,branch-misses,cache-references,cache-misses \
        "$DS_BIN" -c "$DS_CONFIG" \
        >> "$LOGFILE" 2>&1 || true

    # --- Extract from TIME_LOG (single, unambiguous source)
    _LAT_S=$(awk -v s="$_START_NS" -v e="$_END_NS" 'BEGIN {printf "%.3f", (e - s) / 1e9}')
    _MEM_KB=$(grep "Maximum resident set size" "$TIME_LOG" | awk '{print $NF}')
    _MEM_MB=$(awk "BEGIN {printf \"%.2f\", ${_MEM_KB:-0}/1024}")
    _CPU_PCT=$(grep "Percent of CPU this job got" "$TIME_LOG" | awk '{print $NF}' | tr -d '%')

    # --- Extract derived perf stat values from CSV
    # perf stat -x, CSV layout: value,unit,event,variance,run-count,run-pct,metric-value,metric-unit
    # Use perf's own pre-computed metric values ($7) — correct cycle reference, no rounding skew.

    # IPC: "insn per cycle" from the instructions row, field 7
    _IPC=$(awk -F, '
        /instructions/ && $7 ~ /^[0-9]/ { printf "%.3f", $7+0; exit }
    ' "$PERF_STAT")
    _IPC="${_IPC:-N/A}"

    # Cache miss %: "of all cache refs" from the cache-misses row, field 7
    _CACHE_MISS_PCT=$(awk -F, '
        /cache-misses/ && $7 ~ /^[0-9]/ { printf "%.2f", $7+0; exit }
    ' "$PERF_STAT")
    _CACHE_MISS_PCT="${_CACHE_MISS_PCT:-N/A}"

    # Branch misses: absolute count from field 1 (branches hw counter unsupported on Jetson PMU)
    _BRANCH_MISS_PCT=$(awk -F, '
        /branch-misses/ && $1 ~ /^[0-9]/ { print $1+0; exit }
    ' "$PERF_STAT")
    _BRANCH_MISS_PCT="${_BRANCH_MISS_PCT:-N/A}"
    echo "[METRICS] Latency     : ${_LAT_S}s"
    echo "[METRICS] Memory (RSS): ${_MEM_MB} MB"
    echo "[METRICS] CPU util    : ${_CPU_PCT}%"
    echo "[METRICS] IPC         : ${_IPC}"
    echo "[METRICS] Cache miss  : ${_CACHE_MISS_PCT}%"
    echo "[METRICS] Branch misses (abs): ${_BRANCH_MISS_PCT}"
    echo "[PASS: timing] time log → $TIME_LOG  perf stat → $PERF_STAT"

    bench_append_csv "timing" \
        "$_LAT_S" "$_MEM_MB" "$_CPU_PCT" \
        "$_IPC" "$_CACHE_MISS_PCT" "$_BRANCH_MISS_PCT" \
        "N/A" "$PERF_STAT" "N/A" "N/A"
}

# =============================================================================
# bench_run_nsys
# Separate DS run. Nsight Systems must be the outermost wrapper.
# Guards with || true — a missing or unlicensed nsys does not abort the run.
# Note: existing perf/ files use .nsys-rep (Nsight Systems ≥ 2022.x naming).
# =============================================================================
bench_run_nsys() {
    local NSYS_OUT="${PERF_DIR}/nsys_${_RUN_ID}"
    local LOGFILE="${LOG_DIR}/run_${_RUN_ID}_nsys.log"

    if ! command -v nsys &>/dev/null; then
        echo "[PASS: nsys] nsys not found — skipping."
        bench_append_csv "nsys" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" \
            "N/A" "N/A" "N/A" "N/A"
        return 0
    fi

    echo ""
    echo "[PASS: nsys] Nsight Systems profile..."
    sudo nsys profile \
        --trace=cuda,nvtx,osrt \
        --sample=none \
        --output "$NSYS_OUT" \
        "$DS_BIN" -c "$DS_CONFIG" \
        > "$LOGFILE" 2>&1 \
    || echo "[WARN] nsys exited non-zero — check $LOGFILE"

    # Nsight Systems ≥ 2022 writes .nsys-rep; older versions write .qdrep
    local NSYS_FILE="${NSYS_OUT}.nsys-rep"
    [[ -f "$NSYS_FILE" ]] || NSYS_FILE="${NSYS_OUT}.qdrep"
    echo "[PASS: nsys] Output: $NSYS_FILE"

    bench_append_csv "nsys" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" \
        "$NSYS_FILE" "N/A" "N/A" "N/A"
}

# =============================================================================
# bench_run_perf_record
# Separate DS run. perf record + report.
# =============================================================================
bench_run_perf_record() {
    local PERF_RECORD="${PERF_DIR}/perf_record_${_RUN_ID}.data"
    local PERF_REPORT="${PERF_DIR}/perf_report_${_RUN_ID}.txt"
    local LOGFILE="${LOG_DIR}/run_${_RUN_ID}_perf_record.log"

    echo ""
    echo "[PASS: perf_record] perf record..."
    sudo perf record \
        -F 999 -g \
        --call-graph=dwarf \
        -o "$PERF_RECORD" \
        "$DS_BIN" -c "$DS_CONFIG" \
        > "$LOGFILE" 2>&1 \
    || echo "[WARN] perf record exited non-zero — check paranoid setting"

    echo "[PASS: perf_record] perf report..."
    sudo perf report \
        --stdio \
        -i "$PERF_RECORD" \
        > "$PERF_REPORT" 2>&1 \
    || echo "[WARN] perf report failed — data file may be incomplete"

    echo "[PASS: perf_record] data → $PERF_RECORD  report → $PERF_REPORT"

    bench_append_csv "perf_record" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" \
        "N/A" "N/A" "$PERF_RECORD" "N/A"
}

# =============================================================================
# bench_run_ncu
# Separate DS run. Optional — skipped if ncu is absent.
# =============================================================================
bench_run_ncu() {
    local NCU_OUT="${PERF_DIR}/ncu_${_RUN_ID}.csv"
    local LOGFILE="${LOG_DIR}/run_${_RUN_ID}_ncu.log"

    if ! command -v ncu &>/dev/null; then
        echo "[PASS: ncu] ncu not found — skipping."
        bench_append_csv "ncu" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" \
            "N/A" "N/A" "N/A" "N/A"
        return 0
    fi

    # Create a looping config for ncu so DS runs until ncu captures enough kernels.
    # Without file-loop=1 DS finishes in ~3s (native) at full GPU throughput,
    # and ncu misses all kernels.
    local _NCU_CFG
    _NCU_CFG="$(dirname "$DS_CONFIG")/av_app_ncu_loop.txt"
    cp "$DS_CONFIG" "$_NCU_CFG"
    sed -i '/^uri=/a file-loop=1' "$_NCU_CFG"

    echo ""
    echo "[PASS: ncu] Nsight Compute — DS running with file-loop=1 for steady-state capture..."
    sudo ncu \
        --target-processes application-only \
        --launch-skip 200 \
        --launch-count 50 \
        --set full \
        --csv \
        --log-file "$NCU_OUT" \
        "$DS_BIN" -c "$_NCU_CFG" \
        > "$LOGFILE" 2>&1 \
    || echo "[WARN] ncu exited non-zero — check $LOGFILE"

    rm -f "$_NCU_CFG"

    echo "[PASS: ncu] Output: $NCU_OUT"

    bench_append_csv "ncu" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" \
        "N/A" "N/A" "N/A" "$NCU_OUT"

    # Auto-summarise the NCU report immediately after collection
    bench_summarize_ncu "$NCU_OUT"
}

# =============================================================================
# bench_summarize_ncu
# Called after bench_run_ncu. Runs summarize_ncu.py and writes a .txt summary
# alongside the CSV. Skips silently if the CSV is missing or python3 fails.
# =============================================================================
bench_summarize_ncu() {
    local ncu_csv="$1"
    local summarizer="${ROOT}/run_scripts/summarize_ncu.py"

    if [[ ! -f "$ncu_csv" ]]; then
        echo "[ncu-summary] CSV not found — skipping summary."
        return 0
    fi
    if [[ ! -f "$summarizer" ]]; then
        echo "[ncu-summary] summarize_ncu.py not found at $summarizer — skipping."
        return 0
    fi

    local summary_out="${ncu_csv%.csv}_summary.txt"
    echo "[ncu-summary] Generating summary → $summary_out"
    python3 "$summarizer" "$ncu_csv" "$summary_out" "$_RUN_ID" || {
        echo "[ncu-summary] WARNING: summarizer exited non-zero — check $summary_out"
        return 0
    }
    echo "[ncu-summary] Done."
}

# =============================================================================
# bench_append_csv
# One row per profiling pass. Keyed by (run_id, pass) for cross-mode comparison.
#
# Columns:
#   run_id, mode, pass, git_hash,
#   latency_s, mem_mb, cpu_pct,
#   ipc, cache_miss_pct, branch_miss_pct,
#   nsys_path, perf_stat_path, perf_record_path, ncu_path
# =============================================================================
bench_append_csv() {
    local pass="$1"
    local lat="$2"   mem="$3"    cpu="$4"
    local ipc="$5"   cmiss="$6"  bmiss="$7"
    local nsys_p="$8" pstat_p="$9" prec_p="${10}" ncu_p="${11}"

    local HDR="run_id,mode,pass,git_hash,latency_s,mem_mb,cpu_pct,ipc,cache_miss_pct,branch_misses_abs,nsys_path,perf_stat_path,perf_record_path,ncu_path"
    [[ -f "$CSV_SUMMARY" ]] || echo "$HDR" > "$CSV_SUMMARY"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_RUN_ID" "$MODE" "$pass" "$_GIT_HASH" \
        "$lat" "$mem" "$cpu" \
        "$ipc" "$cmiss" "$bmiss" \
        "$nsys_p" "$pstat_p" "$prec_p" "$ncu_p" \
        >> "$CSV_SUMMARY"

    echo "[CSV] → $CSV_SUMMARY  run=$_RUN_ID  pass=$pass"
}

# =============================================================================
# bench_cleanup  — safe to call multiple times; registered via trap
# =============================================================================
bench_cleanup() {
    bench_stop_video
    # Remove runtime config working copy (configs/av_app_runtime.txt)
    if [[ -n "${DS_CONFIG:-}" && -f "$DS_CONFIG" ]]; then
        rm -f "$DS_CONFIG"
    fi
    echo "[CLEANUP] Done."
}
