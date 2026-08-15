#!/usr/bin/env python3
"""aggregate-stage4b-tilesread.py — walk Stage 4.B run dirs, emit summary.

Usage:
    aggregate-stage4b-tilesread.py <glob>
    e.g. aggregate-stage4b-tilesread.py 'runs/2026-*-s4.B-tilesread-*'

Per cell:
  - parses reader-summary.json (app-level: tiles/sec steady, cache hit rate, errors)
  - reads .run_start/.run_end for the recorded window
  - re-reads weka-stats.csv (per-timestamp sum across the client frontends) — Read, Ops/s
  - extracts RDMA rcv (read direction) + xmit (sanity, should be near 0)
  - aggregate %busy from sar-cpu (application cores; the storage client's recorded reserved cores excluded)

Outputs:
  - runs/s4.B-tilesread-summary.csv (1 row per cell)
  - Markdown grid per backend × dataset
"""
import csv
import glob
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path


# Run-name patterns:
#   tilesread-<dataset>-openslide-N<n>
#   tilesread-<dataset>-openslide-N<n>-cold      (Tier 3 OpenSlide cell; the driver appends
#                                                 "-cold" on tier3 regardless of whether the
#                                                 drop_caches step ran -- see variant_from_name)
#   tilesread-<dataset>-cucim-N<n>-nw<w>-bs<b>
#   tilesread-<dataset>-cucim-N<n>-nw<w>-bs<b>-sorted  (Tier 5 sort-batches variant)
RUN_NAME_RE = re.compile(
    r"-s4\.B-tilesread-(?P<dataset>[a-zA-Z0-9_-]+?)-"
    r"(?P<backend>openslide|cucim)-N(?P<N>\d+)"
    r"(?:-nw(?P<nw>\d+)-bs(?P<bs>\d+))?"
    r"(?P<suffix>-cold|-sorted)?$"
)
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


def parse_run_dir_name(p):
    m = RUN_NAME_RE.search(p.name)
    if not m:
        return None
    d = m.groupdict()
    out = {
        "dataset": d["dataset"],
        "backend": d["backend"],
        "n_processes": int(d["N"]),
    }
    out["num_workers"] = int(d["nw"]) if d["nw"] else None
    out["batch_size"] = int(d["bs"]) if d["bs"] else None
    # REQUESTED variant, read off the run-dir name. This says what the cell was
    # ASKED to do -- never what it did. It is deliberately NOT called "variant"
    # and NOT called "cache_state": sweep-stage4b-tilesread.sh appends "-cold"
    # whenever $TIER is tier3, while the sysctl vm.drop_caches step is gated on
    # $TIER3_DROP_CACHES, so a run dir can carry "cold" with no cache-clearing
    # action having occurred. A column named "variant=cold" is then an asserted
    # cache state, which thesis §6 forbids -- cache state is recorded as
    # achieved, per cell. Same rule as aggregate-stage4c-kvikio.py's
    # cufile_mode_requested / gds_engaged split: a name-derived value may be
    # reported as what was requested, never as what was achieved.
    out["variant_from_name"] = d["suffix"][1:] if d["suffix"] else ""  # "", "cold", or "sorted"
    return out


def parse_iso_utc(s):
    return datetime.fromisoformat(s.strip().rstrip("Z"))


def read_run_window(run_dir):
    raw = run_dir / "raw"
    try:
        s = parse_iso_utc((raw / ".run_start").read_text())
        e = parse_iso_utc((raw / ".run_end").read_text())
        return s, e, (e - s).total_seconds()
    except Exception:
        return None, None, None


def parse_bps(s):
    if s is None: return None
    m = _BPS_RE.match(s)
    if m:
        try: return float(m.group(1))
        except ValueError: return None
    try: return float(s)
    except (ValueError, TypeError): return None


def parse_numeric(s):
    if s is None: return None
    try: return float(s)
    except (ValueError, TypeError): return None


