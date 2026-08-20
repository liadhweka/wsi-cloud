#!/usr/bin/env python3
"""aggregate-stage4a-patches.py — walk Stage 4.A run dirs, emit summary.

Usage:
    aggregate-stage4a-patches.py <glob>
    e.g. aggregate-stage4a-patches.py 'runs/2026-*-s4.A-patches-*'

For each matching run dir:
  - parses cmd.log for the extractor's '=== summary ===' block
  - reads .run_start/.run_end for the recorded window
  - re-reads weka-stats.csv with per-timestamp summing across the client's
    wekafs client frontends (Read AND Write — Stage 4.A is write-heavy)
  - extracts RDMA xmit (writes) + rcv (reads) sustained
  - application-core %busy from per-core sar-cpu rows (the storage client's
    recorded reserved cores excluded -- the CPU=-1 aggregate row averages them
    in and inflates the reading)

Outputs:
  - runs/s4.A-patches-summary.csv
  - 2D markdown grid (dataset × concurrency)

Stdlib only. Reuses per-timestamp WEKA-summing pattern from prior aggregators.
"""
import csv
import glob
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE = re.compile(r"-s4\.A-patches-([a-zA-Z0-9_-]+?)-n(\d+)$")
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


def parse_run_dir_name(p):
    m = RUN_NAME_RE.search(p.name)
    if not m: return None
    return {"dataset": m.group(1), "concurrency": int(m.group(2))}


def parse_iso_utc(s): return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    raw = run_dir / "raw"
    try:
        s = parse_iso_utc((raw / ".run_start").read_text())
        e = parse_iso_utc((raw / ".run_end").read_text())
        return s, e, (e - s).total_seconds()
    except Exception:
        return None, None, None


def parse_bps(s):
    if s is None: return None
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
    """Per-second total of weka-stats `col` summed across the client frontends."""
    csv_path = run_dir / "raw" / "weka-stats.csv"
    if not csv_path.exists(): return None
    per_ts = {}
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
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
        "p95": sorted_v[min(int(n * 0.95), n - 1)],
        "max": sorted_v[-1],
    }



def _reserved_cores(run_dir):
    """The storage client's reserved-core set for THIS run, from its recorded metadata.

    The reserved set is a per-filesystem, per-instance measured parameter (STAGES.md
    D15) -- WEKA's client busy-polls its cores at 100% regardless of workload; the
    Lustre client reserves none -- so it is read from what record-run.sh recorded
    for the run (`cores_reserved`), never hardcoded. Refusing on absence is
    deliberate: an application-CPU mean silently computed over an unknown exclusion
    set is exactly the polluted number this field exists to prevent.
    """
    meta = run_dir / "metadata.json"
    try:
        cores = json.loads(meta.read_text()).get("cores_reserved")
    except (OSError, ValueError) as e:
        raise SystemExit(f"FATAL: {meta}: unreadable ({e}); cannot determine the reserved-core set")
    if cores is None:
        raise SystemExit(
            f"FATAL: {run_dir.name}: metadata.json carries no cores_reserved -- the cell was "
            "recorded without FS_CLIENT_RESERVED_CORES set (docs/NAMING-AND-VARIABLES.md), so its "
            "application-CPU mean cannot exclude the storage client's cores. Set it in env.sh "
            "('none' on a leg that reserves none) and re-record."
        )
    return {str(c) for c in cores}

def parse_aggregate_cpu(run_dir):
    """Application-core CPU %busy from per-core sar rows.

    The CPU=-1 aggregate row is NOT used: it averages in the storage client's
    reserved cores, which busy-poll at 100% regardless of workload and inflate
    the reading. Reserved cores are recorded per run -- see _reserved_cores.
    """
    csv_path = run_dir / "raw" / "sar-cpu.csv"
    if not csv_path.exists(): return None
    reserved = _reserved_cores(run_dir)
    per_ts = {}
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
            cpu_s = row.get("CPU", "").strip()
            if cpu_s in ("-1", "all", "") or cpu_s in reserved: continue
            try: b = 100 - float(row["%idle"])
            except (KeyError, ValueError): continue
            ts = row.get("timestamp") or ""
            per_ts.setdefault(ts, []).append(b)
    if not per_ts: return None
    busy = [statistics.fmean(v) for v in per_ts.values() if v]
    if not busy: return None
    n = len(busy)
    sorted_b = sorted(busy)
    sustained_start = int(n * 0.2) if n > 5 else 0
    return {
        "sustained_mean": _active_window_mean(busy),
        "sustained_mean_last80": statistics.fmean(busy[sustained_start:]),
        "active_window_mean": _active_window_mean(busy),
        "p95": sorted_b[min(int(n * 0.95), n - 1)],
        "max": sorted_b[-1],
    }


