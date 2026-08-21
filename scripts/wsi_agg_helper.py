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
      Lustre: derived from the RECORDED stripe layout (`lfs getstripe -d`, the
              contract's lustre_stripe_layout / env LUSTRE_STRIPE_LAYOUT):
              every component of the provisioned layout is pattern raid0 with
              lcm_mirror_count 1 — striping DISTRIBUTES bytes across OSTs but
              never amplifies them, and FSx redundancy is server-side, invisible
              to the client NIC — so wire/app = mirror_count = 1.0 for writes
              and 1.0 for reads. A mirrored (FLR) or non-raid0 layout would
              change that, so the parser refuses those rather than assuming.
              Empirical anchors, this leg's Leg-B build (2026-08-21): EFA
              tx+rx / app = 1.0016 across a 128 MiB direct dd round-trip, and
              wire/osc = 1.002 per direction on the ~6 GB/s stage-0 proof cell.
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
  wsi_agg_helper.py calibrate <run-dir>...  compute + write the leg's canary
                                        bands from the calibration cells
                                        (calibrate-canary-bands.sh drives them)
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


def parse_stripe_layout(layout):
    """Recorded `lfs getstripe -d <mount>` text (the contract's
    lustre_stripe_layout / env LUSTRE_STRIPE_LAYOUT) -> {mirror_count,
    patterns, stripe_counts}. Refuses empty/malformed input rather than
    defaulting — the relation must come from the RECORDED layout (D12/L2)."""
    txt = str(layout or "")
    mm = re.search(r"lcm_mirror_count:\s*(\d+)", txt)
    pats = re.findall(r"pattern:\s*(\S+)", txt)
    scs = re.findall(r"stripe_count:\s*(-?\d+)", txt)
    if not (mm and pats and scs):
        raise ValueError(
            "LUSTRE_STRIPE_LAYOUT is not a recorded `lfs getstripe -d` layout "
            f"(need lcm_mirror_count/pattern/stripe_count), got {txt[:80]!r}...")
    return {"mirror_count": int(mm.group(1)),
            "patterns": pats,
            "stripe_counts": [int(s) for s in scs]}


def expected_relation(fs, direction, ec_scheme=None, stripe_layout=None):
    """Center of the wire/app ratio for a healthy cluster.

    fs='weka': write -> (D+P)/D from the ACTUAL provisioned scheme; read -> 1.0.
    fs='lustre': derived from the RECORDED stripe layout: raid0 striping
    distributes bytes but never amplifies them and FSx redundancy is
    server-side, so read -> 1.0 and write -> mirror_count (1 on the
    provisioned unmirrored layout). A non-raid0 component is a layout this
    derivation was never validated on — refuse, don't assume.
    """
    if direction not in ("read", "write"):
        raise ValueError(f"direction must be read|write, got {direction!r}")
    if fs == "weka":
        if direction == "write":
            d, p = parse_ec_scheme(ec_scheme)
            return (d + p) / d
        return 1.0
    if fs == "lustre":
        lay = parse_stripe_layout(stripe_layout)
        bad = [p for p in lay["patterns"] if p != "raid0"]
        if bad:
            raise NotImplementedError(
                f"stripe layout has non-raid0 component(s) {bad} — the wire/app "
                "relation was derived for raid0-only layouts; re-derive before use (D12)")
        if direction == "write":
            return float(lay["mirror_count"])
        return 1.0
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
                        stripe_layout=None, bands=None, bs_bytes=None,
                        mixed=False, sample_count=None):
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
    center = expected_relation(fs, direction, ec_scheme, stripe_layout)
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


