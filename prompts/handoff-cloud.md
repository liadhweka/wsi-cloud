# Project handoff — WEKA vs Lustre on AWS (cloud instance → build → run the leg)

You are a fresh Claude Code session on a **newly built AWS GPU instance**, working in this repo.
Assume commands run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance, same workload code, same datasets, **only the filesystem
under the mount point changes.** It runs as two sequential legs — **Leg A: WEKA**, then **Leg B: FSx for
Lustre** — followed by the head-to-head synthesis. `$LEG` says which one you are on.

---

## STEP 0 — Establish which state you are in, before anything else

This prompt is pasted on **every** build — first spin-up, a cost-pause rebuild, and the Leg-A→Leg-B switch.
The states differ, so establish which one you are in **mechanically**, never by assumption. Three read-only
checks:

1. Does **`docs/cloud-setup/HANDOFF-NEXT-SESSION.md`** exist?
2. Does `git log` show commits after this prompt was written?
3. Does `runs/INDEX.md` have rows?

**Any of the three → this is a rebuild**, and the delta table at the end of STEP 3 says which STEP 4
substeps change. All three negative → first build, and STEP 4 runs exactly as written.

> **If `HANDOFF-NEXT-SESSION.md` exists, read it before anything else, and treat it as outranking this
> prompt on anything about current state.** It is the previous session's own account of what it completed,
> what was mid-flight, what failed, and what it learned that should change the plan — written at teardown
> precisely because Claude's context does not survive one. It knows things this prompt cannot.

---

**What the human has already done** (per `docs/cloud-setup/NEW-CLOUD-SETUP.md`): provisioned the instance
from a pinned AMI — **verify in 4.0 that it actually carries the GPU stack** — the S3 bucket + IAM role,
and this leg's storage side (the WEKA backend cluster on Leg A, the FSx file system on Leg B); wired
SSH↔GitHub and set their git identity; installed Claude; cloned this repo; restored the memories
(`scripts/restore-memories.sh`); and filled in the decision-only half of `env.sh`.

**What two prior Claude sessions already did** — read their reports rather than re-deriving:
- **env-prep** (`prompts/prompt-env-prep-cloud.md`) verified the GPU/CUDA/GDS/networking stack, reported
  the system `libcufile` path, **enabled the nvidia-fs I/O counters** (off by default — gate Tier 2 row 6),
  installed miniforge, and provisioned `/data/local-nvme`.
- **Cluster setup** — `prompts/prompt-weka-cluster-cloud.md` on Leg A,
  `prompts/prompt-lustre-cluster-cloud.md` on Leg B — created or attached the filesystem, installed the
  client, **mounted it at `$FS_MOUNT`**, and wrote that filesystem's facts into `env.sh`: `FS_TRANSPORT`,
  plus the input the consistency canary is derived from (`WEKA_EC_SCHEME` on Leg A,
  `LUSTRE_STRIPE_LAYOUT` on Leg B — without it the canary cannot be derived at all). On the WEKA leg it
  also wrote `WEKA_CLIENT_CORES`: **`num_cores` is measured configuration, not a knob** (**D15**), so do
  not change it mid-leg.
  > ### ⛔ GATE TIER 0 — the transport, evidenced, before ANY cell including the throwaway
  >
  > **The transport this leg is actually on** — WEKA on **DPDK** (not UDP), Lustre on **EFA** (not TCP),
  > per **D16**. **Not the mount options that were passed; the client's own report.** This precondition is
  > stated here because this is where its evidence arrives — it comes out of the cluster-setup prompt's
  > report, so it is closeable at the earliest point it binds: before anything at all runs.
  >
  > **If that session reported the fallback transport — UDP where DPDK was required, TCP where EFA was
  > required — or could not evidence which it got, STOP AND REPORT IMMEDIATELY. Do not run any cell,
  > including a throwaway one.** Per **D16** the transport is a precondition of the measurement, not a
  > caveat for the writeup: the fallback mounts cleanly and produces a complete, plausible set of numbers
  > for a configuration this project decided not to measure, so "measure now, flag later" spends the
  > wallclock and the money before anyone can act. Only a written human waiver, with the reason recorded,
  > changes that.
  >
  > **Closed when:** `FS_TRANSPORT` carries the client's own evidence of the intended transport, and
  > `run-leg.sh` refuses the leg otherwise. This is **Tier 0 of the three-tier blocker gate**: Tier 1 is at
  > **4.1b**, Tier 2 at **4.5b**, and each tier sits where its precondition first binds.

**The environment contract is what makes two legs run at different times provably comparable** (**D6**):
Leg A writes it, Leg B verifies it before its first cell, and an unrecorded field counts as unverifiable,
therefore failed. A held-constant fact this leg fails to record does not degrade gracefully — it blocks or
invalidates the cross-leg comparison, which is the only deliverable.

**One thing they probably have NOT done: the Hugging Face login.** `hf` ships with the Python environments,
which *you* build in 4.1 — so `hf auth login` cannot have run yet, and one of the three foundation models is
access-gated. Check it in 4.0 and remind them; it blocks 6.A, not the earlier stages.

