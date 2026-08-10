# WEKA vs Lustre — WSI storage comparison on AWS

A competitive, head-to-head storage benchmark for a modern **whole-slide-imaging / digital-pathology
pipeline** on AWS: **WEKA** versus **Lustre**, both POSIX, on the same GPU instance, running the same
workload against the same datasets. **Only the filesystem under the mount point changes.**

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

**Every cell reports the full measurement set, and no metric is designated primary.** Throughput, ops/sec,
latency and its percentiles, metadata rates, concurrency scaling, wallclock — all of it, everywhere it is
meaningful. Naming a headline metric in advance would pre-decide the most contested question in the
comparison; **which axis turns out to be decisive is a result.**

**Cost to complete is measured, not estimated.** `(instance $/hr + filesystem $/hr) × measured wallclock`, per
cell and per leg. It is the figure a buyer actually faces, and the only place the provisioning asymmetry below
stops being a caveat and becomes arithmetic.

**Two asymmetries, deliberate and stated up front** — naming them is what makes the result credible:

1. **Provisioning.** Lustre at **maximum capability**; WEKA at a **realistic production configuration**; cost
   for both reported alongside. Beating a competitor's best configuration is worth far more than beating one
   we sized ourselves. Both sides are sized above what the client can drive, so neither is the constraint.
2. **Transport / GPU-direct.** Lustre over EFA supports GPUDirect Storage; whether WEKA on AWS does is
   **settled empirically by a single cell before the matrix is committed**, because the vendor's materials and
   the transport analysis disagree. We **keep** the GPU-direct path rather than dropping it for symmetry, and
   run **both cuFile modes on both filesystems** — which separates the filesystem effect from the transport
   effect instead of confounding them.

**Results precede story.** No document here contains a predicted outcome or a pre-assigned "headline" stage.
Whatever the benchmark produces is what gets reported, including cells where WEKA loses.

---

## Start here

| If you want to… | Read |
|---|---|
| **Know what to read and paste, and when** | **`docs/cloud-setup/WORKFLOW.md`** — one page, per scenario (first spin-up · teardown · rebuild · leg switch) |
| Understand what we measure and why | **`PROJECT-THESIS.md`** — the source of truth |
| Know the rules this project runs under | **`CLAUDE.md`** |
| See the stage map, plan, and every methodology decision | **`docs/STAGES.md`** — the cross-stage decision register |
| Understand one stage in depth | **`docs/Stage-<N>-*.md`** |
| See what we found | **`docs/RESULTS.md`** |
| Run or recover a benchmark cell | **`docs/RUNBOOK.md`** |
| Know what a script does | **`docs/SCRIPT-TRACKER.md`** |
| Find where something lives | **`docs/FILESYSTEM-MAP.md`** |
| Provision the environment | **`docs/cloud-setup/NEW-CLOUD-SETUP.md`** + **`SPINUP-CHECKLIST.md`** |
| Create + mount a filesystem for a leg | **`prompts/prompt-weka-cluster-cloud.md`** (Leg A) · **`prompts/prompt-lustre-cluster-cloud.md`** (Leg B) — paste-to-Claude, reusable on every rebuild |
| Know what every path / name / variable should be | **`docs/NAMING-AND-VARIABLES.md`** (+ `env.example.sh`) |
| Tear down or rebuild the instance | **`docs/cloud-setup/TEARDOWN-AND-REBUILD.md`** (+ `scripts/teardown-preflight.sh`) — Claude runs it via **`prompts/prompt-teardown-cloud.md`**; the human only commits, pushes, and destroys |
| Pick up where the last session stopped | **`docs/cloud-setup/HANDOFF-NEXT-SESSION.md`** — written at teardown, because Claude's context does not survive one. *Does not exist until the first teardown.* |

**A fresh Claude session continuing this work** starts with the `cloud-session-open-items` memory (the work
list) → `PROJECT-THESIS.md` → `CLAUDE.md` → `docs/STAGES.md` → the relevant roadmap → `docs/RUNBOOK.md` before
running a cell.

