#!/usr/bin/env python3
"""aggregate-sweep.py — walk a set of run dirs and produce a sweep summary.

Usage:
    aggregate-sweep.py <glob-pattern>
    e.g. aggregate-sweep.py 'runs/2026-05-04-*-s1.0-seqw-*'

For each matching run dir, pulls headline numbers from results.json:
  - fio: bandwidth, IOPS, p99 latency
  - rdma: peak/sustained xmit on the device that carried the workload
  - weka_stats: present-or-not (cross-check sanity)

Outputs:
  - <sweep-name>-summary.csv next to the first matching run dir's parent
  - prints a markdown grid to stdout (bs × jobs)

Stdlib only.
"""
import csv
import glob
from datetime import datetime


def _parse_iso_utc(s):
    """`date -u +%FT%TZ` -> datetime, or None. Tolerant of a trailing Z."""
    s = (s or "").strip()
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _run_window(run_dir):
    """(start_iso, end_iso, duration_s) from raw/.run_start + raw/.run_end.

    Returns (None, None, None) when either stamp is missing or unparseable --
    an aborted cell has no end stamp, and inventing a duration for it would put
    a fabricated number in the column cost is computed from.
    """
    raw = run_dir / "raw"
    try:
        s_raw = (raw / ".run_start").read_text()
        e_raw = (raw / ".run_end").read_text()
    except OSError:
        return None, None, None
    s, e = _parse_iso_utc(s_raw), _parse_iso_utc(e_raw)
    if s is None or e is None:
        return None, None, None
    return s_raw.strip(), e_raw.strip(), (e - s).total_seconds()
import json
import re
import sys
from pathlib import Path


# Parse run dir suffixes like:
#   "...-s1.0-seqw-bs64k-jobs8"
#   "...-s1.0b-seqr-bs4k-jobs1"
#   "...-s1.0c-randw-bs16k-jobs32"
RUN_NAME_RE = re.compile(r"-(s\d+(?:\.\d+[a-z]?)?)-([a-z]+)-bs([0-9a-zA-Z]+)-jobs(\d+)$")


def bs_to_bytes(bs_str):
    """Convert a fio block-size string ('4k', '256k', '1M', '4M') to bytes."""
    s = bs_str.lower()
    if s.endswith("k"):
        return int(float(s[:-1]) * 1024)
    if s.endswith("m"):
        return int(float(s[:-1]) * 1024 * 1024)
    return int(s)


def parse_run_dir_name(p: Path):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    stage, workload, bs, jobs = m.groups()
    return {"stage": stage, "workload": workload, "bs": bs, "jobs": int(jobs),
            "bs_bytes": bs_to_bytes(bs)}