**You re-verify all of it yourself, read-only, before touching anything. Trust nothing; confirm it.**

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
   interpretation section does not exist until there is something to interpret** — do not create one as a
   placeholder; a placeholder rots, and a section that does not exist cannot go stale. **Report losses.**
2. **Nothing is portable.** Every path, address, version, core count, GPU map, batch-size schedule, and
   tuning value in this repo's scripts came from a different environment. **Re-derive, never copy.**
3. **Every cell records the full measurement set, and no metric is designated primary**
   (`PROJECT-THESIS.md` § 4) — which axis turns out to be decisive is a *result*, so a cell that captured
   only the axis someone expected to matter cannot be repaired later. The set includes **measured wallclock
   and both price inputs, each stamped with the date it was checked**, so cost-to-complete is computable
   per cell and per leg. `docs/RUNBOOK.md` defines the set and the cost inputs — work from it rather than
   re-deriving them.

---

## STEP 1 — Read the governing instructions first

- **`CLAUDE.md`** — the project constitution. Especially: the **eleven rules**; **recording is
  non-negotiable** (every cell wraps in `scripts/record-run.sh`; time series not point estimates; multiple
  sources; **both canaries every sweep**); **per-filesystem source adapters** (the client's network
  counters are *diagnostic* on the WEKA leg and *primary* on the Lustre leg — get this wrong and every
  number cites a bypassed source); **durability** (both mounts and local scratch are ephemeral; git and S3
  have non-overlapping authority); **reference official docs, not training data** (doc-fetch is
  standing-approved); **record the WHY everywhere**; the **docs-cadence table**; **where unresolved items
  live**; **memory hygiene**; and **plan-first / the four pause triggers / safety** (ask before any sudo,
  mount, install, or destructive operation; surface decisions as a plain-text numbered list with a
  recommendation each — **not** the AskUserQuestion picker).
- **Both memories, end to end.** `MEMORY.md` first, then the two files it indexes. **There are exactly
  two**; a citation anywhere in the repo to any other memory is stale, and the fact it referred to lives in
  the docs.
  - **`cloud-session-open-items`** — **your work list.** **Section A** must be resolved before the first
    measured cell; **section B** is what you watch while benchmarking. **Add to it in the same edit that
    surfaces something new; DELETE an item the moment it is done** — that file holds only open items, and
    completions are recorded in the relevant doc instead. **Cite items by topic, never by number:** the
    list is renumbered as items are deleted, so a number citation rots immediately.
  - **`uni2h-conditional-use-status`** — UNI2-h is internal-only pending approval, so every UNI2-h cell
    carries its tag and those rows are filtered out of anything that leaves the building. Virchow2 and
    GigaPath are unrestricted.
  - **If `MEMORY.md` is missing:** run `./scripts/restore-memories.sh` yourself — the mirror is in-repo
    and the script verifies the result — then report its output and **ask the human to restart the session**
    so the memories actually load. **Do not proceed on this session's context**; that is the failure this
    check exists to catch. If the script *refuses* — empty mirror, or no `MEMORY.md` in it — **STOP and
    report**: that means the mirror itself is broken, and no restore can fix it. **Do not proceed without
    the memories** either way. (`docs/cloud-setup/NEW-CLOUD-SETUP.md` § 4.3 is the human-facing version of
    the same one-liner.)

## STEP 2 — Read the project docs

- **`PROJECT-THESIS.md`** — the source of truth: the question, the held-constant contract, **both
  deliberate asymmetries**, **no metric designated primary**, cost-to-complete, the framing rules, and the
  list of what would make this comparison invalid. Where anything else in the repo disagrees with it, it
  wins and the other thing is a bug.
- **`docs/STAGES.md`** — the stage map, the comparison structure, the GPU-direct matrix, the 20× coord
  contract, the per-leg plan, and the **cross-stage decision register**. Read the whole register; it is
  where the *why* of every cross-stage methodology choice lives.
- **Every `docs/Stage-<N>-*.md` roadmap** — methodology, per-substage rationale, caveats, and that stage's
  own decision register.
- **`docs/RUNBOOK.md`** — the operational reference: **what every cell records**, the **per-cell cost
  inputs**, the **per-leg source table**, **both canaries**, the silent-skip hazards, and the cross-leg
  integrity gates.
- **`docs/SCRIPT-TRACKER.md`** — per-script reference, the **cross-cutting patterns** (each exists because
  its absence caused a real failure), and the **deferred-work table** (`D-4`…`D-24`) that is most of your
  build job — plus the table above it recording what was already completed and how it was verified.
- **`docs/NAMING-AND-VARIABLES.md`** — **read this before touching any script.** Every path, name, and
  identifier that varies between environments, with a recommended value, split into *decide now* / *record
  at provisioning* / *derived*. Its companion `env.example.sh` → `env.sh` is how configuration reaches the
  scripts, and `./env.sh --check` validates the whole set before anything runs. **Nothing is
  hardcoded; nothing silently defaults.**
- **`docs/FILESYSTEM-MAP.md`** and **`docs/RESULTS.md`**.