def client_rate_metrics(results, fs):
    """The four canary inputs (app/wire x read/write, active-window means) from
    a parsed results.json dict, per leg (THESIS §4 source table):
      weka:   app  = weka_stats_client Read/Write_client_sum (fs-level, this client)
              wire = weka_stats_client L6 Recv/Sent_client_sum (WEKA's own wire accounting)
      lustre: app  = lustre_stats_client read/write_bytes_per_sec (osc bytes summed
                     across OSTs — every byte the client moved to storage, aio
                     included; llite is aio-blind, proven on the 2026-08-21 build)
              wire = rdma_counters rcv/xmit_bytes_per_sec (the recorder's column
                     names) summed across the EFA devices' hw_counters rows — the
                     client's network counters ARE the data path on this leg
                     (THESIS §4 inversion). Summing device means is sound because
                     every device is sampled on the same ticks.
    A missing series comes back None (NO_DATA upstream), never zero."""
    src = results.get("sources", {}) or {}

    def awm(d, k):
        return ((d.get(k) or {}).get("active_window_mean")) if d else None

    if fs == "weka":
        m = (src.get("weka_stats_client") or {}).get("metrics") or {}
        return {"app_read": awm(m, "Read_client_sum"),
                "wire_read": awm(m, "L6 Recv_client_sum"),
                "app_write": awm(m, "Write_client_sum"),
                "wire_write": awm(m, "L6 Sent_client_sum")}
    if fs == "lustre":
        m = (src.get("lustre_stats_client") or {}).get("metrics") or {}
        devs = (src.get("rdma_counters") or {}).get("devices") or {}

        def wire(col):
            vals = [awm(d, col) for k, d in devs.items() if k.endswith("/hw_counters")]
            vals = [v for v in vals if v is not None]
            return sum(vals) if vals else None

        return {"app_read": awm(m, "read_bytes_per_sec"),
                "wire_read": wire("rcv_bytes_per_sec"),
                "app_write": awm(m, "write_bytes_per_sec"),
                "wire_write": wire("xmit_bytes_per_sec")}
    raise ValueError(f"fs must be weka|lustre, got {fs!r}")


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
    regime. Lustre cold set (ratified 2026-08-21): drop_caches=3 + ldlm
    lru_size=clear, BOTH acknowledged in cache-evidence.txt.
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
        # Every acknowledged step must have succeeded (the file may carry more
        # than one action block — the lustre cold set is two steps).
        rcs = re.findall(r"^rc=(\d+)", txt, re.M)
        ok = bool(rcs) and all(r == "0" for r in rcs)
        # Lustre cold set (ratified 2026-08-21, D13/D-4): vm.drop_caches=3 PLUS
        # the client DLM-lock clear (ldlm.namespaces.*.lru_size=clear) — a held
        # lock can keep data/attributes servable client-side after the
        # page-cache drop. A lustre cold declaration whose evidence lacks the
        # ldlm acknowledgment is missing half its evidence: marked, never
        # quoted as cold.
        if meta.get("fs") == "lustre" and declared == "cold" and "ldlm" not in txt:
            out["verdict"] = "DECLARED_WITHOUT_EVIDENCE"
            out["detail"] = ("cache-evidence.txt lacks the ldlm lru_size=clear acknowledgment — "
                             "the lustre cold set is drop_caches=3 + ldlm clear (ratified 2026-08-21)")
            out["evidence"] = ["cache-evidence.txt (partial: drop_caches only)"]
            return out
        evidence.append(("cache-evidence.txt", ok))
    for name in ("reader-summary.json", "extraction-summary.json", "file-io-summary.json"):
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

    # Stage 7's inference worker emits per-cell discard COUNTERS, not a boolean
    # (its per-slide discards can partially fail; a cold cell with any failed —
    # or never-attempted — discard read those slides WARM, per the worker's own
    # summary wording).
    p = run_dir / "inference-summary.json"
    if p.exists():
        try:
            d = json.loads(p.read_text())
        except json.JSONDecodeError:
            d = {}
        att = d.get("n_client_page_cache_discards_attempted")
        failed = d.get("n_client_page_cache_discards_failed") or 0
        if att is not None:
            if declared == "cold" and (att == 0 or failed > 0):
                out["verdict"] = "CONTRADICTED"
                out["detail"] = (f"inference-summary.json: discards attempted={att} failed={failed} — "
                                 "slides whose discard failed or was never attempted read WARM")
                return out
            if declared == "warm" and att > 0:
                out["verdict"] = "CONTRADICTED"
                out["detail"] = (f"inference-summary.json: {att} per-slide discards attempted on a "
                                 "declared-warm cell — the cell did not run its declared regime")
                return out
            evidence.append(("inference-summary.json", True))

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
    """Post-cell consistency canary for one run dir (both legs)."""
    import os
    run_dir = Path(run_dir)
    meta = json.loads((run_dir / "metadata.json").read_text())
    fs = meta["fs"]
    repo_root = run_dir.parent.parent
    leg = fs
    bands = load_bands(repo_root, leg)
    ec = os.environ.get("WEKA_EC_SCHEME")
    layout = os.environ.get("LUSTRE_STRIPE_LAYOUT")
    results = json.loads((run_dir / "results.json").read_text())
    rm = client_rate_metrics(results, fs)

    # Block size, from the run-dir name segment every 1.0 cell carries
    # (-bs4k- / -bs1M- ...): without it the calibrated small-bs widening never
    # applies and every small-block cell false-FAILs against the large-block
    # band. A name without a bs segment gets None (no widening), correctly.
    bs_bytes = None
    mb = re.search(r"-bs(\d+)([kKmM])", run_dir.name)
    if mb:
        bs_bytes = int(mb.group(1)) * (1024 if mb.group(2).lower() == "k" else 1024**2)

    verdicts = []
    app_r, wire_r = rm["app_read"], rm["wire_read"]
    app_w, wire_w = rm["app_write"], rm["wire_write"]
    # A direction is evaluated (and counts as "mixed" for the other) only above
    # a materiality floor — metadata dribble on an idle direction is not a
    # mixed workload, and evaluating it would ratio noise against noise.
    MATERIAL = 10e6   # low enough that a 4K jobs=1 cell still gets a verdict
    r_live, w_live = bool(app_r and app_r > MATERIAL), bool(app_w and app_w > MATERIAL)
    if r_live:
        verdicts.append(consistency_verdict(app_r, wire_r, fs=fs, direction="read",
                                            ec_scheme=ec, stripe_layout=layout,
                                            bands=bands, bs_bytes=bs_bytes,
                                            mixed=w_live))
    if w_live:
        verdicts.append(consistency_verdict(app_w, wire_w, fs=fs, direction="write",
                                            ec_scheme=ec, stripe_layout=layout,
                                            bands=bands, bs_bytes=bs_bytes,
                                            mixed=r_live))
    print(json.dumps({"run_dir": str(run_dir), "verdicts": verdicts}, indent=2))
    bad = [v for v in verdicts if v["verdict"] not in ("PASS",)]
    # UNCALIBRATED and FAIL both exit non-zero: an unevaluable canary must be
    # loud enough to abort an unattended chain, not quietly skipped.
    return 0 if verdicts and not bad else 1