def weka_client_per_sec(run_dir, col, parser=parse_bps):
    csv_path = run_dir / "raw" / "weka-stats.csv"
    if not csv_path.exists(): return None
    per_ts = {}
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("Mode") != "client": continue
            ts = row.get("timestamp")
            v = parser(row.get(col))
            if ts is None or v is None: continue
            per_ts[ts] = per_ts.get(ts, 0.0) + v
    if not per_ts: return None
    values = sorted(per_ts.items())
    vals = [v for _, v in values]
    n = len(vals)
    sustained_start = int(n * 0.2) if n > 5 else 0
    sorted_vals = sorted(vals)
    return {
        "n_seconds": n,
        "mean": statistics.fmean(vals),
        "sustained_mean": _active_window_mean(vals),
        "sustained_mean_last80": statistics.fmean(vals[sustained_start:]),
        "active_window_mean": _active_window_mean(vals),
        "p95": sorted_vals[min(int(n * 0.95), n - 1)],
        "max": sorted_vals[-1],
    }



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
    """Aggregate %busy across the APPLICATION cores.

    Per-core rows required; the CPU=-1 aggregate row is skipped, and the storage
    client's reserved cores -- recorded per run, see _reserved_cores -- are excluded.
    """
    csv_path = run_dir / "raw" / "sar-cpu.csv"
    if not csv_path.exists(): return None
    reserved = _reserved_cores(run_dir)
    # Per-timestamp dict of cpu_id -> %idle. Then aggregate non-DPDK cores per timestamp.
    per_ts = {}  # ts -> {cpu: idle}
    with csv_path.open() as f:
        first = f.readline()
        delim = ";" if ";" in first else ","
        if first.startswith("#"): first = first[1:].lstrip()
        header = next(csv.reader([first], delimiter=delim))
        for line in f:
            if line.startswith("#"): continue
            parts = next(csv.reader([line], delimiter=delim))
            if len(parts) != len(header): continue
            row = dict(zip(header, parts))
            cpu_s = row.get("CPU", "").strip()
            try:
                cpu = int(cpu_s)
                idle = float(row["%idle"])
            except (KeyError, ValueError):
                continue
            if cpu == -1: continue  # skip the pre-aggregated row
            if str(cpu) in reserved: continue  # the storage client's cores busy-poll regardless of workload
            ts = row.get("timestamp") or row.get("# hostname") or ""
            per_ts.setdefault(ts, {})[cpu] = 100 - idle
    if not per_ts: return None
    # Per timestamp mean across non-DPDK cores
    per_ts_busy = [statistics.fmean(d.values()) for d in per_ts.values()]
    n = len(per_ts_busy)
    sustained_start = int(n * 0.2) if n > 5 else 0
    sorted_busy = sorted(per_ts_busy)
    return {
        "sustained_mean": _active_window_mean(per_ts_busy),
        "sustained_mean_last80": statistics.fmean(per_ts_busy[sustained_start:]),
        "active_window_mean": _active_window_mean(per_ts_busy),
        "p95": sorted_busy[min(int(n * 0.95), n - 1)],
        "max": sorted_busy[-1],
        "n_seconds": n,
    }


def extract_rdma_pair(d):
    rdma = (d.get("sources") or {}).get("rdma_counters") or {}
    devs = rdma.get("devices") or {}
    max_xmit = max_rcv = 0.0
    xmit_dev = rcv_dev = None
    for dev, m in devs.items():
        x = (m.get("xmit_bytes_per_sec") or {}).get("sustained_mean") or 0
        r = (m.get("rcv_bytes_per_sec") or {}).get("sustained_mean") or 0
        if x > max_xmit: max_xmit, xmit_dev = x, dev
        if r > max_rcv: max_rcv, rcv_dev = r, dev
    return xmit_dev, max_xmit, rcv_dev, max_rcv


