#!/usr/bin/env python3
"""aggregate-stage6b.py — Stage 6.B aggregator (all sub-tiers).

Two output CSVs:
  runs/s6.B-stress-summary.csv   — one row per 6.B.2 file-IO stress cell
  runs/s6.B-mil-summary.csv      — one row per 6.B.3 MIL training cell

Per cell, reads:
  6.B.2:
    - file-io-summary.json (reader's aggregate)
    - per-file-latencies.csv (sampled per-load latency)
  6.B.3:
    - training-summary.json (trainer's aggregate)
    - training-steps.csv (per-step CSV)
  Both:
    - raw/weka-stats.csv (WEKA Read sum + Ops/s — PRIMARY for 6.B)
    - raw/rdma-counters.csv (mlx5_0 rcv rate)
    - raw/sar-cpu.csv (non-DPDK %busy)
    - raw/sar-mem.csv (memory pressure — PRIMARY for 6.B per roadmap)
    - raw/nvidia-smi.csv (GPU util; relevant only for B.3)

Run-dir patterns:
  6.B.2: <UTC>-s6.B.2-stress-{corpus_name}-n{N}-{pattern}
  6.B.3: <UTC>-s6.B.3-train-mil-{model}-{features_tag}-bs{B}-nw{NW}

Smoke runs (with 'smoke' in dir name) are skipped from summaries.
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE_B2 = re.compile(
    r"-s6\.B\.2-stress-(?P<corpus>syn-N\d+-sz\d+MB-(fp32|fp16))-n(?P<n>\d+)-(?P<pat>random|batched-shuffled|sequential)$"
)
RUN_NAME_RE_B3 = re.compile(
    r"-s6\.B\.3-train-mil-(?P<model>virchow2|gigapath|uni2-h)-(?P<features_tag>[\w_]+)-bs(?P<bs>\d+)-nw(?P<nw>\d+)$"
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


def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = max(0, min(len(sorted_vals) - 1, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def parse_bps(s):
    if not s:
        return 0.0
    m = _BPS_RE.match(s)
    if m: return float(m.group(1))
    try: return float(s)
    except ValueError: return 0.0


def parse_numeric(s):
    if s is None: return 0.0
    s = str(s).strip()
    for suffix in (" MiB", " %", " W", " MHz", " B/s", " kB"):
        if s.endswith(suffix):
            s = s[: -len(suffix)].strip()
            break
    try: return float(s)
    except (ValueError, TypeError): return 0.0


def parse_iso_utc(s): return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    rs = run_dir / "raw" / ".run_start"
    re_path = run_dir / "raw" / ".run_end"
    if not rs.exists() or not re_path.exists():
        return None, None
    return parse_iso_utc(rs.read_text()), parse_iso_utc(re_path.read_text())


def weka_client_per_sec(run_dir, col, parser=parse_bps):
    p = run_dir / "raw" / "weka-stats.csv"
    if not p.exists(): return []
    sums = {}
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get("Mode") != "client":
                continue
            ts = row.get("timestamp", "")
            if not ts: continue
            sums[ts] = sums.get(ts, 0.0) + parser(row.get(col, ""))
    return list(sums.values())



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
    """Aggregate application-core CPU %busy (recorded reserved cores excluded)."""
    p = run_dir / "raw" / "sar-cpu.csv"
    if not p.exists(): return None
    reserved = _reserved_cores(run_dir)
    total = {}; count = {}
    with p.open() as f:
        for row in csv.DictReader(f, delimiter=";"):
            cpu = row.get("CPU", "")
            if cpu in ("-1", "all", "") or cpu in reserved: continue
            ts = row.get("timestamp", "")
            if not ts: continue
            try: idle = float(row.get("%idle", "100"))
            except ValueError: continue
            busy = max(0.0, 100.0 - idle)
            total[ts] = total.get(ts, 0.0) + busy
            count[ts] = count.get(ts, 0) + 1
    if not total: return None
    means = sorted([total[ts] / count[ts] for ts in total if count[ts] > 0])
    return {
        "non_dpdk_cpu_mean_pct": sum(means) / len(means),
        "non_dpdk_cpu_p95_pct": percentile(means, 95),
        "non_dpdk_cpu_max_pct": means[-1],
    }


def extract_rdma_rcv(run_dir, device="mlx5_0"):
    p = run_dir / "raw" / "rdma-counters.csv"
    if not p.exists(): return None
    rows = []
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get("ibdev") != device: continue
            try:
                rcv = float(row.get("rcv_bytes", "0"))
                t = datetime.fromisoformat(row["timestamp"].rstrip("Z")).timestamp()
            except (ValueError, TypeError, KeyError): continue
            rows.append((t, rcv))
    if len(rows) < 2: return None
    rows.sort()
    rates = []
    for i in range(1, len(rows)):
        dt_ = rows[i][0] - rows[i-1][0]
        db = rows[i][1] - rows[i-1][1]
        if dt_ > 0 and db >= 0: rates.append(db / dt_)
    if not rates: return None
    rates.sort()
    return {
        "rdma_rcv_mean_bps": (_active_window_mean(rates) or 0.0),
        "rdma_rcv_full_mean_bps": sum(rates) / len(rates),
        "rdma_rcv_max_bps": rates[-1],
    }


def extract_nvidia_gpu(run_dir):
    p = run_dir / "raw" / "nvidia-smi.csv"
    if not p.exists(): return None
    per_gpu_util = {}; per_gpu_mem = {}
    with p.open() as f:
        for row in csv.DictReader(f, skipinitialspace=True):
            try: gi = int(row.get("index", ""))
            except (ValueError, TypeError): continue
            per_gpu_util.setdefault(gi, []).append(parse_numeric(row.get("utilization.gpu [%]", "0")))
            per_gpu_mem.setdefault(gi, []).append(parse_numeric(row.get("memory.used [MiB]", "0")))
    if not per_gpu_util: return None
    active = [g for g, vals in per_gpu_util.items() if max(vals) > 1.0]
    if not active: return None
    util_means = [sum(per_gpu_util[g]) / len(per_gpu_util[g]) for g in active]
    return {
        "n_active_gpus": len(active),
        "gpu_util_mean_pct": sum(util_means) / len(util_means),
        "gpu_mem_max_mib": max(max(per_gpu_mem[g]) for g in active) if per_gpu_mem else 0,
    }


def weka_ops_per_sec(run_dir):
    """Returns list of per-timestamp Ops/s sums across client frontends."""
    return weka_client_per_sec(run_dir, "Ops/s", parser=lambda s: parse_numeric(s))


# ------------------------- 6.B.2 stress cell -------------------------
def extract_b2_summary(run_dir):
    m = RUN_NAME_RE_B2.search(run_dir.name)
    if not m: return None
    d = m.groupdict()

    fio_summary = {}
    fp = run_dir / "file-io-summary.json"
    if fp.exists():
        try: fio_summary = json.loads(fp.read_text())
        except json.JSONDecodeError: pass

    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if rs_dt and re_dt else None

    weka_read = weka_client_per_sec(run_dir, "Read")
    weka_read_mean = (_active_window_mean(weka_read) or 0.0)
    weka_read_full_mean = sum(weka_read) / len(weka_read) if weka_read else 0.0
    weka_read_max = max(weka_read) if weka_read else 0.0

    weka_ops = weka_ops_per_sec(run_dir)
    weka_ops_mean = (_active_window_mean(weka_ops) or 0.0)
    weka_ops_full_mean = sum(weka_ops) / len(weka_ops) if weka_ops else 0.0
    weka_ops_max = max(weka_ops) if weka_ops else 0.0

    rdma = extract_rdma_rcv(run_dir) or {}
    cpu = parse_cpu_aggregate_excluding_dpdk(run_dir) or {}

    return {
        "run_dir": run_dir.name,
        "tier": "6.B.2",
        "corpus": d["corpus"],
        "n_processes": int(d["n"]),
        "pattern": d["pat"],
        "duration_s": duration,
        # App-level (PRIMARY)
        "files_per_sec_steady_aggregate": fio_summary.get("files_per_sec_steady_aggregate"),
        "MiBps_steady_aggregate": fio_summary.get("MiBps_steady_aggregate"),
        "n_files_loaded_steady": fio_summary.get("n_files_loaded_steady"),
        "errors": fio_summary.get("errors"),
        "lat_mean_ms": fio_summary.get("lat_mean_ms"),
        "lat_p50_ms": fio_summary.get("lat_p50_ms"),
        "lat_p95_ms": fio_summary.get("lat_p95_ms"),
        "lat_p99_ms": fio_summary.get("lat_p99_ms"),
        "lat_max_ms": fio_summary.get("lat_max_ms"),
        # WEKA-side (PRIMARY)
        "weka_read_mean_MiBps": weka_read_mean / (1024 * 1024),
        "weka_read_max_MiBps": weka_read_max / (1024 * 1024),
        "weka_ops_per_sec_mean": weka_ops_mean,
        "weka_ops_per_sec_max": weka_ops_max,
        # RDMA cross-check
        "rdma_rcv_mean_MiBps": (rdma.get("rdma_rcv_mean_bps") or 0.0) / (1024 * 1024),
        "rdma_rcv_max_MiBps": (rdma.get("rdma_rcv_max_bps") or 0.0) / (1024 * 1024),
        "ratio_rdma_over_weka_read": (
            (rdma.get("rdma_rcv_mean_bps") or 0.0) / weka_read_mean
            if weka_read_mean > 0 else None
        ),
        # CPU non-DPDK
        "cpu_non_dpdk_mean_pct": cpu.get("non_dpdk_cpu_mean_pct"),
        "cpu_non_dpdk_p95_pct": cpu.get("non_dpdk_cpu_p95_pct"),
    }


# ------------------------- 6.B.3 MIL training cell -------------------------
def parse_training_steps_csv(run_dir):
    p = run_dir / "training-steps.csv"
    if not p.exists(): return None
    steady = []
    with p.open() as f:
        for row in csv.DictReader(f):
            try:
                if row.get("phase") != "steady": continue
                steady.append({
                    "step_duration_ms": float(row["step_duration_ms"]),
                    "t_dataload_ms": float(row["t_dataload_ms"]),
                    "t_forward_ms": float(row["t_forward_ms"]),
                    "t_backward_ms": float(row["t_backward_ms"]),
                    "t_optimizer_ms": float(row["t_optimizer_ms"]),
                })
            except (KeyError, ValueError):
                continue
    if not steady: return None
    sd = sorted([r["step_duration_ms"] for r in steady])
    dl = sorted([r["t_dataload_ms"] for r in steady])
    fw = sorted([r["t_forward_ms"] for r in steady])
    bw = sorted([r["t_backward_ms"] for r in steady])
    return {
        "n_steady_steps": len(steady),
        "step_duration_ms_mean": sum(sd) / len(sd),
        "step_duration_ms_p95": percentile(sd, 95),
        "dataload_ms_mean": sum(dl) / len(dl),
        "dataload_ms_p95": percentile(dl, 95),
        "forward_ms_mean": sum(fw) / len(fw),
        "backward_ms_mean": sum(bw) / len(bw),
        "gpu_stall_pct": (sum(dl) / sum(sd)) * 100.0 if sum(sd) > 0 else 0.0,
    }


def extract_b3_summary(run_dir):
    m = RUN_NAME_RE_B3.search(run_dir.name)
    if not m: return None
    d = m.groupdict()

    tsum = {}
    tp = run_dir / "training-summary.json"
    if tp.exists():
        try: tsum = json.loads(tp.read_text())
        except json.JSONDecodeError: pass

    steps = parse_training_steps_csv(run_dir) or {}
    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if rs_dt and re_dt else None

    weka_read = weka_client_per_sec(run_dir, "Read")
    weka_read_mean = (_active_window_mean(weka_read) or 0.0)
    weka_read_full_mean = sum(weka_read) / len(weka_read) if weka_read else 0.0
    weka_read_max = max(weka_read) if weka_read else 0.0
    weka_ops = weka_ops_per_sec(run_dir)
    weka_ops_mean = (_active_window_mean(weka_ops) or 0.0)
    weka_ops_full_mean = sum(weka_ops) / len(weka_ops) if weka_ops else 0.0

    rdma = extract_rdma_rcv(run_dir) or {}
    cpu = parse_cpu_aggregate_excluding_dpdk(run_dir) or {}
    gpu = extract_nvidia_gpu(run_dir) or {}

    return {
        "run_dir": run_dir.name,
        "tier": "6.B.3",
        "model": d["model"],
        "features_tag": d["features_tag"],
        "batch_size": int(d["bs"]),
        "num_workers": int(d["nw"]),
        "duration_s": duration,
        # Trainer aggregate
        "samples_per_sec_steady": tsum.get("samples_per_sec_steady"),
        "n_steady_steps": tsum.get("total_steady_steps"),
        "n_slides_in_corpus": tsum.get("n_slides_in_corpus"),
        # Per-step CSV
        "step_duration_ms_mean": steps.get("step_duration_ms_mean"),
        "dataload_ms_mean": steps.get("dataload_ms_mean"),
        "forward_ms_mean": steps.get("forward_ms_mean"),
        "backward_ms_mean": steps.get("backward_ms_mean"),
        "gpu_stall_pct": steps.get("gpu_stall_pct"),
        # WEKA-side
        "weka_read_mean_MiBps": weka_read_mean / (1024 * 1024),
        "weka_read_max_MiBps": weka_read_max / (1024 * 1024),
        "weka_ops_per_sec_mean": weka_ops_mean,
        # RDMA
        "rdma_rcv_mean_MiBps": (rdma.get("rdma_rcv_mean_bps") or 0.0) / (1024 * 1024),
        # CPU + GPU
        "cpu_non_dpdk_mean_pct": cpu.get("non_dpdk_cpu_mean_pct"),
        "gpu_util_mean_pct": gpu.get("gpu_util_mean_pct"),
        "gpu_mem_max_mib": gpu.get("gpu_mem_max_mib"),
    }


def write_csv(rows, out_path):
    if not rows: return
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys())
    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows: w.writerow(r)


def main():
    _runs = Path(__file__).resolve().parent.parent / "runs"
    pattern_b2 = sys.argv[1] if len(sys.argv) > 1 else str(_runs / "2026-*-s6.B.2-*")
    pattern_b3 = sys.argv[2] if len(sys.argv) > 2 else str(_runs / "2026-*-s6.B.3-*")

    print(f"# Aggregating 6.B.2 cells matching: {pattern_b2}", file=sys.stderr)
    b2_rows = []
    for p in sorted(glob.glob(pattern_b2)):
        d = Path(p)
        if not d.is_dir(): continue
        if "smoke" in d.name:
            print(f"  skip smoke: {d.name}", file=sys.stderr); continue
        row = extract_b2_summary(d)
        if row is None: continue
        b2_rows.append(row)
        fps = row.get("files_per_sec_steady_aggregate")
        ops = row.get("weka_ops_per_sec_mean", 0)
        fps_s = f"{fps:.0f}" if fps else "N/A"
        print(f"  {d.name}: corpus={row['corpus']} n={row['n_processes']} "
              f"pat={row['pattern']} files/s={fps_s} weka_ops={ops:.0f}",
              file=sys.stderr)

    print(f"# Aggregating 6.B.3 cells matching: {pattern_b3}", file=sys.stderr)
    b3_rows = []
    for p in sorted(glob.glob(pattern_b3)):
        d = Path(p)
        if not d.is_dir(): continue
        if "smoke" in d.name: continue
        row = extract_b3_summary(d)
        if row is None: continue
        b3_rows.append(row)
        sps = row.get("samples_per_sec_steady")
        sps_s = f"{sps:.1f}" if sps else "N/A"
        print(f"  {d.name}: bs={row['batch_size']} nw={row['num_workers']} "
              f"samples/s={sps_s}", file=sys.stderr)

    if b2_rows:
        write_csv(b2_rows, _runs / "s6.B-stress-summary.csv")
        print(f"# Wrote {len(b2_rows)} rows to {_runs / 's6.B-stress-summary.csv'}", file=sys.stderr)
    if b3_rows:
        write_csv(b3_rows, _runs / "s6.B-mil-summary.csv")
        print(f"# Wrote {len(b3_rows)} rows to {_runs / 's6.B-mil-summary.csv'}", file=sys.stderr)

    if not b2_rows and not b3_rows:
        print("# No 6.B cells matched.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
