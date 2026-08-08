#!/usr/bin/env python3
"""aggregate-stage1-mixed.py — walk Stage 1.6 mixed run dirs, emit summary.

Usage:
    aggregate-stage1-mixed.py <glob-pattern>
    e.g. aggregate-stage1-mixed.py 'runs/2026-*-s1.6-mixed-*'

For each matching run dir:
  - parses results.json's `fio` block for read-side bw, IOPS, p99 latency
  - re-reads weka-stats.csv to compute per-timestamp-summed Read AND Write
    on the a100 client (same pattern as aggregate-stage1-fpsync.py)
  - reads notes.md to extract fpsync (write-side) bytes-transferred
  - extracts RDMA xmit (writes) AND rcv (reads) sustained_mean per device
  - computes cross-source ratios: RDMA_xmit ≈ 2× write_app, RDMA_rcv ≈ 1× read_app

Outputs:
  - runs/s1.6-mixed-summary.csv
  - markdown 2D tables (bs × jobs) for: read bw, read p99 lat, read IOPS,
    write app bw, weka client Read/Write sustained, RDMA xmit/rcv
  - cross-source ratio table per cell

Stdlib only.
"""
import csv
import glob
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE = re.compile(r"-s1\.6-mixed-bs([0-9a-zA-Z]+)-jobs(\d+)$")
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


def parse_run_dir_name(p: Path):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    bs, jobs = m.groups()
    return {"bs": bs, "jobs": int(jobs), "bs_bytes": bs_to_bytes(bs)}


def bs_to_bytes(bs_str):
    s = bs_str.lower()
    if s.endswith("k"):
        return int(float(s[:-1]) * 1024)
    if s.endswith("m"):
        return int(float(s[:-1]) * 1024 * 1024)
    return int(s)


def parse_iso_utc(s: str):
    s = s.strip().rstrip("Z")
    return datetime.fromisoformat(s)


def read_run_window(run_dir: Path):
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
    if not m:
        try:
            return float(s)
        except (ValueError, TypeError):
            return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def weka_a100_client_per_sec(run_dir: Path, col: str):
    """Per-second total of a weka-stats column across all a100 client
    frontend processes (selected by Hostname=="a100" & Mode=="client", NOT by
    Node ID — that global range is reinstall-dependent: 15091-15098 post-2026-07,
    was 941-948). Returns aggregate stats over the per-second sums.

    `col` is the weka-stats column name (e.g. "Read", "Write").
    """
    csv_path = run_dir / "raw" / "weka-stats.csv"
    if not csv_path.exists():
        return None
    per_ts = {}
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("Hostname") != "a100":
                continue
            if row.get("Mode") != "client":
                continue
            ts = row.get("timestamp")
            bps = parse_bps(row.get(col))
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


def parse_fpsync_bytes_from_notes(run_dir: Path):
    nm = run_dir / "notes.md"
    if not nm.exists():
        return None
    text = nm.read_text(errors="replace")
    m = re.search(r"^- Post-cell target bytes: (\d+)\s*$", text, re.M)
    if m:
        return int(m.group(1))
    return None


