#!/usr/bin/env python3
"""parse-results.py — read a run's raw/* CSVs, emit results.json.

Usage:
    parse-results.py <run-dir>

Re-runnable on any existing run directory; the parser is independent of the
wrapper so improving the parser does NOT require re-running the benchmark.

Reads:
    raw/weka-stats.csv        WEKA per-process per-second (client rows summed per timestamp)
    raw/nvidia-smi.csv        GPU per-second
    raw/netdev-counters.csv   kernel NIC cumulative counters per-second
    raw/rdma-counters.csv     RDMA/EFA device counters (absent -> header-only)
    raw/nvidia-fs-stats.log   verbatim nvidia-fs accounting (presence only until D-6)
    raw/sar-<cat>.csv         sysstat per-category CSVs
    cmd.log                   if it contains fio JSON output, parsed structurally

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


def _row_epoch(row):
    """Seconds-since-epoch from a recorder row's `timestamp`, or None.

    The recorders write `date -u +%FT%TZ`, so this is second-resolution UTC.
    Tolerant of a trailing Z, of an offset, and of a bare epoch number, because
    a rate that silently falls back to a wrong dt is the failure this exists to
    prevent -- if the stamp cannot be read we drop the pair rather than guess.
    """
    ts = (row.get("timestamp") or "").strip()
    if not ts:
        return None
    try:                                   # bare epoch seconds
        return float(ts)
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _delta_aggregate(rows, key_col, count_cols):
    """Generic cumulative-counter -> per-SECOND rate aggregator.

    Groups rows by `key_col`, then for each consecutive pair computes
    (delta counter) / (delta timestamp) -- a RATE, not a raw delta.

    WHY THE DIVISION IS LOAD-BEARING: the recorders sleep 1 s *plus* loop
    overhead, and under load a sample can slip by several seconds. Treating the
    raw delta as a per-second rate then overstates every wire-counter rate by
    exactly the slip, and those rates feed the cross-source consistency canary
    -- so the error inflates the wire side of a ratio check and can either mask
    a real inconsistency or manufacture a false one.

    Pairs are dropped when dt is missing or non-positive (clock step, duplicate
    stamp), and when the counter delta is negative (wrap/reset).

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
        dts = []
        for prev, curr in zip(krows, krows[1:]):
            t0, t1 = _row_epoch(prev), _row_epoch(curr)
            if t0 is None or t1 is None:
                continue
            dt = t1 - t0
            if dt <= 0:
                continue
            dts.append(dt)
            for c in count_cols:
                try:
                    d = float(curr[c]) - float(prev[c])
                    if d >= 0:
                        deltas[f"{c}_per_sec"].append(d / dt)
                except (ValueError, KeyError, TypeError):
                    continue
        agg_set = {}
        for col, vals in deltas.items():
            agg = aggregate(vals)
            if agg is not None:
                agg_set[col] = agg
        if dts:
            # Surfaced so a reader can see the sampling actually achieved rather
            # than assuming 1 Hz. Second-resolution stamps quantise dt, so a
            # sub-second slip is invisible here -- that residual is recorded as
            # an open item, not silently absorbed.
            agg_set["_sample_interval_s"] = {
                "count": len(dts), "mean": sum(dts) / len(dts),
                "min": min(dts), "max": max(dts),
            }
        out[k] = agg_set
    return out


def derive_netdev_rates(path: Path):
    """Kernel netdev counters from /sys/class/net/<iface>/statistics/.
    Cumulative -> per-second rates. Primary-vs-Diagnostic is per-leg (RUNBOOK
    table): Diagnostic on the WEKA leg (DPDK bypasses the kernel) except on
    1.7, where the S3 source traffic makes them Primary on both legs."""
    rows = read_rows(path)
    if not rows:
        return {"present": False}
    return {
        "present": True,
        "row_count": len(rows),
        "note": "kernel netdev counters; Primary/Diagnostic split is per-leg (docs/RUNBOOK.md)",
        "interfaces": _delta_aggregate(
            rows, "interface",
            ["tx_bytes", "rx_bytes", "tx_packets", "rx_packets"],
        ),
    }


