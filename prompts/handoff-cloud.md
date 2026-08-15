# Project handoff — WEKA vs Lustre on AWS · THE LIVING HANDOFF

Written: 2026-08-14
Leg: **weka** (Leg A) — **nothing has been measured yet.** This handoff says: *start the Leg-A benchmarking.*

> **This file describes the current state and is edited to match it at every teardown** (teardown step 2 in
> `docs/cloud-setup/TEARDOWN-AND-REBUILD.md`; the pre-flight gates on the `Written:` date above and warns if
> the current leg is never named). It carries no idempotence scaffolding — a stale copy is a NO-GO, not a
> fallback.

You are a fresh Claude Code session on the project's AWS GPU instance, working in this repo. Assume commands
run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance, same workload code, same datasets, **only the filesystem
under the mount point changes.** Two sequential legs — **Leg A: WEKA**, then **Leg B: FSx for Lustre** —
followed by the head-to-head synthesis. `$LEG` says which one you are on.

---

## Current state

- **The instance was built end-to-end by `scripts/bootstrap-instance.sh`** (Terraform
  `clients_custom_data_post_mount`): packages, the pinned NVIDIA/CUDA/GDS stack, local-NVMe scratch RAID,
  the WEKA mount, `env.sh` generated from instance evidence — including `FS_TRANSPORT` from the client's own
  report — `LIBCUFILE_PRELOAD` located and exported, the compat-mode cuFile config, both conda environments
  built from `scripts/env-specs/` with import-level smoke tests, the HF token and model prefetch from SSM,
  and the memory restore. Boot log: `/var/log/wsi-bootstrap.log`; triage with `grep WSI-`.
- **The datasets are staged in S3** (`prefetch-datasets-to-s3.sh`, md5-verified per file). **They are not on
  the filesystem yet** — hydration is measured cell 1.7, and its driver does not exist (`D-13`);
  `run-leg.sh` reports that step MISSING and aborts rather than skipping it. Building it is part of your job.
- **`runs/` has no cells.** The deferred-work table in `docs/SCRIPT-TRACKER.md` plus section A of the
  open-items memory is the build job between you and the first kept number.
- **You re-verify all of it yourself, read-only, before touching anything. Trust nothing; confirm it** —
  the bootstrap's smoke tests are import-level and warn-only, not proof.

> ### ⛔ GATE TIER 0 — the transport, evidenced, before ANY cell including the throwaway
>
> **The transport this leg is actually on** — WEKA on **DPDK** (not UDP), Lustre on **EFA** (not TCP), per
> **D16**. **Not the mount options that were passed; the client's own report.** The bootstrap wrote
> `FS_TRANSPORT` from that evidence at boot on this leg (the Lustre cluster prompt records it on Leg B) —
> **verify it yourself before anything runs.**
>
> **If it shows the fallback transport — UDP where DPDK was required, TCP where EFA was required — or you
> cannot evidence which it is, STOP AND REPORT IMMEDIATELY. Do not run any cell, including a throwaway
> one.** The fallback mounts cleanly and produces a complete, plausible set of numbers for a configuration
> this project decided not to measure, so "measure now, flag later" spends the wallclock and the money
> before anyone can act. Only a written human waiver, with the reason recorded, changes that.
>
> **Closed when:** `FS_TRANSPORT` carries the client's own evidence of the intended transport, and
> `run-leg.sh` refuses the leg otherwise. This is **Tier 0 of the three-tier blocker gate**: Tier 1 gates
> kept cells, Tier 2 gates the main sweep, and each tier sits where its precondition first binds.

**The environment contract is what makes two legs run at different times provably comparable** (**D6**):
Leg A writes it at teardown, Leg B verifies it before its first cell, and an unrecorded field counts as
unverifiable, therefore failed. A held-constant fact this leg fails to record does not degrade gracefully —
it blocks or invalidates the cross-leg comparison, which is the only deliverable.

---

## THE CENTRAL DIRECTIVE

**Your job is to make the comparison valid, not just to make it run.** Everything below serves one goal:
when Leg B finishes, the difference between the two legs must be attributable to **the filesystem** and
nothing else. That means the held-constant contract is real, the recording is path-appropriate on each leg,
and every deviation is recorded rather than absorbed.

Three rules that follow, and that you will be tempted to bend:

1. **Results precede story.** No document may gain a predicted outcome, an expected magnitude, or a
   pre-assigned headline stage or metric (`PROJECT-THESIS.md` § 10). Record the **why** of every method —
   that is what makes a number evaluable, and in a competitive comparison every choice is a place a
   skeptical reader looks for bias. Record **nothing** about what the numbers will show. **An
   interpretation section does not exist until there is something to interpret** — a placeholder rots, and
   a section that does not exist cannot go stale. **Report losses.**
