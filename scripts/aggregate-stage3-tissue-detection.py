#!/usr/bin/env python3
"""aggregate-stage3-tissue-detection.py — walk Stage 3.0 run dirs, emit summary.

Usage:
    aggregate-stage3-tissue-detection.py <glob-pattern>
    e.g. aggregate-stage3-tissue-detection.py 'runs/2026-*-s3.0-tissue-*'

For each matching run dir:
  - parses cmd.log for the wrapper's '=== summary ===' block (slides_total,
    slides_with_h5, slides_with_mask, concurrency, dataset)
  - reads .run_start/.run_end for the recorded window
  - computes app-level slides/sec and per-slide-mean from app-level totals
  - re-reads weka-stats.csv with per-timestamp summing across the client's
    the storage client's own processes (cross-cutting pattern #1)
  - **NEW for Stage 3:** parses sar-cpu.csv and computes %busy on the
    NON-WEKA cores (everything except the wekafs DPDK cores 24-31 on NUMA-0).
    Shows the compute-saturation curve that IS the Stage 3 customer story.
  - extracts RDMA rcv (read direction) per device

Outputs:
  - runs/s3.0-tissue-summary.csv
  - 2D markdown grids (dataset × concurrency) for: total seconds, slides/sec,
    weka client Read sum, weka Ops/s sum, non-WEKA-core CPU%, RDMA rcv,
    cross-source canary (RDMA_rcv/weka_R)

Stdlib only. Reuses the per-timestamp WEKA-summing pattern from
aggregate-stage2-properties.py.
"""
import csv
import glob
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE = re.compile(r"-s3\.0-tissue-([a-zA-Z0-9_-]+?)-n(\d+)$")
_BPS_RE = re.compile(r"^\s*([\d.eE+-]+)\s*B/s\s*$")


def _active_window_mean(seq):
    """Idle-robust mean: trim leading/trailing samples below 5% of peak, then
    average the contiguous active span (internal gaps kept). Immune to a
    storage-idle setup / model-load head or teardown tail inside the recording
    window diluting a throughput headline. Added per the Tier-1 recording audit
    (2026-07); replaces the old last-80%-chronological sustained_mean, whose
    value is preserved as sustained_mean_last80."""
    seq = list(seq)
    if not seq:
        return None
    peak = max(seq)
    if peak <= 0:
        return statistics.fmean(seq)
    floor = 0.05 * peak
    idx = [i for i, v in enumerate(seq) if v >= floor]
    if not idx:
        return statistics.fmean(seq)
    return statistics.fmean(seq[idx[0]:idx[-1] + 1])

# Cores reserved by the storage client, excluded from the saturation reading.
# ⏳ D-9: per-filesystem parameter (STAGES.md D15), indices measurable only on the
# real client. Placeholder.
# All other cores (0-23, 32-255) are application cores. For Stage 3 we report
# the compute saturation on non-WEKA cores specifically.
WEKA_CORES = set(range(24, 32))


def parse_run_dir_name(p):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    dataset, n = m.groups()
    return {"dataset": dataset, "concurrency": int(n)}


def parse_iso_utc(s):
    return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    raw = run_dir / "raw"
    try:
        start = parse_iso_utc((raw / ".run_start").read_text())
        end = parse_iso_utc((raw / ".run_end").read_text())
    except Exception:
        return None, None, None
    return start, end, (end - start).total_seconds()


def parse_bps(s):
    if s is None:
        return None
    m = _BPS_RE.match(s)
    if m:
        try: return float(m.group(1))
        except ValueError: return None
    try: return float(s)
    except (ValueError, TypeError): return None


def parse_numeric(s):
    if s is None: return None
    try: return float(s)
    except (ValueError, TypeError): return None


