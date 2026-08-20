---
name: cloud-session-open-items-lustre
description: "Leg B (Lustre) work list — the concurrent leg's own items. Same rules: add in the edit that surfaces it, DELETE when done. Leg A's list is cloud-session-open-items; do not write there."
metadata: 
  node_type: memory
  type: project
  originSessionId: 19527a50-12a1-449d-ab4b-e5df495e7353
  modified: 2026-08-20T20:26:44.504Z
---

Leg B runs CONCURRENT with Leg A under the stage-lag rule (STAGES.md **D6**): never start stage N until Leg A
has completed stage N. Ownership rules: `CLAUDE.md`, "Concurrent legs".

Provisioning is DONE (2026-08-20): EFA-mounted (counter-proven, D16), contract verified clean vs Leg A,
values ratified — decision register: `docs/cloud-setup/LUSTRE-PROVISIONING.md` (entries L1–L7). Phase-2 is
baked (`scripts/wsi-lustre-phase2.sh`); the walk prompt was deleted (register + fallback moved to that doc).

## A. Before the destroy & reapply the human plans next

1. **Teardown checklist is mandatory before the destroy** (`docs/cloud-setup/TEARDOWN-AND-REBUILD.md`):
   `scripts/teardown-prep.sh` gated by `scripts/teardown-preflight.sh` must GO first — its order is
   load-bearing; skipping a step loses work permanently.
2. **The living handoff (`prompts/handoff-cloud.md`) must be edited to Leg-B-current state before teardown**
   (the rebuilt box's motd says "paste the living handoff") — explicitly NOT the provisioning session's
   deliverable; it is a teardown-checklist step.
3. **[USER decided to include a 2nd EFA interface at reapply — if applied:** the rebuilt client gets 2 EFA
   NIs and AWS's configurator adds its CPT/CPU-partition options (register L7 covers both counts;
   `FS_CLIENT_RESERVED_CORES=none` still holds). Verify the phase-2 gate + counter-proof on the rebuilt box
   and record the count in the walk-evidence convention. **Known fail-loud possibility:** the configurator's
   CPT path requires ≥1 EFA device per NUMA node (2 nodes on g6e.24xlarge); if EC2 wires both network cards
   to one node, its precheck raises "No EFA devices found for NUMA node" and phase-2 stops unmounted —
   recovery is dropping the second interface block and reapplying, or a human-ratified manual LNet config.
   Also: with >1 interface the primary loses auto-assign public IP (EC2 rule) — the terraform must carry an
   EIP or the bootstrap has no internet path.]

## B. Before the first measured cell on this leg

1. **The rebuild is phase-2's from-scratch proof.** `scripts/wsi-lustre-phase2.sh` ran clean + idempotent on
   the walk box only; on the rebuilt box treat a failure as a baking bug first
   (`journalctl -u wsi-lustre-phase2.service`). After it passes once: delete this item and the
   "proof-pending" notes in the script header + tracker entry.
2. **Contract: 3 stage-1 fields still UNVERIFIABLE** (`stage1_seq_corpus_gib`, `stage1_randr_region_gib`,
   `stage1_randr_regions`) — they fill at corpus prep (D13 cache-derived). The verify must come back fully
   clean before the first measured cell (**D6**); everything else already matches. NOTE: after the rebuild,
   re-run write+verify on the new instance (instance_id/hostname refresh; kernel/AMI must still MATCH).
3. **No true GDS on this leg either — documented, not measured (STAGES.md D8, checked 2026-08-20):** GDS on
   FSx requires a P5-class client; this client is g6e. Expect compat/bounce like Leg A; do NOT chase GDS
   wiring. The leg's Phase-0 determination cell and every kvikIO cell's path split still verify — a split
   contradicting the docs is a finding to surface immediately.
4. **Metadata IOPS is provisioned at the placeholder (48,000)** — before this leg's metadata-heavy stages,
   verify against Leg A's measured Stage-2/6.B metadata peaks + margin and **raise online if needed** (a
   recorded provisioning event, human-ratified, priced into `FS_USD_PER_HR`).
5. **Calibrate this leg's canary bands** (**D18**/**D-5**) on the Lustre client before the baseline. The
   Lustre consistency relation derives from the recorded stripe layout (register L2), never ported from WEKA.
6. **D-4 Lustre recorder schemas are live-derived here** — `/proc/fs/lustre`, `lctl get_param` shapes from
   the real client, never a recalled format. The mount is live, so this is unblocked.
7. **[USER-side check] `FS_USD_PER_HR` metadata-IOPS assumption** — recorded $29.6088/hr assumes 12,000
   included IOPS (register L6 has both readings + sources). Verify against the first invoice / Cost
   Explorer; if all 48,000 bill, correct to $30.6279/hr, dated, as a provisioning-cost event.
8. **[COSMETIC, no behavior change — batch when convenient] Two D8-symmetric label leftovers in scripts:**
   (a) docstring/comment headers describing the kvikio backend as "kvikIO+GDS" in
   `train-resnet50-stage5.py`, `extract-features-foundation-stage6.py`, `read-tiles-kvikio.py` — the
   backend is kvikIO/cuFile (compat on both legs per D8); (b) `cufile-full-rdma.template.json`'s header
   could carry the D8 note. Functional behavior verified unaffected 2026-08-20.

## C. Watch during benchmarking

0. **Stage-lag check before every stage start** — Leg A's `.leg-state/weka/` markers are the evidence.
1. **D18 knee repeats after each Tier-1** — REP=2/3, same as Leg A.
2. **EFA-interface plateau trigger (register L7):** if knee/peak calibration plateaus below expectation with
   the efa net unsaturated, the interface count is the first candidate — a ratified provisioning event
   (instance stop), not silent tuning.
3. **Push only via `scripts/push-safe.sh`**; structural doc changes are proposed as numbered items to the
   human, never edited from this session (the ratified Phase-4 baking scope was the one exception, spent).
4. **Reboot hygiene:** phase-2 re-proves the EFA data path per boot and UNMOUNTS on a failed counter-proof
   (`journalctl -u wsi-lustre-phase2.service`); `wsi-lustre-tuning.service` re-applies the D-11 lctl set.
   Never assume post-reboot state — the units are the mechanism, the D16 gate in `run-leg.sh` is the check.
