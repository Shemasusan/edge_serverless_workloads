#!/usr/bin/env bash
set -euo pipefail

# ---------- PID detection ----------
if [[ -z "${PID:-}" ]]; then
  PID=$(pgrep -f deepstream-app | head -n1 || true)
  if [[ -z "$PID" ]]; then
    echo "[ERROR] Could not auto-detect DeepStream PID."
    exit 1
  fi
  echo "[WARN] PID not provided, auto-detected DeepStream PID: $PID"
fi

# ---------- Paths and defaults ----------
OUT_PROC="${OUT_PROC:-$PWD/logs/perf_proc_${MODE:-UNKNOWN}_$(date +%Y%m%d_%H%M%S).csv}"
OUT_CORE="${OUT_CORE:-$PWD/logs/perf_core_${MODE:-UNKNOWN}_$(date +%Y%m%d_%H%M%S).csv}"
INTERVAL_MS="${INTERVAL_MS:-2000}"
DURATION_SEC="${DURATION_SEC:-120}"
events="cycles,instructions,cache-misses,branches,branch-misses"

mkdir -p "$(dirname "$OUT_PROC")" "$(dirname "$OUT_CORE")"

# ---------- Per-process metrics ----------
echo "ts_ms,event,value" > "$OUT_PROC"
sudo perf stat --no-big-num -p "$PID" \
  --delay "$INTERVAL_MS" --interval-print "$INTERVAL_MS" \
  -e "$events" -- sleep "$DURATION_SEC" \
  2> >(awk '{
      gsub(/,/, "", $2);
      t = strftime("%s") * 1000;   # seconds → ms
      printf "%d,%s,%s\n", t, $3, $2;
      fflush();
    }' >> "$OUT_PROC") >/dev/null

# ---------- Per-core metrics ----------
echo "ts_ms,cpu,event,value" > "$OUT_CORE"
sudo perf stat --no-big-num -C 2-5 \
  --delay "$INTERVAL_MS" --interval-print "$INTERVAL_MS" \
  -e "$events" -- sleep "$DURATION_SEC" \
  2> >(awk '{
      gsub(/,/, "", $2);
      ev = $3; cpu = "";
      if (match($0, /\[.(\d+)\]/, m)) cpu = m[1];
      t = strftime("%s") * 1000;
      printf "%d,%s,%s,%s\n", t, cpu, ev, $2;
      fflush();
    }' >> "$OUT_CORE") >/dev/null

echo "[INFO] Perf process/core metrics written to:"
echo "  $OUT_PROC"
echo "  $OUT_CORE"

