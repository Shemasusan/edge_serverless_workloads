#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/cuda/bin:/usr/local/bin:$PATH"

PID=${PID:-$(pgrep -f deepstream-app | head -n1)}
MODE=${MODE:-native}
OUTDIR=${OUTDIR:-$PWD/logs}
mkdir -p "$OUTDIR"
OUTBASE="$OUTDIR/nsys_${MODE}_$(date +%Y%m%d_%H%M%S)"

echo "[INFO] Profiling PID=$PID with Nsight Systems (Jetson)"
sudo env "PATH=$PATH" nsys profile \
  --trace=cuda,nvtx,osrt \
  --attach-pid "$PID" \
  --duration 30 \
  --sample=none \
  --output "$OUTBASE"

echo "[OK] NSYS report: ${OUTBASE}.qdrep"

