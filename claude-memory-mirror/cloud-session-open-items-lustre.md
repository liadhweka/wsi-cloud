---
name: cloud-session-open-items-lustre
description: "Leg B (Lustre) work list — the concurrent leg's own items. Same rules: add in the edit that surfaces it, DELETE when done. Leg A's list is cloud-session-open-items; do not write there."
metadata:
  node_type: memory
  type: project
---

Leg B runs CONCURRENT with Leg A under the stage-lag rule (STAGES.md **D6**): never start stage N until Leg A
has completed stage N. Ownership rules: `CLAUDE.md`, "Concurrent legs".

## A. Before the first measured cell on this leg

1. **Run the first-spinup recon** (read-only command set; the human holds it) and report the output — the
   phase-2 mount automation gets baked from it.
2. **The gated EFA + mount walk** (`prompts/prompt-lustre-cluster-cloud.md`) — human-approved throughout;
   record everything that differs from the document. This walk IS the validation the baked automation
   inherits.
3. **Tier 0 for this leg is EFA, evidenced** (`lnetctl net show`), never mount options. TCP fallback = STOP,
   human waiver only (**D16**).
3b. **No true GDS on this leg either — documented, not measured (STAGES.md D8, checked 2026-08-20):** GDS
    on FSx requires a P5-class client; this client is g6e. Expect compat/bounce like Leg A; do NOT chase
    GDS wiring. The leg's Phase-0 determination cell and every kvikIO cell's path split still verify —
    a split contradicting the docs is a finding to surface immediately.
4. **Contract verify against Leg A's current committed contract** before any cell (**D6**) — `aws_az` is
   MAY_DIFFER by design; everything else on MUST_MATCH must hold.
5. **[USER] Cost + ceiling inputs, Lustre values**: `SOFTWARE_USD_PER_HR=0` (FSx is software-inclusive, basis
   recorded), FS price from the provisioned config, the **documented per-client throughput cap** from the
   D7-cited AWS page for the ceiling trio — all fetched dated, proposed, confirmed.
6. **`FS_CLIENT_RESERVED_CORES=none`** — set it explicitly; the Lustre client reserves no cores, and unset
   means unknown, which aggregation refuses (**D15**).
7. **Metadata IOPS is provisioned at the placeholder (48,000)** — before this leg's metadata-heavy stages,
   verify against Leg A's measured Stage-2/6.B metadata peaks + margin and **raise online if needed** (a
   recorded provisioning event, human-ratified, priced into `FS_USD_PER_HR`).
8. **Stripe layout**: decide, record (`LUSTRE_STRIPE_LAYOUT`), and justify per the Lustre prompt's step 7.
9. **Calibrate this leg's canary bands** (**D18**/**D-5**) on the Lustre client before the baseline.
10. **D-4 Lustre recorder schemas are live-derived here** — `/proc/fs/lustre`, `lctl get_param` shapes from
    the real client, never a recalled format.

11. **[COSMETIC, no behavior change — batch when convenient] Two D8-symmetric label leftovers in scripts:**
    (a) docstring/comment headers describing the kvikio backend as "kvikIO+GDS" in
    `train-resnet50-stage5.py`, `extract-features-foundation-stage6.py`, `read-tiles-kvikio.py` — the
    backend is kvikIO/cuFile (compat on both legs per D8); (b) `cufile-full-rdma.template.json`'s header
    could carry the D8 note (template for a GDS-capable transport — expected unused on both legs unless a
    path split contradicts the docs). Functional behavior verified unaffected 2026-08-20: the Phase-0
    probe treats refusal as a valid determination, accounting derives from bytes, mode defaults are
    already best-available.

## B. Watch during benchmarking

0. **Stage-lag check before every stage start** — Leg A's `.leg-state/weka/` markers are the evidence.
1. **D18 knee repeats after each Tier-1** — REP=2/3, same as Leg A.
2. **Push only via `scripts/push-safe.sh`**; structural doc changes are proposed as numbered items to the
   human, never edited from this session.
