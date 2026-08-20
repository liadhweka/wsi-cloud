#!/usr/bin/env python3
"""aggregate-stage1-fpsync.py — walk Stage 1.5 fpsync run dirs, emit summary.

Usage:
    aggregate-stage1-fpsync.py <glob-pattern>
    e.g. aggregate-stage1-fpsync.py 'runs/2026-*-s1.5-fpsync-n*'

For each matching run dir:
  - parses results.json for primary-source stats (weka_stats, rdma_counters, sar)
  - reads notes.md for app-level bytes-transferred (du-based pre/post)
  - computes app-level throughput from .run_start / .run_end + post-bytes
  - extracts RDMA xmit on the device that carried the workload (writes -> xmit)
  - cross-source ratio: RDMA_xmit / app_level (erasure-coding amplification per the cluster's protection scheme)

Outputs:
  - runs/s1.5-fpsync-summary.csv
  - markdown 1D table (one row per n) to stdout

Stdlib only.

Note: this is a separate aggregator from aggregate-sweep.py because Stage 1.5
is a 1D sweep on `n` only, not the 2D `bs × jobs` grid that 1.0a/b/c/d use.
The fio-shaped aggregator's RUN_NAME_RE expects bs<X>-jobs<N> suffixes; here
we have just `fpsync-n<N>`. Cleaner to keep them separate than to overload.
"""
import csv
import glob
import json
import os
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE = re.compile(r"-s1\.5-fpsync-n(\d+)$")


def parse_run_dir_name(p: Path):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    return {"n": int(m.group(1))}


def parse_iso_utc(s: str):
    s = s.strip().rstrip("Z")
    return datetime.fromisoformat(s)


def read_run_window(run_dir: Path):
    """Read .run_start and .run_end (ISO 8601 UTC) from raw/."""
    raw = run_dir / "raw"
    try:
        start = parse_iso_utc((raw / ".run_start").read_text())
        end = parse_iso_utc((raw / ".run_end").read_text())
    except Exception:
        return None, None, None
    duration_s = (end - start).total_seconds()
    return start, end, duration_s


_BPS_RE = re.compile(r"^\s*([\d.eE+-]+)\s*B/s\s*$")


def _active_window_mean(seq):
    """Idle-robust mean: trim leading/trailing samples below 5% of peak, then
    average the contiguous active span (internal gaps kept). Immune to a
    storage-idle setup / model-load head or teardown tail inside the recording
    window diluting a throughput headline. The plain
    last-80%-chronological mean is emitted alongside as sustained_mean_last80;
    it dilutes when the workload finishes early inside the window, which is
    why the active-window mean is the headline."""
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


def parse_bps(s):
    """Parse a 'NNN B/s' string from weka-stats.csv into a float bytes/sec."""
    if s is None:
        return None
    m = _BPS_RE.match(s)
    if not m:
        try:
            return float(s)
        except (ValueError, TypeError):
            return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def weka_client_write_per_sec(run_dir: Path):
    """Read weka-stats.csv and compute per-second total Write across all
    wekafs frontend processes on the client host (Mode=client).

    The recorder captures one row per (Hostname, Roles, Mode, Node ID) per
    second. The wekafs client container runs multiple frontend processes, so the
    correct per-second client throughput is the SUM across those rows sharing
    one timestamp, not the mean across all rows in the file. Rows are selected
    by Mode=="client" (never by hostname or Node ID — both rebuild-unstable).

    Returns a dict with mean / sustained_mean / active_window_mean / p95 / p99 / max of the
    per-second sums, or None if no rows match.
    """
    csv_path = run_dir / "raw" / "weka-stats.csv"
    if not csv_path.exists():
        return None
    per_ts = {}  # timestamp -> sum of Write column (B/s) across client processes
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Selected by ROLE alone: hostnames and Node IDs are both rebuild-
            # unstable, and this cluster runs exactly ONE client container by
            # design, so Mode=="client" uniquely selects it.
            if row.get("Mode") != "client":
                continue
            ts = row.get("timestamp")
            bps = parse_bps(row.get("Write"))
            if ts is None or bps is None:
                continue
            per_ts[ts] = per_ts.get(ts, 0.0) + bps
    if not per_ts:
        return None
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


