#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-NATIVE}"
TAG="${TAG:-default}"
DUR_TOTAL="${DUR_TOTAL:-60}"
ROOT="$PWD"
SCRIPTS="$ROOT/bench_scripts"
LOG="$ROOT/bench_logs"
mkdir -p "$LOG"

# Find DeepStream PID if already running
DS_PID=$(pgrep -f deepstream-app | head -n1 || true)

if [[ -n "$DS_PID" ]]; then
  echo "[INFO] Attaching profilers to DeepStream PID: $DS_PID"

  # Tegrastats
  MODE="$MODE" TAG="$TAG" OUTDIR="$LOG" DUR_SEC="$DUR_TOTAL" bash "$SCRIPTS/tegrastats_collect.sh" &

  # PID-scoped perf
  OUT_PROC="$LOG/perf_proc_${MODE}_${TAG}.csv" OUT_CORE="$LOG/perf_core_${MODE}_${TAG}.csv"
  bash "$SCRIPTS/perf_process_core.sh" PID="$DS_PID" OUT_PROC="$OUT_PROC" OUT_CORE="$OUT_CORE" &

  # Nsight Systems (timeline)
  ( sleep $((DUR_TOTAL/2)); bash "$SCRIPTS/nsys_attach.sh" MODE="$MODE" TAG="$TAG" PID="$DS_PID" DUR=30 OUTDIR="$LOG" ) &

  # Nsight Compute (kernel metrics)
  ( sleep $((DUR_TOTAL/2)); bash "$SCRIPTS/ncu_brief.sh" MODE="$MODE" TAG="$TAG" PID="$DS_PID" OUTDIR="$LOG" ) &

  # Scheduler latency
  bash "$SCRIPTS/runqlat.sh" MODE="$MODE" OUT_DIR="$LOG" &

  # Hotspots (short perf record)
  ( sleep 15; bash "$SCRIPTS/perf_hotspots.sh" MODE="$MODE" PID="$DS_PID" OUT_DIR="$LOG" ) &
else
  echo "[WARN] No DeepStream PID found — skipping profiler attach."
fi