## STEP 3 — Where things stand

- **Configuration reaches the scripts through the environment, and nothing defaults.** Every script
  resolves the mount through `$FS_MOUNT`, builds its interpreter from `$CONDA_ENVS_DIR`, reads
  `$LIBCUFILE_PRELOAD`, and **aborts loudly if any of them is unset.** The filesystem is a dimension, not a
  fork in the code — and a hardcoded mount makes a Lustre cell silently measure WEKA while the number still
  looks correct.
- **How a cell is labelled is load-bearing beyond bookkeeping** (**D11**). The `-<fs>-` segment of a
  run-dir name is what `sync-to-s3.sh` and `teardown-preflight.sh` glob on, so a run dir without it is
  **never backed up to S3, and the teardown gate does not notice.** `docs/RUNBOOK.md` has the mechanics of
  labelling and recording a cell.
- **What is missing is the deferred work in `docs/SCRIPT-TRACKER.md`'s table**, which is the single register
  for it — the open-items memory deliberately does **not** duplicate the list, it points there. **Two things
  sit in the memory instead**, because they are methodology changes to drivers that already run rather than
  missing infrastructure: the **worker measurement-correctness fixes** and the **read-sweep cache-regime
  changes** (4.1b). None of this is incidental cleanup; **it is a hard prerequisite for a valid cell.**
- **Leg A is WEKA; Leg B is FSx for Lustre**, provisioned separately and run later on a rebuilt instance of
  the same type (**D10**). `$LEG` says which one you are on.

### On a rebuild, these STEP 4 substeps change

Detection is STEP 0. What differs:

| On a **rebuild** | Because |
|---|---|
| **4.1 build the environment — REDO** | the conda envs lived on ephemeral scratch. Use the pinned `*.conda-explicit.txt`, not the loose recipe: `conda_env_main` and `python_version` are held-constant contract fields |
| **4.2 datasets — RE-HYDRATE, don't re-download** | S3 holds them; the mount is what died. Byte-verify against the manifest. The re-hydration is still **measured cell 1.7**, so gate Tier 1 (4.1b) binds before it on a rebuild too |
| **4.3 the deferred script work — VERIFY, don't redo** | it is committed to git and arrived with the clone. Re-run its checks; only build what `docs/SCRIPT-TRACKER.md` still marks deferred |
| **4.4 open-items section A — CONTINUE** | the memory holds only what is *still* open, so it is already the correct work list |
| **4.5 baseline — only if the hardware or the mount configuration changed** | otherwise the previous leg's baseline stands, and re-taking it burns wallclock. Say which you concluded and why |
| **the blocker gate, all three tiers — ALWAYS** | the gate binds on the first *measured* cell, not the first build: **Tier 0** before anything at all including the throwaway, **Tier 1 (4.1b)** before the re-hydration and before any re-taken baseline, **Tier 2 (4.5b)** before the leg resumes |
| **4.6 run the leg — RESUME** | `run-leg.sh --leg $LEG` resumes from the markers in `runs/.leg-state/$LEG/`, which are git-tracked and therefore survived the teardown. **If the marker dir is empty on a mid-leg rebuild, stop and say so** — that means the previous teardown did not commit them, and blindly re-running would duplicate hours of cells |

---

## STEP 4 — What to do, in order

### 4.0 — Deep read-only discovery (FIRST; mutate nothing)

Produce a written discovery report. Cover at least:

- **Continuity:** user + sudo; repo integrity (`git status`, `git remote -v`, `git log -1` vs origin);
  **memories restored** (`MEMORY.md` plus the two files it indexes); `.claude/settings.json` present;
  `ssh -T git@github.com`; Hugging Face auth; miniforge present.
- **Hardware:** GPU model/count/memory; **GPU↔NUMA↔NIC affinity**; NUMA nodes and core counts; network
  interfaces, types, link rates, and addresses; EFA presence and versions. **Record how this differs from
  anything the docs assume** — those deltas drive every "re-derive" action below.
- **The mount and the storage client:** is `$FS_MOUNT` mounted, with what options, and — crucially — **how
  many cores and which NICs the client is bound to.** The reserved-core count is a **per-filesystem**
  parameter and part of that filesystem's reported cost (**D15**), not a constant. Flag
  under-provisioning. Confirm the filesystem is healthy, and **capture the provisioned configuration** into
  what becomes the environment contract — WEKA: backend type/count, capacity, EC scheme, client networking
  mode; FSx: tier, capacity, provisioned metadata IOPS, EFA state. **Capacity is not bookkeeping** — the
  raw-TIFF artifacts of the 4.D conversion and 6.A Tier 2 are written to `$FS_MOUNT`, so the *filesystem's*
  provisioned capacity is their sizing input (open-items memory: the raw-TIFF headroom and `CHUNK_SIZE`
  items), and on FSx capacity is simultaneously a performance knob. Confirm ownership and do a tiny
  **recorded** read/write smoke test.
- **GDS stack:** tool presence, `nvidia-fs` and `libcufile` versions **and whether they match**, peer-memory
  module loaded, and what `gdscheck` reports. **Do not conclude from a config flag whether true GDS is
  active** — that is settled empirically in 4.3.
