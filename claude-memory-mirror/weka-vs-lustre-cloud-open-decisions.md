---
name: weka-vs-lustre-cloud-open-decisions
description: "The environment values in the WEKA-vs-Lustre AWS project that are ASSUMED, not confirmed (compute instance, Lustre deploy model, and the deferred WEKA-license cost question). Each is a placeholder: every doc/script reference is tagged '(subject to change)' AND indexed here, so firming one up has a complete change-list and nothing goes stale unnoticed."
metadata:
  node_type: memory
  type: project
---

Load-bearing values in this project that are **placeholders, not settled**. Tag every doc/script
reference **"(subject to change)"** and keep the index below current — the point is that firming one up
is a single complete pass, not a hunt.

## Still open

1. **Compute instance = AWS `g6e.24xlarge`** — 96 vCPU, 768 GiB, 4× L40S (178 GiB), 200 Gbps (2 network
   cards), 2× 1900 GB NVMe, EFA-capable. *Why open:* chosen tentatively; the boss wants L40S (→ g6e
   family) and is cost-conscious. **`g6e.48xlarge`** (8× L40S, 400 Gbps, 192 vCPU) is the upgrade;
   **`g6e.12xlarge`** (100 Gbps, 48 vCPU) the budget floor. *Affects:* the ~25 GB/s client ceiling that
   both filesystems are sized against, DDP N-ranges, `num_workers` concurrency headroom, GPU/NUMA map,
   cost. **Pre-committed revisit trigger:** if Leg A's synthetic ceiling pins at line rate across block
   sizes *and* the `num_workers` sweep saturates on CPU cores rather than storage, the instance is
   measuring itself — move up before Leg B.
2. **Lustre = AWS managed FSx for Lustre** (assumed). *Why open:* not confirmed; could be self-managed
   Lustre on EC2. Managed means thinner telemetry (CloudWatch + client `/proc/fs/lustre` + `lctl`, no
   server internals) but is more customer-representative and far less ops. *Affects:* the Lustre
   recording adapter, provisioning docs, what the measurement story can claim.
3. **WEKA license cost in the price comparison** — *deliberately deferred, not forgotten.* The
   "and we're cheaper" claim is not credible with license excluded and unlabelled. Either price it in
   (if publishable) or label the figure infrastructure-only. Agreed to fix the numbers later rather than
   block the build. *Affects:* every cost figure and the headline claim.

## Resolved (kept here so the reversal is visible if it comes back)

- **WEKA deployment = self-managed on EC2**, provisioned via the company's Port blueprint (the user
  selects backend instance type and count). *Standing caveat to keep in the docs:* a managed/marketplace
  WEKA would be the closer counterpart to managed FSx.
- **Fairness basis = Lustre at maximum, WEKA at a realistic production config, cost reported alongside.**
  See `[[weka-vs-lustre-cloud-project]]`.

## Doc/script-reference INDEX

Every location each open value is baked in. **Update this in the same edit that adds a reference.**

| Value | Referenced in |
|---|---|
| `g6e.24xlarge` | `PROJECT-THESIS.md` § Environment (table + revisit trigger); `runs/STAGES.md` **D10** (+ the ~25 GB/s client-ceiling figure used in D7 and the comparison-structure note); `runs/Stage-5-Training.md` (GPU sweep N ∈ {1,2,4} + its decision-log entry); `runs/Stage-6-Feature-Extraction.md` (GPU sweep; the ~768 GiB client-cache figure in the cold-cache section); `runs/Stage-7-Clinical-Inference-Deployment.md` (batch-size schedule is instance-derived); `cloud-setup/SPINUP-CHECKLIST.md` (header note, item 2 quota, item 3 instance, item 11 WEKA sizing target) |
| FSx for Lustre | `PROJECT-THESIS.md` § Environment, § Asymmetry 1, § Asymmetry 2; `CLAUDE.md` (intro leg definition, § Framing asymmetries, § Recording per-FS source table); `runs/STAGES.md` (comparison structure, GPU-direct matrix, per-FS adapter table, plan rows 2/13, Stage-1 substage 1.8, **D6/D7/D8/D12/D13**); `runs/README.md` (per-FS source table); `runs/Stage-1-Ingest.md` (1.8 capability cell, per-FS sources); `runs/Stage-6-Feature-Extraction.md` (the ~680 GiB server-cache figure driving corpus sizing); `FILESYSTEM-MAP.md` (mount convention); `PRESENTING.md` (asymmetry framing, all stage sections); `README.md`; `cloud-setup/SPINUP-CHECKLIST.md` items 1, 4, 5; `cloud-setup/NEW-CLOUD-SETUP.md` § Phase D; `cloud-setup/handoff-cloud.md` (leg definition, standing facts); `cloud-setup/prompt-env-prep-cloud.md` (why EFA matters now) |
| WEKA license cost | `PROJECT-THESIS.md` § Asymmetry 2; `runs/STAGES.md` **D7** (open sub-item); `PRESENTING.md` § synthesis (item 4) |

*(Extend as the remaining docs are written — `runs/STAGES.md` decision log, the per-stage roadmaps,
`PRESENTING.md`, `SCRIPT-TRACKER.md`, `FILESYSTEM-MAP.md`, and the cloud setup/handoff docs.)*

**How to apply:** never present any open value as settled; when one firms up, use this index to update
every reference in a single pass. Related: `[[weka-vs-lustre-cloud-project]]`, `[[feedback_methodology_why]]`.
