#!/usr/bin/env python3
"""aggregate-stage7-clinical.py — Stage 7 Clinical Inference Deployment aggregator.

Walks Stage 7 run dirs (regex matches `-s7-*`) and emits a single summary CSV
covering all sub-tiers. Per cell, parses the new Stage 7 primary CSVs
(`per-slide-inference-latencies.csv`, `per-slide-heatmap-writes.csv`,
`streaming-loop-events.csv`, `read-after-write-latencies.csv`,
`workload-<name>.csv`), pairs them with cluster-side primary sources
(per-ts WekaFS frontend summing across the 8 a100 client rows, RDMA mlx5_0
cumulative-counter diff, nvidia-smi PRIMARY for 7.2 GPU-memory pressure,
sar-cpu non-DPDK %busy), and computes cross-source canary ratios.

This script DELIBERATELY makes the four debugged parser idioms explicit:
  1. lowercase `timestamp` in weka-stats.csv (per Stage 1.5 finding)
  2. `;` delimiter + leading `#` strip + non-DPDK CPU filter (cores 24-31) in sar-cpu.csv
  3. leading-space + unit-suffix parsing in nvidia-smi.csv
  4. cumulative-counter diff (NOT rate) in rdma-counters.csv

Emits `runs/s7-clinical-summary.csv` — one row per cell, with per-tier columns.

Smoke runs filtered out by name (anything matching `-s7-smoke-*`).
"""
import csv
import glob
import json
import re
import sys
from datetime import datetime
from pathlib import Path

# Stage 7 run-dir name: <utc>-<fs>-s7[.<sub>]-<cell_name>
#   - the <fs> segment sits between the timestamp and the stage, so the stage part
#     must NOT be anchored to the timestamp (it was, and that silently matched
#     nothing once the filesystem dimension was added);
#   - the stage may be `s7` (drivers that pre-compute the dir) or `s7.1` … `s7.6`
#     (dirs that record-run.sh names from --stage), so the sub-stage is optional.
RUN_NAME_RE = re.compile(r"-s7(?:\.[0-9A-Za-z.]+)?-(?P<name>.+)$")
TS_RE = re.compile(r"^(?P<ts>\d{4}-\d{2}-\d{2}-\d{6})-")
FS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-\d{6}-(?P<fs>[a-z0-9]+)-s7")
SMOKE_PAT = re.compile(r"-s7(?:\.[0-9A-Za-z.]+)?-smoke-")

# Cores the storage client reserves for its own data path, excluded from the CPU
# saturation reading. ⏳ D-9: this set is a PER-FILESYSTEM parameter (STAGES.md D15),
# not a constant — WEKA reserves DPDK cores, the Lustre client reserves none — and the
# actual indices are only measurable on the real client. The range below is a placeholder.
DPDK_CORES = set(range(24, 32))


