# Provisioning & pricing record — the whitepaper writer's single stop

**Purpose.** Everything the whitepaper's pricing and methodology sections need about *what was provisioned
and what it cost*, per leg, assembled in one readable place: specs, bases, dates, and the why behind each.
This is the **story layer**, not a new source of truth — field-level authority stays where it is, and every
value here carries a pointer to it:

- **Field-level environment facts** → `../runs/env-contract-leg-<leg>.json` (git-tracked, machine-verified;
  where this doc and a contract field disagree, **the contract wins and this doc is the bug**).
- **As-run price inputs per cell** → each run's `metadata.json` `cost_inputs` block (never overwritten;
  the published headline is repriced at publication from one fresh snapshot — `../PROJECT-THESIS.md` §4,
  `../prompts/prompt-reprice-at-publication.md`).
- **Methodology rationale** → `STAGES.md` **D7** (fairness basis), **D20** (WEKA backend sizing + software
  metering), **D15** (core accounting), and `RESULTS.md` § Provisioning fairness (the whitepaper-facing
  statement).

**Ownership (D6):** each leg's section is that leg's content. Leg A never edits Leg B's, and vice versa.

---

## Held constant across legs — the client

One specification, two instances (**D6**: every must-match field is a specification two instances can both
satisfy; the contract verifies identity-of-spec mechanically).

| | |
|---|---|
| Instance | **`g6e.24xlarge`** — 96 vCPU, 768 GiB RAM, 4× L40S, 200 Gbps across 2 network cards, 2× 1900 GB NVMe, EFA-capable (**D10**: L40S is the required GPU family; ≥200 Gbps for a credible bandwidth axis; EFA-capable because Leg B needs it) |
| Region | `ap-northeast-2` (chosen for g6e capacity). **AZ is per-leg by design** — each client colocated with its filesystem; cross-leg AZ variance is what the D18 canary bands measure |
| Software stack | AMI, kernel, NVIDIA driver, CUDA, nvidia-fs, libcufile, Python env, script commit — all MUST_MATCH contract fields; read them from the contract rather than from any prose copy |

## Leg A — WEKA, self-managed on EC2

| | |
|---|---|
| Backends | **8 × i8ge.6xlarge**, both NVMe per host (16 × 6.82 TiB = **120 TB raw**), **5+2 EC + 1 hot-spare** failure domain → **67.46 TB usable**; aggregate backend RAM **1536 GiB**; aggregate sustained network **300 Gbps** (37.5 Gbps/host, AWS API). *Why this sizing:* the client demonstrably sustains 11.6 GB/s reads, so the backends are floored **above** client capability (**D7**: neither side may be the constraint; arithmetic in `RESULTS.md` § Provisioning fairness) |
| WEKA version | Contract-pinned (`weka_version` field) — 5.1.27 on the live cluster |
| Client config | **DPDK transport**, evidenced per boot from the client's own report, never from mount options (**D16**). **4 FRONTEND cores ↔ 4 NICs** — the vendor-documented pairing rule applied to the deployed network layout (citations in `RESULTS.md` § Provisioning fairness); hand-set at deploy (confirmed 2026-08-21), so the documented pairing rule is the basis. Reserved cores `1-4,49-52` (FRONTENDs + HT siblings), excluded from application-core accounting and **priced rather than hidden** (**D15**) |
| Per-client ceiling | **200 Gbps** — basis: instance line rate (WEKA documents no per-client cap, so the physical NIC is the honest ceiling); checked 2026-08-15 |
| AZ | `ap-northeast-2a` |

## Leg B — FSx for Lustre

**This section is Leg B's content** — filled by the Leg-B session from its own contract, not by Leg A.
What belongs here when filled: FSx tier / capacity / provisioned metadata IOPS / EFA state (the **D7**
"Lustre at maximum" evidence, per axis), the recorded stripe layout, transport evidence (EFA
counter-proven per boot), the documented per-client ceiling (700 Gbps, `performance.html`, dated), AZ,
and the leg's price rows below.

## Prices — the as-run inputs

Fetched from vendor pricing on the date shown, never recalled; recorded per cell by `record-run.sh`. The
**published headline is repriced at publication time from one fresh snapshot applied to both legs**
(thesis §4), so these as-run values are provenance, not the final quote.

| Input | Leg A (WEKA) | Basis | Date checked |
|---|---|---|---|
| Instance $/hr | **18.52234** | g6e.24xlarge on-demand, ap-northeast-2 | 2026-08-15 |
| Filesystem $/hr | **26.8128** | 8 × i8ge.6xlarge @ 3.3516 on-demand | 2026-08-15 |
| Storage-software $/hr | **7.7009** | **67.46 TB usable × $0.1141553/TB-hr** — the public AWS Marketplace rate (citable where a negotiated price is not), **metered on usable capacity, confirmed with WEKA Sales 2026-08-21**. Cells recorded before that correction carry the superseded raw-basis 13.699 as as-run provenance — the data-validity note is `STAGES.md` **D20** | rate 2026-08-15; basis 2026-08-21 |

| Input | Leg B (FSx for Lustre) | Basis | Date checked |
|---|---|---|---|
| Instance $/hr | *(Leg B's row — same instance type by contract)* | on-demand, ap-northeast-2 | *(Leg B)* |
| Filesystem $/hr | *(Leg B's row)* | the provisioned FSx configuration's service rate | *(Leg B)* |
| Storage-software $/hr | **0** | the FSx service rate is software-inclusive — the deliberate asymmetry **D7** records in the data itself | n/a |

## Cost derivation — the recipe

Per cell and per leg, both bases, every quoted figure naming its basis (**D7**):

> **infra-only** = (instance $/hr + filesystem $/hr) × measured wallclock
> **all-in** = (instance $/hr + filesystem $/hr + software $/hr) × measured wallclock

Wallclocks live in each cell's `metadata.json` (`wallclock_s`) and roll up per leg via `../runs/INDEX.md`
and the stage roadmaps. No cell ever stores a computed cost — cost is re-derivable arithmetic, which is
what makes the publication-time reprice and the D20 basis correction safe.

## Why this doc is not the recovery source

Rebuild recovery is **mechanical**, not prose: the bootstrap rebuilds the client from the Terraform
payload, and `env-contract.py env` re-emits the held-constant and recovery fields into the new `env.sh`
(procedure: `cloud-setup/TEARDOWN-AND-REBUILD.md`). This doc exists to be **read at writing time**;
nothing rebuilds from it, so nothing breaks if it lags — the contract check would catch the drift.