def weka_client_per_sec(run_dir, col, parser=parse_bps):
    """Per-second total of weka-stats `col` across all client frontends.
    Returns aggregate stats over per-second sums. Same pattern as Stage 2.
    """
    csv_path = run_dir / "raw" / "weka-stats.csv"
    if not csv_path.exists(): return None
    per_ts = {}
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Role-selected: hostnames are rebuild-unstable; one client by design.
            if row.get("Mode") != "client": continue
            ts = row.get("timestamp")
            v = parser(row.get(col))
            if ts is None or v is None: continue
            per_ts[ts] = per_ts.get(ts, 0.0) + v
    if not per_ts: return None
    series = sorted(per_ts.items())
    values = [v for _, v in series]
    n = len(values)
    sorted_v = sorted(values)
    sustained_start = int(n * 0.2) if n > 5 else 0
    return {
        "n_seconds": n,
        "mean": statistics.fmean(values),
        "sustained_mean": _active_window_mean(values),
        "sustained_mean_last80": statistics.fmean(values[sustained_start:]),
        "active_window_mean": _active_window_mean(values),
        "p50": sorted_v[n // 2],
        "p95": sorted_v[min(int(n * 0.95), n - 1)],
        "p99": sorted_v[min(int(n * 0.99), n - 1)],
        "max": sorted_v[-1],
    }


def parse_non_dpdk_cpu(run_dir):
    """Parse sar-cpu.csv for non-DPDK-core %busy (excludes wekafs cores 24-31).

    Stage 3 originally reported aggregate (CPU=-1) %busy because the recorder
    used `sar -u` without `-P ALL`. The 2026-05-08 post-Stage-3 fix to record-run.sh
    (line 306) added `-P ALL` AND retroactively re-ran `sadf -P ALL` against
    every prior run's existing sar.bin → per-core data is available for all 146
    runs going back to Stage 0, including the 6 Stage 3 cells.

    Updated 2026-05-21 to use the per-core data. For each timestamp we compute
    the mean %busy across the 248 non-DPDK cores (everything except cores 24-31
    on NUMA-0, which busy-poll for the wekafs DPDK frontend regardless of
    workload). Headline customer story is sharper: instead of "n=64 hits 37%
    sustained aggregate CPU (which includes ~3% DPDK baseline)" we can say
    "n=64 hits ~34% sustained non-DPDK CPU" with no caveat needed.

    Old behavior (aggregate, with DPDK baseline) is preserved in the 2026-05-21
    pre-revision summary CSV at `runs/s3.0-tissue-summary-PRIOR-TO-NON-DPDK-FILTER.csv`
    for forensic comparison.
    """
    csv_path = run_dir / "raw" / "sar-cpu.csv"
    if not csv_path.exists(): return None
    # per-timestamp: collect %busy values across non-DPDK cores, then compute mean
    per_ts = {}  # ts → list of per-core %busy at that ts
    with csv_path.open() as f:
        first = f.readline()
        delim = ";" if ";" in first else ","
        if first.startswith("#"): first = first[1:].lstrip()
        header = next(csv.reader([first], delimiter=delim))
        for line in f:
            if line.startswith("#"): continue
            parts = next(csv.reader([line], delimiter=delim))
            if len(parts) != len(header): continue
            row = dict(zip(header, parts))
            cpu_str = row.get("CPU", "").strip()
            # Skip aggregate (CPU=-1) and DPDK frontend cores (24-31)
            if cpu_str == "-1": continue
            try:
                cpu_id = int(cpu_str)
            except ValueError:
                continue
            if cpu_id in WEKA_CORES: continue
            try:
                idle = float(row["%idle"])
                busy = 100 - idle
            except (KeyError, ValueError):
                continue
            ts = row.get("timestamp")
            if ts is None: continue
            per_ts.setdefault(ts, []).append(busy)
    if not per_ts: return None
    # Per-timestamp non-DPDK %busy = mean of per-core %busy across non-DPDK cores
    busy_values = [statistics.fmean(v) for _, v in sorted(per_ts.items()) if v]
    if not busy_values: return None
    n = len(busy_values)
    sorted_v = sorted(busy_values)
    sustained_start = int(n * 0.2) if n > 5 else 0
    return {
        "n_seconds": n,
        "mean_pct_busy": statistics.fmean(busy_values),
        "sustained_mean_pct_busy": _active_window_mean(busy_values),
        "sustained_mean_pct_busy_last80": statistics.fmean(busy_values[sustained_start:]),
        "active_window_mean_pct_busy": _active_window_mean(busy_values),
        "p95_pct_busy": sorted_v[min(int(n * 0.95), n - 1)],
        "max_pct_busy": sorted_v[-1],
    }


def parse_wrapper_summary_from_log(run_dir):
    """Parse wrapper's '=== summary ===' block from cmd.log."""
    log_path = run_dir / "cmd.log"
    if not log_path.exists(): return None
    text = log_path.read_text(errors="replace")
    out = {}
    patterns = {
        "slides_total":     r"slides_total:\s*(\d+)",
        "slides_with_h5":   r"slides_with_h5:\s*(\d+)",
        "slides_with_mask": r"slides_with_mask:\s*(\d+)",
        "concurrency":      r"concurrency:\s*(\d+)",
    }
    for k, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            try: out[k] = int(m.group(1))
            except ValueError: pass
    return out if out else None


def extract_rdma_rcv(d):
    rdma = (d.get("sources") or {}).get("rdma_counters") or {}
    devs = rdma.get("devices") or {}
    max_rcv, max_rcv_dev = 0.0, None
    for dev, m in devs.items():
        r = (m.get("rcv_bytes_per_sec") or {}).get("sustained_mean") or 0
        if r > max_rcv:
            max_rcv, max_rcv_dev = r, dev
    return max_rcv_dev, max_rcv


def extract_cell_summary(run_dir):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None: return None
    out = dict(parsed)
    out["run_dir"] = run_dir.name

    # Run window
    start, end, dur = read_run_window(run_dir)
    out["run_start_utc"] = start.isoformat() + "Z" if start else None
    out["run_end_utc"]   = end.isoformat() + "Z" if end else None
    out["window_s"]      = dur

    # App-level from wrapper summary in cmd.log
    summary = parse_wrapper_summary_from_log(run_dir) or {}
    out["slides_total"]      = summary.get("slides_total")
    out["slides_with_h5"]    = summary.get("slides_with_h5")
    out["slides_with_mask"]  = summary.get("slides_with_mask")
    out["expected_slides"]   = summary.get("slides_total")  # alias

    # Derived: slides_per_sec from app-level slide count + run window
    if out["slides_with_h5"] and dur and dur > 0:
        out["slides_per_sec"] = out["slides_with_h5"] / dur
        out["mean_slide_lat_s"] = dur / out["slides_with_h5"] * out["concurrency"]  # approx per-slide single-stream-equivalent
    else:
        out["slides_per_sec"] = None
        out["mean_slide_lat_s"] = None

    # results.json for RDMA
    rj = run_dir / "results.json"
    rdma_dev, rdma_rcv = None, None
    if rj.exists():
        try:
            d = json.loads(rj.read_text())
            rdma_dev, rdma_rcv = extract_rdma_rcv(d)
        except Exception:
            pass
    out["rdma_rcv_dev"] = rdma_dev
    out["rdma_rcv_sustained_bps"] = rdma_rcv if rdma_rcv and rdma_rcv > 0 else None

    # WEKA-side per-ts-summed across the client's frontends
    wk_read = weka_client_per_sec(run_dir, "Read", parse_bps)
    wk_ops  = weka_client_per_sec(run_dir, "Ops/s", parse_numeric)
    out["weka_read_sustained_bps"]  = wk_read["sustained_mean"]  if wk_read else None
    out["weka_read_max_bps"]        = wk_read["max"]             if wk_read else None
    out["weka_ops_sustained"]       = wk_ops["sustained_mean"]   if wk_ops  else None
    out["weka_ops_max"]             = wk_ops["max"]              if wk_ops  else None

    # Stage 3 headline: non-DPDK CPU saturation (248 application cores, excludes
    # the 8 wekafs DPDK frontend cores 24-31 which busy-poll regardless of workload).
    # See parse_non_dpdk_cpu docstring for the 2026-05-21 revision history.
    cpu = parse_non_dpdk_cpu(run_dir)
    if cpu:
        out["non_dpdk_cpu_busy_sustained_pct"] = cpu["sustained_mean_pct_busy"]
        out["non_dpdk_cpu_busy_p95_pct"]       = cpu["p95_pct_busy"]
        out["non_dpdk_cpu_busy_max_pct"]       = cpu["max_pct_busy"]
    else:
        out["non_dpdk_cpu_busy_sustained_pct"] = None
        out["non_dpdk_cpu_busy_p95_pct"]       = None
        out["non_dpdk_cpu_busy_max_pct"]       = None

    # Cross-source: RDMA rcv ≈ weka client Read (read-only workload, no amplification)
    if out["weka_read_sustained_bps"] and out["rdma_rcv_sustained_bps"]:
        out["ratio_rdma_rcv_over_weka_read"] = (
            out["rdma_rcv_sustained_bps"] / out["weka_read_sustained_bps"]
        )
    else:
        out["ratio_rdma_rcv_over_weka_read"] = None

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-stage3-tissue-detection.py <glob>", file=sys.stderr)
        sys.exit(2)
    pattern = sys.argv[1]
    dirs = [Path(p) for p in sorted(glob.glob(pattern)) if Path(p).is_dir()]
    dirs = [d for d in dirs if RUN_NAME_RE.search(d.name)]
    if not dirs:
        print(f"no sweep-cell dirs matched: {pattern}", file=sys.stderr)
        sys.exit(1)

    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]
    rows.sort(key=lambda r: (r["dataset"], r["concurrency"]))

    out_csv = dirs[0].parent / "s3.0-tissue-summary.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    datasets = sorted(set(r["dataset"] for r in rows))
    concurrencies = sorted(set(r["concurrency"] for r in rows))
    grid = {(r["dataset"], r["concurrency"]): r for r in rows}

    print()
    print("# Stage 3.0 CLAM tissue detection sweep — POSIX, filesystem under test")
    print()
    print("Tool: CLAM create_patches_fp.py + bash-level concurrency (N parallel python3 instances per cell)")
    print("Headline customer story: 'WEKA's distributed metadata path serves CLAM's thumbnail reads while non-WEKA CPU cores saturate at concurrency C.'")
    print()

    def grid_table(title, key, fmt):
        print(f"## {title}")
        print()
        hdr = "| dataset \\ n | " + " | ".join(str(j) for j in concurrencies) + " |"
        sep = "|" + "---|" * (len(concurrencies) + 1)
        print(hdr); print(sep)
        for ds in datasets:
            cells = []
            for n in concurrencies:
                r = grid.get((ds, n))
                v = r.get(key) if r else None
                cells.append(fmt(v) if v is not None else "—")
            print(f"| **{ds}** | " + " | ".join(cells) + " |")
        print()

    grid_table("Headline: total seconds to detect tissue across the dataset",
               "window_s", lambda v: f"{v:.1f}")
    grid_table("Headline: slides processed per second (app-level)",
               "slides_per_sec", lambda v: f"{v:.0f}" if v >= 100 else f"{v:.2f}")
    grid_table("Slides with HDF5 output (= success count)",
               "slides_with_h5", lambda v: f"{v}")
    grid_table("**Stage 3 headline:** Non-DPDK CPU %busy sustained — compute saturation curve (248 application cores, excludes DPDK frontend cores 24-31)",
               "non_dpdk_cpu_busy_sustained_pct", lambda v: f"{v:.1f}%")
    grid_table("Non-DPDK CPU %busy p95 — peak utilization moments",
               "non_dpdk_cpu_busy_p95_pct", lambda v: f"{v:.1f}%")
    grid_table("Non-DPDK CPU %busy max",
               "non_dpdk_cpu_busy_max_pct", lambda v: f"{v:.1f}%")
    grid_table("WEKA client Read sustained (MiB/s) — per-ts sum across the client's frontends",
               "weka_read_sustained_bps", lambda v: f"{v/(1024**2):.1f}")
    grid_table("WEKA Ops/s sustained — per-ts sum",
               "weka_ops_sustained", lambda v: f"{v/1000:.1f}k" if v >= 1000 else f"{v:.0f}")
    grid_table("RDMA rcv sustained (MiB/s) — wire-level read direction",
               "rdma_rcv_sustained_bps", lambda v: f"{v/(1024**2):.1f}")

    # Headline pick
    print()
    valid = [r for r in rows if r.get("slides_per_sec")]
    if valid:
        peak = max(valid, key=lambda r: r["slides_per_sec"])
        print(f"**Peak slides/sec across the sweep:** {peak['slides_per_sec']:.0f} "
              f"({peak['dataset']}, n={peak['concurrency']}, "
              f"{peak.get('window_s', '?')}s for {peak.get('slides_with_h5', '?')}/{peak.get('slides_total', '?')} slides)")

    print()
    print("## Cross-source consistency canary (read-only workload)")
    print()
    print("Expected: RDMA rcv ≈ weka client Read (no read amplification, ~1.0-1.4 ratio).")
    print("Sub-minute cells may have noisy ratios from low sample counts.")
    print()
    print("| dataset | n | RDMA_rcv/weka_R | non-DPDK CPU% | weka Ops/s | weka Read MiB/s |")
    print("|---|---|---|---|---|---|")
    issues = []
    for r in rows:
        ratio = r.get("ratio_rdma_rcv_over_weka_read")
        ratio_s = f"{ratio:.2f}" if ratio is not None else "—"
        cpu_s = f"{r['non_dpdk_cpu_busy_sustained_pct']:.1f}%" if r.get("non_dpdk_cpu_busy_sustained_pct") else "—"
        ops_s = f"{r['weka_ops_sustained']/1000:.1f}k" if r.get("weka_ops_sustained") and r["weka_ops_sustained"] >= 1000 else (f"{r['weka_ops_sustained']:.0f}" if r.get("weka_ops_sustained") else "—")
        rd_s = f"{r['weka_read_sustained_bps']/(1024**2):.1f}" if r.get("weka_read_sustained_bps") else "—"
        print(f"| {r['dataset']} | {r['concurrency']} | {ratio_s} | {cpu_s} | {ops_s} | {rd_s} |")
        if ratio is not None and not (0.7 <= ratio <= 1.6):
            issues.append(f"  - {r['dataset']} n={r['concurrency']}: RDMA_rcv/weka_R={ratio:.2f} (outside 0.7-1.6)")
    print()
    if issues:
        print("**⚠️ Cross-source disagreements (may be sample-count-noise on short cells):**")
        for line in issues:
            print(line)
    else:
        print("All cells within expected bands. ✅")


if __name__ == "__main__":
    main()