2. **Nothing is portable.** Every path, address, version, core count, GPU map, batch-size schedule, and
   tuning value in this repo's scripts came from a different environment. **Re-derive, never copy.**
3. **Every cell records the full measurement set, and no metric is designated primary**
   (`PROJECT-THESIS.md` § 4) — which axis turns out to be decisive is a *result*, so a cell that captured
   only the axis someone expected to matter cannot be repaired later. The set includes **measured wallclock
   and both price inputs, each stamped with the date it was checked**, so cost-to-complete is computable per
   cell and per leg. `docs/RUNBOOK.md` defines the set and the cost inputs — work from it.

---

## STEP 1 — Read the governing instructions first

- **`CLAUDE.md`** — the project constitution. Especially: the **eleven rules**; **recording is
  non-negotiable** (every cell wraps in `scripts/record-run.sh`; time series not point estimates; both
  canaries every sweep); **per-filesystem sources** (the client's network counters are *diagnostic* on the
  WEKA leg and *primary* on the Lustre leg); **durability**; **reference official docs, not training data**
  (doc-fetch is standing-approved); **the docs-cadence table**; **memory hygiene**; and **plan-first / the
  four pause triggers / safety** (ask before any sudo, mount, install, or destructive operation; surface
  decisions as a plain-text numbered list with a recommendation each).
- **Both memories, end to end.** `MEMORY.md` first, then the two files it indexes. **There are exactly two.**
  - **`cloud-session-open-items`** — **your work list.** Section A must be resolved before the first
    measured cell; section B is what you watch while benchmarking. **Add in the same edit that surfaces
    something; DELETE an item the moment it is done. Cite items by topic, never by number** — the list
    renumbers as items close.
  - **`uni2h-conditional-use-status`** — UNI2-h results are internal-only pending approval; every UNI2-h
    cell carries its tag, and those rows are filtered out of anything that leaves the building.
  - **If `MEMORY.md` is missing:** run `./scripts/restore-memories.sh` yourself, report its output, and
    **ask the human to restart the session** so the memories actually load. If the script *refuses* (empty
    or broken mirror), **STOP and report. Do not proceed without the memories** either way.

## STEP 2 — Read the project docs

**`PROJECT-THESIS.md`** (the source of truth — where anything disagrees with it, it wins) →
**`docs/STAGES.md`** (stage map, per-leg plan, the whole cross-stage decision register) → every
**`docs/Stage-<N>-*.md`** roadmap → **`docs/RUNBOOK.md`** (what every cell records, cost inputs, the
per-leg source table, both canaries, silent-skip hazards, cross-leg gates) → **`docs/SCRIPT-TRACKER.md`**
(per-script reference, cross-cutting patterns, **the deferred-work table that is most of your build job**,
and the env-specs route table) → **`docs/NAMING-AND-VARIABLES.md`** (before touching any script) →
**`docs/FILESYSTEM-MAP.md`** and **`docs/RESULTS.md`**.

---

## What to do, in order

### 1 — Deep read-only discovery (FIRST; mutate nothing)

Produce a written discovery report covering at least: **continuity** (user+sudo, repo integrity vs origin,
memories restored, `ssh -T git@github.com`, HF auth — the bootstrap installs the token from SSM; verify the
gated model actually resolves); **hardware** (GPU model/count/memory, **GPU↔NUMA↔NIC affinity**, NUMA and
core counts, NICs and link rates, EFA presence — record how this differs from anything the docs assume);
**the mount and the storage client** (mounted, options, **how many cores and which NICs the client is bound
to** — the reserved-core count is a per-filesystem parameter and part of that filesystem's reported cost,
**D15**; filesystem health; **capture the provisioned configuration**: backend type/count, capacity, EC
scheme, client networking mode — capacity is a sizing input to the raw-TIFF and 6.B corpora, not
bookkeeping; a tiny **recorded** read/write smoke); **GDS stack** (`nvidia-fs` and `libcufile` versions
**and whether they match**, `gdscheck` output — but never conclude the achievable path from a config flag,
that is settled empirically per **D8**); **local scratch + OS hygiene** (`/data/local-nvme` mounted, free
space, `/dev/shm` mode 1777); **S3 access** via the instance profile.
→ **Deliverable:** the report plus a plain-text numbered list of anything broken or suboptimal, each with a
recommendation. **Surface it before mutating state.**

### 2 — Verify the environments; never rebuild what matches

The bootstrap already built `$CONDA_ENV_MAIN` and `$CONDA_ENV_ALT` into `$CONDA_ENVS_DIR`. Verify imports
(torch+CUDA, cupy, cucim, kvikio, openslide, tifffile, h5py, timm, transformers) and that the visible GPU
count matches the hardware — the bootstrap's smoke is import-level and warn-only, so this is the first real
check (`D-22` is the script for it). **Use conda, never pip, for cuCIM** (pip wheels crash on a libstdc++
ABI mismatch inside `read_region()`). **Then regenerate the `scripts/env-specs/` files from what was
actually built** — the route table lives in `docs/SCRIPT-TRACKER.md` § Environment specs; the explicit file
is only a valid Leg-B target once it describes *this* environment.

