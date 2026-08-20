---
name: cloud-session-open-items-lustre
description: "Leg B (Lustre) work list — the concurrent leg's own items. Same rules: add in the edit that surfaces it, DELETE when done. Leg A's list is cloud-session-open-items; do not write there."
metadata: 
  node_type: memory
  type: project
  originSessionId: 19527a50-12a1-449d-ab4b-e5df495e7353
  modified: 2026-08-20T19:17:34.384Z
---

Leg B runs CONCURRENT with Leg A under the stage-lag rule (STAGES.md **D6**): never start stage N until Leg A
has completed stage N. Ownership rules: `CLAUDE.md`, "Concurrent legs".

Provisioning is DONE (2026-08-20): EFA-mounted (counter-proven, D16), contract verified clean vs Leg A,
values ratified — register in `prompts/prompt-lustre-cluster-cloud.md` ("Leg-B provisioning decision
register", entries L1–L7). Phase-2 is baked (`scripts/wsi-lustre-phase2.sh`).

## A. Before the first measured cell on this leg

1. **Contract: 3 stage-1 fields still UNVERIFIABLE** (`stage1_seq_corpus_gib`, `stage1_randr_region_gib`,
   `stage1_randr_regions`) — they fill at corpus prep (D13 cache-derived). The verify must come back fully
   clean before the first measured cell (**D6**); everything else already matches.
2. **No true GDS on this leg either — documented, not measured (STAGES.md D8, checked 2026-08-20):** GDS on
   FSx requires a P5-class client; this client is g6e. Expect compat/bounce like Leg A; do NOT chase GDS
   wiring. The leg's Phase-0 determination cell and every kvikIO cell's path split still verify — a split
   contradicting the docs is a finding to surface immediately.
3. **Metadata IOPS is provisioned at the placeholder (48,000)** — before this leg's metadata-heavy stages,
   verify against Leg A's measured Stage-2/6.B metadata peaks + margin and **raise online if needed** (a
   recorded provisioning event, human-ratified, priced into `FS_USD_PER_HR`).
4. **Calibrate this leg's canary bands** (**D18**/**D-5**) on the Lustre client before the baseline. The
   Lustre consistency relation derives from the recorded stripe layout (register L2), never ported from WEKA.
5. **D-4 Lustre recorder schemas are live-derived here** — `/proc/fs/lustre`, `lctl get_param` shapes from
   the real client, never a recalled format. The mount is live now, so this is unblocked.
6. **[USER-side check] `FS_USD_PER_HR` metadata-IOPS assumption** — recorded $29.6088/hr assumes 12,000
   included IOPS (register L6 has both readings + sources). Verify against the first invoice / Cost
   Explorer; if all 48,000 bill, correct to $30.6279/hr, dated, as a provisioning-cost event.
7. **[CROSS-CUTTING, human decides] `sync-to-s3.sh` env-contracts op false-negative on Leg B:** the op syncs
   `runs/` with include-filters, and Leg A's git-committed `raw` symlinks (dangling on this box) poison the
   exit code — every Leg-B `backup.sh` reports 1 FAILED even though the contracts upload fine (verified in
   S3 2026-08-20). Proposed one-liner: `--no-follow-symlinks` on that single `do_sync archive` call (it
   changes nothing about what the filter uploads, and doesn't touch the per-run raw sync Leg A depends on).
   Until applied: on Leg B, treat exactly this one FAILED line as known-noise ONLY after confirming both
   contract files listed in `aws s3 ls s3://$S3_BUCKET/env-contracts/` — any other FAILED is real.
8. **[COSMETIC, no behavior change — batch when convenient] Two D8-symmetric label leftovers in scripts:**
   (a) docstring/comment headers describing the kvikio backend as "kvikIO+GDS" in
   `train-resnet50-stage5.py`, `extract-features-foundation-stage6.py`, `read-tiles-kvikio.py` — the
   backend is kvikIO/cuFile (compat on both legs per D8); (b) `cufile-full-rdma.template.json`'s header
   could carry the D8 note. Functional behavior verified unaffected 2026-08-20.

## B. Watch during benchmarking

0. **Stage-lag check before every stage start** — Leg A's `.leg-state/weka/` markers are the evidence.
1. **D18 knee repeats after each Tier-1** — REP=2/3, same as Leg A.
2. **Single-EFA-interface plateau trigger (register L7):** if knee/peak calibration plateaus below
   expectation with the efa net unsaturated, the second EFA interface (instance stop; terraform) is the
   first candidate — a ratified provisioning event, not silent tuning.
3. **Push only via `scripts/push-safe.sh`**; structural doc changes are proposed as numbered items to the
   human, never edited from this session (the ratified Phase-4 baking scope was the one exception, spent).
4. **Reboot hygiene:** phase-2 re-proves the EFA data path per boot and UNMOUNTS on a failed counter-proof
   (`journalctl -u wsi-lustre-phase2.service`); `wsi-lustre-tuning.service` re-applies the D-11 lctl set.
   Never assume post-reboot state — the units are the mechanism, the D16 gate in `run-leg.sh` is the check.

## C. Proof-pending

- **`scripts/wsi-lustre-phase2.sh` has not yet built a box from scratch** (ran clean + idempotent on the
  walk box 2026-08-20). On the next rebuild: treat a failure as a baking bug first; after it passes once,
  delete this item and the "proof-pending" notes in its header + tracker entry.
