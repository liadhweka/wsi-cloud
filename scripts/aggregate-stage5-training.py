#!/usr/bin/env python3
"""aggregate-stage5-training.py — walk Stage 5 run dirs, emit summary CSV.

Per cell, reads:
  - training-summary.json   (trainer's aggregate: samples/sec, world_size, total steady steps)
  - training-steps.csv      (per-step CSV — the PRIMARY headline source: phase, step_duration,
                             dataload, forward, backward, optimizer, samples, loss)
  - .run_start / .run_end   (record-run.sh window)
  - raw/weka-stats.csv      (per-ts sum across the client frontends, Read column)
  - raw/rdma-counters.csv   (mlx5_0 rcv rate, cumulative-counter → rate diff)
  - raw/sar-cpu.csv         (non-DPDK per-core %busy aggregate)
  - raw/nvidia-smi.csv      (per-GPU util max/mean — PRIMARY for Stage 5)

Emits runs/s5.A-training-summary.csv (5 rows when complete).

WHY this aggregator is separate from 4.C's:
  - Stage 5 has its NEW PRIMARY per-step CSV source not present in 4.C
  - Headline metric is samples/sec (training throughput), not raw GB/s
  - Customer-quotable metrics: dataload latency distribution, GPU stall time,
    scaling efficiency (samples/sec / (N × single-GPU samples/sec))
  - Reuses the four debugged parser idioms from aggregate-stage4c-kvikio.py:
      * lowercase `timestamp` in weka-stats.csv
      * ';' delimiter in sar-cpu.csv + application-core filter (recorded reserved cores excluded)
      * leading-space + unit-suffix in nvidia-smi.csv
      * cumulative-counter (not rate) in rdma-counters.csv

Run-dir name pattern parsed:
  <UTC>-s5.A-train-resnet50-{kvikio|cucim}-{dataset}-N<N>
  <UTC>-s5.B-train-resnet50-{kvikio|cucim}-{dataset}-N<N>

Smoke runs (run-name starts with 'smoke-') are skipped from the summary CSV
(they are not customer-quotable cells).
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from statistics import median


RUN_NAME_RE = re.compile(
    r"-s5\.(?P<sub>A|B)-train-resnet50-(?P<backend>kvikio|cucim)-(?P<dataset>brca|cam16)-N(?P<n>\d+)$"
)


def parse_run_dir_name(p):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    d = m.groupdict()
    backend = "kvikio" if d["backend"] == "kvikio" else "cucim_batched_cpu"
    return {
        "substage": f"5.{d['sub']}",
        "backend": backend,
        "dataset": d["dataset"],
        "n_gpus": int(d["n"]),
    }


def parse_iso_utc(s):
    return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    rs = run_dir / "raw" / ".run_start"
    re_path = run_dir / "raw" / ".run_end"
    if not rs.exists() or not re_path.exists():
        return None, None
    return parse_iso_utc(rs.read_text()), parse_iso_utc(re_path.read_text())


# ----- Per-training-step CSV parser (NEW for Stage 5) -----
def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = max(0, min(len(sorted_vals) - 1, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def parse_training_steps_csv(run_dir):
    """Returns {steady_metrics, ramp_metrics} from per-step CSV. None if not present.

    Headline customer-quotable metrics derived here:
      - aggregate samples/sec across the run (steady phase only)
      - per-step duration p50/p95/p99 (steady)
      - dataload latency p50/p95/p99 (steady) — the storage-fed latency story
      - per-phase ms means (steady): forward, backward, optimizer
      - GPU stall fraction = dataload_ms / step_duration_ms (steady mean)
        WHY this is the customer-friendly metric: if GPU stall is high,
        storage is the bottleneck; if low, GPU is fed.
    """
    p = run_dir / "training-steps.csv"
    if not p.exists():
        return None
    steady_steps = []
    ramp_steps = []
    with p.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                rec = {
                    "step_idx": int(row["step_idx"]),
                    "step_duration_ms": float(row["step_duration_ms"]),
                    "t_dataload_ms": float(row["t_dataload_ms"]),
                    "t_forward_ms": float(row["t_forward_ms"]),
                    "t_backward_ms": float(row["t_backward_ms"]),
                    "t_optimizer_ms": float(row["t_optimizer_ms"]),
                    "samples_per_step_per_rank": int(row["samples_per_step_per_rank"]),
                    "world_size": int(row["world_size"]),
                    "loss": float(row["loss"]),
                }
            except (ValueError, KeyError):
                continue
            if row.get("phase") == "steady":
                steady_steps.append(rec)
            else:
                ramp_steps.append(rec)

    if not steady_steps:
        return {"n_steady_steps": 0, "n_ramp_steps": len(ramp_steps)}

    def stats_for(field, vals):
        s = sorted(vals)
        return {
            f"{field}_mean": sum(s) / len(s),
            f"{field}_p50": percentile(s, 50),
            f"{field}_p95": percentile(s, 95),
            f"{field}_p99": percentile(s, 99),
            f"{field}_max": s[-1],
        }

    step_dur = [r["step_duration_ms"] for r in steady_steps]
    dl = [r["t_dataload_ms"] for r in steady_steps]
    fw = [r["t_forward_ms"] for r in steady_steps]
    bw = [r["t_backward_ms"] for r in steady_steps]
    opt = [r["t_optimizer_ms"] for r in steady_steps]
    losses = [r["loss"] for r in steady_steps]

    # Total wallclock across steady steps + total samples processed (per-rank * #ranks)
    world_size = steady_steps[0]["world_size"]
    batch_per_rank = steady_steps[0]["samples_per_step_per_rank"]
    total_steady_steps = len(steady_steps)
    # samples per step (aggregate across ranks): batch_per_rank * world_size
    samples_per_step_agg = batch_per_rank * world_size
    total_steady_samples_agg = total_steady_steps * samples_per_step_agg

    # Steady wallclock is approximated from the trainer's t_step_end_s of last - first step
    # but since CSV is rank-0 only and ranks are roughly synchronized via DDP, this is fine.
    sum_step_dur_s = sum(step_dur) / 1000.0
    samples_per_sec_per_rank_from_csv = batch_per_rank / (sum(step_dur) / len(step_dur) / 1000.0) if step_dur else 0.0
    samples_per_sec_aggregate_from_csv = samples_per_sec_per_rank_from_csv * world_size

    # GPU stall fraction: time spent in data load (waiting for tiles) vs full step.
    # If this is high (>50%), storage is the bottleneck.
    gpu_stall_pct = (sum(dl) / sum(step_dur)) * 100.0 if sum(step_dur) > 0 else 0.0
    # Compute-only step time (ideal storage); the "if storage were free" comparison
    compute_only_step_ms_mean = (sum(fw) + sum(bw) + sum(opt)) / len(steady_steps)

    out = {
        "n_steady_steps": total_steady_steps,
        "n_ramp_steps": len(ramp_steps),
        "world_size": world_size,
        "batch_per_rank": batch_per_rank,
        "samples_per_step_aggregate": samples_per_step_agg,
        "total_steady_samples_aggregate": total_steady_samples_agg,
        "samples_per_sec_aggregate": samples_per_sec_aggregate_from_csv,
        "samples_per_sec_per_rank": samples_per_sec_per_rank_from_csv,
        "gpu_stall_pct": gpu_stall_pct,
        "compute_only_step_ms_mean": compute_only_step_ms_mean,
        "loss_mean": sum(losses) / len(losses) if losses else None,
    }
    out.update(stats_for("step_duration_ms", step_dur))
    out.update(stats_for("dataload_ms", dl))
    out.update(stats_for("forward_ms", fw))
    out.update(stats_for("backward_ms", bw))
    out.update(stats_for("optimizer_ms", opt))
    return out


# ----- Storage-side parsers (lifted with tweaks from aggregate-stage4c-kvikio.py) -----
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
    """Strip leading whitespace + common unit suffixes ('MiB', '%', etc.) and parse a float."""
    if s is None:
        return 0.0
    s = str(s).strip()
    for suffix in (" MiB", " %", " W", " MHz", " B/s"):
        if s.endswith(suffix):
            s = s[: -len(suffix)].strip()
            break
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def weka_client_per_sec(run_dir, col, parser=parse_bps):
    """Sum a column from weka-stats.csv across the client frontends per timestamp."""
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
            ts = row.get("timestamp", "")  # lowercase per Stage 1.5 finding
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
    """Aggregate application-core CPU %busy (recorded reserved cores excluded)."""
    p = run_dir / "raw" / "sar-cpu.csv"
    if not p.exists():
        return None
    reserved = _reserved_cores(run_dir)
    by_ts_total = {}
    by_ts_count = {}
    with p.open() as f:
        reader = csv.DictReader(f, delimiter=";")  # semicolon delimited
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
    means_per_ts.sort()
    return {
        "non_dpdk_cpu_mean_pct": sum(means_per_ts) / len(means_per_ts) if means_per_ts else None,
        "non_dpdk_cpu_p95_pct": percentile(means_per_ts, 95),
        "non_dpdk_cpu_max_pct": means_per_ts[-1] if means_per_ts else None,
        "n_samples": len(means_per_ts),
    }


def extract_rdma_rcv(run_dir, device="mlx5_0"):
    """Compute rcv bytes/sec rate from cumulative rcv_bytes counter."""
    p = run_dir / "raw" / "rdma-counters.csv"
    if not p.exists():
        return None
    rows = []
    with p.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("ibdev") != device:
                continue
            ts = row.get("timestamp", "")
            try:
                rcv = float(row.get("rcv_bytes", "0"))
                t_epoch = datetime.fromisoformat(ts.rstrip("Z")).timestamp()
            except (ValueError, TypeError):
                continue
            rows.append((t_epoch, rcv))
    if len(rows) < 2:
        return None
    rows.sort()
    rates = []
    for i in range(1, len(rows)):
        dt_ = rows[i][0] - rows[i - 1][0]
        db = rows[i][1] - rows[i - 1][1]
        if dt_ > 0 and db >= 0:
            rates.append(db / dt_)
    if not rates:
        return None
    rates.sort()
    return {
        "rdma_rcv_mean_bps": (_active_window_mean(rates) or 0.0),
        "rdma_rcv_full_mean_bps": sum(rates) / len(rates),
        "rdma_rcv_p95_bps": percentile(rates, 95),
        "rdma_rcv_max_bps": rates[-1],
        "n_samples": len(rates),
    }


def extract_nvidia_gpu_aggregate(run_dir, n_gpus):
    """Get per-GPU util max/mean across the first n_gpus, plus aggregate min util (worst-fed GPU).

    NOTE: nvidia-smi.csv has columns with LEADING SPACES + unit-suffix values
    ('1 MiB', '0 %'). DictReader(skipinitialspace=True) + parse_numeric handles both.

    For multi-GPU cells the customer story is "are ALL GPUs fed?" — the worst-fed
    GPU's util tells us if storage is stalling the slowest rank.
    """
    p = run_dir / "raw" / "nvidia-smi.csv"
    if not p.exists():
        return None
    # Per-GPU per-timestamp arrays
    per_gpu_util = {}  # gpu_idx -> list of util values
    per_gpu_mem = {}
    with p.open() as f:
        reader = csv.DictReader(f, skipinitialspace=True)
        for row in reader:
            try:
                gi = int(row.get("index", ""))
            except (ValueError, TypeError):
                continue
            ut = parse_numeric(row.get("utilization.gpu [%]", "0"))
            mu = parse_numeric(row.get("memory.used [MiB]", "0"))
            per_gpu_util.setdefault(gi, []).append(ut)
            per_gpu_mem.setdefault(gi, []).append(mu)

    if not per_gpu_util:
        return None

    # Per-GPU summary
    gpu_summaries = {}
    for gi, vals in per_gpu_util.items():
        mems = per_gpu_mem.get(gi, [])
        gpu_summaries[gi] = {
            "util_max_pct": max(vals),
            "util_mean_pct": sum(vals) / len(vals),
            "mem_max_mib": max(mems) if mems else 0.0,
            "mem_mean_mib": sum(mems) / len(mems) if mems else 0.0,
        }

    # Aggregate across active GPUs (those with util > 1% at peak)
    active = [g for g, s in gpu_summaries.items() if s["util_max_pct"] > 1.0]
    active.sort()

    util_means_active = [gpu_summaries[g]["util_mean_pct"] for g in active]
    util_maxes_active = [gpu_summaries[g]["util_max_pct"] for g in active]
    mem_maxes_active = [gpu_summaries[g]["mem_max_mib"] for g in active]

    return {
        "n_active_gpus": len(active),
        "active_gpu_indices": active,
        "gpu_util_mean_pct_across_active": sum(util_means_active) / len(util_means_active) if util_means_active else 0.0,
        "gpu_util_min_mean_pct_across_active": min(util_means_active) if util_means_active else None,
        "gpu_util_max_mean_pct_across_active": max(util_means_active) if util_means_active else None,
        "gpu_util_max_max_pct_across_active": max(util_maxes_active) if util_maxes_active else None,
        "gpu_mem_max_mib_across_active": max(mem_maxes_active) if mem_maxes_active else None,
        "per_gpu": gpu_summaries,
    }


def extract_cell_summary(run_dir):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None:
        return None

    # Trainer summary JSON (rank 0)
    tsum_path = run_dir / "training-summary.json"
    tsum = {}
    if tsum_path.exists():
        try:
            tsum = json.loads(tsum_path.read_text())
        except json.JSONDecodeError:
            pass

    steps = parse_training_steps_csv(run_dir) or {}

    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if (rs_dt and re_dt) else None

    weka_read_per_ts = weka_client_per_sec(run_dir, "Read")
    weka_read_mean = (_active_window_mean(weka_read_per_ts) or 0.0)
    weka_read_full_mean = sum(weka_read_per_ts) / len(weka_read_per_ts) if weka_read_per_ts else 0.0
    weka_read_max = max(weka_read_per_ts) if weka_read_per_ts else 0.0

    rdma = extract_rdma_rcv(run_dir) or {}
    cpu = parse_cpu_aggregate_excluding_dpdk(run_dir) or {}
    gpu = extract_nvidia_gpu_aggregate(run_dir, parsed["n_gpus"]) or {}

    row = {
        "run_dir": run_dir.name,
        "substage": parsed["substage"],
        "backend": parsed["backend"],
        "dataset": parsed["dataset"],
        "n_gpus": parsed["n_gpus"],
        "duration_s": duration,
        # Trainer aggregate (from training-summary.json)
        "samples_per_sec_aggregate_trainer": tsum.get("samples_per_sec_aggregate"),
        "samples_per_sec_per_rank_trainer": tsum.get("samples_per_sec_per_rank"),
        "effective_batch_size": tsum.get("effective_batch_size"),
        "ramp_s": tsum.get("ramp_s"),
        "steady_runtime_s": tsum.get("runtime_s"),
        # Per-step CSV-derived (PRIMARY headline source)
        "n_steady_steps_csv": steps.get("n_steady_steps"),
        "samples_per_sec_aggregate_csv": steps.get("samples_per_sec_aggregate"),
        "samples_per_sec_per_rank_csv": steps.get("samples_per_sec_per_rank"),
        "gpu_stall_pct_csv": steps.get("gpu_stall_pct"),
        "compute_only_step_ms_mean_csv": steps.get("compute_only_step_ms_mean"),
        "step_duration_ms_mean": steps.get("step_duration_ms_mean"),
        "step_duration_ms_p50": steps.get("step_duration_ms_p50"),
        "step_duration_ms_p95": steps.get("step_duration_ms_p95"),
        "step_duration_ms_p99": steps.get("step_duration_ms_p99"),
        "dataload_ms_mean": steps.get("dataload_ms_mean"),
        "dataload_ms_p50": steps.get("dataload_ms_p50"),
        "dataload_ms_p95": steps.get("dataload_ms_p95"),
        "dataload_ms_p99": steps.get("dataload_ms_p99"),
        "forward_ms_mean": steps.get("forward_ms_mean"),
        "backward_ms_mean": steps.get("backward_ms_mean"),
        "optimizer_ms_mean": steps.get("optimizer_ms_mean"),
        "loss_mean": steps.get("loss_mean"),
        # WEKA-side (PRIMARY)
        "weka_read_mean_MiBps": weka_read_mean / (1024 * 1024),
        "weka_read_max_MiBps": weka_read_max / (1024 * 1024),
        # RDMA-side (PRIMARY)
        "rdma_rcv_mean_MiBps": (rdma.get("rdma_rcv_mean_bps") or 0.0) / (1024 * 1024),
        "rdma_rcv_max_MiBps": (rdma.get("rdma_rcv_max_bps") or 0.0) / (1024 * 1024),
        # Cross-source ratio: RDMA rcv / WEKA Read ≈ 1.0 ± 0.4 (no read amplification expected)
        "ratio_rdma_over_weka_read": (
            ((rdma.get("rdma_rcv_mean_bps") or 0.0) / weka_read_mean)
            if weka_read_mean > 0 else None
        ),
        # CPU non-DPDK
        "cpu_non_dpdk_mean_pct": cpu.get("non_dpdk_cpu_mean_pct"),
        "cpu_non_dpdk_p95_pct": cpu.get("non_dpdk_cpu_p95_pct"),
        "cpu_non_dpdk_max_pct": cpu.get("non_dpdk_cpu_max_pct"),
        # GPU (PRIMARY for Stage 5 — the headline customer-friendly metric)
        "n_active_gpus": gpu.get("n_active_gpus"),
        "gpu_util_mean_pct": gpu.get("gpu_util_mean_pct_across_active"),
        "gpu_util_min_mean_pct": gpu.get("gpu_util_min_mean_pct_across_active"),
        "gpu_util_max_mean_pct": gpu.get("gpu_util_max_mean_pct_across_active"),
        "gpu_util_max_max_pct": gpu.get("gpu_util_max_max_pct_across_active"),
        "gpu_mem_max_mib": gpu.get("gpu_mem_max_mib_across_active"),
    }
    return row


def main():
    if len(sys.argv) < 2:
        _LEG = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (the default glob is leg-scoped: pulled other-leg run dirs must not enter this leg's summary CSV)")
        pattern = str(Path(__file__).resolve().parent.parent / "runs" / f"2026-*-{_LEG}-s5.*")
    else:
        pattern = sys.argv[1]
    print(f"# Aggregating Stage 5 cells matching: {pattern}", file=sys.stderr)

    rows = []
    for path in sorted(glob.glob(pattern)):
        d = Path(path)
        if not d.is_dir():
            continue
        # Skip smoke runs (they're not customer-quotable cells)
        if "smoke" in d.name:
            print(f"  skip smoke run: {d.name}", file=sys.stderr)
            continue
        row = extract_cell_summary(d)
        if row is None:
            continue
        rows.append(row)
        sps = row['samples_per_sec_aggregate_csv']
        stall = row['gpu_stall_pct_csv']
        sps_s = f"{sps:.0f}" if sps is not None else "N/A"
        stall_s = f"{stall:.1f}%" if stall is not None else "N/A"
        print(f"  {d.name}: N={row['n_gpus']} backend={row['backend']} "
              f"samples/sec={sps_s} gpu_stall={stall_s}", file=sys.stderr)

    if not rows:
        print("# No cells matched.", file=sys.stderr)
        return 1

    _LEG_OUT = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (summary CSVs are per-leg files: D6 concurrent legs)")
    out_path = Path(__file__).resolve().parent.parent / "runs" / f"s5.A-training-summary-{_LEG_OUT}.csv"
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