### 3 — GATE TIER 1: close these before any cell whose number is kept

The next steps produce cells whose numbers are *kept*: the 1.7 hydration is a measured cell, and the
Stage-1.0 sweeps are the denominator for every "% of ceiling" in the leg. **Do not run either until every
row below is closed, or explicitly waived by the human in writing with the reason recorded.** A row is
closed by being **executed with its evidence named**, never by being read for — every row describes a
failure invisible in the output it produces.

| # | Blocker | Where | Closed when |
|---|---|---|---|
| 1 | **Per-filesystem recording adapters** — the recorder set and required-stream list arrived from an InfiniBand environment, so on AWS those streams are empty and **every run marks `INCOMPLETE`** | `D-4` | a cell records this leg's real Primary sources and `runs/INDEX.md` says `OK` |
| 2 | **Per-filesystem consistency relation** — the canary cannot evaluate without it, and it must be derived, never ported | `D-5` | the post-cell canary passes on a real cell, with the derivation written down |
| 3 | **The measurement-correctness remainders in the Python workers** — each produces a plausible number that is wrong, which is worse than a crash | the open-items memory, the worker measurement-correctness item | each fixed and re-verified against a real cell |
| 4 | **1.7 hydration driver built** — the step has no driver, and the leg orchestrator aborts rather than skipping it. On completion it writes `runs/.leg-state/$LEG/hydration-complete` (the bootstrap's re-hydration guard keys on it) | `D-13` | step 1.7 runs and the datasets byte-verify |
| 5 | **The Stage-1.0 read cells' cache regime, settled before the baseline** — working set sized past the larger of the two server-side caches, staged ahead of the timed window, never unlinked between cells, cell order de-ordered (**D13**; `docs/Stage-1-Ingest.md`). The one row that cannot be fixed after the fact without re-running the whole baseline | **D13**; the open-items memory, the read-sweep driver item | the 1.0b/1.0d drivers implement the regime, and each baseline read cell records the cache state it achieved |

> **Standing constraint — the read drivers do not implement row 5; do not run them as they stand.**
> `sweep-stage1-{seqr,randr}.sh` create a `--size=4G` × jobs working set in fio's layout phase immediately
> before each timed window, `--unlink=1` recreates it per cell, and the grid ascends in concurrency — each
> the opposite of what **D13** requires, on the cells that are the leg's denominator. **Fix the drivers
> first**; `docs/Stage-1-Ingest.md` and **D13** are the specification.

### 4 — The deferred script work (the core build task)

Work the deferred table in `docs/SCRIPT-TRACKER.md` — the single register for it. **This is where the
comparison's validity is won or lost**, and it is where Tier 1's rows close. **Keeping the tracker true is
part of the task:** a `D-n` you close leaves the tracker wrong until you reconcile it — the work is done
when the tracker matches the script, and every completed entry moves out of the deferred table into the
per-script reference. No change log; git is the audit trail.

### 5 — Hydrate (measured cell 1.7), resolve open-items section A, then the baseline — STOP for greenlight

Hydration byte-verifies against the manifests and fails loud on any mismatch. Then run the pre-cell canary
and capture the synthetic baseline **per block size** — the Stage-1.0 sweeps, the denominator for
everything. **Stop for the human's greenlight on the baseline before the main sweep, reporting Tier 0 and
every Tier-1 row, row by row, with the evidence named.** Do not anchor on any number from any prior
environment. Also check the **pre-committed instance revisit trigger** (**D10**): a ceiling pinned at line
rate across block sizes plus concurrency sweeps saturating on CPU means the instance is measuring itself —
surface it before Leg B, not after.

### 6 — GATE TIER 2: close these before the main sweep

**Do not start the leg until every row below — and Tiers 0 and 1 with it — is closed or explicitly waived
in writing.**

| # | Blocker | Where | Closed when |
|---|---|---|---|
| 6 | **cuFile path accounting** — a kvikIO cell without recorded GPU-direct-vs-bounced bytes is **incomplete** (**D8**); a config flag is not proof | `D-6` | a kvikIO cell's run dir contains the byte split **and the counters behind it were enabled and moved** on a known-good read — a present-but-all-zero split does **not** close this row (constraint below) |
| 7 | **`LIBCUFILE_PRELOAD` verified** — the bootstrap exported it; a wrong path is a silent no-op running the cell on the wrong libcufile | `D-10` | `./env.sh --check` shows it and the file exists, matched to the loaded `nvidia-fs` |
| 8 | **GPU/NUMA/NIC map and core accounting re-derived** — driver index lists are placeholders; the reserved-core set is a per-filesystem parameter (**D15**) | `D-8`, `D-9` | measured on this instance and substituted |
| 9 | **Step 4.D actually recorded** — the 20× conversion is treated as a measured workload but produces no run dir | `D-15` | 4.D produces a run dir with telemetry |
| 10 | **Open-items section A resolved** — every item there changes what the numbers *mean*; the ones that govern earlier cells already closed under Tier 1 | the open-items memory, section A | each closed or waived |
| — | **Leg-B additions, on Leg B only:** the FSx-Lustre EFA client configuration (`D-16`), the kernel-vs-contract policy (`D-17`), and Lustre tuning as part of "Lustre at maximum" (`D-11`) | the deferred table | per row |

> **Standing constraint — the nvidia-fs I/O counters are OFF by default, so a *present* byte split does not
> close row 6.** `/proc/driver/nvidia-fs/stats` reports `IO stats: Disabled` until
> `/sys/module/nvidia_fs/parameters/rw_stats_enabled` and `peer_stats_enabled` are set, and a kvikIO cell
> run that way records a split that is present and **entirely zero** — which reads as "no GPU-direct
> traffic" rather than "the accounting was off", landing on the wrong answer to the single question the
> GPU-direct matrix is designed around (**D8**). **Close the row by enabling the counters, reading a
> known-good file, and showing the split move** — `Active Shadow-Buffer (MiB)` is the compat-mode bounce
> signal. The stats block is version-stamped; re-verify field names on this stack.

**Report the gate twice:** Tier 0 + Tier 1 at the baseline greenlight; the full set before the leg starts.
Each row **closed / waived / open** with the evidence named — "done" without evidence is what Rule 11
forbids. Any open row means the leg does not start.

### 7 — Run the leg, then close it out

`scripts/run-leg.sh --leg $LEG` drives the dependency-ordered plan; every cell through `record-run.sh`,
both canaries every sweep, numbers into the roadmaps as they land — **numbers and caveats only, no
narrative.** Close-out is `docs/cloud-setup/TEARDOWN-AND-REBUILD.md` § Teardown: **edit THIS FILE to the
new current state** (step 2 — dated, leg named, what completed, what is mid-stage, what this leg taught
that changes the next one's plan), then the human runs `scripts/teardown-prep.sh`. Single-leg claims stay
scoped as half an unfinished comparison.

---

## Standing facts to carry

- **`--fs` is a dimension, not a fork.** One `runs/` tree; the filesystem is a run-dir segment and a
  `metadata.json` field; the `-<leg>-` segment is what the S3 sync and the teardown gate glob on — a run
  dir without it is never backed up **and the gate does not notice.**
- **No metric is designated primary**; every cell records the full set plus wallclock and both date-stamped
  price inputs, fetched never recalled.
- **Per-filesystem primaries invert:** the client's kernel network counters are diagnostic on WEKA and ARE
  the data path on Lustre. Never quote a bypassed source.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell.**
- **Cold vs warm is an enforced axis, recorded as achieved** — satisfied in **D13**'s order of preference;
  any corpus that must exceed cache is sized against **both** filesystems' caches.
- **kvikIO cells run in both cuFile modes on both filesystems**; a cell without path accounting is
  incomplete. **`LD_PRELOAD` scoped per cell** — nearly every sweep mixes kvikIO and cuCIM.
- **Three silent-skip hazards** (raw-TIFF converter, 6.A extractor, Tier-2 chunked conversion) reuse
  existing output without failing loud — verify cleanup between runs.
- **Cross-leg integrity gates** (dataset bytes, coords, raw-TIFF dimensions, feature shapes) are
  storage-independent and must match across legs; a divergence is fail-loud.
- **MIL is canonical `batch_size=1` + `collate_MIL`**; concurrency via `num_workers`.
- **UNI2-h stays internal-only** — don't strip the tags; filter before anything is externalised.
- **Git: the human commits and pushes.** Run `./backup.sh` before every commit; remind them if you changed
  memories. **Ephemerality:** both mounts, local scratch, and your context die with the instance — only
  git, the memory mirror, and S3 survive. Persist continuously.

## Your first response

After the reading **and** the read-only discovery: what you understand the project to be, the discovery
report (what is solid, what is not, how this instance differs from anything the docs assume), and the build
plan you propose — with the open items as a plain-text numbered list, each with a recommendation: the
discovery findings, the 6.B corpus-sizing decision, the baseline greenlight, any client-reconfigure
proposal, and any methodology revisit the real hardware justifies. **Surface problems and questions first;
mutate nothing before sign-off. Run nothing at all — not even the throwaway — until Tier 0 is closed; run
no kept cell until Tier 1 is closed; start no sweep until the full gate is reported and cleared.**
