#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${OUT_DIR:-$PWD/bench_logs}"
MODE="${MODE:-UNKNOWN}"
TS="$(date +%Y%m%d_%H%M%S)"
RUNQLAT_FILE="$OUT_DIR/runqlat_${MODE}_${TS}.txt"
SUMMARY_CSV="$OUT_DIR/sched_latency_summary.csv"

mkdir -p "$OUT_DIR"

# -------- runqlat equivalent --------
echo "[INFO] Collecting scheduler latency (runqlat equivalent) via bpftrace..."
sudo timeout 60 bpftrace -e 'tracepoint:sched:sched_switch { @[comm] = hist(nsecs/1000000); }' | tee "$RUNQLAT_FILE"

# ---- Parse approximate mean latency (ms) ----
AVG_LAT_MS=$(awk '/^\[[0-9]+/ { 
    split($1, a, "[\\[\\],]");
    low=a[2]; high=a[3]; mid=(low+high)/2;
    val=$2; gsub("[^0-9]", "", val);
    sum += mid * val; count += val;
} END { if (count>0) printf "%.2f", sum/count; else print "0"; }' "$RUNQLAT_FILE")

echo "[METRIC] Approx average scheduler latency: ${AVG_LAT_MS} ms"

# Append summary CSV
if [ ! -f "$SUMMARY_CSV" ]; then
  echo "Mode,AvgSchedulerLatency_ms,Timestamp" > "$SUMMARY_CSV"
fi
echo "$MODE,$AVG_LAT_MS,$TS" >> "$SUMMARY_CSV"

echo "[INFO] Saved latency summary to: $SUMMARY_CSV"
