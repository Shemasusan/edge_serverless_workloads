#!/usr/bin/env bash
set -euo pipefail

OUT="${OUT:-$PWD/logs/perf_${MODE:-UNKNOWN}_$(date +%Y%m%d_%H%M%S).stat.csv}"
INTERVAL_MS="${INTERVAL_MS:-2000}"
DURATION_SEC="${DURATION_SEC:-120}"
DELAY_MS="${DELAY_MS:-10000}"

events="task-clock,context-switches,cpu-migrations,cycles,instructions,branches,branch-misses,\
L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses"

mkdir -p "$(dirname "$OUT")"
echo "ts_ms,event,value" > "$OUT"

sleep "$(awk "BEGIN{print ${DELAY_MS}/1000}")"

sudo perf stat -a --no-big-num \
  --delay "$INTERVAL_MS" --interval-print "$INTERVAL_MS" \
  -e "$events" -- sleep "$DURATION_SEC" \
  2> >(awk '{
      gsub(/,/, "", $2);
      if ($3 ~ /[A-Za-z_-]+/)
        printf "%s,%s,%s\n", strftime("%s%3N"), $3, $2;
      fflush();
    }' >> "$OUT") >/dev/null

echo "[INFO] Perf top-level metrics written to: $OUT"

