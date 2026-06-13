#!/usr/bin/env python3
"""
summarize_ncu.py — Nsight Compute CSV summariser
Called automatically at the end of each benchmark run by bench_common.sh.

Usage:
    python3 run_scripts/summarize_ncu.py <ncu_csv> <output_summary_txt> [run_id]

Produces a human-readable summary covering:
  1. Run metadata
  2. Per-kernel roofline position (SM% and Memory% throughput)
  3. Per-kernel IPC and occupancy
  4. Bottleneck rules (OPT/WRN with estimated speedup %)
  5. Top opportunities ranked by estimated speedup
  6. Overall hotspot ranking by elapsed cycles
"""

import sys
import os
import pandas as pd
from datetime import datetime

# ---------------------------------------------------------------------------
def load_ncu_csv(path: str) -> pd.DataFrame:
    """
    NCU CSV has 1-2 ==PROF== header lines before the column row.
    Find the real header line by looking for the 'ID' column.
    """
    with open(path) as f:
        lines = f.readlines()
    skip = 0
    for i, line in enumerate(lines):
        if line.startswith('"ID"') or line.startswith('ID,'):
            skip = i
            break
    df = pd.read_csv(path, skiprows=skip)
    # Strip commas from numeric strings (NCU formats 305,513,416.94)
    def clean_num(v):
        s = str(v).replace(",", "")
        try:
            return float(s)
        except ValueError:
            return float("nan")
    df["_NumVal"] = df["Metric Value"].apply(clean_num)
    return df

# ---------------------------------------------------------------------------
def shorten_kernel(name: str, maxlen: int = 72) -> str:
    """Strip template args for readability."""
    # Keep everything up to the first '<' or '(' then truncate
    short = name.split("<")[0].split("(")[0].strip()
    if len(name) <= maxlen:
        return name
    return short[:maxlen] + "…"

# ---------------------------------------------------------------------------
def pivot_metric(df: pd.DataFrame, section: str, metric: str) -> pd.Series:
    """Return a Series keyed by Kernel Name for one section+metric."""
    mask = (df["Section Name"] == section) & (df["Metric Name"] == metric)
    sub = df[mask][["Kernel Name", "_NumVal"]].dropna()
    # Average across launches if multiple
    return sub.groupby("Kernel Name")["_NumVal"].mean()

