#!/usr/bin/env python3
"""aggregate-stage2-properties.py — walk Stage 2.0 run dirs, emit summary.

Usage:
    aggregate-stage2-properties.py <glob-pattern>
    e.g. aggregate-stage2-properties.py 'runs/2026-*-s2.0-properties-*'

For each matching run dir:
  - parses per-slide-latencies.csv (archived by the sweep driver) for app-level
    per-slide stats (mean, p50, p95, p99, max, success/fail counts)
  - parses cmd.log for the extractor's summary line (slides_per_second, total_seconds)
  - re-reads weka-stats.csv directly with per-timestamp summing across
    the storage client's own processes (cross-cutting pattern #1, from
    Stages 1.5/1.6) — pulls Ops/s (NEW Stage 2 headline), Read, Reads/s
  - extracts RDMA rcv (read direction) per device, picks the busiest

Outputs:
  - runs/s2.0-properties-summary.csv
  - 2D markdown grids (dataset × concurrency) for: slides/sec, p99 lat, mean lat,
    weka client Read sum, weka client Ops/s sum, RDMA rcv, cross-source canary

Stdlib only. Reuses the per-timestamp-sum pattern from aggregate-stage1-fpsync.py
(cross-cutting pattern #1 in docs/SCRIPT-TRACKER.md).
"""
import csv
import glob
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


# The cache arm is a parsed field and a grid dimension, never a name fragment
# to strip: without it a 16-cell sweep would either drop the suffixed cells or
# collapse each cold cell against its warm twin — both silent (Stage-2 roadmap).
RUN_NAME_RE = re.compile(r"-s2\.0-properties-([a-zA-Z0-9_-]+?)-n(\d+)-(cold|warm)$")
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


def parse_run_dir_name(p: Path):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    dataset, n, arm = m.groups()
    return {"dataset": dataset, "concurrency": int(n), "cache_arm": arm}


def parse_iso_utc(s):
    return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir: Path):
    raw = run_dir / "raw"
    try:
        start = parse_iso_utc((raw / ".run_start").read_text())
        end = parse_iso_utc((raw / ".run_end").read_text())
    except Exception:
        return None, None, None
    return start, end, (end - start).total_seconds()


def parse_bps(s):
    """Parse 'NNN B/s' or bare number into a float."""
    if s is None:
        return None
    m = _BPS_RE.match(s)
    if m:
        try:
            return float(m.group(1))
        except ValueError:
            return None
    try:
        return float(s)
    except (ValueError, TypeError):
        return None


def parse_numeric(s):
    """Parse bare number (Ops/s and Reads/s columns are bare floats)."""
    if s is None:
        return None
    try:
        return float(s)
    except (ValueError, TypeError):
        return None


def weka_client_per_sec(run_dir: Path, col: str, parser=parse_bps):
    """Per-second total of weka-stats `col` across all client frontend
    processes (selected by Mode=="client", never by hostname or
    Node ID — both rebuild-unstable). Returns aggregate stats over the per-second sums.

    `parser` is the function to convert the raw cell text (parse_bps for B/s
    columns, parse_numeric for bare-float columns like Ops/s).
    """
    csv_path = run_dir / "raw" / "weka-stats.csv"
    if not csv_path.exists():
        return None
    per_ts = {}
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Selected by ROLE alone: hostnames and Node IDs are both rebuild-
            # unstable, and this cluster runs exactly ONE client container by
            # design, so Mode=="client" uniquely selects it.
            if row.get("Mode") != "client":
                continue
            ts = row.get("timestamp")
            v = parser(row.get(col))
            if ts is None or v is None:
                continue
            per_ts[ts] = per_ts.get(ts, 0.0) + v
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


