#!/usr/bin/env python3
"""compose-stage6d.py — Stage 6.D constructive end-to-end composition (per leg).

6.D is NOT a measured cell (Stage-6 roadmap § 6.D): the phases are strictly
sequential with no shared-resource interaction, so measured per-phase wallclocks
compose to the end-to-end number exactly. This script IS the ratified recipe
(2026-08-23), so both legs compose identically:

  per (backend, model):
    tissue_s   = the 3.0 TCGA-BRCA n=64 cell's run window (the measured
                 production-shaped optimum of the swept curve)
    convert_s  = kvikIO only: the chunked Tier-2 cell's own recorded per-chunk
                 convert total (same run, same interleaving as the extraction it
                 composes with), amortised across the models that share it
    extract_s  = kvikIO: the chunked cell's per-model extract wallclock
                 (extraction-summary-<model>.json); cuCIM: that model's
                 full-cohort cell wallclock (extraction-summary.json)
    mil_s      = one epoch DERIVED from the nw=16 knee cell: n_slides_in_corpus
                 / slides_per_sec_steady (the 6.B.3 cells are fixed-window
                 throughput cells, not epoch runs; startup excluded — the share
                 is ~0.1% of the pipeline, and the derivation is stated where
                 quoted)

Cost follows from the composed wallclock at the leg contract's recorded rates
(as-run basis; headline costs come from the publication-time reprice).

Reads only recorded artifacts; refuses (exit 2) if any source cell is missing
or ambiguous. FAILED-renamed and -repN dirs are never sources (D-38/D18).

Usage:  LEG must be set (source env.sh).  compose-stage6d.py
Writes: runs/s6.D-e2e-composed-summary-<leg>.csv + a markdown table to stdout.
"""
import csv
import glob
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODELS = ["virchow2", "gigapath", "uni2-h"]


def die(msg):
    print(f"compose-stage6d: {msg}", file=sys.stderr)
    sys.exit(2)


def one(pattern, what):
    hits = [p for p in glob.glob(str(REPO / "runs" / pattern))
            if "-FAILED-" not in p and not re.search(r"-rep\d+$", p)]
    if len(hits) != 1:
        die(f"{what}: expected exactly 1 dir for {pattern!r}, found {len(hits)}: {hits}")
    return Path(hits[0])


def run_window_s(d):
    def ts(name):
        return datetime.fromisoformat((d / "raw" / name).read_text().strip().rstrip("Z"))
    return (ts(".run_end") - ts(".run_start")).total_seconds()


def main():
    leg = os.environ.get("LEG", "").strip()
    if not leg:
        die("LEG is unset -- source env.sh (summary CSVs are per-leg files: D6 concurrent legs)")

    tissue_dir = one(f"*-{leg}-s3.0-tissue-tcga-brca-n64", "3.0 tissue cell")
    tissue_s = run_window_s(tissue_dir)

    chunk_dir = one(f"*-{leg}-s6.A-extract-multimodel-kvikio-brca_full-N4", "chunked Tier-2 cell")
    # convert is shared per chunk and its wallclock repeats on every model row of
    # that chunk -- sum it once per chunk_idx or it multiplies by the model count.
    per_chunk = {}
    with open(chunk_dir / "per-chunk-summary.csv") as f:
        for row in csv.DictReader(f):
            per_chunk[row["chunk_idx"]] = float(row["convert_wallclock_s"])
    convert_total_s = sum(per_chunk.values())
    convert_amortised_s = convert_total_s / len(MODELS)

    contract = json.loads((REPO / "runs" / f"env-contract-leg-{leg}.json").read_text())
    infra_hr = float(contract["instance_usd_per_hr"]) + float(contract["fs_usd_per_hr"])
    allin_hr = infra_hr + float(contract["software_usd_per_hr"])

    rows = []
    for model in MODELS:
        kv = json.loads((chunk_dir / f"extraction-summary-{model}.json").read_text())
        cu_dir = one(f"*-{leg}-s6.A-extract-{model}-cucim-brca_full-N4", f"cuCIM cell ({model})")
        cu = json.loads((cu_dir / "extraction-summary.json").read_text())
        mil_dir = one(f"*-{leg}-s6.B.3-train-mil-{model}-brca_full-bs1-nw16", f"MIL knee cell ({model})")
        mil = json.loads((mil_dir / "training-summary.json").read_text())
        mil_s = mil["n_slides_in_corpus"] / mil["slides_per_sec_steady"]

        for backend, extract_s, conv_s, src in (
            ("kvikio", kv["cell_wallclock_s"], convert_amortised_s, chunk_dir.name),
            ("cucim", cu["cell_wallclock_s"], 0.0, cu_dir.name),
        ):
            total_s = tissue_s + conv_s + extract_s + mil_s
            rows.append({
                "leg": leg, "backend": backend, "model": model,
                "tissue_s": round(tissue_s, 1),
                "convert_amortised_s": round(conv_s, 1),
                "extract_s": round(extract_s, 1),
                "mil_epoch_s": round(mil_s, 1),
                "total_s": round(total_s, 1),
                "total_h": round(total_s / 3600, 2),
                "infra_only_usd": round(total_s / 3600 * infra_hr, 2),
                "all_in_usd": round(total_s / 3600 * allin_hr, 2),
                "price_checked_utc": contract["price_checked_utc"],
                "src_tissue": tissue_dir.name, "src_extract": src,
                "src_mil": mil_dir.name,
            })

    out = REPO / "runs" / f"s6.D-e2e-composed-summary-{leg}.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {out.relative_to(REPO)}\n")

    print(f"# Stage 6.D composed end-to-end (leg={leg}) — raw SVS to trained MIL classifier\n")
    print("| backend | model | tissue | convert (amortised /3) | extract | MIL epoch | TOTAL | infra-only | all-in |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['backend']} | {r['model']} | {r['tissue_s']} s | {r['convert_amortised_s']} s "
              f"| {r['extract_s']} s | {r['mil_epoch_s']} s | **{r['total_h']} h** "
              f"| ${r['infra_only_usd']} | ${r['all_in_usd']} |")
    print(f"\nRates (as-run, checked {rows[0]['price_checked_utc']}): "
          f"infra {infra_hr:.5f} $/hr, all-in {allin_hr:.5f} $/hr.")


if __name__ == "__main__":
    main()