def extract_rdma_pair(d):
    """Returns (xmit_dev, xmit_bps, rcv_dev, rcv_bps) — picking the device
    that moved the most for each direction. For mixed workload we expect
    xmit ≈ 2× writes (writes amplified by erasure coding) and rcv ≈ reads.
    """
    rdma = (d.get("sources") or {}).get("rdma_counters") or {}
    devs = rdma.get("devices") or {}
    max_xmit, max_xmit_dev = 0.0, None
    max_rcv, max_rcv_dev = 0.0, None
    for dev, m in devs.items():
        x = (m.get("xmit_bytes_per_sec") or {}).get("sustained_mean") or 0
        r = (m.get("rcv_bytes_per_sec")  or {}).get("sustained_mean") or 0
        if x > max_xmit: max_xmit, max_xmit_dev = x, dev
        if r > max_rcv:  max_rcv,  max_rcv_dev  = r, dev
    return max_xmit_dev, max_xmit, max_rcv_dev, max_rcv


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
    out["duration_s"]    = dur

    # results.json
    rj = run_dir / "results.json"
    if not rj.exists():
        out["status"] = "NO_RESULTS"
        return out
    try:
        d = json.loads(rj.read_text())
    except Exception as e:
        out["status"] = f"JSON_ERROR:{e}"
        return out

    # Read side from fio JSON (parser already pulled headline numbers)
    fio = d.get("fio") or {}
    jobs_summary = fio.get("jobs_summary") or []
    if jobs_summary:
        j = jobs_summary[0]
        r = j.get("read") or {}
        out["fio_read_bw_kib"]    = r.get("bw_mean_kib")
        out["fio_read_iops"]      = r.get("iops_mean")
        out["fio_read_lat_mean_ns"] = r.get("lat_ns_mean")
        out["fio_read_lat_p99_ns"]  = r.get("lat_ns_p99")
    else:
        out["fio_read_bw_kib"] = None
        out["fio_read_iops"] = None
        out["fio_read_lat_mean_ns"] = None
        out["fio_read_lat_p99_ns"] = None

    # Write side (fpsync) from notes.md sidecar + run window
    fpsync_bytes = parse_fpsync_bytes_from_notes(run_dir)
    out["fpsync_bytes_total"] = fpsync_bytes
    if fpsync_bytes is not None and dur and dur > 0:
        # Note: "duration_s" is the full record-run.sh window, which closely
        # tracks fio's runtime (600s+60s ramp + a few s of pre/post). For an
        # apples-to-apples write throughput, prefer fpsync's actual completion
        # time from cmd.log if available — but du-based ÷ run-window gives a
        # reasonable approximation since fpsync occupies most of the window.
        out["fpsync_bw_bytes_per_sec"] = fpsync_bytes / dur
        out["fpsync_bw_mib_per_sec"]   = fpsync_bytes / dur / (1024**2)
    else:
        out["fpsync_bw_bytes_per_sec"] = None
        out["fpsync_bw_mib_per_sec"]   = None

    # WEKA-side primary numbers (per-timestamp-sum across a100 client procs)
    wk_read  = weka_a100_client_per_sec(run_dir, "Read")
    wk_write = weka_a100_client_per_sec(run_dir, "Write")
    out["weka_read_sustained_bps"]  = wk_read["sustained_mean"]  if wk_read  else None
    out["weka_write_sustained_bps"] = wk_write["sustained_mean"] if wk_write else None
    out["weka_read_max_bps"]  = wk_read["max"]  if wk_read  else None
    out["weka_write_max_bps"] = wk_write["max"] if wk_write else None

    # RDMA wire-level
    xmit_dev, xmit_bps, rcv_dev, rcv_bps = extract_rdma_pair(d)
    out["rdma_xmit_sustained_bps"] = xmit_bps if xmit_bps > 0 else None
    out["rdma_xmit_dev"]           = xmit_dev
    out["rdma_rcv_sustained_bps"]  = rcv_bps if rcv_bps > 0 else None
    out["rdma_rcv_dev"]            = rcv_dev

    # Read-side ratios (data flows IN on reads = rcv direction)
    read_app = (out["fio_read_bw_kib"] or 0) * 1024.0
    if read_app > 0 and out["rdma_rcv_sustained_bps"]:
        out["ratio_rdma_rcv_over_read_app"] = out["rdma_rcv_sustained_bps"] / read_app
    else:
        out["ratio_rdma_rcv_over_read_app"] = None
    if read_app > 0 and out["weka_read_sustained_bps"]:
        out["ratio_weka_read_over_read_app"] = out["weka_read_sustained_bps"] / read_app
    else:
        out["ratio_weka_read_over_read_app"] = None

    # Write-side ratios (data flows OUT on writes = xmit direction; ~2× from EC)
    write_app = out["fpsync_bw_bytes_per_sec"] or 0
    if write_app > 0 and out["rdma_xmit_sustained_bps"]:
        out["ratio_rdma_xmit_over_write_app"] = out["rdma_xmit_sustained_bps"] / write_app
    else:
        out["ratio_rdma_xmit_over_write_app"] = None
    if write_app > 0 and out["weka_write_sustained_bps"]:
        out["ratio_weka_write_over_write_app"] = out["weka_write_sustained_bps"] / write_app
    else:
        out["ratio_weka_write_over_write_app"] = None

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-stage1-mixed.py <glob>", file=sys.stderr)
        sys.exit(2)
    pattern = sys.argv[1]
    dirs = [Path(p) for p in sorted(glob.glob(pattern)) if Path(p).is_dir()]
    dirs = [d for d in dirs if RUN_NAME_RE.search(d.name)]
    if not dirs:
        print(f"no sweep-cell dirs matched: {pattern}", file=sys.stderr)
        sys.exit(1)

    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]
    rows.sort(key=lambda r: (r["bs_bytes"], r["jobs"]))

    out_csv = dirs[0].parent / "s1.6-mixed-summary.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    bs_set   = sorted(set(r["bs"] for r in rows), key=bs_to_bytes)
    jobs_set = sorted(set(r["jobs"] for r in rows))
    grid     = {(r["bs"], r["jobs"]): r for r in rows}

    print()
    print("# Stage 1.6 mixed sweep — concurrent fpsync ingest + fio randread")
    print()
    print("Ingest: fpsync -n 4 (FIXED, 1.72 GiB/s baseline from 1.5)")
    print("Read:   fio --rw=randread --iodepth=8 against pre-staged scratch on wekafs")
    print()

    def grid_table(title, key, fmt):
        print(f"## {title}")
        print()
        hdr = "| bs \\ jobs | " + " | ".join(str(j) for j in jobs_set) + " |"
        sep = "|" + "---|" * (len(jobs_set) + 1)
        print(hdr); print(sep)
        for bs in bs_set:
            cells = []
            for j in jobs_set:
                r = grid.get((bs, j))
                v = r.get(key) if r else None
                cells.append(fmt(v) if v is not None else "—")
            print(f"| **{bs}** | " + " | ".join(cells) + " |")
        print()

    grid_table("fio read bandwidth (MiB/s, mean over steady state)",
               "fio_read_bw_kib", lambda v: f"{v/1024:.0f}")
    grid_table("fio read mean latency (ms) — viewer-relevant",
               "fio_read_lat_mean_ns", lambda v: f"{v/1e6:.2f}")
    grid_table("fio read p99 latency (ms) — tail-latency story",
               "fio_read_lat_p99_ns", lambda v: f"{v/1e6:.2f}")
    grid_table("fio read IOPS",
               "fio_read_iops", lambda v: f"{v/1000:.1f}k" if v >= 1000 else f"{v:.0f}")
    grid_table("fpsync write bandwidth (MiB/s) — concurrent ingest stream",
               "fpsync_bw_mib_per_sec", lambda v: f"{v:.0f}")
    grid_table("WEKA client Read sustained (MiB/s) — per-ts sum across 8 a100 frontends",
               "weka_read_sustained_bps", lambda v: f"{v/(1024**2):.0f}")
    grid_table("WEKA client Write sustained (MiB/s) — per-ts sum across 8 a100 frontends",
               "weka_write_sustained_bps", lambda v: f"{v/(1024**2):.0f}")
    grid_table("RDMA rcv sustained (MiB/s) — wire-level read direction",
               "rdma_rcv_sustained_bps", lambda v: f"{v/(1024**2):.0f}")
    grid_table("RDMA xmit sustained (MiB/s) — wire-level write direction (~2× write app)",
               "rdma_xmit_sustained_bps", lambda v: f"{v/(1024**2):.0f}")

    # Cross-source ratio canary
    print("## Cross-source consistency canary")
    print()
    print("Expected: weka/app ratios ≈ 1.0 (both directions); RDMA xmit/write_app ≈ 2.0 (3+2 erasure);")
    print("RDMA rcv/read_app ≈ 1.0 (no read amplification). Bands trip warnings.")
    print()
    print("| bs | jobs | weka_R/read_app | RDMA_rcv/read_app | weka_W/write_app | RDMA_xmit/write_app |")
    print("|---|---|---|---|---|---|")
    issues = []
    for r in rows:
        a = r.get("ratio_weka_read_over_read_app")
        b = r.get("ratio_rdma_rcv_over_read_app")
        c = r.get("ratio_weka_write_over_write_app")
        e = r.get("ratio_rdma_xmit_over_write_app")
        a_s = f"{a:.2f}" if a is not None else "—"
        b_s = f"{b:.2f}" if b is not None else "—"
        c_s = f"{c:.2f}" if c is not None else "—"
        e_s = f"{e:.2f}" if e is not None else "—"
        print(f"| {r['bs']} | {r['jobs']} | {a_s} | {b_s} | {c_s} | {e_s} |")
        for label, val, lo, hi in [
            ("weka_R/read_app",     a, 0.7, 1.5),
            ("RDMA_rcv/read_app",   b, 0.7, 1.6),
            ("weka_W/write_app",    c, 0.7, 1.5),
            ("RDMA_xmit/write_app", e, 1.3, 2.5),
        ]:
            if val is not None and not (lo <= val <= hi):
                issues.append(f"  - bs={r['bs']} jobs={r['jobs']}: {label}={val:.2f} (outside {lo}-{hi})")
    print()
    if issues:
        print("**⚠️ Cross-source disagreements:**")
        for line in issues:
            print(line)
    else:
        print("All cells within expected bands. ✅")


if __name__ == "__main__":
    main()
