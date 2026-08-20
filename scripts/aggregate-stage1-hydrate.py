#!/usr/bin/env python3
"""aggregate-stage1-hydrate.py — roll the Stage 1.7 hydration cells into
runs/s1.7-hydrate-summary.csv (the roadmap's promised aggregate; built
2026-08-17 when the closeout gate found the substage had no aggregator at all).

Per cell: max_concurrent_requests (from the run name), wallclock, the fs-side
write rates (client-summed active-window mean — the quotable one — plus the
naive full-window mean for visibility), effective corpus GiB/s over wallclock
(the full 2 dataset prefixes are re-hydrated per cell by construction), and the
INDEX verdict. Self-locates the runs tree from its own path; no arguments.
"""
import csv
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RUNS = REPO / "runs"
CORPUS_BYTES = 1158795315120 + 762471984787  # byte-verified staging totals (both prefixes)

rows = []
_LEG = __import__("os").environ.get("LEG") or __import__("sys").exit("LEG is unset -- source env.sh (the default glob is leg-scoped: pulled other-leg run dirs must not enter this leg's summary CSV)")
for d in sorted(RUNS.glob(f"*-{_LEG}-s1.7-hydrate-*")):
    if not d.is_dir() or "FAILED" in d.name:
        continue
    m = re.search(r"-mcr(\d+)$", d.name)
    meta = json.loads((d / "metadata.json").read_text())
    results = json.loads((d / "results.json").read_text())
    cl = (results.get("sources", {}).get("weka_stats_client", {}) or {}).get("metrics", {})
    w = cl.get("Write_client_sum") or {}
    wall = meta.get("wallclock_s")
    index_ok = "OK" if any(f"`{d.name}`" in ln and " OK)" in ln
                           for ln in (RUNS / "INDEX.md").read_text().splitlines()) else "NOT-OK"
    rows.append({
        "mcr": int(m.group(1)) if m else None,
        "run_dir": d.name,
        "wallclock_s": wall,
        "fs_write_active_mean_gib_s": round((w.get("active_window_mean") or 0) / 2**30, 3),
        "fs_write_naive_mean_gib_s": round((w.get("mean") or 0) / 2**30, 3),
        "corpus_gib_per_s_over_wallclock": round(CORPUS_BYTES / 2**30 / wall, 3) if wall else None,
        "fs": meta.get("fs"),
        "cache_state": meta.get("cache_state"),
        "status": index_ok,
    })

if not rows:
    sys.exit("aggregate-stage1-hydrate: no s1.7 run dirs found")
rows.sort(key=lambda r: (r["mcr"] is None, r["mcr"]))
out = RUNS / "s1.7-hydrate-summary.csv"
with out.open("w", newline="") as f:
    wtr = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    wtr.writeheader()
    wtr.writerows(rows)
print(f"wrote {out} ({len(rows)} cells)")
for r in rows:
    print(f"  mcr={r['mcr']:>3}: {r['wallclock_s']:>5}s  active {r['fs_write_active_mean_gib_s']} GiB/s  "
          f"corpus/wallclock {r['corpus_gib_per_s_over_wallclock']} GiB/s  [{r['status']}]")