def extract_cell_summary(run_dir: Path):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None:
        return None
    results_path = run_dir / "results.json"
    if not results_path.exists():
        return {**parsed, "status": "NO_RESULTS"}
    try:
        d = json.loads(results_path.read_text())
    except Exception as e:
        return {**parsed, "status": f"JSON_ERROR:{e}"}

    out = dict(parsed)
    out["run_dir"] = run_dir.name

    # The recorder's own window, from raw/.run_start + raw/.run_end.
    #
    # Without it this summary carries no time basis at all, and cost-to-complete
    # -- both bases, infra-only and all-in, PROJECT-THESIS.md section 4 --
    # cannot be reconstructed from it afterwards.
    # That matters most here of all the aggregators: these are the Stage-1.0
    # synthetic ceiling cells, the denominator every downstream "% of ceiling"
    # divides by, so they are also the reference the per-leg cost roll-up is
    # anchored against. Absent stamps yield None rather than a guessed duration.
    out["run_start_utc"], out["run_end_utc"], out["duration_s"] = _run_window(run_dir)

    # fio numbers — both write and read sides extracted; the workload
    # detection below picks which side to display in the headline grid.
    fio = d.get("fio", {})
    jobs = fio.get("jobs_summary", [])
    if jobs:
        j = jobs[0]
        w = j.get("write", {})
        r = j.get("read", {})
        out["fio_write_bw_kib"] = w.get("bw_mean_kib")
        out["fio_write_iops"] = w.get("iops_mean")
        out["fio_write_p99_ns"] = w.get("lat_ns_p99")
        out["fio_write_lat_mean_ns"] = w.get("lat_ns_mean")
        out["fio_read_bw_kib"] = r.get("bw_mean_kib")
        out["fio_read_iops"] = r.get("iops_mean")
        out["fio_read_p99_ns"] = r.get("lat_ns_p99")
        out["fio_read_lat_mean_ns"] = r.get("lat_ns_mean")

    # RDMA: extract BOTH xmit and rcv across all devices. The "data direction"
    # depends on the workload — for writes, data flows out (xmit); for reads,
    # data flows in (rcv). xmit alone undercounts read workloads by 10-20×.
    rdma = (d.get("sources") or {}).get("rdma_counters") or {}
    devs = rdma.get("devices") or {}
    max_xmit = 0.0; max_rcv = 0.0
    max_xmit_dev = None; max_rcv_dev = None
    for dev, m in devs.items():
        x = (m.get("xmit_bytes_per_sec") or {}).get("sustained_mean") or 0
        r = (m.get("rcv_bytes_per_sec")  or {}).get("sustained_mean") or 0
        if x > max_xmit: max_xmit = x; max_xmit_dev = dev
        if r > max_rcv:  max_rcv  = r; max_rcv_dev  = dev
    out["rdma_xmit_bytes_sustained"] = max_xmit
    out["rdma_xmit_dev"] = max_xmit_dev
    out["rdma_rcv_bytes_sustained"] = max_rcv
    out["rdma_rcv_dev"] = max_rcv_dev

    # Sanity: the leg's own fs-side stream present? (the other leg's column
    # reads 0 by construction — results.json is leg-invariant in shape)
    wk = (d.get("sources") or {}).get("weka_stats") or {}
    out["weka_stats_rows"] = wk.get("row_count", 0)
    ls = (d.get("sources") or {}).get("lustre_stats_client") or {}
    out["lustre_stats_ticks"] = ls.get("tick_count", 0)

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-sweep.py <glob>", file=sys.stderr)
        sys.exit(2)
    pattern = sys.argv[1]
    dirs = [Path(p) for p in sorted(glob.glob(pattern)) if Path(p).is_dir()]
    if not dirs:
        print(f"no dirs matched: {pattern}", file=sys.stderr)
        sys.exit(1)

    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]

    # Reference cells (workload 'warmref' — the D13 evidence cells the 1.0b/d
    # sweeps carry) are excluded from the grid: keyed on (bs, jobs) they would
    # silently collide with the grid cell at the same point, which is the exact
    # pair the reference exists to contrast with. Printed separately below.
    refrows = [r for r in rows if r["workload"] == "warmref"]
    rows = [r for r in rows if r["workload"] != "warmref"]

    # Group by (workload, stage) — typically all the same in one sweep.
    if not rows:
        print("no parseable rows", file=sys.stderr)
        sys.exit(1)

    workload = rows[0]["workload"]
    stage = rows[0]["stage"]
    # Detect read-vs-write workload to know which side of fio's stats to display.
    is_read = workload in ("seqr", "randr")
    side = "read" if is_read else "write"

    # CSV next to runs/
    _LEG_OUT = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (summary CSVs are per-leg files: D6 concurrent legs)")
    out_csv = dirs[0].parent / f"{stage}-{workload}-summary-{_LEG_OUT}.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    # Markdown grid: bs × jobs, value = fio_write_bw_kib in MiB/s
    bs_set = sorted(set(r["bs"] for r in rows), key=lambda b: bs_to_bytes(b))
    jobs_set = sorted(set(r["jobs"] for r in rows))

    grid = {(r["bs"], r["jobs"]): r for r in rows}

    print()
    print(f"# {stage} {workload} sweep — bandwidth grid")
    bw_key = f"fio_{side}_bw_kib"
    iops_key = f"fio_{side}_iops"
    lat_mean_key = f"fio_{side}_lat_mean_ns"
    lat_p99_key = f"fio_{side}_p99_ns"

    print()
    print(f"## fio {side} bandwidth (MiB/s, mean over steady state)")
    print()
    hdr = "| bs \\ jobs | " + " | ".join(str(j) for j in jobs_set) + " |"
    sep = "|" + "---|" * (len(jobs_set) + 1)
    print(hdr)
    print(sep)
    for bs in bs_set:
        cells = []
        for j in jobs_set:
            r = grid.get((bs, j))
            if r and r.get(bw_key):
                cells.append(f"{r[bw_key]/1024:.0f}")
            else:
                cells.append("—")
        print(f"| **{bs}** | " + " | ".join(cells) + " |")

    print()
    print(f"## fio {side} mean latency (ms) — from lat_ns.mean (end-to-end, reliable across all configs)")
    print()
    print(hdr)
    print(sep)
    for bs in bs_set:
        cells = []
        for j in jobs_set:
            r = grid.get((bs, j))
            if r and r.get(lat_mean_key):
                cells.append(f"{r[lat_mean_key]/1e6:.2f}")
            else:
                cells.append("—")
        print(f"| **{bs}** | " + " | ".join(cells) + " |")

    print()
    print(f"## fio {side} p99 latency (ms) — from clat_ns.percentile (meaningful when iodepth > 1)")
    print()
    print(hdr)
    print(sep)
    for bs in bs_set:
        cells = []
        for j in jobs_set:
            r = grid.get((bs, j))
            if r and r.get(lat_p99_key):
                cells.append(f"{r[lat_p99_key]/1e6:.2f}")
            else:
                cells.append("—")
        print(f"| **{bs}** | " + " | ".join(cells) + " |")

    print()
    print(f"## fio {side} IOPS")
    print()
    print(hdr)
    print(sep)
    for bs in bs_set:
        cells = []
        for j in jobs_set:
            r = grid.get((bs, j))
            if r and r.get(iops_key):
                v = r[iops_key]
                cells.append(f"{v/1000:.1f}k" if v >= 1000 else f"{v:.0f}")
            else:
                cells.append("—")
        print(f"| **{bs}** | " + " | ".join(cells) + " |")

    # For reads, data flows IN to the client (rcv); for writes, OUT (xmit).
    rdma_key = "rdma_rcv_bytes_sustained" if is_read else "rdma_xmit_bytes_sustained"
    rdma_label = "rcv" if is_read else "xmit"
    print()
    print(f"## RDMA {rdma_label} (MiB/s sustained, all devices) — the data path direction for {side}s")
    print()
    print(hdr)
    print(sep)
    for bs in bs_set:
        cells = []
        for j in jobs_set:
            r = grid.get((bs, j))
            if r and r.get(rdma_key):
                cells.append(f"{r[rdma_key]/1024**2:.0f}")
            else:
                cells.append("—")
        print(f"| **{bs}** | " + " | ".join(cells) + " |")

    # Headline takeaways
    print()
    valid = [r for r in rows if r.get(bw_key)]
    if valid:
        peak = max(valid, key=lambda r: r[bw_key])
        print(f"**Peak fio {side} bandwidth:** {peak[bw_key]/1024:.0f} MiB/s "
              f"({peak[bw_key]/1024**2:.2f} GiB/s) "
              f"at bs={peak['bs']}, jobs={peak['jobs']}")
        valid_iops = [r for r in valid if r.get(iops_key)]
        if valid_iops:
            peak_iops = max(valid_iops, key=lambda r: r[iops_key])
            print(f"**Peak fio {side} IOPS:** {peak_iops[iops_key]:,.0f} "
                  f"at bs={peak_iops['bs']}, jobs={peak_iops['jobs']}")

    # Reference cells — the D13 evidence the grid's cold construction rests on.
    # Their informative content is the warm-vs-cold contrast: the second half of
    # a warmref's own timeline (split-window) is deliberately cache-served, and
    # for randr the whole cell re-reads a just-touched region. Compare against
    # the matching grid cell; never fold into the grid.
    if refrows:
        print()
        print("## Reference cells (D13 evidence — not grid cells)")
        for r in refrows:
            grid_twin = grid.get((r["bs"], r["jobs"]))
            twin_bw = f'{grid_twin["fio_read_bw_kib"]/1024:.0f} MiB/s' if grid_twin and grid_twin.get("fio_read_bw_kib") else "—"
            own_bw = f'{r["fio_read_bw_kib"]/1024:.0f} MiB/s' if r.get("fio_read_bw_kib") else "—"
            print(f"- `{r['run_dir']}` (bs={r['bs']}, jobs={r['jobs']}): warmref mean {own_bw} "
                  f"vs grid twin {twin_bw} — split-window detail in the run's results.json/timeline")


if __name__ == "__main__":
    main()
