# R2 — second rebuild: sanity-check the provisioning, then start the Leg-B benchmark

Written: 2026-08-20 · Leg: **lustre** (Leg B). You are a fresh Claude Code session on the twice-rebuilt
Leg-B box, inside `tmux new -A -s wsi`. **Everything provisioning-side should already be true** — R1 proved
the baked spinup and finished the automation, so this box was built hands-off and verified itself at boot.
Your session has two parts: a mechanical sanity pass that should find nothing, then the benchmark itself,
through the Stage-1.0 baseline greenlight.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a whole-slide-imaging pipeline
on AWS: same instance, same workload code, same datasets, **only the filesystem under the mount point
changes.** You are Leg B, running CONCURRENT with Leg A under the stage-lag rule (STAGES.md **D6**): never
start stage N until Leg A's `.leg-state/weka/` markers show stage N complete.

## THE CENTRAL DIRECTIVE

**Your job is to make the comparison valid, not just to make it run.** The delta must be attributable to
the filesystem and nothing else. Results precede story; record the why of every method; report losses.
Nothing is portable across legs — re-derive, never copy; a recovered value is not a fact until verified on
this box. Every cell records the full measurement set; no metric is designated primary (thesis §4).

## STEP 1 — Read the governing instructions

**`CLAUDE.md`** (the eleven rules; recording; durability; "Concurrent legs" — push only via
`scripts/push-safe.sh`; structural docs are proposals to the human), then **the memories end to end** —
`cloud-session-open-items-lustre` (**your work list**; Leg A's list is read-only context) and
`uni2h-conditional-use-status`. If `MEMORY.md` is missing: `./scripts/restore-memories.sh`, report, ask for
a session restart; if it refuses, STOP.

## STEP 2 — Read the project docs

**`PROJECT-THESIS.md`** → **`docs/STAGES.md`** (stage map + register) → **`docs/Stage-1-Ingest.md`** (and
later roadmaps as their stages approach) → **`docs/RUNBOOK.md`** (the per-cell set, both canaries,
`wsi_agg_helper.py check`) → **`docs/cloud-setup/LUSTRE-PROVISIONING.md`** (this leg's decision register
L1–L7 — ratified; carry, don't re-litigate) → **`docs/SCRIPT-TRACKER.md`** → **`docs/NAMING-AND-VARIABLES.md`**.

> ### ⛔ GATE TIER 0 — the transport, evidenced, before ANY cell including the throwaway
>
> Leg B is on **EFA** (never tcp) per **D16**, evidenced on THIS box by you: `sudo lnetctl net show` lists
> the efa net(s) up, AND a direct-I/O probe moves the efa net's `send_count` (~1 RPC/MiB) with tcp
> near-flat — the mount string says `@tcp` by design (MGS NID) and proves nothing. `FS_TRANSPORT=efa` from
> that evidence only; `run-leg.sh` refuses otherwise. **tcp-only, or unevidenced = STOP AND REPORT. A TCP
> mount is a human decision, in writing.**

---

## What to do, in order

### 1 — Mechanical sanity (read-only; expected outcome: nothing to fix)

`git pull --ff-only`. Boot triage (`grep WSI- /var/log/wsi-bootstrap.log`; FATAL = stop).
`journalctl -u wsi-lustre-phase2.service` — gate + counter-proof passed unattended.
**Contract fully clean:** the boot automation wrote+verified it and left
`runs/.leg-state/lustre/contract-verified`; re-run `env-contract.py verify` yourself — **every
held-constant field must now verify, including `stage1_*`** (filled + D13-re-verified at the 2026-08-20
teardown); any violation is a stop.
`./env.sh --check` (cost/ceiling trios present and dated; `FS_CLIENT_RESERVED_CORES=none`;
`LUSTRE_STRIPE_LAYOUT` live). Tier 0 per the gate above. `./scripts/verify-conda-env.sh` (both envs, GPU
count). nvidia-fs counters enabled (`/sys/module/nvidia_fs/parameters/*_stats_enabled` = 1). S3 reachable;
`backup.sh` exits 0. Metadata IOPS still the 48,000 placeholder (raise-check is a later-stage item).
Deliverable: a short discovery report; anything broken is a numbered list and pauses the plan.

### 2 — Prove the recording loop on this build

`./scripts/prove-recording.sh` with the **Lustre recorder set** (R1's D-4 work): one real Stage-0-shaped
cell, named assertions, filesystem-side streams non-empty, S3 sync verified. Cheap, before wallclock.

### 3 — Close the pre-baseline rows on THIS filesystem

- **Calibrate the canary bands** (D18/D-5): probe-shaped Stage-0 cells (seq write + seq read), REP≥3; the
  Lustre wire/app relation derives from the recorded stripe layout (register L2/D12) — never ported from
  WEKA's EC relation; write `runs/.leg-state/lustre/canary-bands.json`. `check` exits UNCALIBRATED until
  then, by design.
- **The recorded D8 Phase-0 determination cell**: kvikIO known-good read, modes forced explicitly (never
  AUTO), three-layer path accounting recorded. **Expected: compat/bounce — no true GDS on g6e (D8,
  doc-grounded on both legs); a split contradicting that is a finding to surface immediately, not wiring
  to add.**
- **Stage-1.0 corpora staging** via `run-leg.sh`'s prep step, against the D13 values now in the contract.
- **Watch item (register L7):** if calibration plateaus below expectation with the efa net unsaturated,
  stop and surface — the interface count is the first candidate, a ratified provisioning event.

### 4 — Hydrate (measured cell 1.7), then the baseline — STOP for greenlight

Stage-lag check first (Leg A's markers). `run-leg.sh --leg lustre` drives: C0 canary → 1.0a → corpora prep
→ 1.0b/c/d → 1.7 (datasets byte-verified in S3 already; hydration is the measured cell). **Stop after the
Stage-1.0 baselines and report Tier 0 and every Tier-1 row, row by row, with evidence named, for the
human's greenlight.** Check the D10 instance-revisit trigger at the baseline. Compare the measured ceiling
against the documented one honestly (register L5: 700 Gbps documented per client; 200 Gbps line rate is
the binding bound — both in the basis string).

### 5 — Run the leg per `run-leg.sh` under the stage-lag rule

Numbers into the roadmaps as they land. Substage closeouts are mechanical:
`scripts/verify-substage-closeout.sh` must exit 0 before the next phase. Leg-B session discipline
throughout: own files only, structural docs proposed as numbered items, `cloud-session-open-items-lustre`
kept current, commits per work block via `backup.sh` + push-safe, **never while a measured cell is in
flight**.

## Standing facts to carry

- **Per-filesystem primaries invert** (thesis §7): client kernel network counters are **primary on
  Lustre**, diagnostic on WEKA. Never quote a source the filesystem bypasses.
- **Cold vs warm is enforced and recorded as achieved** (D13); don't "simplify" the read sweeps' staging.
- **kvikIO cells record the three-layer path accounting**; a config flag is not proof (D8). `LD_PRELOAD`
  scoped per cell.
- **Reboot hygiene:** phase-2 re-proves the transport per boot and unmounts on a failed counter-proof;
  `wsi-lustre-tuning.service` re-applies L4. Never assume post-reboot state.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell.** Cost math uses the dated
  trios; the FS_USD_PER_HR invoice check is a [USER] item in memory.
- **UNI2-h stays internal-only**; filter its rows from anything that leaves the building.
- **Ephemerality:** mounts, scratch, and your context die with the instance — only git, the memory mirror,
  and S3 survive. Persist continuously.

## Your first response

After the reading and the sanity pass: the state as you understand it, the discovery report, and the plan
through the baseline greenlight — decisions as a plain-text numbered list with a recommendation each.
**Mutate nothing before sign-off. Run nothing — not even the throwaway — until Tier 0 is evidenced on this
box.**
