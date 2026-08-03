# WEKA vs Lustre — WSI storage comparison on AWS

A competitive, head-to-head storage benchmark for a modern **whole-slide-imaging / digital-pathology
pipeline** on AWS: **WEKA** versus **Lustre**, both POSIX, on the same GPU instance, running the same
workload against the same datasets. **Only the filesystem under the mount point changes.**

> ## Status: BUILD PHASE — no benchmark has run
> The methodology, documentation, and script library are complete. **The cloud environment does not exist
> yet.** Every number in this repo is `[PENDING]` and every interpretation is `[STORY PENDING RESULTS]`.

---

## What makes this a real comparison

**One variable.** Held constant and recorded: the compute instance, the workload code, the datasets and
their byte contents, the magnification contract, the model set, the recording harness. Varied: the mount.

**Two sequential legs.** **Leg A: WEKA**, then **Leg B: FSx for Lustre**, then the synthesis. Because they
run at different times, comparability is enforced mechanically — Leg A writes a machine-readable
**environment contract** that Leg B verifies before its first cell.

**The full pipeline, not a microbenchmark.** Ingest → cataloging → tissue detection → patching → training →
foundation-model feature extraction and MIL → clinical inference. Each stage stresses storage differently, and
a comparison that measures only peak bandwidth answers almost none of the questions a pathology platform team
actually has.

**Two asymmetries, deliberate and stated up front** — naming them is what makes the result credible:

1. **Provisioning.** Lustre at **maximum capability**; WEKA at a **realistic production configuration**; cost
   for both reported alongside. Beating a competitor's best configuration is worth far more than beating one
   we sized ourselves.
2. **Transport / GPU-direct.** Lustre over EFA supports GPUDirect Storage; WEKA on AWS is expected to fall
   back to cuFile compat mode. We **keep** the GPU-direct path rather than dropping it for symmetry, and run
   **both cuFile modes on both filesystems** — which separates the filesystem effect from the transport
   effect instead of confounding them.

**Results precede story.** No document here contains a predicted outcome or a pre-assigned "headline" stage.
Whatever the benchmark produces is what gets reported, including cells where WEKA loses.

---

## Start here

| If you want to… | Read |
|---|---|
| Understand what we measure and why | **`PROJECT-THESIS.md`** |
| Present this to stakeholders | **`PRESENTING.md`** |
| Know the rules this project runs under | **`CLAUDE.md`** |
| See the stage map, plan, and every methodology decision | **`runs/STAGES.md`** (decision log **D1–D15**) |
| Understand one stage in depth | **`runs/Stage-<N>-*.md`** |
| Run or recover a benchmark cell | **`runs/README.md`** |
| Know what a script does | **`SCRIPT-TRACKER.md`** |
| Find where something lives | **`FILESYSTEM-MAP.md`** |
| Provision the environment | **`cloud-setup/NEW-CLOUD-SETUP.md`** + **`SPINUP-CHECKLIST.md`** |
| Know what every path / name / variable should be | **`cloud-setup/NAMING-AND-VARIABLES.md`** (+ `env.example.sh`) |
| Tear down or rebuild the instance | **`cloud-setup/TEARDOWN-AND-REBUILD.md`** (+ `runs/lib/teardown-preflight.sh`) |

**A fresh Claude session continuing this work** starts with the memories — `cloud-session-open-items` (the
work list), `weka-vs-lustre-cloud-project` (what this is), `weka-vs-lustre-cloud-open-decisions` (what is
still assumed) — then `PROJECT-THESIS.md` → `runs/STAGES.md` → the relevant roadmap.

---

## Layout

```
CLAUDE.md              project rules: the 11 Rules, recording, durability, docs cadence, framing
PROJECT-THESIS.md      the question, held-constant contract, both asymmetries, scope
PRESENTING.md          per-stage presentation script (methodology until results land)
SCRIPT-TRACKER.md      per-script reference + the deferred-work table
FILESYSTEM-MAP.md      where everything lives
backup.sh              memories → mirror, then S3 sync
claude-memory-mirror/  git-tracked copy of the Claude memories (the only continuity across rebuilds)
cloud-setup/           provisioning guide, the two Claude prompts, conda env specs
runs/
  STAGES.md            stage map, per-leg plan, decision log D1–D15
  README.md            operational runbook + both canaries
  Stage-{1..7}-*.md    per-stage roadmaps (the audit trail)
  lib/                 63-script library
  manifests/           dataset manifests, incl. the 1073-slide cohort
```

---

## Getting to a first result

1. **Provision** — `cloud-setup/SPINUP-CHECKLIST.md` (region, quota, instance, S3 + IAM, WEKA cluster).
2. **Bootstrap** — `cloud-setup/NEW-CLOUD-SETUP.md`, which hands off to Claude twice: once for the system
   stack (`prompt-env-prep-cloud.md`), once for the project (`handoff-cloud.md`).
3. **Build + Leg A** — Claude does the deferred script work (mount retargeting, `--fs` plumbing,
   per-filesystem recording adapters, S3 sync), proves the pipeline on a throwaway cell, takes a baseline,
   and runs Leg A.
4. **Leg B** — provision FSx at maximum, rebuild the instance from the pinned AMI, verify the environment
   contract, repeat.
5. **Synthesis** — the actual deliverable.

> **Everything the scripts contain about paths, addresses, versions, core counts, and tuning came from a
> different environment. Re-derive; never copy.** The deferred-work table at the top of `SCRIPT-TRACKER.md`
> is the authoritative list, mirrored in the `cloud-session-open-items` memory.

---

## Conventions worth knowing before you touch anything

- **`--fs {weka|lustre}` is a dimension, not a fork.** One `runs/` tree; the filesystem appears in the
  run-dir name and in `metadata.json`; aggregators pivot on it. Scripts resolve the mount through
  **`$FS_MOUNT`** — a hardcoded mount path is a bug, because it silently makes one leg measure the other.
- **The primary telemetry sources differ per filesystem.** The client's network counters are *diagnostic* on
  the WEKA leg and the *actual data path* on the Lustre leg. Never quote a bypassed source.
- **Both mounts and local scratch are ephemeral.** git is authoritative for small text; **S3** for heavy
  write-once telemetry and datasets. Run `./backup.sh` before every commit and every teardown.
- **The human commits and pushes.** Never do it autonomously.
