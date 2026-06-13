#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${OUT_DIR:-$PWD/logs}"
MODE="${MODE:-UNKNOWN}"
TS="$(date +%Y%m%d_%H%M%S)"
RUNQLAT_FILE="$OUT_DIR/runqlat_${MODE}_${TS}.txt"
SUMMARY_CSV="$OUT_DIR/sched_latency_summary.csv"

mkdir -p "$OUT_DIR"

echo "[INFO] Collecting scheduler latency (runqlat equivalent)..."

if command -v bpftrace &>/dev/null; then
  # Collect scheduler latency histogram quietly
  sudo timeout 60 bpftrace -e 'tracepoint:sched:sched_switch { @[comm] = hist(nsecs/1000000); }' >"$RUNQLAT_FILE" 2>&1

  # Parse approximate average latency (ms)
  AVG_LAT_MS=$(awk '
    /^\[[0-9]+/ {
      gsub(/\[|\]/,"",$1)
      split($1,a,",")
      low=a[1]; high=a[2]; mid=(low+high)/2
      val=$2; gsub(/[^0-9]/,"",val)
      sum += mid * val; count += val
    }
    END {
      if (count>0) printf "%.2f", sum/count; else print "0"
    }' "$RUNQLAT_FILE")

else
  echo "[WARN] bpftrace not found, skipping actual runqlat capture."
  AVG_LAT_MS="N/A"
fi

# Append to summary CSV
if [ ! -f "$SUMMARY_CSV" ]; then
  echo "Mode,AvgSchedulerLatency_ms,Timestamp" > "$SUMMARY_CSV"
fi
echo "$MODE,$AVG_LAT_MS,$TS" >> "$SUMMARY_CSV"

echo "[INFO] Avg scheduler latency: ${AVG_LAT_MS} ms"
echo "[INFO] Log saved to: $RUNQLAT_FILE"
echo "[INFO] Summary CSV: $SUMMARY_CSV"

