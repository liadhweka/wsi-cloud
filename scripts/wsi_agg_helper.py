#!/usr/bin/env python3
"""wsi_agg_helper.py — the shared per-leg aggregation helper (D-4 / D-5 / D-12
/ D-13 / D-15 / D-18). One module the aggregators import, so per-leg logic
lives in exactly one place and cannot drift per file.

What lives here
  - The per-filesystem CONSISTENCY RELATION (D-5, D12), derived from the
    provisioned scheme, never ported:
      WEKA:   clients place erasure-coded stripes on backends directly
              (docs.weka.io: each client "directly accesses the relevant WEKA
              backend"; write overhead is the parity share of the stripe), so
              for a D+P scheme  write wire/app = (D+P)/D  and  read wire/app
              = 1.0 (healthy reads carry no parity).
              Empirical anchors, this leg's 5+2 Stage-0 probes (2026-08-15):
              write 1.455 (= 1.40 x ~1.04 protocol), read 1.034.
      Lustre: follows from the actual stripe layout (lfs getstripe) — BUILT ON
              LEG B against the live cluster; asking for it here raises.
  - CANARY BANDS: loaded from the leg's calibration file
    (runs/.leg-state/<leg>/canary-bands.json), written by the calibration
    cells on the PROVISIONED cluster. No calibration file -> the canary
    reports UNCALIBRATED loudly instead of inventing a tolerance; a ported or
    guessed band can both mask a real inconsistency and manufacture a false
    one.
  - The pattern-#1 CLIENT SERIES: filter the stats stream to this client's
    rows by ROLE, sum across its processes per timestamp, aggregate the sums.
  - D18 REP GROUPING: median + spread for configs with multiple reps.
  - D13 CACHE RECONCILIATION: declared cache_state vs achieved evidence; a
    declaration without evidence is MARKED, never quoted as its regime.
  - Leg-neutral METRIC-KEY naming for the CPU keys the audit left stable.

CLI:
  wsi_agg_helper.py check <run-dir>     post-cell consistency canary verdict
  wsi_agg_helper.py cache <run-dir>     cache-state reconciliation verdict
  wsi_agg_helper.py selftest            unit checks (no environment needed)

Stdlib only.
"""

import csv
import json
import re
import statistics
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Consistency relation (D-5 / D12)
# ---------------------------------------------------------------------------

def parse_ec_scheme(scheme):
    """'5+2' -> (5, 2). Refuses malformed input rather than defaulting."""
    m = re.fullmatch(r"\s*(\d+)\s*\+\s*(\d+)\s*", str(scheme or ""))
    if not m:
        raise ValueError(f"WEKA_EC_SCHEME must look like 'D+P', got {scheme!r}")
    d, p = int(m.group(1)), int(m.group(2))
    if not (3 <= d <= 16 and 2 <= p <= 4):
        raise ValueError(f"EC scheme {d}+{p} outside WEKA's documented D 3-16 / P 2-4 range")
    return d, p


def expected_relation(fs, direction, ec_scheme=None):
    """Center of the wire/app ratio for a healthy cluster.

    fs='weka': write -> (D+P)/D from the ACTUAL provisioned scheme; read -> 1.0.
    fs='lustre': derived from the actual stripe layout on the Leg-B cluster —
    deliberately NotImplemented until that adapter is built there (D-4).
    """
    if fs == "weka":
        if direction == "write":
            d, p = parse_ec_scheme(ec_scheme)
            return (d + p) / d
        if direction == "read":
            return 1.0
        raise ValueError(f"direction must be read|write, got {direction!r}")
    if fs == "lustre":
        raise NotImplementedError(
            "The Lustre consistency relation is derived from the actual stripe "
            "layout on the provisioned Leg-B cluster (D-5/D-4) — never ported or recalled.")
    raise ValueError(f"fs must be weka|lustre, got {fs!r}")


def load_bands(repo_root, leg):
    """The leg's calibrated canary bands, or None (=> UNCALIBRATED, loudly).

    Written by the calibration cells on the provisioned cluster as
    runs/.leg-state/<leg>/canary-bands.json:
      {"calibrated_utc": ..., "cells": [...run dirs...],
       "bands": {"read": {"lo":..., "hi":...}, "write": {...},
                 "mixed_widening": <factor>,
                 "smallbs_bytes": <threshold>, "smallbs_widening": <factor>}}
    """
    p = Path(repo_root) / "runs" / ".leg-state" / leg / "canary-bands.json"
    if not p.exists():
        return None
    return json.loads(p.read_text())


