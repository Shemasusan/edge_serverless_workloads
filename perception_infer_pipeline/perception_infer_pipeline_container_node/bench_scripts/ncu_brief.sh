#!/usr/bin/env bash
set -euo pipefail
PID=${PID:-$(pgrep -f deepstream-app | head -n1)}
MODE=${MODE:-native}
TAG=${TAG:-brief}
OUTDIR=${OUTDIR:-$PWD/logs}
mkdir -p "$OUTDIR"
BASE="$OUTDIR/ncu_${MODE}_${TAG}_$(date +%Y%m%d_%H%M%S)"
METRICS="sm__throughput.avg.pct_of_peak_sustained_elapsed,\
sm__warps_active.avg.pct_of_peak_sustained_active,\
l1tex__t_bytes.sum.per_second,\
lts__t_bytes.sum.per_second,\
dram__bytes.sum.per_second"

echo "[INFO] Profiling PID=$PID with Nsight Compute (Jetson)"
sudo env "PATH=$PATH" ncu \
  --target-processes all \
  --metrics "$METRICS" \
  --csv \
  --log-file "${BASE}.csv" \
  --launch-skip 10 \
  --launch-count 5 \
  --duration 30 \
  --set default \
  --profile-from-start off \
  --pid "$PID"

echo "[OK] NCU log written: ${BASE}.csv"