---

## Layout

```
CLAUDE.md              project rules: the 11 Rules, recording, durability, docs cadence, memory hygiene
PROJECT-THESIS.md      the source of truth: the question, held-constant contract, both asymmetries, scope
env.example.sh         → env.sh (gitignored); has a --check validator
backup.sh              memories → mirror, then S3 sync
claude-memory-mirror/  git-tracked copy of the Claude memories (the only continuity across rebuilds)
docs/
  STAGES.md            stage map, per-leg plan, cross-stage decision register
  Stage-{1..7}-*.md    per-stage roadmaps — methodology, why each substage exists, per-cell results
  RESULTS.md           the cross-stage synthesis: findings and their story
  RUNBOOK.md           how to run and record a cell; both canaries; recovery
  SCRIPT-TRACKER.md    per-script reference + the deferred-work table
  FILESYSTEM-MAP.md    where everything lives
  NAMING-AND-VARIABLES.md  every path/name/variable with its recommended value
  cloud-setup/         WORKFLOW.md (the router), provisioning, teardown + rebuild
prompts/               the five paste-to-Claude prompts, re-runnable on every rebuild
scripts/               the script library + manifests/ + env-specs/
runs/                  one directory per run, plus INDEX.md, the per-leg resume markers, and sweep logs
```

---

## Getting to a first result

1. **Provision** — `docs/cloud-setup/SPINUP-CHECKLIST.md` (region, quota, instance, S3 + IAM, WEKA cluster).
2. **Bootstrap** — `docs/cloud-setup/NEW-CLOUD-SETUP.md`, which hands off to Claude four times (a fifth,
   `prompts/prompt-teardown-cloud.md`, closes each leg out): the system stack
   (`prompts/prompt-env-prep-cloud.md`), the WEKA filesystem (`prompts/prompt-weka-cluster-cloud.md`), the
   project itself (`prompts/handoff-cloud.md`), and later the Lustre filesystem
   (`prompts/prompt-lustre-cluster-cloud.md`). *Why prompts rather than checklist steps:* each runs again on
   every instance rebuild, and the storage ones have silent-failure modes (a UDP-fallback WEKA mount, a
   TCP-instead-of-EFA Lustre mount) that produce believable numbers for the wrong configuration.
3. **Build + Leg A** — Claude does the deferred script work, proves the pipeline on a throwaway cell, takes a
   baseline, and runs Leg A. The deferred-work table in `docs/SCRIPT-TRACKER.md` is the authoritative list of
   what is still owed and what is already done.
4. **Leg B** — provision FSx at maximum, rebuild the instance from the pinned AMI, verify the environment
   contract, repeat.
5. **Synthesis** — the actual deliverable.

> **Everything the scripts contain about paths, addresses, versions, core counts, and tuning came from a
> different environment. Re-derive; never copy.**

---

## Conventions worth knowing before you touch anything

- **The filesystem is a dimension, not a fork.** One `runs/` tree; it appears as a segment of the run-dir
  name and as a field in `metadata.json`. Scripts resolve the mount through **`$FS_MOUNT`**, derived from
  `$LEG` — a hardcoded mount path is a bug, because it silently makes one leg measure the other. The run-dir
  segment is equally load-bearing: the S3 sync and the teardown gate both glob on it.
- **The primary telemetry sources differ per filesystem.** The client's network counters are *diagnostic* on
  the WEKA leg and the *actual data path* on the Lustre leg. Never quote a bypassed source.
- **Each filesystem is measured on its intended transport** — WEKA on DPDK, Lustre on EFA. A fallback
  transport is a **stop**, not a caveat: it mounts cleanly and reports plausible numbers for a configuration
  this project decided not to measure.
- **Both mounts and local scratch are ephemeral.** git is authoritative for small text; **S3** for heavy
  write-once telemetry and datasets. Run `./backup.sh` before every commit and every teardown.
- **The human commits and pushes.** Never do it autonomously.