- **Local scratch + OS hygiene:** `/data/local-nvme` mounted, with its **free space recorded and checked
  against the floor env-prep provisions it to** (`prompts/prompt-env-prep-cloud.md`) — it carries the conda
  environments *and* the locally-staged `fpsync-source` corpus that the 1.5/1.6 ingest cells copy *from*.
  `/dev/shm` mode 1777; free space on `/`.
- **S3 access** via the instance profile: read and small write.

→ **Deliverable:** the report plus a plain-text numbered list of anything broken or suboptimal, each with a
recommendation. **Surface it to the human before mutating state.**

### 4.1 — Build the environment

- **Python environments** into `$CONDA_ENVS_DIR` (`/data/local-nvme/conda-envs/`), named `$CONDA_ENV_MAIN` and
  `$CONDA_ENV_ALT`. **Use conda/mamba, not pip, for cuCIM** — pip wheels have been observed to crash on a
  libstdc++ ABI mismatch inside `read_region()`.

  **`scripts/env-specs/` holds four kinds of file, and they are NOT interchangeable. Pick deliberately:**

  | File | What it is | Use it when |
  |---|---|---|
  | `env-create-history.txt` | **The recipe** — the actual `mamba create` / `mamba install` commands, with loose pins that re-solve against whatever CUDA is present | **Building the FIRST environment on a new instance.** It re-solves against this instance's stack, so it is the route most likely to succeed |
  | `*.conda-explicit.txt` | Fully pinned package URLs — reproduces the environment **bit-identically** (`conda create -p <path> --file <file>`) | **The Leg-B rebuild.** Use this so Leg B's environment matches Leg A exactly |
  | `*.environment.yml` | Solved spec with versions. Note its `name:` is an absolute **path**, so create with `-p`, not `-n` | A middle route if the explicit file will not solve |
  | `*.pip-freeze.txt` | Record of the pip-installed remainder | Cross-check only — never the primary route |

  **Why this ordering matters, not just which command runs:** `conda_env_main` and `python_version` are
  `MUST_MATCH` fields in the environment contract. So the environment is a **held-constant input**: whatever
  Leg A ends up with, Leg B must reproduce, which is exactly what the explicit file is for. If the recipe
  resolves to different versions on the Leg-B instance, that is a contract violation, not a detail.

  **After building:** verify imports (torch+CUDA, cupy, cucim, kvikio, openslide, tifffile, h5py, timm,
  transformers) and that the visible GPU count matches the hardware. Then **regenerate the spec files from what
  you actually built** and say so — the ones in the repo came from a different machine, so the explicit file is
  only a valid Leg-B target once it describes *this* environment.

  Remind the human to do the **Hugging Face login** (`docs/cloud-setup/NEW-CLOUD-SETUP.md` § 7.2) as soon as
  the environments exist: `hf` does not exist before this step, one model is access-gated, and the failure
  surfaces deep inside a Stage-6 cell.
- **cuFile configuration for THIS instance** — instantiate the template with **this** instance's own
  addresses and the transport options the mounted filesystem needs. Follow
  `scripts/GDS-TUNING-CHECKLIST.md`, which currently carries a **`⏳ PENDING RETARGET`** banner listing what
  its rewrite must do — **rewriting it is deferred item `D-10` and is part of this step**, including adding
  the Lustre-over-EFA branch you will need for Leg B.
- **Client provisioning.** If discovery found the storage client under-provisioned, propose the fix and get
  sign-off — it is mount-disrupting, so ask first. **Then hold that configuration constant for the whole
  leg** and record it; a mid-leg change is a benchmark change and requires re-baselining.

### 4.1b — GATE TIER 1: close these before any cell whose number is kept

**The blocker gate has three tiers, and each sits where its precondition first binds** — Tier 0 (the
transport) above, before anything at all; **Tier 1 here**, because the next two steps produce cells whose
numbers are *kept*: 4.2's hydration **is measured cell 1.7**, and 4.5's Stage-1.0 sweeps are the cells every
downstream "% of ceiling" divides by. Tier 2 (4.5b) is everything that binds only at the main sweep.

**Do not run 4.2's hydration or 4.5's baseline until every row below is closed, or explicitly waived by the
human in writing with the reason recorded.** A denominator measured through a broken recorder is precisely the
failure this gate exists to prevent, and nothing downstream can detect it — it cannot be repaired afterwards,
only re-run, at the wallclock and the money it already cost.

**Why a checklist and not a careful re-read.** Every row in this gate describes a failure that is invisible in
the output it produces: the cell finishes, the run dir looks normal, `results.json` parses, and the number is
wrong. Reading for that class of defect does not work — each row has to be *executed* and its evidence named.

