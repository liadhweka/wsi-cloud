#!/usr/bin/env python3
"""parse-results.py — read a run's raw/* CSVs, emit results.json.

Usage:
    parse-results.py <run-dir>

Re-runnable on any existing run directory; the parser is independent of the
wrapper so improving the parser does NOT require re-running the benchmark.

Reads:
    raw/weka-stats.csv      WEKA per-process per-second
    raw/nvidia-smi.csv      GPU per-second
    raw/ib-counters.csv     IB cumulative byte/packet counters per-second
    raw/sar.csv             sysstat all-metrics, semicolon-delimited
    cmd.log                 if it contains fio JSON output, parsed structurally

Writes:
    results.json — per-source aggregates: count, mean, p50, p95, p99,
                   min, max, stdev, sustained_mean (idle-robust active-window
                   mean; old last-80%-chronological value kept as
                   sustained_mean_last80), active_window_mean

Stdlib only (csv, json, statistics) — no pip deps.
"""

import argparse
import csv
import json
import re
import statistics
import sys
from pathlib import Path
from datetime import datetime


# ---- Unit-aware value parsing -----------------------------------------------
# WEKA stats with --raw-units emits "<n> B/s"; nvidia-smi --format=csv emits
# "<n> %", "<n> MiB", "<n> W", "<n> MHz"; sar emits bare floats. Strip the
# unit suffix (or apply a multiplier) so we can aggregate the numeric portion.
_NUM = r"-?[\d.]+"
_UNIT_PATTERNS = [
    (re.compile(rf"^({_NUM})\s*B/s$"),    1.0),
    (re.compile(rf"^({_NUM})\s*KB/s$"),   1e3),
    (re.compile(rf"^({_NUM})\s*MB/s$"),   1e6),
    (re.compile(rf"^({_NUM})\s*GB/s$"),   1e9),
    (re.compile(rf"^({_NUM})\s*KiB/s$"),  1024.0),
    (re.compile(rf"^({_NUM})\s*MiB/s$"),  1024.0**2),
    (re.compile(rf"^({_NUM})\s*GiB/s$"),  1024.0**3),
    (re.compile(rf"^({_NUM})\s*%$"),      1.0),
    (re.compile(rf"^({_NUM})\s*MiB$"),    1.0),
    (re.compile(rf"^({_NUM})\s*GiB$"),    1.0),
    (re.compile(rf"^({_NUM})\s*W$"),      1.0),
    (re.compile(rf"^({_NUM})\s*MHz$"),    1.0),
    (re.compile(rf"^({_NUM})\s*Hz$"),     1.0),
    (re.compile(rf"^({_NUM})\s*C$"),      1.0),  # temperature
    (re.compile(rf"^({_NUM})$"),          1.0),  # bare float
]

# Columns that look numeric but are identifiers / labels — meaningless to
# aggregate (mean of node IDs etc.). Pattern matches column-name substrings.
_IDENT_PATTERNS = [
    re.compile(r"^(node\s*id|index|timestamp|hostname|roles?|mode|"
               r"interface|name|jobname|cpu|pid|uid|gid)$", re.I),
    re.compile(r"\bid\b", re.I),
]


def parse_unit(s):
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    s = s.strip()
    if not s:
        return None
    for pat, mult in _UNIT_PATTERNS:
        m = pat.match(s)
        if m:
            try:
                return float(m.group(1)) * mult
            except ValueError:
                continue
    return None


def is_identifier(col_name):
    if col_name is None:
        return True
    name = col_name.strip()
    return any(p.search(name) for p in _IDENT_PATTERNS)


def detect_delimiter(path: Path) -> str:
    with path.open() as f:
        head = f.readline()
    if ";" in head and "," not in head:
        return ";"
    return ","


def read_rows(path: Path):
    """Read CSV. Skip lines that begin with '#' (sadf-style comment headers)
    AFTER the first row; the first row is treated as the column header even
    if it begins with '#'."""
    if not path.exists() or path.stat().st_size == 0:
        return []
    delim = detect_delimiter(path)
    with path.open(newline="") as f:
        # Strip the leading '#' from the first line so DictReader gets clean
        # column names; preserve all subsequent non-comment data rows.
        first = f.readline()
        if first.startswith("#"):
            first = first[1:].lstrip()
        rest = [ln for ln in f if not ln.lstrip().startswith("#")]
    header = next(csv.reader([first], delimiter=delim))
    reader = csv.DictReader(rest, fieldnames=header, delimiter=delim)
    return list(reader)


