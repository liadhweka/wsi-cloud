# Project handoff — WEKA vs Lustre on AWS

Written: 2026-08-23 ~18:1x UTC · Leg: weka · Kind: instance-destroy (teardown)
Mission in one line: **Leg A (WEKA) is CLOSED — nothing on this box remains to resume.** This file exists
so a future rebuild of a Leg-A box knows it starts from a finished leg, not an interrupted one.

## State at teardown

- Every substage CLOSEOUT CLEAN (`verify-substage-closeout.sh --all-completed` exit 0, 2026-08-23).
- Leg-end environment contract written + verified (19/19 held-constant; `runs/env-contract-leg-weka.json`,
  sha in `runs/.leg-state/weka/contract-verified`, copy in `s3://liad-wsi-cloud/env-contracts/`).
- `docs/RESULTS.md` carries the per-stage Leg-A record (headlines + pointers). Roadmaps hold per-cell truth.
- Repo-wide pre-teardown audit done 2026-08-23 (commit `7a71b30`): 20 staleness/consistency fixes; audit
  verdicts in that commit's message.
- All work pushed; S3 sync verified by `backup.sh` and the teardown preflight.

## Open at teardown (none block destruction)

1. Leg B continues on its own box under the stage-lag rule; its gates for 1.5/1.6 are open and the leg-end
   contract it verifies against is pushed. **6.D is composed on Leg A** (recipe ratified 2026-08-23, now
   code: `scripts/compose-stage6d.py`) — Leg B composes identically at its Stage-6 close.
2. Multi-client restart consideration (open-items memory item 23) — the human's, undecided.

## If this box is ever rebuilt for Leg-A work

Follow `docs/cloud-setup/TEARDOWN-AND-REBUILD.md`. There is no in-flight state: the rebuild would be for
NEW work (e.g. D18 knee repeats for 1.0a, recorded as a standing caveat in the 1.0a row), not resumption.
Read `cloud-session-open-items` memory → `PROJECT-THESIS.md` → `CLAUDE.md` first, as always.