| # | Blocker | Where | Closed when |
|---|---|---|---|
| 1 | **Per-filesystem recording adapters** — the recorder set and required-stream list arrived from an InfiniBand environment, so on AWS those streams are empty and **every run marks `INCOMPLETE`** | `D-4` | a cell records this leg's real Primary sources and `runs/INDEX.md` says `OK` |
| 2 | **Per-filesystem consistency relation** — the canary cannot evaluate without it, and it must be derived, never ported | `D-5` | the post-cell canary passes on a real cell, with the derivation written down |
| 3 | **The measurement-correctness bugs in the Python workers** — a whole class of them: latency sampled before the I/O wait, uninitialised GPU memory saved as features, per-second rates never divided by dt, `gds_engaged` inferred from the run-dir name rather than from behaviour. **Each produces a plausible number that is wrong, which is worse than a crash** | the open-items memory, the worker measurement-correctness item | each fixed and re-verified against a real cell |
| 4 | **1.7 hydration driver built** — the step has no driver, and the leg orchestrator aborts rather than skipping it. **This row gates 4.2 by definition:** without it the step cannot run at all | `D-13` | step 1.7 runs and the datasets byte-verify |
| 5 | **The Stage-1.0 read cells' cache regime, settled before the baseline is taken** — the read working set sized past the larger of the two server-side caches, the data staged ahead of the timed window rather than created and unlinked per cell, and cell order not ascending (**D13**, `docs/Stage-1-Ingest.md`). A cache-inflated ceiling makes **every** downstream percentage wrong in the flattering direction, and it is the one row here that cannot be fixed after the fact without re-running the whole baseline | **D13**; the open-items memory, the read-sweep driver item | the 1.0b/1.0d drivers implement the regime, and each baseline read cell records the cache state it achieved |

> **Standing constraint — the read drivers do not implement row 5, so do not run them as they stand.**
> `sweep-stage1-seqr.sh` and `sweep-stage1-randr.sh` read a `--size=4G` × `numjobs` working set that fio
> creates in a layout phase immediately before the timed window, `--unlink=1` recreates it per cell, and the
> grid ascends in concurrency (all read out of the drivers themselves). Each of those is the opposite of what
> **D13** requires, so the ceiling they produce may be served partly from cache on either side — and it is the
> denominator for the leg. **Fix the drivers first.** The work is tracked in the open-items memory (the
> read-sweep driver item); `docs/Stage-1-Ingest.md` and **D13** are its specification.

**Reported to the human at the baseline greenlight (4.5)** — Tier 0 and this table together, each row marked
closed / waived / open with **the evidence named**. See 4.5b for both report points.

### 4.2 — Datasets, once, into S3 — then hydrate

Download the datasets **once** to S3 via the tracked manifests in `scripts/manifests/` (they are not on this
instance and not in git). Then hydrate onto `$FS_MOUNT` and **byte-verify**, failing loud on any mismatch.

**Why this order matters:** S3 is what makes the datasets a *held-constant input* — the second leg hydrates
the same bytes from the same place instead of re-downloading. The hydration itself is **measured cell 1.7**,
so run it through `record-run.sh` rather than as a side task.

**Gate: Tier 1 (4.1b) must be closed before the hydration**, which is a kept cell. **The download to S3 is
not a measured cell and does not wait** — it is slow, so start it in the background and do 4.3 while it runs,
which is also where Tier 1's rows get closed, row 4 (the 1.7 driver) being the one that makes the hydration
runnable at all.

### 4.3 — The deferred script work (the core build task)

Work **`D-4` … `D-24`** from the deferred-work table in `docs/SCRIPT-TRACKER.md` — the single register for
this work. **This is where the comparison's validity is won or lost.**

**Gate: this step is where Tier 1 (4.1b) gets closed.** Rows 1, 2 and 4 are `D-4`, `D-5` and `D-13`; row 3's
worker fixes and row 5's read-driver changes are script work tracked in the open-items memory rather than in
that table. Until they are closed, no kept cell runs — which is why 4.2's hydration waits on this step.

> ### `docs/SCRIPT-TRACKER.md` is yours, and keeping it true is part of this task
>
> It describes the scripts you are changing, so a `D-n` you close leaves the tracker wrong until you
> reconcile it: **the work is not done when the script works; it is done when the tracker matches it.**
> Reconcile against the scripts as they now are, whatever the tracker says on the build you find it in.
>
> That means, per `CLAUDE.md`:
> - **Every entry you complete comes out of the deferred table** and into the per-script reference — what it
>   does **and why**, its inputs and outputs, its caveats. A `D-n` left listed after completion gets redone.
> - **No change log.** Git is the audit trail.
> - **Any decisions become a register** — live decisions only, each justified on its own terms, never dated and
>   never as a contrast with what it replaced.
> - **Remove what no longer applies** — an entry describing a script, a path or an environment that is no
>   longer there is worse than no entry at all, because a later session plans against it and believes it.
> - The **cross-cutting patterns** stay: each one exists because its absence caused a real failure, so each is
>   a standing constraint, not history.

Priorities and traps:

- **Do not redo `D-1`/`D-2`/`D-3`/`D-12`/`D-14`** — they are complete, with what was done and how it was
  verified recorded in `docs/SCRIPT-TRACKER.md` § "Done before leaving the build machine". Re-grep to satisfy
  yourself (a hardcoded mount makes a Lustre cell silently measure WEKA and the number still looks correct),
  but the work itself is done.