# ---------------------------------------------------------------------------
# Parsing primitives
# ---------------------------------------------------------------------------
def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = max(0, min(len(sorted_vals) - 1, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def _bps_or_zero(s):
    """Parse WEKA stats byte-rate strings like '12345 B/s' -> 12345.0."""
    if not s:
        return 0.0
    s = str(s).strip()
    if s.endswith(' B/s'):
        s = s[:-4].strip()
    try:
        return float(s)
    except ValueError:
        return 0.0


def _bare_float(s):
    if not s:
        return 0.0
    try:
        return float(str(s).strip())
    except ValueError:
        return 0.0


def parse_iso_utc(s: str):
    return datetime.fromisoformat(s.strip().rstrip('Z'))


def read_run_window(run_dir: Path):
    """The recorder's own window, from raw/.run_start + raw/.run_end.

    Same pair every other stage aggregator reads. Without it the summary CSV
    carries no time basis at all, and cost-to-complete — (instance $/hr +
    filesystem $/hr) × measured wallclock, PROJECT-THESIS.md §4 — is not
    reconstructable from it afterwards. Stage 7 holds the leg's longest cells
    (7.4 endurance, the 7.2 concurrency grid), so it is the largest cost line.
    """
    raw = run_dir / 'raw'
    try:
        start = parse_iso_utc((raw / '.run_start').read_text())
        end = parse_iso_utc((raw / '.run_end').read_text())
    except Exception:
        return None, None, None
    return start, end, (end - start).total_seconds()


def worker_cell_wallclock(run_dir: Path):
    """Max `cell_wallclock_s` across this cell's worker summary JSONs.

    A CROSS-CHECK on the recorder window, never a replacement: the orchestrated
    tiers run N worker processes, so the cell is not finished until the slowest
    one is, hence max rather than sum or mean. The gap to duration_s is the
    recorder's pre/post snapshots plus model load inside the recording window —
    real information about setup overhead, not noise. Returns the count too, so
    a null cannot be misread as "workers reported zero".
    """
    best = None
    n = 0
    for p in sorted(run_dir.glob('*summary*.json')):
        try:
            v = json.loads(p.read_text()).get('cell_wallclock_s')
            v = float(v) if v is not None else None
        except Exception:
            continue
        if v is None:
            continue
        n += 1
        if best is None or v > best:
            best = v
    return best, n


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


def weka_per_sec_sum(run_dir: Path, col: str, parser=_bps_or_zero):
    """Per-timestamp sum across 8 a100 wekafs client frontends.

    The pre-aggregated results.json mean dilutes ~100× from idle backend rows
    (cross-cutting pattern #1). We re-read the raw CSV and sum per
    timestamp across the rows where Hostname=a100 + Mode=client.
    """
    p = run_dir / 'raw' / 'weka-stats.csv'
    if not p.exists():
        return []
    sums = {}
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get('Hostname') != 'a100' or row.get('Mode') != 'client':
                continue
            ts = row.get('timestamp', '')  # lowercase per Stage 1.5 finding
            if not ts:
                continue
            sums[ts] = sums.get(ts, 0.0) + parser(row.get(col, ''))
    return list(sums.values())


def rdma_per_sec_diff(run_dir: Path, device: str, counter: str):
    """Cumulative-counter diff between adjacent timestamps -> per-second bytes/s rate.

    rdma-counters.csv (wide-format, per the actual recorder schema verified
    2026-05-27):
      timestamp,ibdev,xmit_bytes,rcv_bytes,xmit_packets,rcv_packets,xmit_wait,xmit_discards
    where xmit_bytes/rcv_bytes are cumulative bytes since boot (already in
    BYTES — recorder normalizes; no IB-spec 4-byte-chunk multiplier needed).
    `counter` arg should be 'xmit_bytes' or 'rcv_bytes'. Mirrors the working
    parser in Stage 5/4.C aggregators.
    """
    p = run_dir / 'raw' / 'rdma-counters.csv'
    if not p.exists():
        return []
    rows = []
    with p.open() as f:
        for row in csv.DictReader(f):
            if row.get('ibdev') != device:
                continue
            try:
                # timestamp is ISO 8601 with 'Z' suffix; convert to epoch
                ts_s = row['timestamp'].rstrip('Z')
                ts = datetime.fromisoformat(ts_s).timestamp()
                v = float(row.get(counter, '0'))
                rows.append((ts, v))
            except (KeyError, ValueError):
                continue
    rows.sort()
    rates = []
    for i in range(1, len(rows)):
        dt_ = rows[i][0] - rows[i-1][0]
        dv = rows[i][1] - rows[i-1][1]
        if dt_ > 0 and dv >= 0:
            rates.append(dv / dt_)
    return rates


def sar_cpu_non_dpdk_busy(run_dir: Path):
    """sar-cpu.csv has `;` delimiter + leading `#` lines. Returns mean %busy
    across non-DPDK cores (cores 0-23, 32+; cores 24-31 are the wekafs
    DPDK frontends and busy-poll under WEKA I/O load — non-DPDK gives the
    application-CPU saturation curve)."""
    p = run_dir / 'raw' / 'sar-cpu.csv'
    if not p.exists():
        return None
    per_ts = {}
    with p.open() as f:
        # Skip the leading sar comment header line(s)
        # sadf output starts with a # line; csv.DictReader doesn't strip it
        first = True
        header = None
        for raw in f:
            line = raw.rstrip('\n')
            if not line:
                continue
            if line.startswith('#'):
                # The header row is the first '#'-prefixed line in sadf -d output
                if first:
                    header = line[1:].split(';')
                    first = False
                continue
            parts = line.split(';')
            if header is None or len(parts) != len(header):
                continue
            row = dict(zip(header, parts))
            try:
                cpu = int(row.get('CPU', '-1'))
            except ValueError:
                continue
            if cpu == -1 or cpu in DPDK_CORES:
                continue
            ts = row.get('timestamp', '')
            try:
                idle = float(row.get('%idle', '100'))
            except ValueError:
                continue
            busy = 100.0 - idle
            per_ts.setdefault(ts, []).append(busy)
    if not per_ts:
        return None
    # Mean across non-DPDK cores at each timestamp, then mean across timestamps
    per_ts_mean = [sum(v) / len(v) for v in per_ts.values() if v]
    if not per_ts_mean:
        return None
    return sum(per_ts_mean) / len(per_ts_mean)


def nvidia_smi_summary(run_dir: Path):
    """nvidia-smi.csv has leading-space + unit-suffix values like ' 1 MiB',
    ' 0 %'. We strip and split on whitespace to get the numeric part."""
    p = run_dir / 'raw' / 'nvidia-smi.csv'
    if not p.exists():
        return None
    mem_used = []
    util = []
    with p.open() as f:
        for row in csv.DictReader(f):
            # The CSV writes columns with a leading space; the parsed dict
            # keys may have leading spaces too.
            for k, v in row.items():
                key = (k or '').strip().lower()
                val = (v or '').strip()
                if not val:
                    continue
                num = val.split()[0]
                try:
                    n = float(num)
                except ValueError:
                    continue
                if 'memory.used' in key:
                    mem_used.append(n)
                elif 'utilization.gpu' in key:
                    util.append(n)
    return {
        'gpu_mem_used_mean_mib': (sum(mem_used) / len(mem_used)) if mem_used else None,
        'gpu_mem_used_max_mib': max(mem_used) if mem_used else None,
        'gpu_util_mean_pct': (sum(util) / len(util)) if util else None,
        'gpu_util_max_pct': max(util) if util else None,
    }


# ---------------------------------------------------------------------------
# Stage 7 primary CSV parsers
# ---------------------------------------------------------------------------
def parse_per_slide_inference(run_dir: Path):
    """Parse per-slide-inference-latencies.csv -> per-phase + total stats."""
    p = run_dir / 'per-slide-inference-latencies.csv'
    if not p.exists():
        return None
    rows = []
    with p.open() as f:
        rd = csv.DictReader(f)
        for r in rd:
            try:
                rows.append({
                    'total_ms': float(r['t_total_ms']),
                    'tissue_ms': float(r['t_tissue_ms']),
                    'extract_ms': float(r['t_extract_ms']),
                    'mil_ms': float(r['t_mil_ms']),
                    'heatmap_write_ms': float(r['t_heatmap_write_ms']),
                    'n_tiles': int(r.get('n_tiles', '0') or '0'),
                })
            except (ValueError, KeyError):
                continue
    if not rows:
        return None
    totals = sorted(r['total_ms'] for r in rows)
    return {
        'n_slides': len(rows),
        'total_ms_p50': percentile(totals, 50),
        'total_ms_p95': percentile(totals, 95),
        'total_ms_p99': percentile(totals, 99),
        'total_ms_mean': sum(totals) / len(totals),
        'total_ms_max': max(totals),
        'tissue_ms_mean': sum(r['tissue_ms'] for r in rows) / len(rows),
        'extract_ms_mean': sum(r['extract_ms'] for r in rows) / len(rows),
        'mil_ms_mean': sum(r['mil_ms'] for r in rows) / len(rows),
        'heatmap_write_ms_mean': sum(r['heatmap_write_ms'] for r in rows) / len(rows),
        'mean_n_tiles': sum(r['n_tiles'] for r in rows) / len(rows),
    }


def parse_per_slide_heatmap(run_dir: Path):
    p = run_dir / 'per-slide-heatmap-writes.csv'
    if not p.exists():
        return None
    bytes_per = []
    write_ms = []
    fmt = None
    with p.open() as f:
        for r in csv.DictReader(f):
            try:
                bytes_per.append(int(r['bytes_written']))
                write_ms.append(float(r['write_ms']))
                fmt = r.get('format')
            except (ValueError, KeyError):
                continue
    if not bytes_per:
        return None
    write_ms.sort()
    return {
        'n_heatmaps': len(bytes_per),
        'heatmap_format': fmt,
        'heatmap_bytes_mean': sum(bytes_per) / len(bytes_per),
        'heatmap_bytes_max': max(bytes_per),
        'heatmap_total_bytes': sum(bytes_per),
        'heatmap_write_ms_p50': percentile(write_ms, 50),
        'heatmap_write_ms_p95': percentile(write_ms, 95),
        'heatmap_write_ms_p99': percentile(write_ms, 99),
        'heatmap_write_ms_mean': sum(write_ms) / len(write_ms),
    }


def parse_streaming_events(run_dir: Path):
    p = run_dir / 'streaming-loop-events.csv'
    if not p.exists():
        return None
    e2e = []
    queued = []
    with p.open() as f:
        for r in csv.DictReader(f):
            try:
                e2e.append(float(r['end_to_end_s']))
                queued.append(float(r['queued_s']))
            except (ValueError, KeyError):
                continue
    if not e2e:
        return None
    e2e.sort()
    return {
        'streaming_n_slides': len(e2e),
        'end_to_end_s_mean': sum(e2e) / len(e2e),
        'end_to_end_s_p99': percentile(e2e, 99),
        'queued_s_mean': sum(queued) / len(queued) if queued else None,
        'queued_s_max': max(queued) if queued else None,
    }


def parse_raw_consistency(run_dir: Path):
    """Read-after-write consistency CSV (7.4.b)."""
    p = run_dir / 'read-after-write-latencies.csv'
    if not p.exists():
        return None
    cons_ms = []
    with p.open() as f:
        for r in csv.DictReader(f):
            v = r.get('consistency_latency_ms', '').strip()
            if not v:
                continue
            try:
                cons_ms.append(float(v))
            except ValueError:
                continue
    if not cons_ms:
        return None
    cons_ms.sort()
    return {
        'raw_n_samples': len(cons_ms),
        'raw_consistency_ms_mean': sum(cons_ms) / len(cons_ms),
        'raw_consistency_ms_p50': percentile(cons_ms, 50),
        'raw_consistency_ms_p95': percentile(cons_ms, 95),
        'raw_consistency_ms_p99': percentile(cons_ms, 99),
        'raw_consistency_ms_max': max(cons_ms),
    }


# ---------------------------------------------------------------------------
# Per-cell aggregator
# ---------------------------------------------------------------------------
def aggregate_cell(run_dir: Path) -> dict:
    name_m = RUN_NAME_RE.search(run_dir.name)
    if not name_m:
        return {}
    cell_name = name_m.group('name')
    ts_m = TS_RE.match(run_dir.name)
    start, end, duration = read_run_window(run_dir)
    app_wall, n_worker_summaries = worker_cell_wallclock(run_dir)
    out = {
        'run_dir': run_dir.name,
        'cell_name': cell_name,
        # TS_RE, not name_m: RUN_NAME_RE carries no `ts` group, so asking it for
        # one raised IndexError on EVERY cell — main() swallowed that as a
        # per-cell WARN and wrote a header-only CSV while still exiting 0.
        'ts': ts_m.group('ts') if ts_m else None,
        'run_start_utc': start.isoformat() + 'Z' if start else None,
        'run_end_utc': end.isoformat() + 'Z' if end else None,
        'duration_s': duration,
        'app_cell_wallclock_s_max': app_wall,
        'n_worker_summaries': n_worker_summaries,
    }

    # Inference latencies (7.1, 7.2, 7.5 inference workload, 7.6)
    inf = parse_per_slide_inference(run_dir)
    if inf:
        out.update({f'inf_{k}': v for k, v in inf.items()})

    # Heatmap writes (7.3, 7.5)
    hm = parse_per_slide_heatmap(run_dir)
    if hm:
        out.update({f'hm_{k}': v for k, v in hm.items()})

    # Streaming loop (7.4.a)
    sl = parse_streaming_events(run_dir)
    if sl:
        out.update(sl)

    # Read-after-write (7.4.b)
    raw = parse_raw_consistency(run_dir)
    if raw:
        out.update(raw)

    # Cluster-side primary sources
    weka_read = weka_per_sec_sum(run_dir, 'Read', _bps_or_zero)
    weka_write = weka_per_sec_sum(run_dir, 'Write', _bps_or_zero)
    weka_ops = weka_per_sec_sum(run_dir, 'Ops/s', _bare_float)
    if weka_read:
        out['weka_read_MiBps_mean'] = (_active_window_mean(weka_read) or 0.0) / (1024 * 1024)
        out['weka_read_MiBps_full_mean'] = (sum(weka_read) / len(weka_read)) / (1024 * 1024)
        out['weka_read_MiBps_max'] = max(weka_read) / (1024 * 1024)
    if weka_write:
        out['weka_write_MiBps_mean'] = (_active_window_mean(weka_write) or 0.0) / (1024 * 1024)
        out['weka_write_MiBps_full_mean'] = (sum(weka_write) / len(weka_write)) / (1024 * 1024)
        out['weka_write_MiBps_max'] = max(weka_write) / (1024 * 1024)
    if weka_ops:
        out['weka_ops_per_sec_mean'] = (_active_window_mean(weka_ops) or 0.0)
        out['weka_ops_per_sec_full_mean'] = sum(weka_ops) / len(weka_ops)
        out['weka_ops_per_sec_max'] = max(weka_ops)

    # RDMA mlx5_0 (the data-path device per the mlx5 mystery — verified
    # to be re-derived on the real client — ⏳ D-9).
    # Recorder schema: rcv_bytes/xmit_bytes are already in BYTES (cumulative);
    # diff between timestamps recovers bytes/sec.
    rdma_rcv = rdma_per_sec_diff(run_dir, 'mlx5_0', 'rcv_bytes')
    rdma_xmit = rdma_per_sec_diff(run_dir, 'mlx5_0', 'xmit_bytes')
    if rdma_rcv:
        out['rdma_rcv_MiBps_mean'] = (_active_window_mean(rdma_rcv) or 0.0) / (1024 * 1024)
        out['rdma_rcv_MiBps_full_mean'] = (sum(rdma_rcv) / len(rdma_rcv)) / (1024 * 1024)
    if rdma_xmit:
        out['rdma_xmit_MiBps_mean'] = (_active_window_mean(rdma_xmit) or 0.0) / (1024 * 1024)
        out['rdma_xmit_MiBps_full_mean'] = (sum(rdma_xmit) / len(rdma_xmit)) / (1024 * 1024)

    # Cross-source canary ratios
    if 'weka_read_MiBps_mean' in out and out['weka_read_MiBps_mean'] > 0 and 'rdma_rcv_MiBps_mean' in out:
        out['canary_rdma_rcv_over_weka_read'] = out['rdma_rcv_MiBps_mean'] / out['weka_read_MiBps_mean']
    if 'weka_write_MiBps_mean' in out and out['weka_write_MiBps_mean'] > 0 and 'rdma_xmit_MiBps_mean' in out:
        out['canary_rdma_xmit_over_weka_write'] = out['rdma_xmit_MiBps_mean'] / out['weka_write_MiBps_mean']

    # CPU non-DPDK %busy (PRIMARY for 7.2 per Q13)
    cpu_busy = sar_cpu_non_dpdk_busy(run_dir)
    if cpu_busy is not None:
        out['cpu_non_dpdk_busy_pct_mean'] = cpu_busy

    # nvidia-smi (PRIMARY for Stage 7)
    nv = nvidia_smi_summary(run_dir)
    if nv:
        out.update(nv)

    return out


def main():
    if len(sys.argv) > 1:
        runs_root = Path(sys.argv[1])
    else:
        # Default to this script's own tree's runs/ (lib → runs), so it resolves
        # in whichever phase tree the script lives in (no hardcoded repo path).
        runs_root = Path(__file__).resolve().parent.parent / "runs"

    # Discover Stage 7 cells
    cells = []
    for p in sorted(runs_root.glob('*-s7*-*')):
        if not p.is_dir():
            continue
        if SMOKE_PAT.search(p.name):
            continue
        cells.append(p)

    if not cells:
        print(f"[agg] no Stage 7 cells found under {runs_root}", file=sys.stderr)
        return

    rows = []
    for rd in cells:
        try:
            row = aggregate_cell(rd)
            if row:
                rows.append(row)
                print(f"[agg] {rd.name}: "
                      f"n_slides={row.get('inf_n_slides')} "
                      f"p99_ms={row.get('inf_total_ms_p99')} "
                      f"weka_read_MiBps={row.get('weka_read_MiBps_mean')}",
                      flush=True)
        except Exception as e:
            print(f"[agg] WARN: {rd.name} aggregation failed: {e}", file=sys.stderr)

    # Build the union of all column names across rows (cells have different
    # field sets depending on which sub-tier).
    fieldnames = ['run_dir', 'cell_name', 'ts',
                  'run_start_utc', 'run_end_utc', 'duration_s',
                  'app_cell_wallclock_s_max', 'n_worker_summaries']
    seen = set(fieldnames)
    for r in rows:
        for k in r:
            if k not in seen:
                fieldnames.append(k)
                seen.add(k)

    out_csv = runs_root / 's7-clinical-summary.csv'
    with out_csv.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"[agg] wrote {out_csv} with {len(rows)} cells, {len(fieldnames)} columns", flush=True)

    # Headline markdown — focuses on the 7.1 baselines + 7.2 concurrent grid
    print("\n=== Stage 7 headline grids ===\n")
    print("## 7.1 — Per-slide inference latency baselines\n")
    print("| Cell | n_slides | p50 ms | p95 ms | p99 ms | mean tissue ms | mean extract ms | mean mil ms | mean hm_write ms |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        if not r['cell_name'].startswith('7.1'):
            continue
        print(f"| {r['cell_name']} | {r.get('inf_n_slides')} | "
              f"{r.get('inf_total_ms_p50')} | {r.get('inf_total_ms_p95')} | "
              f"{r.get('inf_total_ms_p99')} | {r.get('inf_tissue_ms_mean')} | "
              f"{r.get('inf_extract_ms_mean')} | {r.get('inf_mil_ms_mean')} | "
              f"{r.get('inf_heatmap_write_ms_mean')} |")

    print("\n## 7.2 — Latency under concurrent inference load\n")
    print("| N | p50 ms | p95 ms | p99 ms | mean ms | WekaFS Read MiBps | CPU non-DPDK %busy | GPU util mean |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        if not r['cell_name'].startswith('7.2'):
            continue
        N = r['cell_name'].split('-')[-1]
        print(f"| {N} | {r.get('inf_total_ms_p50')} | {r.get('inf_total_ms_p95')} | "
              f"{r.get('inf_total_ms_p99')} | {r.get('inf_total_ms_mean')} | "
              f"{r.get('weka_read_MiBps_mean')} | {r.get('cpu_non_dpdk_busy_pct_mean')} | "
              f"{r.get('gpu_util_mean_pct')} |")

    print("\n## 7.3 — Heatmap output writes\n")
    print("| Cell | format | n | bytes mean | total bytes | write_ms p50 | write_ms p99 | WekaFS Write MiBps |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        if not r['cell_name'].startswith('7.3'):
            continue
        print(f"| {r['cell_name']} | {r.get('hm_heatmap_format')} | {r.get('hm_n_heatmaps')} | "
              f"{r.get('hm_heatmap_bytes_mean')} | {r.get('hm_heatmap_total_bytes')} | "
              f"{r.get('hm_heatmap_write_ms_p50')} | {r.get('hm_heatmap_write_ms_p99')} | "
              f"{r.get('weka_write_MiBps_mean')} |")

    print("\n## 7.4 — Streaming + read-after-write\n")
    for r in rows:
        if r['cell_name'].startswith('7.4.a'):
            print(f"streaming-loop: N={r.get('streaming_n_slides')} e2e_mean={r.get('end_to_end_s_mean')}s "
                  f"e2e_p99={r.get('end_to_end_s_p99')}s queued_mean={r.get('queued_s_mean')}s")
        if r['cell_name'].startswith('7.4.b'):
            print(f"read-after-write: N={r.get('raw_n_samples')} consistency_mean={r.get('raw_consistency_ms_mean')}ms "
                  f"p99={r.get('raw_consistency_ms_p99')}ms max={r.get('raw_consistency_ms_max')}ms")


if __name__ == '__main__':
    main()
