#!/usr/bin/env python3
"""aggregate-stage4c-kvikio.py — walk Stage 4.C run dirs, emit summary CSV.

Stage 4.C cell run dirs follow:
    <UTC>-s4.C-{mode}-{dataset}-nb{n_buffer}-nt{num_threads}-{compat}gds[-{tag}]
  e.g.
    2026-05-16-180000-s4.C-faithful-brca-nb256-nt16-offgds
    2026-05-16-180300-s4.C-random-brca-nb64-nt16-ongds
    2026-05-16-181100-s4.C-random-brca-nb256-nt16-offgds-prereg

Per cell, this aggregator reads:
  - reader-summary.json (app-level: tiles/sec, GB/s, latencies, knob settings)
  - .run_start / .run_end (recording window from record-run.sh)
  - raw/weka-stats.csv — per-timestamp sum across the client frontends
    (Read column; for faithful mode reads are large-sequential, for random mode
    they're random small)
  - raw/rdma-counters.csv — rcv on the wekafs DPDK device (typically mlx5_0)
  - raw/sar-cpu.csv — aggregate application-core %busy (recorded reserved cores excluded)
  - raw/nvidia-smi.csv — GPU memory used & util (PRIMARY for Stage 4.C since
    kvikIO writes directly into GPU memory)

Emits:
  - runs/s4.C-kvikio-summary.csv (1 row per cell)

WHY this is a separate aggregator from 4.B's:
  - 4.C has different knobs (n_buffer, num_threads, compat_mode, mode-faithful-vs-random)
  - 4.C promotes nvidia-smi to primary
  - 4.C cells emit reader-summary.json with different fields (no batch_size, etc.)
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE = re.compile(
    r"-s4\.C-(?P<mode>faithful|random)-(?P<dataset>brca|cam16)-"
    r"nb(?P<nb>\d+)-nt(?P<nt>\d+)-(?P<compat>off|on)gds"
    r"(?:-(?P<tag>[\w-]+))?$"
)

# Multi-process cell name pattern from tier2_mp:
#   <ts>-s4.C-random-brca-N<N>-nb<nb>-nt<nt>-<off|on>gds-mp
MP_RUN_NAME_RE = re.compile(
    r"-s4\.C-(?P<mode>random|faithful)-(?P<dataset>brca|cam16)-"
    r"N(?P<N>\d+)-nb(?P<nb>\d+)-nt(?P<nt>\d+)-(?P<compat>off|on)gds-mp$"
)
_BPS_RE = re.compile(r"^\s*([\d.eE+-]+)\s*B/s\s*$")


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


def parse_run_dir_name(p):
    # Try multi-process first (more specific)
    m = MP_RUN_NAME_RE.search(p.name)
    if m:
        d = m.groupdict()
        return {
            "mode": d["mode"],
            "dataset": d["dataset"],
            "n_buffer": int(d["nb"]),
            "num_threads": int(d["nt"]),
            "compat_mode": d["compat"],
            "n_processes": int(d["N"]),
            "tag": "mp",
        }
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    d = m.groupdict()
    return {
        "mode": d["mode"],
        "dataset": d["dataset"],
        "n_buffer": int(d["nb"]),
        "num_threads": int(d["nt"]),
        "compat_mode": d["compat"],  # "off" = GDS-on, "on" = POSIX
        "n_processes": 1,
        "tag": d["tag"] or "",
    }


def parse_iso_utc(s):
    return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    rs = run_dir / "raw" / ".run_start"
    re_path = run_dir / "raw" / ".run_end"
    if not rs.exists() or not re_path.exists():
        return None, None
    return parse_iso_utc(rs.read_text()), parse_iso_utc(re_path.read_text())


def parse_bps(s):
    if not s:
        return 0.0
    m = _BPS_RE.match(s)
    if m:
        return float(m.group(1))
    try:
        return float(s)
    except ValueError:
        return 0.0


def parse_numeric(s):
    """Strip whitespace + common unit suffixes ('MiB', '%', 'W', etc.) and parse a float."""
    if s is None:
        return 0.0
    s = str(s).strip()
    # Strip trailing unit suffix if present: e.g. "1 MiB" → "1", "0 %" → "0"
    for suffix in (" MiB", " %", " W", " MHz", " B/s"):
        if s.endswith(suffix):
            s = s[: -len(suffix)].strip()
            break
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def weka_client_per_sec(run_dir, col, parser=parse_bps):
    """Sum a column from weka-stats.csv across the client frontends per timestamp.

    Returns list of per-second sums (one float per recorded timestamp).

    WHY this function exists: per the project-memory aggregator pattern (Stage 1.5
    discovery), the parser's pre-aggregated weka_stats metric is the MEAN across
    all (host, role, mode, NodeID) tuples — diluted ~100× by idle backend rows.
    For client-side WEKA throughput, sum per timestamp across the client's frontends
    only.

    NOTE column name in the CSV is lowercase `timestamp` (not `Timestamp`); using
    the wrong case silently buckets all rows into one empty-string key, inflating
    the "mean" by N_samples ≈ 230×.
    """
    p = run_dir / "raw" / "weka-stats.csv"
    if not p.exists():
        return []
    sums_by_ts = {}
    with p.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Selected by ROLE alone: hostnames and Node IDs are both rebuild-
            # unstable, and this cluster runs exactly ONE client container by
            # design, so Mode=="client" uniquely selects it.
            if row.get("Mode") != "client":
                continue
            ts = row.get("timestamp", "")
            if not ts:
                continue
            val = parser(row.get(col, ""))
            sums_by_ts[ts] = sums_by_ts.get(ts, 0.0) + val
    return list(sums_by_ts.values())



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

def parse_cpu_aggregate_excluding_dpdk(run_dir):
    """Aggregate application-core CPU %busy (the storage client's recorded
    reserved cores excluded -- see _reserved_cores).

    NOTE sar-cpu.csv uses SEMICOLON delimiter and the first column header is
    `# hostname` (with leading #). DictReader needs delimiter=';' and we strip
    the leading '#' from the first key.
    """
    p = run_dir / "raw" / "sar-cpu.csv"
    if not p.exists():
        return None
    reserved = _reserved_cores(run_dir)
    by_ts_total = {}
    by_ts_count = {}
    with p.open() as f:
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            cpu = row.get("CPU", "")
            if cpu in ("-1", "all", ""):
                continue
            if cpu in reserved:
                continue
            ts = row.get("timestamp", "")
            if not ts:
                continue
            try:
                idle = float(row.get("%idle", "100"))
            except ValueError:
                continue
            busy = max(0.0, 100.0 - idle)
            by_ts_total[ts] = by_ts_total.get(ts, 0.0) + busy
            by_ts_count[ts] = by_ts_count.get(ts, 0) + 1
    if not by_ts_total:
        return None
    means_per_ts = []
    for ts, tot in by_ts_total.items():
        c = by_ts_count.get(ts, 1)
        if c > 0:
            means_per_ts.append(tot / c)
    if not means_per_ts:
        return None
    means_per_ts.sort()
    return {
        "non_dpdk_cpu_mean_pct": sum(means_per_ts) / len(means_per_ts),
        "non_dpdk_cpu_p95_pct": means_per_ts[int(len(means_per_ts) * 0.95)] if len(means_per_ts) > 1 else means_per_ts[0],
        "non_dpdk_cpu_max_pct": means_per_ts[-1],
        "n_samples": len(means_per_ts),
    }


def extract_rdma_rcv(run_dir, device="mlx5_0"):
    """Extract rcv bandwidth (in bytes/sec) on a specific RDMA device.

    NOTE rdma-counters.csv has columns: timestamp, ibdev, xmit_bytes, rcv_bytes,
    xmit_packets, rcv_packets, xmit_wait, xmit_discards. **Values are CUMULATIVE
    counters (since boot or driver load), not rates.** Must take diffs between
    consecutive timestamps for the same device, divided by the time delta, to
    get bytes/sec.
    """
    p = run_dir / "raw" / "rdma-counters.csv"
    if not p.exists():
        return None
    rows_by_dev = []
    with p.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("ibdev") != device:
                continue
            ts = row.get("timestamp", "")
            try:
                rcv = float(row.get("rcv_bytes", "0"))
            except ValueError:
                continue
            if not ts:
                continue
            # Parse ISO 8601 to epoch float seconds for diff
            try:
                dt = datetime.fromisoformat(ts.rstrip("Z"))
                t_epoch = dt.timestamp()
            except ValueError:
                continue
            rows_by_dev.append((t_epoch, rcv))

    if len(rows_by_dev) < 2:
        return None

    rows_by_dev.sort(key=lambda x: x[0])
    rates = []
    for i in range(1, len(rows_by_dev)):
        dt_ = rows_by_dev[i][0] - rows_by_dev[i - 1][0]
        db = rows_by_dev[i][1] - rows_by_dev[i - 1][1]
        if dt_ > 0 and db >= 0:
            rates.append(db / dt_)
    if not rates:
        return None
    rates.sort()
    return {
        "rdma_rcv_mean_bps": (_active_window_mean(rates) or 0.0),
        "rdma_rcv_full_mean_bps": sum(rates) / len(rates),
        "rdma_rcv_p95_bps": rates[int(len(rates) * 0.95)] if len(rates) > 1 else rates[0],
        "rdma_rcv_max_bps": rates[-1],
        "n_samples": len(rates),
    }


def extract_nvidia_gpu(run_dir, gpu_index=None):
    """Get max GPU memory used (MiB) + max GPU util (%). Optionally filter by index.

    NOTE nvidia-smi.csv has columns with LEADING SPACES (header is
    `index, timestamp, utilization.gpu [%], ...` so subsequent columns parse as
    ` timestamp`, ` utilization.gpu [%]`, etc.) AND VALUES INCLUDE UNIT SUFFIXES
    like '1 MiB' and '0 %' — parse_numeric strips both.
    """
    p = run_dir / "raw" / "nvidia-smi.csv"
    if not p.exists():
        return None
    mem_used = []
    util = []
    with p.open() as f:
        reader = csv.DictReader(f, skipinitialspace=True)
        for row in reader:
            if gpu_index is not None and str(row.get("index", "")) != str(gpu_index):
                continue
            mu = parse_numeric(row.get("memory.used [MiB]", "0"))
            ut = parse_numeric(row.get("utilization.gpu [%]", "0"))
            mem_used.append(mu)
            util.append(ut)
    if not mem_used:
        return None
    return {
        "gpu_mem_max_mib": max(mem_used),
        "gpu_mem_mean_mib": sum(mem_used) / len(mem_used),
        "gpu_util_max_pct": max(util),
        "gpu_util_mean_pct": sum(util) / len(util),
        "n_samples": len(util),
    }


def _gds_engaged_from_accounting(reader):
    pa = reader.get("path_accounting") or {}
    per_proc = pa.get("per_process_gds_engaged")
    if per_proc:
        uniq = sorted(set(per_proc))
        return uniq[0] if len(uniq) == 1 else "mixed(" + ",".join(uniq) + ")"
    return pa.get("gds_engaged", "unknown")


def extract_cell_summary(run_dir):
    """Build one CSV row for this Stage 4.C cell.

    For multi-process cells (tag='mp'), per-process summaries live at
    run_dir/proc<i>-summary.json; we sum tiles/sec, GB/s, n_tiles across them.
    """
    parsed = parse_run_dir_name(run_dir)
    if parsed is None:
        return None

    reader = {}
    if parsed.get("tag") == "mp":
        # Multi-process cell: aggregate per-process summaries
        proc_summaries = sorted(run_dir.glob("proc*-summary.json"))
        per_proc = []
        for p in proc_summaries:
            try:
                per_proc.append(json.loads(p.read_text()))
            except json.JSONDecodeError:
                continue
        if per_proc:
            # Sum across processes for the cell aggregate
            sum_tiles = sum(s.get("n_tiles_steady", 0) for s in per_proc)
            sum_bytes = sum(s.get("bytes_steady_aligned", 0) for s in per_proc)
            sum_tps  = sum(s.get("tiles_per_sec_steady", 0) for s in per_proc)
            sum_gbps = sum(s.get("gbps_steady", 0) for s in per_proc)
            # All procs ran the same wallclock (~60s steady); take from first
            wall_steady = per_proc[0].get("wallclock_steady_s", 0.0)
            reader = {
                "tiles_per_sec_steady": sum_tps,
                "gbps_steady": sum_gbps,
                "n_tiles_steady": sum_tiles,
                "bytes_steady_aligned": sum_bytes,
                "wallclock_steady_s": wall_steady,
                "n_slides_in_pool": per_proc[0].get("n_slides_in_pool", 0),
                "n_processes": len(per_proc),
                "per_process_tps": [s.get("tiles_per_sec_steady", 0) for s in per_proc],
                "per_process_gbps": [s.get("gbps_steady", 0) for s in per_proc],
                "latency_stats_per_tile_batch": per_proc[0].get("latency_stats_per_tile_batch", {}),
                # Per-process verdicts; the nvidia-fs delta is device-global, so
                # under concurrency each per-process split is an upper bound —
                # a uniform verdict across processes is still decisive.
                "path_accounting": {
                    "per_process_gds_engaged":
                        [(_s.get("path_accounting") or {}).get("gds_engaged", "unknown")
                         for _s in per_proc],
                },
            }
    else:
        reader_summary_path = run_dir / "reader-summary.json"
        if reader_summary_path.exists():
            try:
                reader = json.loads(reader_summary_path.read_text())
            except json.JSONDecodeError:
                pass

    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if (rs_dt and re_dt) else None

    # Primary sources
    weka_read_per_ts = weka_client_per_sec(run_dir, "Read")
    weka_read_mean = (_active_window_mean(weka_read_per_ts) or 0.0)
    weka_read_full_mean = sum(weka_read_per_ts) / len(weka_read_per_ts) if weka_read_per_ts else 0.0
    weka_read_max = max(weka_read_per_ts) if weka_read_per_ts else 0.0

    rdma = extract_rdma_rcv(run_dir) or {}
    cpu = parse_cpu_aggregate_excluding_dpdk(run_dir) or {}
    gpu = extract_nvidia_gpu(run_dir) or {}

    row = {
        "run_dir": run_dir.name,
        "mode": parsed["mode"],
        "dataset": parsed["dataset"],
        "compat_mode": parsed["compat_mode"],
        # REQUESTED cuFile mode, read off the run-dir name. This says what the
        # cell was ASKED to do -- never what it did.
        "cufile_mode_requested": parsed["compat_mode"],
        # ACHIEVED path, from the reader's recorded GPU-direct-vs-bounced byte
        # split (path_accounting; D-6) — NEVER from the requested mode, which is
        # precisely the "a configuration flag is not proof of behaviour" failure
        # D8 forbids. Values: gds | partial | none | no-reads |
        # unknown-accounting-off (the nvidia-fs counters were disabled — the
        # standing constraint that an all-zero split must never read as "no
        # GPU-direct traffic") | unknown (no recorded split at all: pre-D-6
        # cells, or a summary that failed to land). For multi-process cells the
        # verdict is the per-process consensus, or "mixed(...)" when processes
        # disagree — a disagreement is a finding, not an aggregation choice.
        "gds_engaged": _gds_engaged_from_accounting(reader),
        "n_buffer": parsed["n_buffer"],
        "num_threads": parsed["num_threads"],
        "n_processes": parsed.get("n_processes", 1),
        "tag": parsed["tag"],
        "duration_s": duration,
        # App-level (from reader-summary.json)
        "app_tiles_per_sec": reader.get("tiles_per_sec_steady") or reader.get("tiles_per_sec_cell") or 0.0,
        "app_gbps": reader.get("gbps_steady") or reader.get("gbps_cell") or 0.0,
        "app_n_tiles": reader.get("n_tiles_steady") or reader.get("total_tiles") or 0,
        "app_n_slides_read": reader.get("n_slides_read") or reader.get("n_slides_in_pool") or 0,
        "app_wallclock_s": reader.get("wallclock_steady_s") or reader.get("cell_wallclock_s") or 0.0,
        "app_lat_p50_ms": (reader.get("latency_stats_per_tile_batch") or {}).get("p50_ms"),
        "app_lat_p95_ms": (reader.get("latency_stats_per_tile_batch") or {}).get("p95_ms"),
        "app_lat_p99_ms": (reader.get("latency_stats_per_tile_batch") or {}).get("p99_ms"),
        # WEKA-side
        "weka_read_mean_MiBps": weka_read_mean / (1024 * 1024),
        "weka_read_max_MiBps": weka_read_max / (1024 * 1024),
        # RDMA-side
        "rdma_rcv_mean_MiBps": (rdma.get("rdma_rcv_mean_bps") or 0.0) / (1024 * 1024),
        "rdma_rcv_max_MiBps": (rdma.get("rdma_rcv_max_bps") or 0.0) / (1024 * 1024),
        # Cross-source ratio: at GDS-on, RDMA rcv should track app reads ~1× (no read amplification)
        "ratio_rdma_over_app": (
            (rdma.get("rdma_rcv_mean_bps") or 0.0) / ((reader.get("gbps_steady") or reader.get("gbps_cell") or 0.0) * 1e9)
            if (reader.get("gbps_steady") or reader.get("gbps_cell")) else None
        ),
        # CPU non-DPDK
        "cpu_non_dpdk_mean_pct": cpu.get("non_dpdk_cpu_mean_pct"),
        "cpu_non_dpdk_p95_pct": cpu.get("non_dpdk_cpu_p95_pct"),
        "cpu_non_dpdk_max_pct": cpu.get("non_dpdk_cpu_max_pct"),
        # GPU (PRIMARY for 4.C)
        "gpu_mem_max_MiB": gpu.get("gpu_mem_max_mib"),
        "gpu_mem_mean_MiB": gpu.get("gpu_mem_mean_mib"),
        "gpu_util_max_pct": gpu.get("gpu_util_max_pct"),
        "gpu_util_mean_pct": gpu.get("gpu_util_mean_pct"),
    }
    return row


def main():
    if len(sys.argv) < 2:
        pattern = str(Path(__file__).resolve().parent.parent / "runs" / "2026-*-s4.C-*")
    else:
        pattern = sys.argv[1]
    print(f"# Aggregating Stage 4.C cells matching: {pattern}", file=sys.stderr)

    rows = []
    for path in sorted(glob.glob(pattern)):
        d = Path(path)
        if not d.is_dir():
            continue
        if "s4.C-convert" in d.name:
            # Skip the conversion prep cell; it's not a sweep cell
            continue
        row = extract_cell_summary(d)
        if row is None:
            continue
        rows.append(row)
        print(f"  {d.name}: tps={row['app_tiles_per_sec']:.0f} GB/s={row['app_gbps']:.2f} "
              f"weka_R={row['weka_read_mean_MiBps']:.0f}MiB/s "
              f"cufile_requested={row['cufile_mode_requested']} "
              f"gds_achieved={row['gds_engaged']}",
              file=sys.stderr)

    if not rows:
        print("# No cells matched.", file=sys.stderr)
        return 1

    out_path = Path(__file__).resolve().parent.parent / "runs" / "s4.C-kvikio-summary.csv"
    fieldnames = list(rows[0].keys())
    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"# Wrote {len(rows)} rows to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