def consistency_verdict(app_bps, wire_bps, *, fs, direction, ec_scheme=None,
                        bands=None, bs_bytes=None, mixed=False, sample_count=None):
    """One direction's post-cell cross-source check.

    Returns a dict with ratio, expected center, band used, and verdict in
    {PASS, FAIL, UNCALIBRATED, UNDER_SAMPLED, NO_DATA}. Never silently widens:
    every widening is named in the verdict.
    """
    out = {"direction": direction, "fs": fs}
    if not app_bps or not wire_bps:
        out["verdict"] = "NO_DATA"
        out["detail"] = "app or wire series missing/zero — a missing Primary source is a recording failure, not a pass"
        return out
    center = expected_relation(fs, direction, ec_scheme)
    ratio = wire_bps / app_bps
    out.update(ratio=round(ratio, 4), expected_center=round(center, 4))
    if sample_count is not None and sample_count < 5:
        out["verdict"] = "UNDER_SAMPLED"
        out["detail"] = (f"only {sample_count} samples — a sub-second/short cell under-samples the 1 Hz "
                         "recorders; a sampling limit, not a consistency failure (record the judgement)")
        return out
    if bands is None:
        out["verdict"] = "UNCALIBRATED"
        out["detail"] = ("no canary-bands.json for this leg — run the calibration cells on the "
                         "provisioned cluster first; refusing to invent a tolerance")
        return out
    b = bands["bands"][direction]
    lo, hi = b["lo"], b["hi"]
    widenings = []
    if mixed:
        w = bands["bands"].get("mixed_widening", 1.0)
        lo, hi = lo / w, hi * w
        widenings.append(f"mixed x{w}")
    if bs_bytes is not None and bs_bytes <= bands["bands"].get("smallbs_bytes", 0):
        w = bands["bands"].get("smallbs_widening", 1.0)
        lo, hi = lo / w, hi * w
        widenings.append(f"small-bs x{w}")
    out["band"] = [round(center * lo, 4), round(center * hi, 4)]
    out["widenings_applied"] = widenings  # named, never silent
    out["verdict"] = "PASS" if center * lo <= ratio <= center * hi else "FAIL"
    return out


# ---------------------------------------------------------------------------
# Pattern #1: the client's own series from the WEKA stats stream
# ---------------------------------------------------------------------------

_BPS = re.compile(r"^\s*(-?[\d.eE+]+)\s*(?:B/s)?\s*$")

def _num(v):
    m = _BPS.match(v or "")
    return float(m.group(1)) if m else None


def weka_client_series(weka_stats_csv, column):
    """Per-timestamp sums of `column` across THIS client's processes.

    Filter by ROLE (Mode=='client' — this cluster runs exactly one client
    container by design), never hostname or numeric id. Returns the sorted
    per-timestamp list; empty means the filter matched nothing, which is a
    MISSING filesystem-side source, not zero throughput.
    """
    p = Path(weka_stats_csv)
    if not p.exists():
        return []
    by_ts = {}
    with p.open(newline="") as f:
        for row in csv.DictReader(f):
            if (row.get("Mode") or "").strip().lower() != "client":
                continue
            v = _num(row.get(column, ""))
            if v is None:
                continue
            by_ts.setdefault(row.get("timestamp"), 0.0)
            by_ts[row["timestamp"]] += v
    return [by_ts[t] for t in sorted(by_ts)]


def active_window_mean(seq):
    """Idle-robust mean (same definition as parse-results.py)."""
    seq = [v for v in seq if v is not None]
    if not seq:
        return None
    peak = max(seq)
    if peak <= 0:
        return statistics.fmean(seq)
    idx = [i for i, v in enumerate(seq) if v >= 0.05 * peak]
    return statistics.fmean(seq[idx[0]:idx[-1] + 1]) if idx else statistics.fmean(seq)


# ---------------------------------------------------------------------------
# D18: rep grouping and the stability noise band
# ---------------------------------------------------------------------------

