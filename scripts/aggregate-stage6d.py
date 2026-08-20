#!/usr/bin/env python3
"""aggregate-stage6d.py — Stage 6.D end-to-end pipeline timing aggregator.

Per cell, reads:
  - pipeline-summary.json (orchestrator's per-phase + total wallclock)
  - per-phase-summary.csv (per-phase status + notes)
  - raw/weka-stats.csv    (WEKA Read+Write per-second across the full pipeline)
  - raw/rdma-counters.csv (RDMA rcv rate)
  - raw/nvidia-smi.csv    (GPU util for the extract + MIL phases)

Emits runs/s6.D-e2e-summary.csv — one row per cell with:
  cell_name, backend, model, total_wallclock_s, per_phase_wallclock_s columns,
  weka_read_mean / max, weka_write_mean / max, GPU util mean during extract+mil phases

Customer-quotable single-cell metric: total_wallclock_s = "full TCGA-BRCA from
raw SVS to trained MIL classifier in T seconds (= T/60 minutes / T/3600 hours)."

Run-dir patterns:
  <UTC>-s6.D-pipeline-e2e-{backend}-{model}  e.g. -s6.D-pipeline-e2e-kvikio-virchow2
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE_D = re.compile(
    r"-s6\.D-pipeline-e2e-(?P<backend>kvikio|cucim)-(?P<model>virchow2|gigapath|uni2-h)$"
)


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
    window diluting a throughput headline."""
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


def weka_client_per_sec(run_dir, col):
    p = run_dir / "raw" / "weka-stats.csv"
    if not p.exists(): return []
    sums = {}
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get("Mode") != "client": continue
            ts = row.get("timestamp", "")
            if not ts: continue
            sums[ts] = sums.get(ts, 0.0) + _bps(row.get(col, ""))
    return list(sums.values())


def extract_cell_summary(run_dir):
    m = RUN_NAME_RE_D.search(run_dir.name)
    if not m: return None
    d = m.groupdict()

    pipeline = {}
    pp = run_dir / "pipeline-summary.json"
    if pp.exists():
        try: pipeline = json.loads(pp.read_text())
        except json.JSONDecodeError: pass

    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if rs_dt and re_dt else None

    weka_read = weka_client_per_sec(run_dir, "Read")
    weka_write = weka_client_per_sec(run_dir, "Write")

    row = {
        "run_dir": run_dir.name,
        "backend": d["backend"],
        "model": d["model"],
        "embedding_dim": pipeline.get("embedding_dim"),
        "pipeline_wallclock_s": pipeline.get("pipeline_end_to_end_wallclock_s"),
        "duration_s": duration,
        "n_features_pt_produced": pipeline.get("n_features_pt_produced"),
        "weka_read_MiBps_mean": ((_active_window_mean(weka_read) or 0.0) / (1024 * 1024)) if weka_read else 0.0,
        "weka_read_MiBps_full_mean": (sum(weka_read) / len(weka_read) / (1024 * 1024)) if weka_read else 0.0,
        "weka_read_MiBps_max": (max(weka_read) / (1024 * 1024)) if weka_read else 0.0,
        "weka_write_MiBps_mean": ((_active_window_mean(weka_write) or 0.0) / (1024 * 1024)) if weka_write else 0.0,
        "weka_write_MiBps_full_mean": (sum(weka_write) / len(weka_write) / (1024 * 1024)) if weka_write else 0.0,
        "weka_write_MiBps_max": (max(weka_write) / (1024 * 1024)) if weka_write else 0.0,
    }

    # Per-phase wallclock columns
    for phase in pipeline.get("phases", []):
        name = phase.get("phase")
        if name:
            try: row[f"{name}_wallclock_s"] = float(phase.get("wallclock_s", 0))
            except (ValueError, TypeError): pass
            row[f"{name}_status"] = phase.get("status")

    # Derive percentages
    total = row.get("pipeline_wallclock_s")
    if total and total > 0:
        for k, v in list(row.items()):
            if k.endswith("_wallclock_s") and k != "pipeline_wallclock_s" and k != "duration_s":
                row[k.replace("_wallclock_s", "_pct_of_total")] = (v / total) * 100.0
    return row


def main():
    _LEG = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (the default glob is leg-scoped: pulled other-leg run dirs must not enter this leg's summary CSV)")
    pattern = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "runs" / f"2026-*-{_LEG}-s6.D-pipeline-e2e-*")
    print(f"# Aggregating 6.D cells matching: {pattern}", file=sys.stderr)
    rows = []
    for p in sorted(glob.glob(pattern)):
        d = Path(p)
        if not d.is_dir(): continue
        if "smoke" in d.name: continue
        row = extract_cell_summary(d)
        if row is None: continue
        rows.append(row)
        wc = row.get("pipeline_wallclock_s") or 0
        print(f"  {d.name}: backend={row['backend']} model={row['model']} "
              f"total={wc:.0f}s ({wc/3600:.2f} hr)", file=sys.stderr)

    if not rows:
        print("# No 6.D cells matched.", file=sys.stderr)
        return 1

    out = Path(__file__).resolve().parent.parent / "runs" / "s6.D-e2e-summary.csv"
    # Union fieldnames
    fieldnames = []
    seen = set()
    for r in rows:
        for k in r:
            if k not in seen: seen.add(k); fieldnames.append(k)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows: w.writerow(r)
    print(f"# Wrote {len(rows)} rows to {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