def numeric_columns(rows, sample_size: int = 200):
    if not rows:
        return []
    cols = []
    for col in rows[0].keys():
        if col is None or is_identifier(col):
            continue
        sample = [r.get(col, "") for r in rows[:sample_size]]
        ok = 0
        nonempty = 0
        for v in sample:
            if v is None or v == "":
                continue
            nonempty += 1
            if parse_unit(v) is not None:
                ok += 1
        if nonempty >= 3 and ok >= max(3, nonempty // 2):
            cols.append(col)
    return cols


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


def aggregate(values):
    nums = []
    for v in values:
        x = parse_unit(v)
        if x is not None:
            nums.append(x)
    if not nums:
        return None
    n = len(nums)
    sorted_nums = sorted(nums)

    def pct(p):
        idx = int(p * n / 100)
        return sorted_nums[min(idx, n - 1)]

    sustained_start = int(n * 0.2) if n > 5 else 0
    return {
        "count": n,
        "mean": statistics.fmean(nums),
        "median": statistics.median(nums),
        "p50": pct(50),
        "p95": pct(95),
        "p99": pct(99),
        "min": sorted_nums[0],
        "max": sorted_nums[-1],
        "stdev": statistics.stdev(nums) if n > 1 else 0.0,
        "sustained_mean": _active_window_mean(nums),
        "sustained_mean_last80": statistics.fmean(nums[sustained_start:]),
        "active_window_mean": _active_window_mean(nums),
    }


def summarize_csv(path: Path):
    rows = read_rows(path)
    if not rows:
        return {"present": False, "row_count": 0, "metrics": {}}
    summary = {"present": True, "row_count": len(rows), "metrics": {}}
    for col in numeric_columns(rows):
        agg = aggregate([r.get(col, "") for r in rows])
        if agg is not None:
            summary["metrics"][col] = agg
    return summary


def _delta_aggregate(rows, key_col, count_cols):
    """Generic cumulative-counter -> per-second-delta aggregator.

    Groups rows by `key_col`, computes per-pair deltas of each `count_col`,
    aggregates non-negative deltas (negatives = wrap/reset).
    Returns {key_value: {col_per_sec: aggregate, ...}, ...}
    """
    by_key = {}
    for r in rows:
        k = r.get(key_col)
        if not k:
            continue
        by_key.setdefault(k, []).append(r)

    out = {}
    for k, krows in by_key.items():
        deltas = {f"{c}_per_sec": [] for c in count_cols}
        for prev, curr in zip(krows, krows[1:]):
            for c in count_cols:
                try:
                    d = float(curr[c]) - float(prev[c])
                    if d >= 0:
                        deltas[f"{c}_per_sec"].append(d)
                except (ValueError, KeyError, TypeError):
                    continue
        agg_set = {}
        for col, vals in deltas.items():
            agg = aggregate(vals)
            if agg is not None:
                agg_set[col] = agg
        out[k] = agg_set
    return out


def derive_ib_rates(path: Path):
    """IPoIB counters from /sys/class/net/<iface>/statistics/. Cumulative -> deltas."""
    rows = read_rows(path)
    if not rows:
        return {"present": False}
    return {
        "present": True,
        "row_count": len(rows),
        "note": "IPoIB control-plane only; NOT the wekafs RDMA data path",
        "interfaces": _delta_aggregate(
            rows, "interface",
            ["tx_bytes", "rx_bytes", "tx_packets", "rx_packets"],
        ),
    }


def derive_rdma_rates(path: Path):
    """RDMA counters from /sys/class/infiniband/<dev>/ports/1/counters/. The
    wekafs data path. xmit_bytes/rcv_bytes already converted from 4-byte
    words to bytes by the wrapper."""
    rows = read_rows(path)
    if not rows:
        return {"present": False}
    return {
        "present": True,
        "row_count": len(rows),
        "note": "Native RDMA — wekafs data path",
        "devices": _delta_aggregate(
            rows, "ibdev",
            ["xmit_bytes", "rcv_bytes", "xmit_packets", "rcv_packets"],
        ),
    }


def parse_fio_from_log(cmd_log: Path):
    """If cmd.log contains fio's --output-format=json+ output, extract the
    final complete JSON object and pull out the headline numbers."""
    if not cmd_log.exists():
        return None
    text = cmd_log.read_text(errors="replace")
    # fio json+ emits one big JSON object at the end (with --status-interval,
    # also intermediate ones). Find balanced object boundaries.
    # Simple approach: find the last '\n}\n' or '}\n' at end of file.
    candidates = []
    depth = 0
    start = -1
    for i, ch in enumerate(text):
        if ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0 and start >= 0:
                candidates.append((start, i + 1))
                start = -1
    # Walk backwards through candidates trying to find one that parses as fio.
    for s, e in reversed(candidates):
        try:
            obj = json.loads(text[s:e])
            if isinstance(obj, dict) and "jobs" in obj:
                return obj
        except json.JSONDecodeError:
            continue
    return None


def fio_summary(fio_obj):
    out = {
        "fio_version": fio_obj.get("fio version"),
        "global_options": fio_obj.get("global options"),
        "jobs_summary": [],
    }
    # NOTE: clat_ns.percentile.99 measures completion-event observation only.
    # At iodepth=1 with libaio, the completion is observed synchronously inside
    # io_submit, so clat shrinks to syscall overhead while lat_ns (= slat + clat)
    # is the true end-to-end I/O time. We export both: lat_ns_mean is reliable
    # across all configs; clat_ns_p99 is meaningful when iodepth > 1.
    def clat_p99_ns(io):
        return ((io.get("clat_ns") or {}).get("percentile") or {}).get("99.000000")
    def lat_mean_ns(io):
        return (io.get("lat_ns") or {}).get("mean")
    for job in fio_obj.get("jobs", []):
        read = job.get("read", {}) or {}
        write = job.get("write", {}) or {}
        out["jobs_summary"].append({
            "jobname": job.get("jobname"),
            "read": {
                "iops_mean": read.get("iops_mean"),
                "bw_mean_kib": read.get("bw_mean"),
                "lat_ns_p99": clat_p99_ns(read),
                "lat_ns_mean": lat_mean_ns(read),
            },
            "write": {
                "iops_mean": write.get("iops_mean"),
                "bw_mean_kib": write.get("bw_mean"),
                "lat_ns_p99": clat_p99_ns(write),
                "lat_ns_mean": lat_mean_ns(write),
            },
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    args = ap.parse_args()
    run_dir = args.run_dir
    if not run_dir.is_dir():
        print(f"not a directory: {run_dir}", file=sys.stderr)
        sys.exit(2)

    raw = run_dir / "raw"
    results = {
        "run_dir": str(run_dir.resolve()),
        "parsed_at_utc": datetime.utcnow().isoformat() + "Z",
        "sources": {},
    }

    results["sources"]["weka_stats"]   = summarize_csv(raw / "weka-stats.csv")
    results["sources"]["nvidia_smi"]   = summarize_csv(raw / "nvidia-smi.csv")
    # Two interface-level streams:
    #   ipoib-counters: IPoIB control-plane traffic (NOT wekafs data path).
    #   rdma-counters:  native RDMA, the actual wekafs data path.
    results["sources"]["ipoib_counters"] = derive_ib_rates(raw / "ipoib-counters.csv")
    results["sources"]["rdma_counters"]  = derive_rdma_rates(raw / "rdma-counters.csv")
    # sar is split into per-category CSVs by record-run.sh's cleanup (cpu, disk,
    # net, mem, swap, paging, queue, ctxsw). Each is a clean single-header CSV.
    sar = {}
    for cat in ("cpu", "disk", "net", "mem", "swap", "paging", "queue", "ctxsw"):
        cat_path = raw / f"sar-{cat}.csv"
        if cat_path.exists():
            sar[cat] = summarize_csv(cat_path)
    results["sources"]["sar"] = sar

    fio_obj = parse_fio_from_log(run_dir / "cmd.log")
    if fio_obj is not None:
        results["fio"] = fio_summary(fio_obj)

    out_path = run_dir / "results.json"
    with out_path.open("w") as f:
        json.dump(results, f, indent=2, default=str)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
