# Stage 1.5 cell 3/4 — fpsync n=16

## App-level (du-based, authoritative for bytes-transferred)

- Source bytes: 1158795413424
- Source files: 1133
- Target bytes (post): 1158795315120
- Target files (post): 1133
- Cell start (UTC): 2026-08-23T12:21:52Z
- Cell end (UTC):   2026-08-23T12:30:01Z

The wall-clock duration in this notes file brackets the entire record-run.sh
operation (including pre-snapshot, fpsync run, post-snapshot, parser).
For the timed-window-only duration, use raw/.run_start and raw/.run_end.

## Cross-source check

After running aggregate-stage1-fpsync.py (or eyeballing results.json), run the
post-cell cross-source consistency canary using THIS leg's Primary sources
(docs/RUNBOOK.md § What gets recorded) and THIS leg's consistency relation, derived
per filesystem and never ported across (STAGES.md D12):
- App-level bytes/sec = 1158795315120 / wall-time
- Compare to the filesystem-side client Write sustained_mean
- Compare to the wire counters for the data path in use, at the write amplification
  this leg's relation implies (WEKA: from the provisioned EC scheme; Lustre: from the
  actual stripe layout)
⏳ D-5: the relation is not derived yet. Do not fill numbers in from another
environment.