- **`D-4` per-filesystem recording adapters.** Write them against the **real** telemetry schemas. Preserve
  the **per-timestamp client-summing pattern** (a naive pre-aggregated mean under-reports by ~100×) and
  filter by a stable identity, never a numeric node id.
- **`D-5` derive each filesystem's consistency relation** — WEKA from the actual EC scheme, Lustre from the
  actual stripe layout. **Never port one across.** The canary cannot run without this.
- **`D-6` cuFile path accounting** as a mandatory per-cell source. **Then settle the empirical question:
  does WEKA on this instance do true GDS or fall back to compat?** Use `gdscheck` plus a recorded canary
  cell. Either answer is usable — the Stage 4 matrix is built for both — but it must be *measured*.
- **`D-7` S3 sync + per-cell watchdog + canary-aborts-the-chain** before any unattended run. A 3am canary
  failure that waits to be noticed produces hours of contaminated cells that look fine.
  **`scripts/sync-to-s3.sh` already exists** and implements both sync semantics — but it carries an
  **`UNVERIFIED AGAINST A REAL BUCKET`** banner. **Run the first-run procedure in its header before trusting
  it, then remove the banner.** The load-bearing step is the one proving that a file deleted locally under an
  *archive* path does **not** disappear from S3 — archive semantics are the only thing protecting raw
  telemetry when local disk is reclaimed. What is still missing is wiring per-cell sync into
  `record-run.sh`, the per-cell watchdog, and the canary abort.
- **`D-8`/`D-9` re-derive the GPU/NUMA map, the GPU-count ranges, and the core accounting** — including how
  many cores the storage client reserves, which is a per-filesystem parameter and part of that filesystem's
  reported cost (**D15**).

**Then prove the pipeline end-to-end on a throwaway Stage-0 cell** before spending real wallclock: recording
complete, both canaries functional, S3 sync verified, `runs/INDEX.md` row correct, aggregator produces a row
pivoted on `--fs`. **Gate Tier 0 covers this cell too — the throwaway is not exempt**, because nothing at all
runs on an unevidenced or fallback transport, discardable output included.

### 4.4 — Resolve open-items section A

Every item in section A changes what the numbers *mean*, so resolving them after cells have run means
re-running cells. Two deserve special attention:

- **The sub-second-cell sampling question** — decide it, and apply the same decision to both legs.
- **Corpus sizing for Stage 6.B** (the open-items memory, the 6.B corpus-sizing item) — **this one must be
  settled before this leg generates anything.** The corpus has to defeat *two* caches, and the second differs
  per filesystem, so it is sized against **both** filesystems' caches and yields **one identical corpus
  definition serving both legs** — per-leg sizes would break the held-constant contract on exactly the
  substage most sensitive to it. Recommendation is in the item; surface it to the human.

### 4.5 — Baseline, then STOP for greenlight

**Gate: Tiers 0 and 1 (4.1b) must be closed before the baseline runs** — these are kept cells, and Tier-1
row 5 governs them directly, so the read sweeps must already carry the decided cache regime before they start.

Run the pre-cell canary, then capture the synthetic baseline **per block size** — that means the Stage 1.0
sweeps (`sweep-stage1-{seqw,seqr,randw,randr}.sh`), which are the cells every downstream "% of ceiling"
divides by. The single-cell spot-check helpers (`fe-core-fio.sh`, `fe-core-kvikio.sh`) give a quick recorded
reference point at one fixed configuration but are **not** the per-block-size ceiling. The pre-cell canary
requires each read cell's **cache regime to be known before it runs** — an unestablished regime makes the cell
unlabelled, not cold (`docs/RUNBOOK.md`). Confirm the post-cell canary is consistent. **Do not anchor on any
number from any prior environment.**

**Stop and get the human's greenlight on the baseline before Step 4.6.** It becomes the denominator for
every "% of ceiling" in the leg, so a wrong baseline propagates everywhere. **Report Tier 0 and the Tier-1
rows here, row by row with the evidence named** — that report is the greenlight's other half, because a
baseline is only as good as the recording that produced it.

Also check the **pre-committed instance revisit trigger** (**D10** in `docs/STAGES.md`) here: if the ceiling
pins at line rate across block sizes *and* the concurrency sweeps saturate on CPU cores rather than storage,
the instance is measuring itself rather than the filesystem — surface that before Leg B rather than after.

### 4.5b — GATE TIER 2: close these before the main sweep

**Tier 2 is everything that binds at 4.6 rather than earlier. Do not start 4.6 until every row below — and
Tiers 0 and 1 with it — is closed or explicitly waived by the human, in writing, with the reason recorded.**
These are not cleanup. Each one either stops a cell, or — worse — lets a cell complete and report a number that
is wrong in a way nothing downstream can detect. **4.1b's rule applies here identically: a row is closed by
being executed with its evidence named, never by being read for.**