# ---------------------------------------------------------------------------
def build_summary(df: pd.DataFrame, run_id: str) -> str:
    lines = []
    W = 80

    def hr(ch="═"): lines.append(ch * W)
    def section(title): hr(); lines.append(f"  {title}"); hr()
    def blank(): lines.append("")

    # ── Header ──────────────────────────────────────────────────────────────
    hr("═")
    lines.append(f"  Nsight Compute — Benchmark Summary")
    lines.append(f"  Run ID  : {run_id}")
    lines.append(f"  Source  : {os.path.basename(sys.argv[1])}")
    lines.append(f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    hr("═")
    blank()

    # ── 1. Run metadata ──────────────────────────────────────────────────────
    n_kernels = df["Kernel Name"].nunique()
    n_launches = len(df[df["Metric Name"] == df["Metric Name"].iloc[0]])
    device = df["Device"].dropna().iloc[0] if "Device" in df.columns else "unknown"
    cc     = df["CC"].dropna().iloc[0]     if "CC"     in df.columns else "unknown"

    section("1. Run Metadata")
    lines.append(f"  Device            : {device}")
    lines.append(f"  Compute capability: {cc}")
    lines.append(f"  Unique kernels    : {n_kernels}")
    lines.append(f"  Total metric rows : {len(df)}")
    blank()

    # ── 2. Roofline position per kernel ─────────────────────────────────────
    sm_pct  = pivot_metric(df, "GPU Speed Of Light Throughput", "Compute (SM) Throughput")
    mem_pct = pivot_metric(df, "GPU Speed Of Light Throughput", "Memory Throughput")
    cycles  = pivot_metric(df, "GPU Speed Of Light Throughput", "Elapsed Cycles")
    dur_us  = pivot_metric(df, "GPU Speed Of Light Throughput", "Duration")

    section("2. Roofline Position (% of peak throughput)")
    hdr = f"  {'Kernel':<52}  {'SM%':>6}  {'Mem%':>6}  {'Bound':<8}  {'Cycles':>12}"
    lines.append(hdr)
    lines.append("  " + "-" * (W - 2))

    kernels_by_cycles = cycles.sort_values(ascending=False).index.tolist()
    for k in kernels_by_cycles:
        sm  = sm_pct.get(k, float("nan"))
        mem = mem_pct.get(k, float("nan"))
        cyc = cycles.get(k, float("nan"))
        bound = "balanced"
        if not (pd.isna(sm) or pd.isna(mem)):
            if sm > mem + 10:
                bound = "compute"
            elif mem > sm + 10:
                bound = "memory"
        sm_s  = f"{sm:6.1f}" if not pd.isna(sm)  else "   N/A"
        mem_s = f"{mem:6.1f}" if not pd.isna(mem) else "   N/A"
        cyc_s = f"{int(cyc):>12,}" if not pd.isna(cyc) else "           N/A"
        lines.append(f"  {shorten_kernel(k, 52):<52}  {sm_s}  {mem_s}  {bound:<8}  {cyc_s}")
    blank()

    # ── 3. IPC and occupancy per kernel ─────────────────────────────────────
    ipc_active = pivot_metric(df, "Compute Workload Analysis", "Executed Ipc Active")
    ipc_elap   = pivot_metric(df, "Compute Workload Analysis", "Executed Ipc Elapsed")
    occupancy  = pivot_metric(df, "Occupancy", "Achieved Occupancy")

    section("3. IPC and Occupancy")
    hdr = f"  {'Kernel':<52}  {'IPC-Act':>7}  {'IPC-Elp':>7}  {'Occup%':>6}"
    lines.append(hdr)
    lines.append("  " + "-" * (W - 2))
    for k in kernels_by_cycles:
        ia  = ipc_active.get(k, float("nan"))
        ie  = ipc_elap.get(k, float("nan"))
        occ = occupancy.get(k, float("nan"))
        ia_s  = f"{ia:7.3f}"  if not pd.isna(ia)  else "    N/A"
        ie_s  = f"{ie:7.3f}"  if not pd.isna(ie)  else "    N/A"
        occ_s = f"{occ:6.1f}" if not pd.isna(occ) else "   N/A"
        lines.append(f"  {shorten_kernel(k, 52):<52}  {ia_s}  {ie_s}  {occ_s}")
    blank()

    # ── 4. Bottleneck rules ──────────────────────────────────────────────────
    rules = df[
        df["Rule Name"].notna() &
        (df["Rule Name"].astype(str) != "") &
        (df["Rule Name"].astype(str) != "nan")
    ].copy()

    section("4. Bottleneck Rules (OPT = optimisation opportunity, WRN = warning)")
    if rules.empty:
        lines.append("  No rules found in this report.")
    else:
        rules["_SpeedupNum"] = pd.to_numeric(
            rules["Estimated Speedup"].astype(str).str.replace(",", ""), errors="coerce"
        )
        # Deduplicate per kernel × rule
        rules_dedup = rules.drop_duplicates(subset=["Kernel Name", "Rule Name"])
        # Sort: WRN first, then OPT by speedup desc
        rules_dedup = rules_dedup.sort_values(
            ["Rule Type", "_SpeedupNum"], ascending=[True, False]
        )
        hdr = f"  {'Kernel':<42}  {'Rule':<30}  {'Type':>4}  {'Speedup%':>8}"
        lines.append(hdr)
        lines.append("  " + "-" * (W - 2))
        for _, row in rules_dedup.iterrows():
            k   = shorten_kernel(str(row["Kernel Name"]), 42)
            r   = str(row["Rule Name"])[:30]
            rt  = str(row["Rule Type"])
            sp  = row["_SpeedupNum"]
            sp_s = f"{sp:8.1f}" if not pd.isna(sp) else "     N/A"
            lines.append(f"  {k:<42}  {r:<30}  {rt:>4}  {sp_s}")
    blank()

    # ── 5. Top optimisation opportunities (ranked by speedup) ───────────────
    section("5. Top Optimisation Opportunities (by estimated speedup %)")
    if rules.empty:
        lines.append("  No rules found.")
    else:
        opt_rules = rules_dedup[
            (rules_dedup["Rule Type"] == "OPT") & rules_dedup["_SpeedupNum"].notna()
        ].nlargest(10, "_SpeedupNum")

        if opt_rules.empty:
            lines.append("  No OPT rules with speedup estimates found.")
        else:
            for rank, (_, row) in enumerate(opt_rules.iterrows(), 1):
                k  = shorten_kernel(str(row["Kernel Name"]), 60)
                r  = str(row["Rule Name"])
                sp = row["_SpeedupNum"]
                lines.append(f"  {rank:>2}. [{sp:5.1f}% speedup]  {r}")
                lines.append(f"      Kernel: {k}")
                desc = str(row.get("Rule Description", "")).strip()
                if desc and desc != "nan" and len(desc) > 4:
                    # Word-wrap description to 76 chars
                    words = desc.split()
                    cur = "      "
                    for w in words:
                        if len(cur) + len(w) + 1 > 76:
                            lines.append(cur.rstrip())
                            cur = "      " + w + " "
                        else:
                            cur += w + " "
                    if cur.strip():
                        lines.append(cur.rstrip())
                blank()

    # ── 6. Hotspot ranking by elapsed cycles ────────────────────────────────
    section("6. Kernel Hotspot Ranking (by elapsed GPU cycles)")
    total_cycles = cycles.sum()
    lines.append(f"  {'Rank':<5}  {'Cycles':>12}  {'Share%':>6}  Kernel")
    lines.append("  " + "-" * (W - 2))
    for rank, k in enumerate(kernels_by_cycles, 1):
        cyc = cycles.get(k, float("nan"))
        if pd.isna(cyc):
            continue
        share = 100.0 * cyc / total_cycles if total_cycles > 0 else 0
        lines.append(f"  {rank:<5}  {int(cyc):>12,}  {share:6.1f}%  {shorten_kernel(k, 55)}")
    blank()

    # ── Footer ───────────────────────────────────────────────────────────────
    hr("═")
    lines.append("  Legend:")
    lines.append("    SM%      : compute (SM) throughput as % of roofline peak")
    lines.append("    Mem%     : memory throughput as % of roofline peak")
    lines.append("    Bound    : compute = SM-limited, memory = memory-limited")
    lines.append("    IPC-Act  : instructions per active cycle (no stalls)")
    lines.append("    IPC-Elp  : instructions per elapsed cycle (includes stalls)")
    lines.append("    Occup%   : achieved warp occupancy")
    lines.append("    Speedup% : estimated gain from fixing this issue (ncu estimate)")
    hr("═")

    return "\n".join(lines)

# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <ncu_csv> <output_summary_txt> [run_id]")
        sys.exit(1)

    ncu_csv   = sys.argv[1]
    out_txt   = sys.argv[2]
    run_id    = sys.argv[3] if len(sys.argv) > 3 else os.path.basename(ncu_csv)

    if not os.path.isfile(ncu_csv):
        print(f"[ERROR] NCU CSV not found: {ncu_csv}")
        sys.exit(1)

    print(f"[ncu-summary] Loading {ncu_csv} ...")
    df = load_ncu_csv(ncu_csv)

    print(f"[ncu-summary] Building summary ({df['Kernel Name'].nunique()} kernels) ...")
    summary = build_summary(df, run_id)

    os.makedirs(os.path.dirname(out_txt) if os.path.dirname(out_txt) else ".", exist_ok=True)
    with open(out_txt, "w") as f:
        f.write(summary)

    print(f"[ncu-summary] Written → {out_txt}")
    print()
    print(summary)

if __name__ == "__main__":
    main()