def parse_extractor_summary(run_dir):
    log_path = run_dir / "cmd.log"
    if not log_path.exists(): return None
    text = log_path.read_text(errors="replace")
    out = {}
    for k, pat in {
        "slides_total":   r"slides_total:\s*(\d+)",
        "slides_success": r"slides_success:\s*(\d+)",
        "slides_failed":  r"slides_failed:\s*(\d+)",
        "total_tiles":    r"total_tiles:\s*(\d+)",
        "total_bytes":    r"total_bytes:\s*(\d+)",
        "total_seconds":  r"total_seconds:\s*([\d.]+)",
        "tiles_per_second": r"tiles_per_second:\s*([\d.]+)",
        "bytes_per_second": r"bytes_per_second:\s*([\d.]+)",
        "slides_per_second": r"slides_per_second:\s*([\d.]+)",
    }.items():
        m = re.search(pat, text)
        if m:
            try: out[k] = float(m.group(1)) if "." in m.group(1) else int(m.group(1))
            except ValueError: pass
    return out if out else None


def extract_rdma_pair(d):
    rdma = (d.get("sources") or {}).get("rdma_counters") or {}
    devs = rdma.get("devices") or {}
    max_xmit = max_rcv = 0.0; xmit_dev = rcv_dev = None
    for dev, m in devs.items():
        x = (m.get("xmit_bytes_per_sec") or {}).get("sustained_mean") or 0
        r = (m.get("rcv_bytes_per_sec") or {}).get("sustained_mean") or 0
        if x > max_xmit: max_xmit, xmit_dev = x, dev
        if r > max_rcv: max_rcv, rcv_dev = r, dev
    return xmit_dev, max_xmit, rcv_dev, max_rcv


