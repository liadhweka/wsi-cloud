#!/usr/bin/env python3
"""aggregate-stage6c-concurrent.py — Stage 6.C concurrent multi-workload aggregator.

Per cell, reads:
  - orchestration.log     (workload-start barrier timestamp + start/end timestamps)
  - workload-<name>.csv   (per-workload telemetry — file format varies per workload)
  - workload-<name>-summary.json (where the workload was a script that emits one)
  - raw/weka-stats.csv    (cluster-side aggregate)
  - raw/rdma-counters.csv
  - raw/sar-cpu.csv
  - raw/nvidia-smi.csv

Computes per-workload throughput-during-concurrent vs solo-baseline → retention%.
The customer-quotable metric is per-workload retention% under all-four-up
(Tier 4) compared to each workload's Tier 1 solo cell.

Emits runs/s6.C-concurrent-summary.csv — one row per cell, with per-workload
throughput columns + retention% (computed via cross-cell comparison against
tagged Tier 1 cells).

Run-dir patterns:
  <UTC>-s6.C-concurrent-<workloads_tag>
    where <workloads_tag> = workload names joined with '+', e.g.
    'extract+ingest+mil+viewer' for all-four-up.

Smoke runs filtered out by name.

Note on workload-specific telemetry parsing:
  - ingest:  CSV (timestamp, bytes_written_so_far) → derive bytes/sec via diff
  - extract: extraction-steps.csv (Stage 6.A schema) → samples_per_step/step_duration
  - mil:     training-steps.csv (Stage 5/6.B.3 schema) → samples_per_sec
  - viewer:  fio --output-format=json+ JSON with per-second status_interval samples
             → IOPS, bw, p99 latency
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE_C = re.compile(r"-s6\.C-concurrent-(?P<wl>[\w+]+)$")


def percentile(sorted_vals, p):
    if not sorted_vals: return None
    k = max(0, min(len(sorted_vals) - 1, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def parse_iso_utc(s): return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    rs = run_dir / "raw" / ".run_start"
    re_path = run_dir / "raw" / ".run_end"
    if not rs.exists() or not re_path.exists(): return None, None
    return parse_iso_utc(rs.read_text()), parse_iso_utc(re_path.read_text())


def _bps(s):
    if not s: return 0.0
    s = str(s).strip()
    if s.endswith(" B/s"): s = s[:-4].strip()
    try: return float(s)
    except ValueError: return 0.0


def _active_window_mean(seq):
    """Idle-robust mean: trim leading/trailing samples below 5% of peak, then
    average the contiguous active span (internal gaps kept). Immune to a
    storage-idle setup / model-load head or teardown tail inside the recording
    window diluting a throughput headline (Tier-1 recording audit, 2026-07)."""
    seq = list(seq)
    if not seq:
        return None
    peak = max(seq)
    if peak <= 0:
        return sum(seq) / len(seq)
    floor = 0.05 * peak
    idx = [i for i, v in enumerate(seq) if v >= floor]
    if not idx:
        return sum(seq) / len(seq)
    span = seq[idx[0]:idx[-1] + 1]
    return sum(span) / len(span)


def weka_a100_client_per_sec(run_dir, col, parser=_bps):
    p = run_dir / "raw" / "weka-stats.csv"
    if not p.exists(): return []
    sums = {}
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get("Hostname") != "a100" or row.get("Mode") != "client": continue
            ts = row.get("timestamp", "")
            if not ts: continue
            sums[ts] = sums.get(ts, 0.0) + parser(row.get(col, ""))
    return list(sums.values())


# ---------- Per-workload throughput extractors ----------
def extract_ingest_throughput(run_dir):
    """Returns mean bytes/sec from workload-ingest.csv (timestamp,bytes_written diff)."""
    p = run_dir / "workload-ingest.csv"
    if not p.exists(): return None
    pairs = []
    with p.open() as f:
        rd = csv.reader(f)
        next(rd, None)  # header
        for r in rd:
            try:
                ts = float(r[0])
                bz = int(r[1])
                pairs.append((ts, bz))
            except (ValueError, IndexError):
                continue
    if len(pairs) < 2: return None
    pairs.sort()
    rates = []
    for i in range(1, len(pairs)):
        dt_ = pairs[i][0] - pairs[i-1][0]
        db = pairs[i][1] - pairs[i-1][1]
        if dt_ > 0 and db >= 0: rates.append(db / dt_)
    if not rates: return None
    return {
        "ingest_bytes_per_sec_mean": (_active_window_mean(rates) or 0.0),
        "ingest_bytes_per_sec_full_mean": sum(rates) / len(rates),
        "ingest_bytes_per_sec_max": max(rates),
        "ingest_MiBps_mean": (_active_window_mean(rates) or 0.0) / (1024 * 1024),
        "ingest_MiBps_full_mean": (sum(rates) / len(rates)) / (1024 * 1024),
    }


def extract_extract_throughput(run_dir):
    """Returns samples_per_sec from workload-extract.csv (Stage 6.A extraction-steps schema)."""
    # Match what the extractor writes: it's the extraction-steps.csv schema
    p = run_dir / "workload-extract.csv"
    if not p.exists(): return None
    steady_samples = 0
    steady_steps = 0
    step_durs = []
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get("phase") != "steady": continue
            try:
                steady_samples += int(row["samples_per_step"])
                steady_steps += 1
                step_durs.append(float(row["step_duration_ms"]))
            except (KeyError, ValueError):
                continue
    if steady_steps == 0: return None
    # Approximate: steady wallclock from sum of step_durs (close enough for retention math)
    steady_wall = sum(step_durs) / 1000.0
    return {
        "extract_tiles_per_sec_mean": steady_samples / steady_wall if steady_wall > 0 else 0.0,
        "extract_step_ms_mean": sum(step_durs) / len(step_durs),
        "extract_n_steady_steps": steady_steps,
    }


def extract_mil_throughput(run_dir):
    """Returns samples_per_sec from workload-mil.csv (training-steps schema) or summary JSON."""
    sum_path = run_dir / "workload-mil-summary.json"
    if sum_path.exists():
        try:
            s = json.loads(sum_path.read_text())
            return {
                "mil_samples_per_sec_mean": s.get("samples_per_sec_steady"),
                "mil_n_steady_steps": s.get("total_steady_steps"),
            }
        except json.JSONDecodeError:
            pass
    # Fallback: parse training-steps.csv directly
    p = run_dir / "workload-mil.csv"
    if not p.exists(): return None
    steady_samples = 0
    steady_steps = 0
    step_durs = []
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get("phase") != "steady": continue
            try:
                steady_samples += int(row["samples_per_step"])
                steady_steps += 1
                step_durs.append(float(row["step_duration_ms"]))
            except (KeyError, ValueError):
                continue
    if steady_steps == 0: return None
    return {
        "mil_samples_per_sec_mean": steady_samples / (sum(step_durs) / 1000.0)
            if step_durs else 0.0,
        "mil_n_steady_steps": steady_steps,
    }


def extract_viewer_throughput(run_dir):
    """Returns fio iops/bw/p99 from workload-viewer.csv (fio JSON output)."""
    p = run_dir / "workload-viewer.csv"
    if not p.exists(): return None
    try:
        # fio's --output-format=json+ produces one big JSON object (not per-sec records
        # when --status-interval is used; the json+ format wraps everything).
        data = json.loads(p.read_text())
    except json.JSONDecodeError:
        return None
    # Aggregate across all fio jobs
    jobs = data.get("jobs", [])
    if not jobs: return None
    total_iops = sum(j.get("read", {}).get("iops_mean", 0.0) for j in jobs)
    total_bw_kbps = sum(j.get("read", {}).get("bw_mean", 0.0) for j in jobs)  # KB/s
    # p99 latency: take max across jobs (worst-case GPU)
    p99_ns = max(
        (j.get("read", {}).get("clat_ns", {}).get("percentile", {}).get("99.000000", 0.0)
         for j in jobs),
        default=0.0,
    )
    return {
        "viewer_iops_aggregate": total_iops,
        "viewer_bw_MiBps_aggregate": total_bw_kbps / 1024.0,
        "viewer_p99_lat_ms": p99_ns / 1e6,
    }


# ---------- Per-cell aggregator ----------
WORKLOAD_TO_FN = {
    "ingest":  extract_ingest_throughput,
    "extract": extract_extract_throughput,
    "mil":     extract_mil_throughput,
    "viewer":  extract_viewer_throughput,
}


def extract_cell_summary(run_dir):
    m = RUN_NAME_RE_C.search(run_dir.name)
    if not m: return None
    wl_tag = m.group("wl")
    workloads = wl_tag.split("+")

    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if rs_dt and re_dt else None

    row = {
        "run_dir": run_dir.name,
        "workloads_tag": wl_tag,
        "n_workloads": len(workloads),
        "duration_s": duration,
    }

    # Per-workload throughput
    for wl in ["ingest", "extract", "mil", "viewer"]:
        if wl in workloads:
            wl_metrics = WORKLOAD_TO_FN[wl](run_dir) or {}
            for k, v in wl_metrics.items():
                row[k] = v
        else:
            # Not in this cell — note absence
            row[f"{wl}_present"] = 0
        if wl in workloads:
            row[f"{wl}_present"] = 1

    # WEKA-side aggregate
    weka_read = weka_a100_client_per_sec(run_dir, "Read")
    weka_write = weka_a100_client_per_sec(run_dir, "Write")
    row["weka_read_MiBps_mean"] = ((_active_window_mean(weka_read) or 0.0) / (1024*1024)) if weka_read else 0.0
    row["weka_read_MiBps_full_mean"] = (sum(weka_read) / len(weka_read) / (1024*1024)) if weka_read else 0.0
    row["weka_write_MiBps_mean"] = ((_active_window_mean(weka_write) or 0.0) / (1024*1024)) if weka_write else 0.0
    row["weka_write_MiBps_full_mean"] = (sum(weka_write) / len(weka_write) / (1024*1024)) if weka_write else 0.0
    row["weka_read_MiBps_max"] = (max(weka_read) / (1024*1024)) if weka_read else 0.0
    row["weka_write_MiBps_max"] = (max(weka_write) / (1024*1024)) if weka_write else 0.0
    return row


def compute_retention(rows):
    """Find Tier 1 solo cells and compute retention% for each workload in concurrent cells.

    Tier 1 solo cells have workloads_tag in {ingest, extract, mil, viewer}.
    Retention% = (concurrent_throughput / solo_throughput) × 100.
    """
    # Find latest solo baseline per workload (latest by run_dir name, lexicographic)
    solo_baselines = {}  # workload → reference throughput value
    for r in rows:
        tag = r["workloads_tag"]
        if tag in ("ingest", "extract", "mil", "viewer"):
            wl = tag
            key_metric = {
                "ingest":  "ingest_bytes_per_sec_mean",
                "extract": "extract_tiles_per_sec_mean",
                "mil":     "mil_samples_per_sec_mean",
                "viewer":  "viewer_iops_aggregate",
            }[wl]
            val = r.get(key_metric)
            if val:
                solo_baselines[wl] = val

    # Annotate concurrent cells with retention%
    for r in rows:
        if r["n_workloads"] <= 1: continue
        for wl in ["ingest", "extract", "mil", "viewer"]:
            if not r.get(f"{wl}_present"): continue
            key_metric = {
                "ingest":  "ingest_bytes_per_sec_mean",
                "extract": "extract_tiles_per_sec_mean",
                "mil":     "mil_samples_per_sec_mean",
                "viewer":  "viewer_iops_aggregate",
            }[wl]
            cur = r.get(key_metric)
            base = solo_baselines.get(wl)
            if cur and base:
                r[f"{wl}_retention_pct"] = (cur / base) * 100.0
    return rows


def main():
    pattern = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "2026-*-s6.C-concurrent-*")
    print(f"# Aggregating 6.C cells matching: {pattern}", file=sys.stderr)

    rows = []
    for p in sorted(glob.glob(pattern)):
        d = Path(p)
        if not d.is_dir(): continue
        if "smoke" in d.name: continue
        row = extract_cell_summary(d)
        if row is None: continue
        rows.append(row)
        print(f"  {d.name}: n_workloads={row['n_workloads']} weka_read={row.get('weka_read_MiBps_mean',0):.0f}MiB/s",
              file=sys.stderr)

    if not rows:
        print("# No 6.C cells matched.", file=sys.stderr)
        return 1

    rows = compute_retention(rows)
    # Sort: solos first, then by n_workloads ascending, then by tag
    rows.sort(key=lambda r: (r["n_workloads"], r["workloads_tag"]))

    out = Path(__file__).resolve().parent.parent / "s6.C-concurrent-summary.csv"
    # Union fieldnames across all rows (different cells have different per-workload keys)
    fieldnames = []
    seen = set()
    for r in rows:
        for k in r:
            if k not in seen:
                seen.add(k); fieldnames.append(k)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows: w.writerow(r)
    print(f"# Wrote {len(rows)} rows to {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