def _cli_calibrate(run_dirs):
    """Compute and write the leg's canary bands from calibration cells (D-5).

    Input: >=3 large-block write cells and >=3 large-block read cells (the
    probe-shaped calibration cells), plus optional small-bs cells (run name
    contains 'bs4k') that set smallbs_widening — the Stage-1 register requires
    the small-block band to be DERIVED at the block size under test, never
    inherited from the large-block cells.

    lo/hi are multipliers on the expected center (write (D+P)/D, read 1.0):
    min/max of the observed normalized ratios across the repeats, +/-5% margin.
    Refuses (exit non-zero) on fewer than 3 cells for either direction — a band
    from fewer repeats is a guess wearing a measurement's clothes.
    mixed_widening is deliberately NOT written here: it needs mixed calibration
    cells (open-items memory B.3), and a guessed widening can mask a real
    inconsistency. Until it exists, mixed cells widen by 1.0 and a FAIL there
    is a judgement to record, not a band to bend.
    """
    import os
    MARGIN = 1.05
    leg = None
    repo_root = None
    ec = os.environ.get("WEKA_EC_SCHEME")
    layout = os.environ.get("LUSTRE_STRIPE_LAYOUT")
    norms = {"read": [], "write": []}      # large-bs normalized ratios
    small_norms = []                       # small-bs normalized ratios (both dirs)
    cells = []
    for rd in run_dirs:
        rd = Path(rd)
        meta = json.loads((rd / "metadata.json").read_text())
        fs = meta["fs"]
        leg = leg or fs
        repo_root = repo_root or rd.parent.parent
        results = json.loads((rd / "results.json").read_text())
        rm = client_rate_metrics(results, fs)
        m = lambda k: rm.get(k) or 0.0
        small = "bs4k" in rd.name
        pairs = (("read", m("app_read"), m("wire_read")),
                 ("write", m("app_write"), m("wire_write")))
        for direction, app, wire in pairs:
            if app < 50e6:   # idle direction on a single-direction probe cell
                continue
            if not wire:
                print(f"calibrate: REFUSING — {rd.name} has app traffic but no wire series "
                      f"({direction}); a calibration cell with a dead Primary source calibrates nothing",
                      file=sys.stderr)
                return 1
            n = (wire / app) / expected_relation(fs, direction, ec, layout)
            (small_norms if small else norms[direction]).append(n)
            cells.append({"run_dir": rd.name, "direction": direction,
                          "ratio": round(wire / app, 4), "normalized": round(n, 4),
                          "small_bs": small})
    for direction in ("read", "write"):
        if len(norms[direction]) < 3:
            print(f"calibrate: REFUSING — only {len(norms[direction])} large-bs {direction} cells; "
                  "the procedure requires >=3 repeats per direction (D-5)", file=sys.stderr)
            return 1
    bands = {}
    for direction in ("read", "write"):
        v = norms[direction]
        bands[direction] = {"lo": round(min(v) / MARGIN, 4), "hi": round(max(v) * MARGIN, 4)}
    out = {"bands": {**bands, "smallbs_bytes": 65536}}
    if small_norms:
        lo_all = min(bands[d]["lo"] for d in ("read", "write"))
        hi_all = max(bands[d]["hi"] for d in ("read", "write"))
        w = max([1.0] + [max(n / hi_all, lo_all / n) for n in small_norms]) * MARGIN
        out["bands"]["smallbs_widening"] = round(w, 4)
    else:
        print("calibrate: WARNING — no small-bs cells supplied; small-block cells will be "
              "judged at the LARGE-block band, which the Stage-1 register forbids. "
              "Supply bs4k calibration cells.", file=sys.stderr)
    out["calibrated_utc"] = __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc).isoformat()
    # The scheme input the centers were normalized against, per leg — recorded so
    # a band file can be audited against the contract it was calibrated under.
    out["ec_scheme"] = ec
    if leg == "lustre":
        out["stripe_layout"] = layout
    out["cells"] = cells
    p = Path(repo_root) / "runs" / ".leg-state" / leg / "canary-bands.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    print(f"calibrate: wrote {p}")
    return 0