def extract_cell_summary(run_dir):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None: return None
    out = dict(parsed); out["run_dir"] = run_dir.name

    s, e, dur = read_run_window(run_dir)
    out["run_start_utc"] = s.isoformat() + "Z" if s else None
    out["run_end_utc"]   = e.isoformat() + "Z" if e else None
    out["window_s"]      = dur

    summary = parse_extractor_summary(run_dir) or {}
    out.update({k: summary.get(k) for k in ["slides_total", "slides_success", "slides_failed",
                                              "total_tiles", "total_bytes", "total_seconds",
                                              "tiles_per_second", "bytes_per_second", "slides_per_second"]})

    rj = run_dir / "results.json"
    xmit_dev = rcv_dev = None; xmit_bps = rcv_bps = 0.0
    if rj.exists():
        try:
            d = json.loads(rj.read_text())
            xmit_dev, xmit_bps, rcv_dev, rcv_bps = extract_rdma_pair(d)
        except Exception:
            pass
    out["rdma_xmit_dev"] = xmit_dev
    out["rdma_xmit_sustained_bps"] = xmit_bps if xmit_bps > 0 else None
    out["rdma_rcv_dev"] = rcv_dev
    out["rdma_rcv_sustained_bps"] = rcv_bps if rcv_bps > 0 else None

    wk_read  = weka_client_per_sec(run_dir, "Read", parse_bps)
    wk_write = weka_client_per_sec(run_dir, "Write", parse_bps)
    wk_ops   = weka_client_per_sec(run_dir, "Ops/s", parse_numeric)
    out["weka_read_sustained_bps"]  = wk_read["sustained_mean"]  if wk_read else None
    out["weka_write_sustained_bps"] = wk_write["sustained_mean"] if wk_write else None
    out["weka_ops_sustained"]       = wk_ops["sustained_mean"]   if wk_ops else None

    cpu = parse_aggregate_cpu(run_dir)
    out["agg_cpu_busy_sustained_pct"] = cpu["sustained_mean"] if cpu else None
    out["agg_cpu_busy_p95_pct"]       = cpu["p95"]            if cpu else None
    out["agg_cpu_busy_max_pct"]       = cpu["max"]            if cpu else None

    # Cross-source: writes EC-amplified per the protection scheme; reads ~1× (no amplification)
    if out["weka_write_sustained_bps"] and out["rdma_xmit_sustained_bps"]:
        out["ratio_xmit_over_write"] = out["rdma_xmit_sustained_bps"] / out["weka_write_sustained_bps"]
    else:
        out["ratio_xmit_over_write"] = None

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-stage4a-patches.py <glob>", file=sys.stderr); sys.exit(2)
    dirs = [Path(p) for p in sorted(glob.glob(sys.argv[1])) if Path(p).is_dir()]
    dirs = [d for d in dirs if RUN_NAME_RE.search(d.name)]
    if not dirs:
        print(f"no sweep-cell dirs matched", file=sys.stderr); sys.exit(1)
    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]
    rows.sort(key=lambda r: (r["dataset"], r["concurrency"]))

    _LEG_OUT = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (summary CSVs are per-leg files: D6 concurrent legs)")
    out_csv = dirs[0].parent / f"s4.A-patches-summary-{_LEG_OUT}.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows: w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    datasets = sorted(set(r["dataset"] for r in rows))
    concurrencies = sorted(set(r["concurrency"] for r in rows))
    grid = {(r["dataset"], r["concurrency"]): r for r in rows}

    print("\n# Stage 4.A — Pre-extract tiles to per-slide HDF5 (Strategy A)\n")
    print("Tool: openslide-python + multiprocessing.Pool + h5py + JPEG-encoded variable-length bytes")
    print("Headline: 'pre-extracted N slides (M tiles, X GiB) in Y seconds at concurrency C.'\n")

    def grid_table(title, key, fmt):
        print(f"## {title}\n")
        hdr = "| dataset \\ n | " + " | ".join(str(j) for j in concurrencies) + " |"
        sep = "|" + "---|" * (len(concurrencies) + 1)
        print(hdr); print(sep)
        for ds in datasets:
            cells = [fmt(grid.get((ds, n), {}).get(key)) if grid.get((ds, n), {}).get(key) is not None else "—"
                     for n in concurrencies]
            print(f"| **{ds}** | " + " | ".join(cells) + " |")
        print()

    grid_table("Total seconds to pre-extract dataset", "total_seconds", lambda v: f"{v:.0f}")
    grid_table("Slides per second", "slides_per_second", lambda v: f"{v:.2f}")
    grid_table("Tiles per second (the customer-quotable write throughput)", "tiles_per_second", lambda v: f"{v:.0f}")
    grid_table("Bytes per second written (MiB/s)", "bytes_per_second", lambda v: f"{v/(1024**2):.0f}")
    grid_table("Aggregate CPU %busy sustained", "agg_cpu_busy_sustained_pct", lambda v: f"{v:.1f}%")
    grid_table("WEKA client Write sustained (MiB/s)", "weka_write_sustained_bps", lambda v: f"{v/(1024**2):.0f}")
    grid_table("WEKA client Read sustained (MiB/s) — slide-source reads", "weka_read_sustained_bps", lambda v: f"{v/(1024**2):.0f}")
    grid_table("RDMA xmit sustained (MiB/s) — wire-level write direction", "rdma_xmit_sustained_bps", lambda v: f"{v/(1024**2):.0f}")
    grid_table("Cross-source: RDMA_xmit / weka_Write (EC-amplified; expected ratio per protection scheme)", "ratio_xmit_over_write", lambda v: f"{v:.2f}")

    valid = [r for r in rows if r.get("tiles_per_second")]
    if valid:
        peak = max(valid, key=lambda r: r["tiles_per_second"])
        print(f"\n**Peak tiles/sec across the sweep:** {peak['tiles_per_second']:.0f} "
              f"({peak['dataset']}, n={peak['concurrency']}, {peak.get('total_seconds', '?')}s for "
              f"{peak.get('slides_total', '?')} slides → {peak.get('total_tiles', '?')} tiles → "
              f"{(peak.get('total_bytes', 0) or 0)/(1024**3):.1f} GiB written)")


if __name__ == "__main__":
    main()