def derive_rdma_rates(path: Path):
    """RDMA-device counters from /sys/class/infiniband/<dev>/ports/1/. Two
    shapes per device — IB-spec counters/ (4-byte words, converted to bytes by
    the wrapper) and EFA hw_counters/ (bytes) — recorded as separate rows.
    Keyed on device+source so deltas never mix the two streams."""
    rows = read_rows(path)
    if not rows:
        return {"present": False}
    for r in rows:
        if r.get("ibdev") and r.get("source"):
            r["ibdev"] = f'{r["ibdev"]}/{r["source"]}'
    return {
        "present": True,
        "row_count": len(rows),
        "note": "RDMA/EFA device counters; header-only where no such device exists",
        "devices": _delta_aggregate(
            rows, "ibdev",
            ["xmit_bytes", "rcv_bytes", "xmit_packets", "rcv_packets"],
        ),
    }


# Columns summed across this client's processes per timestamp (rates and byte
# gauges add); latency and CPU%% are averaged instead — a latency does not sum.
_WEKA_SUM_COLS = ["Writes/s", "Write", "Reads/s", "Read", "Ops/s",
                  "L6 Recv", "L6 Sent", "OBS Upload", "OBS Download",
                  "RDMA Recv", "RDMA Sent"]
_WEKA_MEAN_COLS = ["Write Latency(µs)", "Read Latency(µs)", "CPU%"]


def derive_weka_client(path: Path):
    """The filesystem-side number for THIS client, per cross-cutting pattern #1:
    filter to the client's own rows by ROLE (Mode=="client" — this cluster runs
    exactly one client container by design; never a hostname or numeric id),
    sum across the client's processes PER TIMESTAMP, then aggregate the
    per-second sums. A whole-stream mean averages in every idle backend row and
    under-reports by ~100x while looking plausible."""
    rows = read_rows(path)
    client = [r for r in rows if (r.get("Mode") or "").strip().lower() == "client"]
    if not client:
        return {"present": False,
                "note": "no Mode==client rows — the client filter matched nothing; "
                        "the filesystem-side number for this cell is MISSING, not zero"}
    by_ts = {}
    for r in client:
        ts = r.get("timestamp")
        if ts:
            by_ts.setdefault(ts, []).append(r)
    series = {c: [] for c in _WEKA_SUM_COLS + _WEKA_MEAN_COLS}
    for ts in sorted(by_ts):
        group = by_ts[ts]
        for c in _WEKA_SUM_COLS:
            vals = [parse_unit(r.get(c, "")) for r in group]
            vals = [v for v in vals if v is not None]
            if vals:
                series[c].append(sum(vals))
        for c in _WEKA_MEAN_COLS:
            vals = [parse_unit(r.get(c, "")) for r in group]
            vals = [v for v in vals if v is not None]
            if vals:
                series[c].append(sum(vals) / len(vals))
    metrics = {}
    for c, vals in series.items():
        agg = aggregate(vals)
        if agg is not None:
            suffix = "_client_sum" if c in _WEKA_SUM_COLS else "_client_mean"
            metrics[c + suffix] = agg
    return {
        "present": True,
        "client_process_count": len({r.get("Node ID") for r in client}),
        "timestamp_count": len(by_ts),
        "note": "Mode==client rows only, summed per timestamp across the client's "
                "processes (latency/CPU%% averaged) — the quotable filesystem-side "
                "series for this cell",
        "metrics": metrics,
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

    # weka_stats: whole-stream per-column aggregates (context only — they average
    # every process row, backends included). weka_stats_client is the quotable
    # per-client series (pattern #1). Keep both: the divergence between them is
    # itself a check that the filter matched.
    results["sources"]["weka_stats"]        = summarize_csv(raw / "weka-stats.csv")
    results["sources"]["weka_stats_client"] = derive_weka_client(raw / "weka-stats.csv")
    results["sources"]["nvidia_smi"]   = summarize_csv(raw / "nvidia-smi.csv")
    results["sources"]["netdev_counters"] = derive_netdev_rates(raw / "netdev-counters.csv")
    results["sources"]["rdma_counters"]   = derive_rdma_rates(raw / "rdma-counters.csv")
    # nvidia-fs accounting is captured verbatim (timestamped raw blocks); its
    # parser is written against the enabled-under-load format with D-6, so for
    # now results.json records presence and block count only.
    nvfs = raw / "nvidia-fs-stats.log"
    if nvfs.exists() and nvfs.stat().st_size > 0:
        blocks = sum(1 for ln in nvfs.open(errors="replace") if ln.startswith("=== "))
        results["sources"]["nvidia_fs_stats"] = {"present": True, "block_count": blocks,
                                                 "note": "verbatim 1 Hz capture; parsed with D-6"}
    else:
        results["sources"]["nvidia_fs_stats"] = {"present": False}
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