| # | Blocker | Where | Closed when |
|---|---|---|---|
| 6 | **cuFile path accounting** — a kvikIO cell without recorded GPU-direct-vs-bounced bytes is **incomplete** (**D8**); a config flag is not proof | `D-6` | a kvikIO cell's run dir contains the byte split **and the counters behind it were enabled and moved** on a known-good read. A present-but-all-zero split does **not** close this row — see the constraint below |
| 7 | **`LIBCUFILE_PRELOAD` located and exported** — every kvikIO driver refuses without it, and a wrong path is a silent no-op that runs the cell on the wrong libcufile. **This row gates the first kvikIO cell specifically**, not the sweep as a whole | `D-10` | `./env.sh --check` shows it, and the file exists |
| 8 | **GPU/NUMA/NIC map and core accounting re-derived** — the index lists in the drivers are 0-based placeholders; the reserved-core set is a per-filesystem parameter (**D15**) | `D-8`, `D-9` | measured on this instance and substituted |
| 9 | **Step 4.D actually recorded** — the 20× conversion is treated as a measured workload but currently produces no run dir at all | `D-15` | 4.D produces a run dir with telemetry |
| 10 | **Open-items section A resolved** (4.4) — every item there changes what the numbers *mean*. The items that govern an earlier cell are already closed under Tier 1 (the worker fixes, the read-sweep cache regime); the remainder closes here | the open-items memory, section A (*resolve before the first measured cell*) | each closed or waived |

> **Standing constraint — the nvidia-fs I/O counters are OFF by default, so a *present* byte split does not
> close row 6.** `/proc/driver/nvidia-fs/stats` reports `IO stats: Disabled, peer IO stats: Disabled` until
> `/sys/module/nvidia_fs/parameters/rw_stats_enabled` and `peer_stats_enabled` are set, and a kvikIO cell run
> that way records a split that is present and **entirely zero**. All-zeros reads as *"no GPU-direct traffic"*
> rather than *"the accounting was off"* — the same error as trusting a config flag, one level deeper, because
> an unenabled counter is itself a configuration state being mistaken for evidence. It lands on the wrong
> answer to the single question the GPU-direct matrix is designed around (**D8**), and nothing downstream can
> tell the two apart. **Close the row by enabling the counters, reading a known-good file, and showing the
> split move** — `Active Shadow-Buffer (MiB)` is the compat-mode bounce signal the split depends on. The stats
> block is version-stamped (`NVFS statistics(ver: …)`), so re-verify the field names against the cloud stack
> rather than assuming them.
>
> **On the WEKA leg the kernel counters do not carry the split at all** — NVIDIA documents `READ`/`WRITE`
> driver statistics as available for every filesystem *except* Weka — so Leg A's split comes from cuFile's own
> per-process accounting (`CUFILE_STATS` / `gds_stats`), whose per-GPU counters separate the P2P/nvfs path from
> the POSIX path. A zero *kernel* counter on Leg A is therefore expected, and is not evidence of compat mode.
> *Source:*
> [GDS installation and troubleshooting guide](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/index.html).

**Lustre-leg additions, closed before Leg B's first cell rather than discovered during it:**

| # | Blocker | Where |
|---|---|---|
| 11 | **Lustre client-side EFA configuration** — without it the client mounts over TCP, forfeiting GDS *and* the per-server-cap escape while still producing numbers. That breaks the "Lustre at maximum" fairness basis (**D7**) invisibly, and trips Tier 0 | `D-16` |
| 12 | **The kernel-vs-contract policy** — installing `linux-aws` can move the kernel, and `kernel` is a `MUST_MATCH` contract field, so the documented procedure can invalidate the comparison it protects | `D-17` |
| 13 | **Lustre tuning** — part of "Lustre at maximum"; skipping it understates Lustre | `D-11` |

**How to report this gate — twice, at the two points where it binds:**

1. **At the baseline greenlight (4.5):** Tier 0 and the Tier-1 table (4.1b). An open Tier-1 row means the
   baseline does not run, and a re-run baseline costs the whole sweep again.
2. **Before 4.6:** the full set — Tiers 0, 1 and 2, plus the Leg-B additions on Leg B.

Each row marked **closed / waived / open**, and **name the evidence** for every "closed". "Done" without
evidence is what this project's Rule 11 exists to forbid. If any row is still open, say so and stop — a leg run
on an open blocker costs more than the wait, because the cells look fine.

### 4.6 — Run the leg

**Gate: Tier 2 (4.5b) closed and the full gate reported and cleared before this step starts.**

Follow the dependency-ordered plan in `docs/STAGES.md`. Every cell goes through `scripts/record-run.sh`,
which takes the filesystem from `--fs` or from `$LEG`; every cell carries the **full measurement set plus
its wallclock and both date-stamped price inputs** (`docs/RUNBOOK.md`); both canaries every sweep; fill
numbers into the roadmaps as they land — **numbers and caveats only, no narrative.**

### 4.7 — Close out the leg

**Read `prompts/prompt-teardown-cloud.md` and do what it says** — it is the whole close-out procedure
(finish the roadmaps and `docs/RESULTS.md`, write `docs/cloud-setup/HANDOFF-NEXT-SESSION.md`, `./backup.sh`,
the environment contract, the verified S3 sync, then the GO/NO-GO gate), with the human owning only
commit+push and the destruction. `docs/cloud-setup/TEARDOWN-AND-REBUILD.md` § Teardown is the same sequence
written for them.