def parse_app_bytes_from_notes(run_dir: Path):
    """Pull post-target bytes count from notes.md (written by sweep driver)."""
    nm = run_dir / "notes.md"
    if not nm.exists():
        return None
    text = nm.read_text(errors="replace")
    m = re.search(r"^- Target bytes \(post\): (\d+)\s*$", text, re.M)
    if m:
        return int(m.group(1))
    return None


def extract_cell_summary(run_dir: Path):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None:
        return None
    out = dict(parsed)
    out["run_dir"] = run_dir.name

    # Run window from recorder timestamps (more accurate than wall-clock
    # of the wrapper, excludes pre/post snapshot time).
    start, end, dur = read_run_window(run_dir)
    out["run_start_utc"] = start.isoformat() + "Z" if start else None
    out["run_end_utc"] = end.isoformat() + "Z" if end else None
    out["duration_s"] = dur

    # App-level bytes from notes.md (du-based, authoritative).
    bytes_post = parse_app_bytes_from_notes(run_dir)
    out["app_bytes_post"] = bytes_post
    if bytes_post is not None and dur and dur > 0:
        out["app_bw_bytes_per_sec"] = bytes_post / dur
        out["app_bw_mib_per_sec"] = bytes_post / dur / (1024**2)
    else:
        out["app_bw_bytes_per_sec"] = None
        out["app_bw_mib_per_sec"] = None

    # Pull primary sources from results.json.
    rj = run_dir / "results.json"
    if not rj.exists():
        out["status"] = "NO_RESULTS"
        return out
    try:
        d = json.loads(rj.read_text())
    except Exception as e:
        out["status"] = f"JSON_ERROR:{e}"
        return out

    sources = d.get("sources") or {}

    # weka-stats client-side Write throughput. The pre-aggregated metric in
    # results.json is the mean across ALL (Hostname, Roles, Mode, Node ID)
    # tuples — diluted ~100x by idle backend rows. Re-derive directly from
    # weka-stats.csv: per-second sum across our client frontend
    # processes. This is the number WEKAmon-Prometheus would scrape if
    # filtered to (mode=client).
    client_agg = weka_client_write_per_sec(run_dir)
    if client_agg:
        out["weka_write_sustained_bps"] = client_agg["sustained_mean"]
        out["weka_write_mean_bps"]      = client_agg["mean"]
        out["weka_write_p95_bps"]       = client_agg["p95"]
        out["weka_write_max_bps"]       = client_agg["max"]
        out["weka_write_n_seconds"]     = client_agg["n_seconds"]
    else:
        out["weka_write_sustained_bps"] = None
    wk = sources.get("weka_stats") or {}
    out["weka_stats_rows"] = wk.get("row_count", 0)

    # RDMA xmit (data-plane direction for writes). Pick the device that
    # actually moved (parser already shows per-device — we pick the max).
    rdma = sources.get("rdma_counters") or {}
    devs = rdma.get("devices") or {}
    max_xmit = 0.0
    max_xmit_dev = None
    for dev, m in devs.items():
        x = (m.get("xmit_bytes_per_sec") or {}).get("sustained_mean") or 0
        if x > max_xmit:
            max_xmit = x
            max_xmit_dev = dev
    out["rdma_xmit_sustained_bps"] = max_xmit if max_xmit > 0 else None
    out["rdma_xmit_dev"] = max_xmit_dev

    # Cross-source ratios (the project's recording-infra canary).
    if out["app_bw_bytes_per_sec"] and out["rdma_xmit_sustained_bps"]:
        out["ratio_rdma_xmit_over_app"] = out["rdma_xmit_sustained_bps"] / out["app_bw_bytes_per_sec"]
    else:
        out["ratio_rdma_xmit_over_app"] = None
    if out["app_bw_bytes_per_sec"] and out["weka_write_sustained_bps"]:
        out["ratio_weka_over_app"] = out["weka_write_sustained_bps"] / out["app_bw_bytes_per_sec"]
    else:
        out["ratio_weka_over_app"] = None

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-stage1-fpsync.py <glob>", file=sys.stderr)
        sys.exit(2)
    pattern = sys.argv[1]
    dirs = [Path(p) for p in sorted(glob.glob(pattern)) if Path(p).is_dir()]
    # Filter out the prep run (it's not a sweep cell).
    dirs = [d for d in dirs if RUN_NAME_RE.search(d.name)]
    if not dirs:
        print(f"no sweep-cell dirs matched: {pattern}", file=sys.stderr)
        sys.exit(1)

    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]
    rows.sort(key=lambda r: r["n"])

    if not rows:
        print("no parseable rows", file=sys.stderr)
        sys.exit(1)

    _LEG_OUT = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (summary CSVs are per-leg files: D6 concurrent legs)")
    out_csv = dirs[0].parent / f"s1.5-fpsync-summary-{_LEG_OUT}.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    # Markdown 1D table.
    print()
    print("# Stage 1.5 fpsync sweep — local NVMe -> the filesystem under test (POSIX)")
    print()
    print(f"Source: TCGA-BRCA full (1133 SVS, 1.05 TiB per the manifest), "
          f"pre-staged on {os.environ.get('SCRATCH_DIR', '$SCRATCH_DIR')}/fpsync-source/.")
    print()
    print("## Headline grid")
    print()
    print("| n | duration | app bw (MiB/s) | weka Write sustained (MiB/s) | RDMA xmit (MiB/s, dev) | RDMA/app ratio (expect ~2.0) | weka/app ratio (expect ~1.0) |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        dur = f"{r['duration_s']:.0f}s" if r['duration_s'] else "—"
        app_bw = f"{r['app_bw_mib_per_sec']:.0f}" if r.get('app_bw_mib_per_sec') else "—"
        wk = (r.get('weka_write_sustained_bps') or 0) / (1024**2)
        wk_str = f"{wk:.0f}" if wk else "—"
        rd = (r.get('rdma_xmit_sustained_bps') or 0) / (1024**2)
        rd_dev = r.get('rdma_xmit_dev') or "—"
        rd_str = f"{rd:.0f} ({rd_dev})" if rd else "—"
        rda = r.get('ratio_rdma_xmit_over_app')
        rda_str = f"{rda:.2f}" if rda else "—"
        wkr = r.get('ratio_weka_over_app')
        wkr_str = f"{wkr:.2f}" if wkr else "—"
        print(f"| **{r['n']}** | {dur} | {app_bw} | {wk_str} | {rd_str} | {rda_str} | {wkr_str} |")

    # Headline picks.
    print()
    valid = [r for r in rows if r.get('app_bw_mib_per_sec')]
    if valid:
        peak = max(valid, key=lambda r: r['app_bw_mib_per_sec'])
        print(f"**Peak app-level write bw:** {peak['app_bw_mib_per_sec']:.0f} MiB/s "
              f"({peak['app_bw_mib_per_sec']/1024:.2f} GiB/s) at n={peak['n']}")

    # Cross-source consistency canary
    print()
    print("## Cross-source consistency (from CLAUDE.md primary sources)")
    print()
    print("Expected for write workloads: RDMA xmit / app ≈ 2.0 (erasure-coding amplification per the cluster's protection scheme),")
    print("weka Write / app ≈ 1.0 (cluster-side throughput tracks app-level).")
    print()
    issues = []
    for r in rows:
        rda = r.get('ratio_rdma_xmit_over_app')
        wkr = r.get('ratio_weka_over_app')
        if rda is None or wkr is None:
            continue
        if rda < 1.3 or rda > 2.5:
            issues.append(f"  - n={r['n']}: RDMA/app = {rda:.2f} (outside 1.3-2.5 expected band)")
        if wkr < 0.7 or wkr > 1.5:
            issues.append(f"  - n={r['n']}: weka/app = {wkr:.2f} (outside 0.7-1.5 expected band)")
    if issues:
        print("**⚠️ Cross-source disagreements (recording-infra canary may be tripping):**")
        for line in issues:
            print(line)
    else:
        print("All cells within expected ratio bands. ✅")


if __name__ == "__main__":
    main()
