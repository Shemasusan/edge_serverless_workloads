#!/usr/bin/env bash
set -euo pipefail
OUTDIR="${OUTDIR:-$PWD/logs}"
MODE="${MODE:-UNKNOWN}"
TAG="${TAG:-res1920x1080_fps30_modelyolov8n_bs1}"
INTERVAL_MS="${INTERVAL_MS:-100}"
DUR_SEC="${DUR_SEC:-600}"
RAW="$OUTDIR/tegrastats_${MODE}__${TAG}_$(date +%Y%m%d_%H%M%S).raw.log"
CSV="${RAW/.raw.log/.csv}"
mkdir -p "$OUTDIR"
sudo bash -c "tegrastats --interval ${INTERVAL_MS} --logfile $RAW & echo \$! > $RAW.pid"
PID=$(cat "$RAW.pid")
sleep "$DUR_SEC"
sudo kill "$PID" || true
sleep 0.2
awk -v OFS=',' '
  BEGIN { print "ts_ms","ram_used_mb","ram_total_mb","cpu_pct","gpu_gr3d_pct","emc_pct","gpu_clk_mhz","emc_clk_mhz","cpu_clk_mhz","temp_gpu_c","temp_cpu_c","power_in_mw" }
  {
    ts = systime()*1000
    match($0, /RAM[ ]+([0-9]+)\/([0-9]+)MB/, r); ru=r[1]; rt=r[2];
    cpu=""; if (match($0, /CPU *\[[^]]*\]/, c)) { cpu=c[0]; gsub(/CPU |\[|\]|@|%/,"",cpu); }
    match($0, /GR3D_FREQ[ ]+([0-9]+)%/, g); gr3d=g[1];
    match($0, /EMC_FREQ[ ]+([0-9]+)%/, e); emc=e[1];
    match($0, /GR3D_CLK[ ]+([0-9]+)MHz/, gc); gclk=gc[1];
    match($0, /EMC_CLK[ ]+([0-9]+)MHz/, ec); eclk=ec[1];
    match($0, /CPU@([0-9]+)MHz/, cc); cclk=cc[1];
    match($0, /GPU@([0-9]+)C/, tg); tGPU=tg[1];
    match($0, /CPU@([0-9]+)C/, tc); tCPU=tc[1];
    match($0, /(POM_5V_IN|VDD_IN): *([0-9]+)mW/, pw); pIn=pw[2];
    print ts,ru,rt,cpu,gr3d,emc,gclk,eclk,cclk,tGPU,tCPU,pIn
  }
' "$RAW" > "$CSV"
echo "RAW : $RAW"
echo "CSV : $CSV"
