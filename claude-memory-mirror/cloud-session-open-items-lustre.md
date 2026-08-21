---
name: cloud-session-open-items-lustre
description: "Leg B (Lustre) work list — the concurrent leg's own items. Same rules: add in the edit that surfaces it, DELETE when done. Leg A's list is cloud-session-open-items; do not write there."
metadata: 
  node_type: memory
  type: project
  originSessionId: 19527a50-12a1-449d-ab4b-e5df495e7353
  modified: 2026-08-21T03:16:09.704Z
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
2. **Handoff SOP (ratified 2026-08-20, repo-wide):** `prompts/handoff-skeleton.md` is a TEMPLATE, never
   pasted directly. Same-instance session turnover (the normal mode): the outgoing session prints the
   filled handoff inline in its final message. Destroy/rebuild: OPTIONALLY (human's call, worth it
   mid-work) the filled handoff goes into `tmp/` as a durable committed file — memory + repo are the
   designed continuity and the preflight only warns, never blocks, without one. A prompt is deleted once
   its session has executed it (spent once read); the pending one is
   `tmp/prompt-r2-verify-and-benchmark.md` (updated 2026-08-21 to R1's as-left state).
3. **2nd EFA interface: APPLIED and verified on the 2026-08-21 rebuild** — 2 devices, 2 efa NIs up, CPT
   options landed, `FS_CLIENT_RESERVED_CORES=none` holds; count-as-built recorded in register L7. The
   feared per-NUMA CPT failure did not fire (the configurator saw 1 NUMA node). Nothing left to do; delete
   this line at the next memory pass if R2's boot re-proves clean.

## B. Before the first measured cell on this leg

1. **Contract-at-boot is BAKED (2026-08-21, R1):** the bootstrap appends a lustre-only step to the end of
   `wsi-build-envs.sh` — gated on `wsi-lustre-phase2.service` active — that writes the leg contract and
   verifies it against Leg A's committed one; a clean verify arms
   `runs/.leg-state/lustre/contract-verified`, any failure leaves NO marker and `run-leg.sh` refuses the
   leg. **R2 must confirm the bake fired unattended** (`grep -A3 contract /var/log/wsi-env-build.log`;
   marker present without a session step) before the first measured cell (**D6**). Manually reproduced
   clean on this rebuild: 18 match + script_commit ancestor-ok, 0 violations, 0 unverifiable.
2. **No true GDS on this leg either — documented, not measured (STAGES.md D8, checked 2026-08-20):** GDS on
   FSx requires a P5-class client; this client is g6e. Expect compat/bounce like Leg A; do NOT chase GDS
   wiring. The leg's Phase-0 determination cell and every kvikIO cell's path split still verify — a split
   contradicting the docs is a finding to surface immediately.
3. **Metadata IOPS is provisioned at the placeholder (48,000)** — before this leg's metadata-heavy stages,
   verify against Leg A's measured Stage-2/6.B metadata peaks + margin and **raise online if needed** (a
   recorded provisioning event, human-ratified, priced into `FS_USD_PER_HR`).
4. **Calibrate this leg's canary bands** (**D18**/**D-5**) on the Lustre client before the baseline.
   The relation is DERIVED and built (raid0 layout → wire/app centers 1.0/1.0, `wsi_agg_helper`; empirical
   wire/osc = 1.002 on the 2026-08-21 stage-0 proof) — calibration only fills the BANDS
   (`runs/.leg-state/lustre/canary-bands.json`, dies with the filesystem, R2 work). Recorder half of D-4 is
   DONE + capture-verified; at calibration also decide the lustre cold-cell evidence set (D-4 remainder:
   page-cache drop is leg-neutral, ldlm/osc client caches are the open question).
5. **[USER-side check] `FS_USD_PER_HR` metadata-IOPS assumption** — recorded $29.6088/hr assumes 12,000
   included IOPS (register L6 has both readings + sources). Verify against the first invoice / Cost
   Explorer; if all 48,000 bill, correct to $30.6279/hr, dated, as a provisioning-cost event.
6. **[COSMETIC, no behavior change — batch when convenient] Two D8-symmetric label leftovers in scripts:**
   (a) docstring/comment headers describing the kvikio backend as "kvikIO+GDS" in
   `train-resnet50-stage5.py`, `extract-features-foundation-stage6.py`, `read-tiles-kvikio.py` — the
   backend is kvikIO/cuFile (compat on both legs per D8); (b) `cufile-full-rdma.template.json`'s header
   could carry the D8 note. Functional behavior verified unaffected 2026-08-20.

## C. Watch during benchmarking

0. **Stage-lag check before every stage start** — Leg A's `.leg-state/weka/` markers are the evidence.
1. **D18 knee repeats after each Tier-1** — REP=2/3, same as Leg A.
2. **Plateau trigger (register L7):** the interface count is 2 as built, so a knee/peak plateau below
   expectation with the efa net unsaturated no longer points there — next candidates are the CPT/LNet
   config and FSx-side limits; surface to the human as a provisioning question, never silent tuning.
3. **Push only via `scripts/push-safe.sh`**; structural doc changes are proposed as numbered items to the
   human, never edited from this session (the ratified Phase-4 baking scope was the one exception, spent).
4. **Reboot hygiene:** phase-2 re-proves the EFA data path per boot and UNMOUNTS on a failed counter-proof
   (`journalctl -u wsi-lustre-phase2.service`); `wsi-lustre-tuning.service` re-applies the D-11 lctl set.
   Never assume post-reboot state — the units are the mechanism, the D16 gate in `run-leg.sh` is the check.