def _selftest():
    assert parse_ec_scheme("5+2") == (5, 2)
    assert abs(expected_relation("weka", "write", "5+2") - 1.4) < 1e-9
    assert expected_relation("weka", "read") == 1.0
    # Lustre relation: derives from the recorded layout; refuses without one and
    # on layouts (mirrored / non-raid0) the derivation was never validated for.
    _LAY = ("lcm_layout_gen: 0 lcm_mirror_count: 1 lcm_entry_count: 4 "
            "stripe_count: 1 stripe_size: 1048576 pattern: raid0 stripe_offset: -1 "
            "stripe_count: 8 stripe_size: 1048576 pattern: raid0 stripe_offset: -1")
    assert expected_relation("lustre", "read", stripe_layout=_LAY) == 1.0
    assert expected_relation("lustre", "write", stripe_layout=_LAY) == 1.0
    try:
        expected_relation("lustre", "read")
        raise AssertionError("lustre relation must refuse without a recorded layout")
    except ValueError:
        pass
    try:
        expected_relation("lustre", "write",
                          stripe_layout=_LAY.replace("pattern: raid0", "pattern: mdt", 1))
        raise AssertionError("lustre relation must refuse a non-raid0 component")
    except NotImplementedError:
        pass
    fake_lustre_results = {"sources": {
        "lustre_stats_client": {"metrics": {
            "read_bytes_per_sec": {"active_window_mean": 5.0e9},
            "write_bytes_per_sec": {"active_window_mean": 2.0e9}}},
        "rdma_counters": {"devices": {
            "efa_0/hw_counters": {"rcv_bytes_per_sec": {"active_window_mean": 3.0e9},
                                  "xmit_bytes_per_sec": {"active_window_mean": 1.1e9}},
            "efa_1/hw_counters": {"rcv_bytes_per_sec": {"active_window_mean": 2.0e9},
                                  "xmit_bytes_per_sec": {"active_window_mean": 0.9e9}}}}}}
    rm = client_rate_metrics(fake_lustre_results, "lustre")
    assert rm == {"app_read": 5.0e9, "wire_read": 5.0e9,
                  "app_write": 2.0e9, "wire_write": 2.0e9}, rm
    v = consistency_verdict(rm["app_read"], rm["wire_read"], fs="lustre",
                            direction="read", stripe_layout=_LAY,
                            bands={"bands": {"read": {"lo": 0.95, "hi": 1.10},
                                             "write": {"lo": 0.95, "hi": 1.10}}})
    assert v["verdict"] == "PASS", v
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
    if cmd == "calibrate" and len(sys.argv) >= 3:
        return _cli_calibrate(sys.argv[2:])
    if cmd == "cache" and len(sys.argv) == 3:
        print(json.dumps(reconcile_cache_state(sys.argv[2]), indent=2))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