def group_reps(rows, config_key, value_key):
    """Group rows by config; multi-rep configs report median + spread.

    `rep` comes from metadata (null/absent = the single-shot base run). A
    single-shot config is flagged single_shot=True so a headline built on it
    can say so, per RUNBOOK.
    """
    groups = {}
    for r in rows:
        groups.setdefault(config_key(r), []).append(r)
    out = []
    for key, members in groups.items():
        vals = [m.get(value_key) for m in members if m.get(value_key) is not None]
        if not vals:
            continue
        out.append({
            "config": key,
            "n": len(vals),
            "median": statistics.median(vals),
            "spread": (max(vals) - min(vals)) if len(vals) > 1 else 0.0,
            "spread_pct": (100.0 * (max(vals) - min(vals)) / statistics.median(vals))
                          if len(vals) > 1 and statistics.median(vals) else 0.0,
            "single_shot": len(vals) == 1,
        })
    return out


def stability_band(values):
    """The leg's empirical noise band from the stability-canary cells (C0-C8):
    the spread of a deliberately fixed config across the leg. A cross-leg delta
    is quoted only where it clears BOTH legs' bands."""
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return None
    med = statistics.median(vals)
    return {"n": len(vals), "median": med, "min": min(vals), "max": max(vals),
            "band_pct": 100.0 * (max(vals) - min(vals)) / med if med else None}


# ---------------------------------------------------------------------------
# D13: declared vs achieved cache state
# ---------------------------------------------------------------------------

def reconcile_cache_state(run_dir):
    """Declared (metadata.json cache_state) vs achieved evidence.

    Evidence sources, in the order they were designed in:
      - cache-evidence.txt in the run dir (the drivers' drop_caches
        acknowledgment / warmup record; rc must be 0)
      - reader-summary.json / extraction-summary.json fields
        client_page_cache_discarded (true/false/null — false makes a declared
        cold cell WARM, not cold-with-a-caveat)
    Verdicts: CONSISTENT | DECLARED_WITHOUT_EVIDENCE | CONTRADICTED |
    NOT_APPLICABLE (na-* declarations, write cells) | UNDECLARED.
    A cell that is not CONSISTENT is marked and never quoted as its declared
    regime. The Lustre-side evidence source gets named during the Leg-B build.
    """
    run_dir = Path(run_dir)
    meta = json.loads((run_dir / "metadata.json").read_text())
    declared = meta.get("cache_state")
    out = {"declared": declared}
    if declared is None:
        out["verdict"] = "UNDECLARED"
        return out
    if str(declared).startswith("na-"):
        out["verdict"] = "NOT_APPLICABLE"
        return out

    evidence = []
    ev_file = run_dir / "cache-evidence.txt"
    if ev_file.exists():
        txt = ev_file.read_text()
        rc = re.search(r"^rc=(\d+)", txt, re.M)
        ok = bool(rc and rc.group(1) == "0")
        evidence.append(("cache-evidence.txt", ok))
    for name in ("reader-summary.json", "extraction-summary.json"):
        p = run_dir / name
        if p.exists():
            try:
                d = json.loads(p.read_text())
            except json.JSONDecodeError:
                continue
            v = d.get("client_page_cache_discarded")
            if v is False and declared == "cold":
                out["verdict"] = "CONTRADICTED"
                out["detail"] = f"{name}: discard attempted and FAILED — the cell is warm, not cold-with-a-caveat"
                return out
            if v is not None:
                evidence.append((name, bool(v)))

    # A cold declaration whose one-touch construction is its evidence carries
    # it in the note (the drivers write the construction there); accept a
    # note-based construction only for the 1.0b/d sweeps' explicit wording.
    note = " ".join(meta.get("note", "")) if isinstance(meta.get("note"), list) else str(meta.get("note", ""))
    if declared == "cold" and "COLD BY CONSTRUCTION" in note:
        evidence.append(("note: cold-by-construction", True))
    if declared == "warm" and ("WARM REFERENCE" in note or "warmup pass" in note or "steady-state" in note.lower()):
        evidence.append(("note: warm-by-construction/exemption", True))

    if not evidence:
        out["verdict"] = "DECLARED_WITHOUT_EVIDENCE"
        out["detail"] = "no achieved-state evidence found — marked; never quoted as its declared regime"
        return out
    if all(ok for _, ok in evidence):
        out["verdict"] = "CONSISTENT"
    else:
        out["verdict"] = "CONTRADICTED"
    out["evidence"] = [name for name, _ in evidence]
    return out


# ---------------------------------------------------------------------------
# Metric-key normalization (leg-neutral names for the audit-stable keys)
# ---------------------------------------------------------------------------

