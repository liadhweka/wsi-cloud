# Stage 1.6 cell 2/9 — mixed (fpsync n=4 + fio randread bs=64k jobs=16)

## Ingest side (app-level, du-based)

- Source: /data/local-nvme/fpsync-source/tcga-brca/ (1133 files, 1158795413424 bytes)
- Write target: /mnt/weka/data/fpsync-target/mixed (cleaned pre-cell)
- Post-cell target bytes: 1158795315120
- Post-cell target files: 1133
- fpsync concurrency: -n 4 (fixed)

## Read side

Headline numbers come from fio's JSON output in cmd.log. Use the parser /
aggregate-stage1-mixed.py for structured extraction:
- read bandwidth (mean, sustained)
- read IOPS
- read latency (mean, p99)

## Cell window

- Cell start (UTC): 2026-08-23T13:21:32Z
- Cell end   (UTC): 2026-08-23T13:33:06Z

The wall-clock duration in this notes file brackets the entire record-run.sh
operation. For the timed-window-only duration, use raw/.run_start and raw/.run_end.

## Cross-source check (post-aggregation)

Run the post-cell cross-source consistency canary using THIS leg's Primary
sources (docs/RUNBOOK.md § The source table) and THIS leg's consistency
relation, derived per filesystem and never ported across (STAGES.md D12):
- filesystem-side Write sustained  vs  fpsync app-level
- filesystem-side Read  sustained  vs  fio app-level
- wire counters for the data path in use  vs  the app-level rate, at the
  amplification the relation implies (WEKA: from the provisioned EC scheme;
  Lustre: from the actual stripe layout)
⚠ Mixed read+write cells need WIDER bands than single-direction cells — the wire
carries payload plus acknowledgements in both directions, and at small block
sizes the non-payload share is material. Widen deliberately and say so here.
⏳ D-5: the relation itself is not derived yet. Do not fill numbers in from
another environment.