def extract_cell_summary(run_dir):
    parsed = parse_run_dir_name(run_dir)
    if parsed is None: return None
    out = dict(parsed)
    out["run_dir"] = run_dir.name

    s, e, dur = read_run_window(run_dir)
    out["run_start_utc"] = s.isoformat() + "Z" if s else None
    out["run_end_utc"]   = e.isoformat() + "Z" if e else None
    out["window_s"]      = dur

    # Reader summary (app-level)
    reader_path = run_dir / "reader-summary.json"
    if reader_path.exists():
        try:
            reader = json.loads(reader_path.read_text())
            out["tiles_steady"] = reader.get("tiles_steady")
            out["tiles_per_sec_steady"] = reader.get("tiles_per_sec_steady")
            out["cache_hit_rate"] = reader.get("cache_hit_rate")
            out["errors"] = reader.get("errors")
            out["unique_slides_read"] = reader.get("unique_slides_read")
        except Exception as e:
            print(f"WARN: {run_dir.name} reader-summary.json parse: {e}", file=sys.stderr)

    # RDMA from results.json
    rj = run_dir / "results.json"
    xmit_dev = rcv_dev = None; xmit_bps = rcv_bps = 0.0
    if rj.exists():
        try:
            d = json.loads(rj.read_text())
            xmit_dev, xmit_bps, rcv_dev, rcv_bps = extract_rdma_pair(d)
        except Exception: pass
    out["rdma_xmit_dev"] = xmit_dev
    out["rdma_xmit_sustained_bps"] = xmit_bps if xmit_bps > 0 else None
    out["rdma_rcv_dev"] = rcv_dev
    out["rdma_rcv_sustained_bps"] = rcv_bps if rcv_bps > 0 else None

    # WEKA client per-ts summed
    wk_read = weka_client_per_sec(run_dir, "Read", parse_bps)
    wk_ops  = weka_client_per_sec(run_dir, "Ops/s", parse_numeric)
    out["weka_read_sustained_bps"] = wk_read["sustained_mean"] if wk_read else None
    out["weka_ops_sustained"] = wk_ops["sustained_mean"] if wk_ops else None

    # CPU aggregate excluding DPDK cores
    cpu = parse_cpu_aggregate_excluding_dpdk(run_dir)
    out["agg_cpu_busy_ex_dpdk_sustained_pct"] = cpu["sustained_mean"] if cpu else None
    out["agg_cpu_busy_ex_dpdk_p95_pct"]       = cpu["p95"]            if cpu else None
    out["agg_cpu_busy_ex_dpdk_max_pct"]       = cpu["max"]            if cpu else None

    # Cross-source ratio: app tiles/sec × tile_bytes ≈ WEKA Read ≈ RDMA rcv (no read amplification)
    # tile_bytes for a 256x256 RGB JPEG q=85 = ~12-15 KB stored compressed.
    # OpenSlide reads decompressed bytes (256x256x4 RGBA = 256 KB raw); cucim batched reads compressed.
    # Different per-backend — leave ratio analysis to a follow-up.

    out["status"] = "OK"
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: aggregate-stage4b-tilesread.py <glob>", file=sys.stderr)
        sys.exit(2)
    dirs = [Path(p) for p in sorted(glob.glob(sys.argv[1])) if Path(p).is_dir()]
    dirs = [d for d in dirs if RUN_NAME_RE.search(d.name)]
    if not dirs:
        print("no sweep-cell dirs matched", file=sys.stderr)
        sys.exit(1)
    rows = [extract_cell_summary(d) for d in dirs]
    rows = [r for r in rows if r is not None]
    rows.sort(key=lambda r: (r["dataset"], r["backend"], r["n_processes"], r.get("num_workers") or 0))

    out_csv = dirs[0].parent / "s4.B-tilesread-summary.csv"
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows: w.writerow(r)
    print(f"wrote {out_csv}", file=sys.stderr)

    # Markdown grids per backend
    datasets = sorted(set(r["dataset"] for r in rows))
    backends = sorted(set(r["backend"] for r in rows))
    ns = sorted(set(r["n_processes"] for r in rows))

    print("\n# Stage 4.B — On-the-fly random tile reads (Strategy B)\n")
    print("Tile read pattern: random (slide, x, y) sampling across full datasets (1131 BRCA / 399 CAMELYON16). LRU(8) slide handle cache per worker. 60s steady-state + 10s ramp per cell.\n")

    def grid_table(title, key, fmt):
        print(f"## {title}\n")
        hdr = "| dataset \\ N_processes | " + " | ".join(str(j) for j in ns) + " |"
        sep = "|" + "---|" * (len(ns) + 1)
        for backend in backends:
            print(f"### Backend: **{backend}**\n")
            print(hdr); print(sep)
            for ds in datasets:
                cells = []
                for n in ns:
                    matches = [r for r in rows if r["dataset"]==ds and r["backend"]==backend and r["n_processes"]==n]
                    if matches and matches[0].get(key) is not None:
                        cells.append(fmt(matches[0][key]))
                    else:
                        cells.append("—")
                print(f"| **{ds}** | " + " | ".join(cells) + " |")
            print()

    grid_table("Tiles/sec steady-state (the customer-quotable headline)", "tiles_per_sec_steady", lambda v: f"{v:.0f}")
    grid_table("WEKA client Read sustained (MiB/s)", "weka_read_sustained_bps", lambda v: f"{v/(1024**2):.1f}")
    grid_table("WEKA Ops/s sustained", "weka_ops_sustained", lambda v: f"{v:.0f}")
    grid_table("RDMA rcv sustained (MiB/s) — wire-level read direction", "rdma_rcv_sustained_bps", lambda v: f"{v/(1024**2):.1f}")
    grid_table("Aggregate CPU %busy sustained (application cores; storage-client reserved cores excluded)", "agg_cpu_busy_ex_dpdk_sustained_pct", lambda v: f"{v:.1f}%")
    grid_table("Cache hit rate (LRU(8))", "cache_hit_rate", lambda v: f"{v*100:.1f}%")

    valid = [r for r in rows if r.get("tiles_per_sec_steady")]
    if valid:
        peak = max(valid, key=lambda r: r["tiles_per_sec_steady"])
        print(f"\n**Peak tiles/sec across the sweep:** {peak['tiles_per_sec_steady']:.0f} "
              f"({peak['dataset']}, backend={peak['backend']}, N={peak['n_processes']}"
              + (f", nw={peak.get('num_workers')}, bs={peak.get('batch_size')}" if peak.get('num_workers') else "")
              + ")")


if __name__ == "__main__":
    main()