_KEY_MAP = {
    # old WEKA-era key -> leg-neutral key (the reserved-core exclusion is a
    # per-filesystem parameter, not a DPDK-specific concept — D15)
    "non_dpdk_cpu_busy_mean": "app_cores_cpu_busy_mean",
    "non_dpdk_cpu_busy_max": "app_cores_cpu_busy_max",
    "agg_cpu_busy_ex_dpdk_mean": "app_cores_cpu_busy_mean",
    "agg_cpu_busy_ex_dpdk_max": "app_cores_cpu_busy_max",
}

def normalize_metric_key(key):
    return _KEY_MAP.get(key, key)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cli_check(run_dir):
    """Post-cell consistency canary for one run dir (WEKA leg)."""
    import os
    run_dir = Path(run_dir)
    meta = json.loads((run_dir / "metadata.json").read_text())
    fs = meta["fs"]
    repo_root = run_dir.parent.parent
    leg = fs
    bands = load_bands(repo_root, leg)
    ec = os.environ.get("WEKA_EC_SCHEME")
    results = json.loads((run_dir / "results.json").read_text())
    cl = (results.get("sources", {}).get("weka_stats_client", {}) or {}).get("metrics", {})

    def m(k):
        return (cl.get(k) or {}).get("active_window_mean")

    verdicts = []
    app_r, wire_r = m("Read_client_sum"), m("L6 Recv_client_sum")
    app_w, wire_w = m("Write_client_sum"), m("L6 Sent_client_sum")
    if app_r and app_r > 0:
        verdicts.append(consistency_verdict(app_r, wire_r, fs=fs, direction="read",
                                            ec_scheme=ec, bands=bands))
    if app_w and app_w > 0:
        verdicts.append(consistency_verdict(app_w, wire_w, fs=fs, direction="write",
                                            ec_scheme=ec, bands=bands,
                                            mixed=bool(app_r and app_r > 0)))
    print(json.dumps({"run_dir": str(run_dir), "verdicts": verdicts}, indent=2))
    bad = [v for v in verdicts if v["verdict"] not in ("PASS",)]
    # UNCALIBRATED and FAIL both exit non-zero: an unevaluable canary must be
    # loud enough to abort an unattended chain, not quietly skipped.
    return 0 if verdicts and not bad else 1


def _selftest():
    assert parse_ec_scheme("5+2") == (5, 2)
    assert abs(expected_relation("weka", "write", "5+2") - 1.4) < 1e-9
    assert expected_relation("weka", "read") == 1.0
    try:
        expected_relation("lustre", "read")
        raise AssertionError("lustre relation must refuse until built on Leg B")
    except NotImplementedError:
        pass
    bands = {"bands": {"write": {"lo": 0.95, "hi": 1.10}, "read": {"lo": 0.95, "hi": 1.10},
                       "mixed_widening": 1.15, "smallbs_bytes": 65536, "smallbs_widening": 1.25}}
    v = consistency_verdict(5.2e9, 7.56e9, fs="weka", direction="write",
                            ec_scheme="5+2", bands=bands)
    assert v["verdict"] == "PASS", v          # measured probe anchor passes
    v = consistency_verdict(5.2e9, 9.9e9, fs="weka", direction="write",
                            ec_scheme="5+2", bands=bands)
    assert v["verdict"] == "FAIL", v
    v = consistency_verdict(5.2e9, 7.56e9, fs="weka", direction="write",
                            ec_scheme="5+2", bands=None)
    assert v["verdict"] == "UNCALIBRATED", v
    v = consistency_verdict(0, 7.56e9, fs="weka", direction="write", ec_scheme="5+2", bands=bands)
    assert v["verdict"] == "NO_DATA", v
    g = group_reps([{"cfg": "a", "v": 10}, {"cfg": "a", "v": 12}, {"cfg": "b", "v": 5}],
                   lambda r: r["cfg"], "v")
    ga = next(x for x in g if x["config"] == "a")
    assert ga["n"] == 2 and ga["median"] == 11 and not ga["single_shot"]
    sb = stability_band([10, 11, 10.5])
    assert sb and abs(sb["band_pct"] - 100 * 1 / 10.5) < 1e-6
    assert normalize_metric_key("non_dpdk_cpu_busy_mean") == "app_cores_cpu_busy_mean"
    print("selftest OK")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "selftest":
        return _selftest()
    if cmd == "check" and len(sys.argv) == 3:
        return _cli_check(sys.argv[2])
    if cmd == "cache" and len(sys.argv) == 3:
        print(json.dumps(reconcile_cache_state(sys.argv[2]), indent=2))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
