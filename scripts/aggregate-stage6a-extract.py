#!/usr/bin/env python3
"""aggregate-stage6a-extract.py — walk Stage 6.A run dirs, emit summary CSV.

Per cell, reads:
  - extraction-summary.json   (model, backend, world_size, total_tiles_steady, cell_wallclock)
  - extraction-steps.csv      (PRIMARY headline source — per-step dataload+forward timing)
  - per-slide.csv             (per-slide wallclock + tiles_per_sec)
  - .run_start / .run_end     (record-run.sh window)
  - raw/weka-stats.csv        (per-ts sum across the client frontends — WEKA Read)
  - raw/rdma-counters.csv     (mlx5_0 rcv rate, cumulative-counter → rate diff)
  - raw/sar-cpu.csv           (non-DPDK per-core %busy aggregate)
  - raw/nvidia-smi.csv        (per-GPU util — PRIMARY for Stage 6.A)

Emits runs/s6.A-extract-summary.csv (1 row per cell).

WHY this aggregator is separate from Stage 5's:
  - Stage 6.A is single-pass extraction; no backward/optimizer phases
  - Per-extraction-step CSV has 8 cols (vs Stage 5's 12) — no bw/opt
  - Per-slide CSV is unique to 6.A — captures per-slide wallclock distribution
  - Headline metric: tiles/sec aggregate at the cell wallclock granularity
  - GPU util (PRIMARY for Stage 6.A; foundation-model extractors are compute-heavy)

Reuses the four debugged parser idioms from aggregate-stage4c-kvikio.py /
aggregate-stage5-training.py:
  - lowercase `timestamp` in weka-stats.csv (Stage 1.5 finding)
  - `;` delimiter + application-core filter in sar-cpu.csv (recorded reserved cores excluded)
  - leading-space + unit-suffix in nvidia-smi.csv
  - cumulative-counter (not rate) in rdma-counters.csv

Run-dir name patterns parsed:
  <UTC>-s6.A-extract-{model}-{backend}-{dataset}-N{N}
    where {model} ∈ {virchow2, gigapath, uni2-h}
          {backend} ∈ {kvikio, cucim}  (cucim_batched_cpu → "cucim" in dir name)
          {dataset} ∈ {brca50, cam16, brca_full}

Smoke runs (run-name starts with 'smoke-') are skipped from the summary CSV.
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path


RUN_NAME_RE = re.compile(
    r"-s6\.A-extract-(?P<model>virchow2|gigapath|uni2-h)-"
    r"(?P<backend>kvikio|cucim)-(?P<dataset>brca50|cam16|brca_full)-N(?P<n>\d+)$"
)

# Multi-model kvikIO Tier 2 cell: per-model summaries are inside a single
# run dir (`extraction-summary-<model>.json` + per-model CSVs). Detected
# by the dir name pattern; outer extraction-summary.json carries `models`.
MULTIMODEL_NAME_RE = re.compile(
    r"-s6\.A-extract-multimodel-(?P<backend>kvikio|cucim)-(?P<dataset>brca_full)-N(?P<n>\d+)$"
)


def parse_run_dir_name(p: Path):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    d = m.groupdict()
    return {
        "model": d["model"],
        "backend": "kvikio" if d["backend"] == "kvikio" else "cucim_batched_cpu",
        "dataset": d["dataset"],
        "n_gpus": int(d["n"]),
    }


def parse_iso_utc(s: str):
    return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir: Path):
    rs = run_dir / "raw" / ".run_start"
    re_path = run_dir / "raw" / ".run_end"
    if not rs.exists() or not re_path.exists():
        return None, None
    return parse_iso_utc(rs.read_text()), parse_iso_utc(re_path.read_text())


# ----- Parsers (lifted from Stage 5 aggregator) -----
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
    if m:
        return float(m.group(1))
    try:
        return float(s)
    except ValueError:
        return 0.0


def parse_numeric(s):
    """Strip leading whitespace + common unit suffixes."""
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
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            cpu = row.get("CPU", "")
            if cpu in ("-1", "all", "") or cpu in reserved:
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
    means = [by_ts_total[ts] / by_ts_count[ts]
             for ts in by_ts_total if by_ts_count[ts] > 0]
    means.sort()
    return {
        "non_dpdk_cpu_mean_pct": sum(means) / len(means) if means else None,
        "non_dpdk_cpu_p95_pct": percentile(means, 95),
        "non_dpdk_cpu_max_pct": means[-1] if means else None,
        "n_samples": len(means),
    }


def extract_rdma_rcv(run_dir, device="mlx5_0"):
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


def extract_nvidia_gpu_aggregate(run_dir):
    """Per-GPU util + mem max/mean, across all GPUs that showed activity."""
    p = run_dir / "raw" / "nvidia-smi.csv"
    if not p.exists():
        return None
    per_gpu_util = {}
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
    gpu_summaries = {}
    for gi, vals in per_gpu_util.items():
        mems = per_gpu_mem.get(gi, [])
        gpu_summaries[gi] = {
            "util_max_pct": max(vals),
            "util_mean_pct": sum(vals) / len(vals),
            "mem_max_mib": max(mems) if mems else 0.0,
            "mem_mean_mib": sum(mems) / len(mems) if mems else 0.0,
        }
    active = [g for g, s in gpu_summaries.items() if s["util_max_pct"] > 1.0]
    active.sort()
    util_means = [gpu_summaries[g]["util_mean_pct"] for g in active]
    util_maxes = [gpu_summaries[g]["util_max_pct"] for g in active]
    mem_maxes = [gpu_summaries[g]["mem_max_mib"] for g in active]
    return {
        "n_active_gpus": len(active),
        "active_gpu_indices": active,
        "gpu_util_mean_pct": sum(util_means) / len(util_means) if util_means else 0.0,
        "gpu_util_min_mean_pct": min(util_means) if util_means else None,
        "gpu_util_max_mean_pct": max(util_means) if util_means else None,
        "gpu_util_max_max_pct": max(util_maxes) if util_maxes else None,
        "gpu_mem_max_mib": max(mem_maxes) if mem_maxes else None,
    }


# ----- Per-extraction-step CSV parser (Stage 6-specific) -----
def parse_extraction_steps_csv(run_dir, suffix: str = ""):
    """Returns per-step aggregates filtered to phase=='steady'.

    `suffix` is "" for single-model cells, "-<model>" for multi-model Tier 2 cells.
    """
    p = run_dir / f"extraction-steps{suffix}.csv"
    if not p.exists():
        return None
    steady = []
    ramp_count = 0
    with p.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                rec = {
                    "step_duration_ms": float(row["step_duration_ms"]),
                    "t_dataload_ms": float(row["t_dataload_ms"]),
                    "t_forward_ms": float(row["t_forward_ms"]),
                    "samples_per_step": int(row["samples_per_step"]),
                    "world_size": int(row["world_size"]),
                }
            except (ValueError, KeyError):
                continue
            if row.get("phase") == "steady":
                steady.append(rec)
            else:
                ramp_count += 1
    if not steady:
        return {"n_steady_steps": 0, "n_ramp_steps": ramp_count}

    def stats_for(field, vals):
        s = sorted(vals)
        return {
            f"{field}_mean": sum(s) / len(s),
            f"{field}_p50": percentile(s, 50),
            f"{field}_p95": percentile(s, 95),
            f"{field}_p99": percentile(s, 99),
        }

    step_dur = [r["step_duration_ms"] for r in steady]
    dl = [r["t_dataload_ms"] for r in steady]
    fw = [r["t_forward_ms"] for r in steady]

    world_size = steady[0]["world_size"]
    total_samples = sum(r["samples_per_step"] for r in steady) * world_size  # aggregate across ranks
    # GPU stall fraction = dataload time / step time. Foundation-model regime
    # this should be VERY LOW because forward dominates step time.
    gpu_stall_pct = (sum(dl) / sum(step_dur)) * 100.0 if sum(step_dur) > 0 else 0.0

    out = {
        "n_steady_steps_rank0": len(steady),  # rank 0 only writes
        "n_ramp_steps": ramp_count,
        "world_size": world_size,
        "samples_per_step_per_rank": steady[0]["samples_per_step"],
        "total_samples_steady_aggregate": total_samples,
        "gpu_stall_pct_steady": gpu_stall_pct,
    }
    out.update(stats_for("step_duration_ms", step_dur))
    out.update(stats_for("dataload_ms", dl))
    out.update(stats_for("forward_ms", fw))
    return out


def parse_per_slide_csv(run_dir, suffix: str = ""):
    """Per-slide aggregates: n_slides, total tiles, mean/p95 per-slide wallclock + tiles_per_sec.

    `suffix` is "" for single-model cells, "-<model>" for multi-model Tier 2 cells.
    """
    p = run_dir / f"per-slide{suffix}.csv"
    if not p.exists():
        return None
    rows = []
    with p.open() as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                rows.append({
                    "n_tiles": int(r["n_tiles"]),
                    "wallclock_s": float(r["wallclock_s"]),
                    "tiles_per_sec_slide": float(r["tiles_per_sec_slide"]),
                })
            except (ValueError, KeyError):
                continue
    if not rows:
        return None
    n_slides = len(rows)
    total_tiles = sum(r["n_tiles"] for r in rows)
    walls = sorted([r["wallclock_s"] for r in rows])
    tps = sorted([r["tiles_per_sec_slide"] for r in rows])
    return {
        "n_slides_extracted": n_slides,
        "total_tiles_extracted": total_tiles,
        "per_slide_wallclock_mean_s": sum(walls) / len(walls),
        "per_slide_wallclock_p50_s": percentile(walls, 50),
        "per_slide_wallclock_p95_s": percentile(walls, 95),
        "per_slide_wallclock_max_s": walls[-1],
        "per_slide_tps_mean": sum(tps) / len(tps),
        "per_slide_tps_p50": percentile(tps, 50),
    }


# ----- Per-cell summary row -----
def extract_cell_summary(run_dir: Path, model_override: str = None,
                          backend_override: str = None,
                          dataset_override: str = None,
                          n_gpus_override: int = None,
                          tsum_suffix: str = ""):
    """Build a row for a Stage 6.A cell.

    For single-model cells: derive (model, backend, dataset, n_gpus) from the
    run-dir name regex; read extraction-summary.json + per-step CSV + per-slide CSV.

    For multi-model kvikIO Tier 2 cells: caller passes overrides + tsum_suffix
    (e.g. "-virchow2"). We read extraction-summary{suffix}.json + the per-model
    CSVs (extraction-steps{suffix}.csv, per-slide{suffix}.csv). WEKA/RDMA/CPU/GPU
    sources are at the run-dir level (aggregate across the whole multi-model cell);
    those are the same for all 3 model rows from one multi-model dir.
    """
    if model_override:
        # n_gpus is reported, never defaulted. It is the column every throughput
        # figure in the row is read against and the one cost-per-cell arithmetic
        # keys off, so a fabricated GPU count is a plausible integer that nothing
        # downstream can detect. Missing stays missing, loudly.
        if not n_gpus_override:
            print(f"  WARN: {run_dir.name}: no GPU count recorded (world_size absent from "
                  f"extraction-summary.json and not in the run-dir name) — n_gpus left empty",
                  file=sys.stderr)
        parsed = {
            "model": model_override,
            "backend": backend_override or "kvikio",
            "dataset": dataset_override or "brca_full",
            "n_gpus": n_gpus_override or None,
        }
    else:
        parsed = parse_run_dir_name(run_dir)
        if parsed is None:
            return None

    tsum = {}
    tsum_path = run_dir / f"extraction-summary{tsum_suffix}.json"
    if tsum_path.exists():
        try:
            tsum = json.loads(tsum_path.read_text())
        except json.JSONDecodeError as e:
            # Say which file could not be read. Swallowed, an unparseable summary
            # emits a row whose throughput columns are all empty, which reads as
            # "this cell produced no throughput" rather than "this file is
            # truncated" — the second is fixable, the first is a false finding.
            print(f"  ERROR: {run_dir.name}: could not parse {tsum_path.name}: {e}",
                  file=sys.stderr)

    steps = parse_extraction_steps_csv(run_dir, suffix=tsum_suffix) or {}
    per_slide = parse_per_slide_csv(run_dir, suffix=tsum_suffix) or {}

    rs_dt, re_dt = read_run_window(run_dir)
    duration = (re_dt - rs_dt).total_seconds() if (rs_dt and re_dt) else None

    weka_read = weka_client_per_sec(run_dir, "Read")
    weka_read_mean = (_active_window_mean(weka_read) or 0.0)
    weka_read_full_mean = sum(weka_read) / len(weka_read) if weka_read else 0.0
    weka_read_max = max(weka_read) if weka_read else 0.0

    rdma = extract_rdma_rcv(run_dir) or {}
    cpu = parse_cpu_aggregate_excluding_dpdk(run_dir) or {}
    gpu = extract_nvidia_gpu_aggregate(run_dir) or {}

    return {
        "run_dir": run_dir.name,
        "model": parsed["model"],
        "backend": parsed["backend"],
        "dataset": parsed["dataset"],
        "n_gpus": parsed["n_gpus"],
        "duration_s": duration,
        # Trainer aggregate (from extraction-summary.json)
        "tiles_per_sec_aggregate_steady": tsum.get("tiles_per_sec_aggregate_steady"),
        "n_slides_manifest": tsum.get("n_slides_manifest"),
        "n_slides_extracted_total": tsum.get("n_slides_extracted_total"),
        "total_tiles_steady_phase": tsum.get("total_tiles_steady_phase"),
        "cell_wallclock_s_trainer": tsum.get("cell_wallclock_s"),
        "embedding_dim": tsum.get("embedding_dim"),
        # Per-step CSV
        "n_steady_steps_rank0": steps.get("n_steady_steps_rank0"),
        "step_duration_ms_mean": steps.get("step_duration_ms_mean"),
        "step_duration_ms_p95": steps.get("step_duration_ms_p95"),
        "dataload_ms_mean": steps.get("dataload_ms_mean"),
        "dataload_ms_p95": steps.get("dataload_ms_p95"),
        "forward_ms_mean": steps.get("forward_ms_mean"),
        "forward_ms_p95": steps.get("forward_ms_p95"),
        "gpu_stall_pct_steady_csv": steps.get("gpu_stall_pct_steady"),
        # Per-slide CSV
        "n_slides_per_slide_csv": per_slide.get("n_slides_extracted"),
        "per_slide_wallclock_mean_s": per_slide.get("per_slide_wallclock_mean_s"),
        "per_slide_wallclock_p95_s": per_slide.get("per_slide_wallclock_p95_s"),
        "per_slide_tps_mean": per_slide.get("per_slide_tps_mean"),
        # WEKA-side
        "weka_read_mean_MiBps": weka_read_mean / (1024 * 1024),
        "weka_read_max_MiBps": weka_read_max / (1024 * 1024),
        # RDMA-side
        "rdma_rcv_mean_MiBps": (rdma.get("rdma_rcv_mean_bps") or 0.0) / (1024 * 1024),
        "rdma_rcv_max_MiBps": (rdma.get("rdma_rcv_max_bps") or 0.0) / (1024 * 1024),
        "ratio_rdma_over_weka_read": (
            ((rdma.get("rdma_rcv_mean_bps") or 0.0) / weka_read_mean)
            if weka_read_mean > 0 else None
        ),
        # CPU non-DPDK
        "cpu_non_dpdk_mean_pct": cpu.get("non_dpdk_cpu_mean_pct"),
        "cpu_non_dpdk_p95_pct": cpu.get("non_dpdk_cpu_p95_pct"),
        # GPU (PRIMARY for Stage 6.A)
        "n_active_gpus": gpu.get("n_active_gpus"),
        "gpu_util_mean_pct": gpu.get("gpu_util_mean_pct"),
        "gpu_util_min_mean_pct": gpu.get("gpu_util_min_mean_pct"),
        "gpu_util_max_max_pct": gpu.get("gpu_util_max_max_pct"),
        "gpu_mem_max_mib": gpu.get("gpu_mem_max_mib"),
    }


def main():
    if len(sys.argv) < 2:
        _LEG = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (the default glob is leg-scoped: pulled other-leg run dirs must not enter this leg's summary CSV)")
        pattern = str(Path(__file__).resolve().parent.parent / "runs" / f"2026-*-{_LEG}-s6.A-extract-*")
    else:
        pattern = sys.argv[1]
    print(f"# Aggregating Stage 6.A cells matching: {pattern}", file=sys.stderr)

    rows = []
    n_hard_errors = 0
    for path in sorted(glob.glob(pattern)):
        d = Path(path)
        if not d.is_dir():
            continue
        if "smoke" in d.name:
            print(f"  skip smoke run: {d.name}", file=sys.stderr)
            continue

        # Multi-model kvikIO Tier 2 cells: one run dir → 3 logical rows
        # (one per model from extraction-summary-<model>.json).
        mm = MULTIMODEL_NAME_RE.search(d.name)
        if mm:
            outer = {}
            outer_path = d / "extraction-summary.json"
            if outer_path.exists():
                try:
                    outer = json.loads(outer_path.read_text())
                except json.JSONDecodeError as e:
                    print(f"  ERROR: {d.name}: could not parse extraction-summary.json: {e}",
                          file=sys.stderr)
            else:
                print(f"  ERROR: {d.name}: extraction-summary.json is missing",
                      file=sys.stderr)
            models = outer.get("models") or []
            if not models:
                # The outer summary names the models, so without it this run dir
                # contributes ZERO rows — the single most expensive cell in the
                # project disappearing from the table with no message. A missing
                # row is the absence nobody notices, so it exits non-zero instead.
                # The orchestrator writes this file at the very end of a multi-hour
                # run, which is exactly when a truncated write is plausible; the
                # per-model summaries and CSVs beside it are still intact and the
                # cell can be re-aggregated by hand once `models` is restored.
                print(f"  ERROR: {d.name}: multi-model cell lists no models — "
                      f"emitting NO rows for it. Repair extraction-summary.json "
                      f"(its `models` key) and re-run.", file=sys.stderr)
                n_hard_errors += 1
                continue
            backend = outer.get("backend") or mm.group("backend")
            n_gpus = outer.get("world_size") or int(mm.group("n"))
            dataset = mm.group("dataset")
            for model in models:
                row = extract_cell_summary(
                    d,
                    model_override=model,
                    backend_override=backend,
                    dataset_override=dataset,
                    n_gpus_override=n_gpus,
                    tsum_suffix=f"-{model}",
                )
                if row is None:
                    continue
                rows.append(row)
                tps = row.get("tiles_per_sec_aggregate_steady")
                gum = row.get("gpu_util_mean_pct")
                tps_s = f"{tps:.0f}" if tps else "N/A"
                gum_s = f"{gum:.1f}%" if gum else "N/A"
                print(f"  {d.name} [{model}]: model={row['model']} backend={row['backend']} "
                      f"N={row['n_gpus']} tiles/s={tps_s} gpu_util={gum_s}",
                      file=sys.stderr)
            continue

        # Standard single-model cell
        row = extract_cell_summary(d)
        if row is None:
            continue
        rows.append(row)
        tps = row.get("tiles_per_sec_aggregate_steady")
        gum = row.get("gpu_util_mean_pct")
        tps_s = f"{tps:.0f}" if tps else "N/A"
        gum_s = f"{gum:.1f}%" if gum else "N/A"
        print(f"  {d.name}: model={row['model']} backend={row['backend']} "
              f"N={row['n_gpus']} tiles/s={tps_s} gpu_util={gum_s}",
              file=sys.stderr)

    if not rows:
        print("# No cells matched.", file=sys.stderr)
        return 1

    out_path = Path(__file__).resolve().parent.parent / "runs" / "s6.A-extract-summary.csv"
    fieldnames = list(rows[0].keys())
    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"# Wrote {len(rows)} rows to {out_path}", file=sys.stderr)
    # The CSV is written first, then the exit code reports the dropped cells: the
    # rows that did parse are still worth having, but a zero exit on a table that
    # is silently short a cell is the failure this aggregator must not produce.
    if n_hard_errors:
        print(f"# FAILED: {n_hard_errors} cell(s) contributed no rows (see ERROR lines above). "
              f"{out_path.name} is INCOMPLETE.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
