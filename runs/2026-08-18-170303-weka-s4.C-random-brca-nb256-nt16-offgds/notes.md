# Data-validity note — per-tile-latencies.csv

This cell's `per-tile-latencies.csv` was OVERWRITTEN by its D18 REP=2 and REP=3 re-invocations
(rerun-cell.sh re-ran the recorded command verbatim, whose `--latency-csv` pointed into this dir;
fixed the same day with the RECORD_RUN_DIR path-rewrite). The file now holds **rep3's** series —
a valid same-config cell, but not this run's. This cell's own aggregate latency stats survive in
`reader-summary.json` (restored verbatim from this cell's cmd.log, which prints the summary).
The 1 Hz `raw/` telemetry is untouched.