def parse_per_slide_latencies(run_dir: Path):
    """Parse per-slide-latencies.csv (slide_id, elapsed_seconds, error)."""
    csv_path = run_dir / "per-slide-latencies.csv"
    if not csv_path.exists():
        return None
    latencies = []
    successes = 0
    failures = 0
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                lat = float(row["elapsed_seconds"])
            except (KeyError, ValueError):
                continue
            err = row.get("error", "").strip()
            if err:
                failures += 1
            else:
                successes += 1
            latencies.append(lat)
    if not latencies:
        return None
    sorted_lat = sorted(latencies)
    n = len(sorted_lat)
    return {
        "slide_count": n,
        "successes": successes,
        "failures": failures,
        "mean_s": statistics.fmean(latencies),
        "p50_s": sorted_lat[n // 2],
        "p95_s": sorted_lat[min(int(n * 0.95), n - 1)],
        "p99_s": sorted_lat[min(int(n * 0.99), n - 1)],
        "max_s": sorted_lat[-1],
        "min_s": sorted_lat[0],
    }


def parse_extractor_summary_from_log(run_dir: Path):
    """Parse the extractor's '=== summary ===' block from cmd.log."""
    log_path = run_dir / "cmd.log"
    if not log_path.exists():
        return None
    text = log_path.read_text(errors="replace")
    out = {}
    patterns = {
        "slides_total":    r"slides_total:\s*(\d+)",
        "slides_success":  r"slides_success:\s*(\d+)",
        "slides_failed":   r"slides_failed:\s*(\d+)",
        "total_seconds":   r"total_seconds:\s*([\d.]+)",
        "slides_per_second": r"slides_per_second:\s*([\d.]+)",
    }
    for k, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            try:
                out[k] = float(m.group(1)) if "." in m.group(1) else int(m.group(1))
            except ValueError:
                pass
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


def extract_cell_summary(run_dir: Path):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None:
        return None
    out = dict(parsed)
    out["run_dir"] = run_dir.name

    # Run window
    start, end, dur = read_run_window(run_dir)
    out["run_start_utc"] = start.isoformat() + "Z" if start else None
    out["run_end_utc"]   = end.isoformat() + "Z" if end else None
    out["window_s"]      = dur

    # App-level from extractor's summary in cmd.log (authoritative for total time + slides/sec)
    extr = parse_extractor_summary_from_log(run_dir) or {}
    out["app_slides_total"]    = extr.get("slides_total")
    out["app_slides_success"]  = extr.get("slides_success")
    out["app_slides_failed"]   = extr.get("slides_failed")
    out["app_total_seconds"]   = extr.get("total_seconds")
    out["app_slides_per_sec"]  = extr.get("slides_per_second")

    # Per-slide latency stats from per-slide-latencies.csv (rich distribution)
    lat = parse_per_slide_latencies(run_dir) or {}
    out["per_slide_count"]      = lat.get("slide_count")
    out["per_slide_lat_mean_ms"] = (lat["mean_s"] * 1000) if lat.get("mean_s") else None
    out["per_slide_lat_p50_ms"]  = (lat["p50_s"]  * 1000) if lat.get("p50_s")  else None
    out["per_slide_lat_p95_ms"]  = (lat["p95_s"]  * 1000) if lat.get("p95_s")  else None
    out["per_slide_lat_p99_ms"]  = (lat["p99_s"]  * 1000) if lat.get("p99_s")  else None
    out["per_slide_lat_max_ms"]  = (lat["max_s"]  * 1000) if lat.get("max_s")  else None
    out["per_slide_lat_min_ms"]  = (lat["min_s"]  * 1000) if lat.get("min_s")  else None

    # results.json for RDMA + sanity row counts
    rj = run_dir / "results.json"
    if not rj.exists():
        out["status"] = "NO_RESULTS"
        return out
    try:
        d = json.loads(rj.read_text())
    except Exception as e:
        out["status"] = f"JSON_ERROR:{e}"
        return out

    rdma_dev, rdma_rcv = extract_rdma_rcv(d)
    out["rdma_rcv_dev"] = rdma_dev
    out["rdma_rcv_sustained_bps"] = rdma_rcv if rdma_rcv > 0 else None

    # WEKA-side per-ts-summed across the client's frontends
    wk_read = weka_client_per_sec(run_dir, "Read", parse_bps)
    wk_ops  = weka_client_per_sec(run_dir, "Ops/s", parse_numeric)
    wk_rds  = weka_client_per_sec(run_dir, "Reads/s", parse_numeric)

    out["weka_read_sustained_bps"] = wk_read["sustained_mean"] if wk_read else None
    out["weka_read_max_bps"]       = wk_read["max"]            if wk_read else None
    out["weka_ops_sustained"]      = wk_ops["sustained_mean"]  if wk_ops  else None
    out["weka_ops_max"]            = wk_ops["max"]             if wk_ops  else None
    out["weka_reads_per_sec_sustained"] = wk_rds["sustained_mean"] if wk_rds else None

    # Cross-source: RDMA_rcv / weka_Read should be ~1.0-1.4 (no read amplification)
    if out["weka_read_sustained_bps"] and out["rdma_rcv_sustained_bps"]:
        out["ratio_rdma_rcv_over_weka_read"] = out["rdma_rcv_sustained_bps"] / out["weka_read_sustained_bps"]
    else:
        out["ratio_rdma_rcv_over_weka_read"] = None

    # Cross-source: weka Ops/s vs app slides/sec — expect Ops/s >> slides/sec
    # because each OpenSlide.OpenSlide(path) triggers many internal metadata ops
    if out["weka_ops_sustained"] and out["app_slides_per_sec"]:
        out["ratio_weka_ops_over_app_slides_per_sec"] = (
            out["weka_ops_sustained"] / out["app_slides_per_sec"]
        )
    else:
        out["ratio_weka_ops_over_app_slides_per_sec"] = None

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-stage2-properties.py <glob>", file=sys.stderr)
        sys.exit(2)
    pattern = sys.argv[1]
    dirs = [Path(p) for p in sorted(glob.glob(pattern)) if Path(p).is_dir()]
    dirs = [d for d in dirs if RUN_NAME_RE.search(d.name)]
    if not dirs:
        print(f"no sweep-cell dirs matched: {pattern}", file=sys.stderr)
        sys.exit(1)

    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]

    # Sort: dataset alphabetical, arm (cold first), concurrency ascending
    rows.sort(key=lambda r: (r["dataset"], r["cache_arm"], r["concurrency"]))

    # Write CSV
    out_csv = dirs[0].parent / "s2.0-properties-summary.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    # Build the grid: one row per (dataset, arm), one column per concurrency —
    # the arm is a first-class dimension so cold and warm never collapse together.
    datasets = sorted(set(r["dataset"] for r in rows))
    arms = sorted(set(r["cache_arm"] for r in rows))
    concurrencies = sorted(set(r["concurrency"] for r in rows))
    grid = {(r["dataset"], r["cache_arm"], r["concurrency"]): r for r in rows}

    print()
    print("# Stage 2.0 OpenSlide property extraction sweep — POSIX, filesystem under test")
    print()
    print("Tool: openslide-python + multiprocessing.Pool")
    print("Headline: 'the filesystem cataloged N slides in X seconds at concurrency C.'")
    print()

    def grid_table(title, key, fmt):
        print(f"## {title}")
        print()
        hdr = "| dataset · arm \\ n | " + " | ".join(str(j) for j in concurrencies) + " |"
        sep = "|" + "---|" * (len(concurrencies) + 1)
        print(hdr); print(sep)
        for ds in datasets:
            for arm in arms:
                cells = []
                for n in concurrencies:
                    r = grid.get((ds, arm, n))
                    v = r.get(key) if r else None
                    cells.append(fmt(v) if v is not None else "—")
                print(f"| **{ds} · {arm}** | " + " | ".join(cells) + " |")
        print()

    grid_table("Headline: total seconds to catalog the dataset",
               "app_total_seconds", lambda v: f"{v:.2f}")
    grid_table("Headline: slides cataloged per second (app-level)",
               "app_slides_per_sec", lambda v: f"{v:.0f}" if v >= 100 else f"{v:.1f}")
    grid_table("Per-slide mean latency (ms)",
               "per_slide_lat_mean_ms", lambda v: f"{v:.2f}")
    grid_table("Per-slide p99 latency (ms)",
               "per_slide_lat_p99_ms", lambda v: f"{v:.2f}")
    grid_table("Per-slide max latency (ms) — slowest single slide in the run",
               "per_slide_lat_max_ms", lambda v: f"{v:.0f}")
    grid_table("WEKA client Read sustained (MiB/s) — per-ts sum across the client's frontends",
               "weka_read_sustained_bps", lambda v: f"{v/(1024**2):.2f}" if v < 1024**3 else f"{v/(1024**3):.2f} GiB/s")
    grid_table("WEKA Ops/s sustained — NEW headline metric for Stage 2 (metadata ops)",
               "weka_ops_sustained", lambda v: f"{v/1000:.1f}k" if v >= 1000 else f"{v:.0f}")
    grid_table("WEKA Ops/s peak — burst metadata-ops capacity",
               "weka_ops_max", lambda v: f"{v/1000:.1f}k" if v >= 1000 else f"{v:.0f}")
    grid_table("RDMA rcv sustained (MiB/s) — wire-level read direction on mlx5_0",
               "rdma_rcv_sustained_bps", lambda v: f"{v/(1024**2):.2f}")
    grid_table("Ops/s ÷ (slides/sec) — internal metadata ops per OpenSlide.open()",
               "ratio_weka_ops_over_app_slides_per_sec", lambda v: f"{v:.1f}")

    # Headline pick
    print()
    valid = [r for r in rows if r.get("app_slides_per_sec")]
    if valid:
        peak = max(valid, key=lambda r: r["app_slides_per_sec"])
        print(f"**Peak slides/sec across the sweep:** {peak['app_slides_per_sec']:.0f} "
              f"({peak['dataset']}, n={peak['concurrency']}, {peak['cache_arm']}, "
              f"{peak.get('app_total_seconds', '?')}s for {peak.get('app_slides_total', '?')} slides)")

    print()
    print("## Cross-source consistency canary")
    print()
    print("Stage 2 expectations: read-only workload. RDMA rcv ≈ weka client Read (no read amplification).")
    print("Ops/s should be much higher than slides/sec because each `OpenSlide.OpenSlide(path)` triggers")
    print("many internal metadata ops (open, multiple read syscalls into header + tile-offset tables).")
    print()
    print("| dataset | n | arm | RDMA_rcv/weka_R (expect ~1.0-1.4) | Ops_per_sec/slides_per_sec (expect >>1) |")
    print("|---|---|---|---|---|")
    issues = []
    for r in rows:
        rb = r.get("ratio_rdma_rcv_over_weka_read")
        rb_s = f"{rb:.2f}" if rb is not None else "—"
        opr = r.get("ratio_weka_ops_over_app_slides_per_sec")
        opr_s = f"{opr:.1f}" if opr is not None else "—"
        print(f"| {r['dataset']} | {r['concurrency']} | {r['cache_arm']} | {rb_s} | {opr_s} |")
        if rb is not None and not (0.7 <= rb <= 1.6):
            issues.append(f"  - {r['dataset']} n={r['concurrency']}: RDMA_rcv/weka_R={rb:.2f} (outside 0.7-1.6)")
    print()
    if issues:
        print("**⚠️ Cross-source disagreements:**")
        for line in issues:
            print(line)
    else:
        print("All cells within expected bands. ✅")


if __name__ == "__main__":
    main()