Two things there that are yours specifically and cannot be recovered later: **single-leg claims stay scoped as
half an unfinished comparison**, and the handoff must carry **everything this leg taught us that should change
the next one's plan** — the next leg's roadmap is explicitly provisional, and improving it from this leg's
findings is the point, not a deviation.

---

## Standing facts to carry

- **`--fs` is a dimension, not a fork.** One `runs/` tree; the filesystem is a run-dir segment and a
  `metadata.json` field; aggregators pivot on it.
- **No metric is designated primary.** Every cell reports the full measurement set (`docs/RUNBOOK.md`);
  which axis turns out to be decisive is a result, not a design input.
- **Cost is measured on every cell, never estimated.** Wallclock plus both price inputs, each stamped with
  the date it was checked, so cost-to-complete is computable per cell and per leg. Prices are fetched from
  current vendor pricing, never recalled — a stale price silently rewrites the conclusion.
- **Per-filesystem primaries.** WEKA: its own stats + the DPDK-path wire counters + app-level; the client's
  kernel network counters are **diagnostic**. Lustre: client `/proc/fs/lustre` + `lctl` + CloudWatch +
  app-level, **and the client's network counters ARE the data path.** Never quote a bypassed source.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell.**
- **Cold vs warm is an enforced axis, recorded as achieved, not asserted** — satisfied in **D13**'s order of
  preference, cold-by-construction first and an explicit doubled dimension only where it is informative and
  cheap. Any corpus that must exceed cache is sized against **both** filesystems' caches, so one identical
  corpus definition serves both legs.
- **kvikIO cells run in both cuFile modes on both filesystems** — that is what separates the filesystem
  effect from the transport effect. A cell without path accounting is incomplete.
- **`LD_PRELOAD` scoped per cell.** Nearly every sweep mixes kvikIO and cuCIM; cuCIM segfaults under a
  preloaded newer libcufile.
- **Three silent-skip hazards** (raw-TIFF converter, 6.A extractor, Tier-2 chunked conversion) reuse existing
  output **without failing loud**. Verify cleanup between runs.
- **Cross-leg integrity gates** — dataset bytes, coords, raw-TIFF dimensions, feature shapes are all
  storage-independent and must match across legs. A divergence is fail-loud.
- **MIL is canonical `batch_size=1` + `collate_MIL`**; concurrency via `num_workers`. Padded batching OOMs.
- **UNI2-h results stay internal-only** (`uni2h-conditional-use-status`) — don't strip the tags; filter
  before anything is externalised.
- **Git:** the human commits (one per stage) and pushes, and runs `./backup.sh` first. If you change
  memories, remind them.
- **Ephemerality:** both mounts and local scratch die with the instance, and **your context dies with it
  too.** Only git, the memory mirror, and S3 survive. Persist continuously.

## Open items to surface to the human (numbered list, a recommendation each)

1. The **discovery report** and anything broken or suboptimal — before mutating state.
2. **Corpus sizing for 6.B** (the open-items memory's 6.B corpus-sizing item) — needs a decision before
   generating anything.
3. The **baseline greenlight** (4.5) — new environment, new number; anchor on nothing prior. **Report Tier 0
   and the Tier-1 rows (4.1b) here with the evidence named**: the baseline is itself a kept cell.
4. **The full blocker gate — Tiers 0, 1 and 2** — before 4.6, every row marked closed / waived / open with the
   evidence named. Any open row means the leg does not start.
5. Any **client-reconfigure** proposal, the **dataset plan**, and the **script adaptations** — get sign-off on
   the mutating ones.
6. Any **methodology revisit** the real hardware justifies (concurrency ranges, GPU-count sweeps, the
   instance-size trigger), per the revisability rule.

## STEP 5 — Your first response

After the reading **and** the read-only discovery, give the human: what you understand the project to be, the
results of your deep sanity-check of their bootstrap and the hardware (what is solid, what is not), how this
instance differs from anything the docs assume, and the build plan you propose — with the open items above as
a plain-text numbered list, each with a recommendation.

**Surface problems and questions first.** Then, once you have sign-off, execute in order — environment →
dataset download to S3 (background; not a measured cell) → deferred script work → Stage-0 proof (**Tier 0
closed first**) → **Tier 1 closed (4.1b)** → 1.7 hydration → open-items section A → baseline (**stop for
greenlight; Tier 0 and Tier 1 reported there, row by row with evidence**) → **the full gate reported before
4.6, Tiers 0, 1 and 2** → the leg.

Do not build environments, mutate the client or filesystem, download datasets, or run any measured cell
before you have read everything, completed the read-only discovery, and gotten sign-off. **Run nothing at all
— not even the throwaway — until Tier 0 is closed; run no kept cell until Tier 1 is closed; start no sweep
until the full gate is reported and cleared.** A cell run on an open blocker looks identical to a good one, and
both the 1.7 hydration and the 4.5 baseline are kept cells that sit earlier in this order — which is why the
gate binds at three points rather than one.
