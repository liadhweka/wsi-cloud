# Project handoff — WEKA vs Lustre on AWS (fresh cloud instance → build → run Leg A)

You are a fresh Claude Code session on a **newly provisioned AWS GPU instance**, working in this repo.
Assume commands run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance, same workload code, same datasets, **only the filesystem
under the mount point changes.** It runs as two sequential legs — **Leg A: WEKA (now)**, **Leg B: FSx for
Lustre (later)** — followed by the head-to-head synthesis.

**Nothing has been benchmarked. Every number in the repo is `[PENDING]`.** You are the first session to run
a cell.

> **If `docs/cloud-setup/HANDOFF-NEXT-SESSION.md` exists, read it before anything else** — and the sentence above is
> then out of date. That file is the *previous* session's own account of what it completed, what is
> mid-stage, and what it learned that should change the plan. It is written at teardown precisely because
> Claude's context does not survive one, so it outranks this prompt's assumptions about the current state.

**What the human has already done** (per `docs/cloud-setup/NEW-CLOUD-SETUP.md`): provisioned the instance (from a
pinned AMI — **verify in 4.0 that it actually carries the GPU stack**; the image choice was still an open
decision when this prompt was written, `C10`), the S3 bucket + IAM role, and the WEKA **backend cluster**;
wired SSH↔GitHub and set their git identity; installed Claude; cloned this repo; restored the memories
(`scripts/restore-memories.sh`); and filled in the decision-only half of `env.sh`.

**What two prior Claude sessions already did** — read their reports rather than re-deriving:
- **env-prep** (`prompts/prompt-env-prep-cloud.md`) verified the GPU/CUDA/GDS/networking stack, reported
  the system `libcufile` path, installed miniforge, and provisioned `/data/local-nvme`.
- **WEKA cluster setup** (`prompts/prompt-weka-cluster-cloud.md`) created the filesystem, installed the
  client, **mounted it at `/mnt/weka`**, and wrote the WEKA facts into `env.sh` — including `WEKA_EC_SCHEME`
  (without which the consistency canary cannot be derived) and `WEKA_CLIENT_CORES`. **`num_cores` is measured
  configuration, not a knob** (`D15`): do not change it mid-leg.
  > **If that session reported a UDP mount instead of DPDK — or could not evidence which — STOP AND REPORT
  > IMMEDIATELY. Do not run any cell, including a throwaway one.** Per **D16** the transport is a precondition
  > of the measurement, not a caveat to note in the writeup: a UDP mount produces a complete, plausible set of
  > numbers for a configuration this project decided not to measure. Only a written human waiver, with the
  > reason recorded, changes that.

The Leg-B equivalent, `prompts/prompt-lustre-cluster-cloud.md`, runs before Leg B and is not your concern
now — but its two hard gates (an EFA-not-TCP mount, and the kernel-vs-contract question) are why Leg A's
contract must be written completely.

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

Two rules that follow, and that you will be tempted to bend:

1. **Results precede story.** No document may gain a predicted outcome, an expected magnitude, or a
   pre-assigned "headline" stage. Record the WHY of every method; record nothing about what numbers will
   show. Interpretation sections stay `[STORY PENDING RESULTS]` until results exist. **Report losses.**
2. **Nothing is portable.** Every path, address, version, core count, GPU map, batch-size schedule, and
   tuning value in this repo's scripts came from a different environment. **Re-derive, never copy.**

---

## STEP 1 — Read the governing instructions first

- **`CLAUDE.md`** — the project constitution. Especially: the **11 Rules**; **recording is non-negotiable**
  (every cell wraps in `scripts/record-run.sh`; time series not point estimates; multiple sources; **both
  canaries every sweep**); **per-filesystem source adapters** (the client's network counters are
  *diagnostic* on the WEKA leg and *primary* on the Lustre leg — get this wrong and every number cites a
  bypassed source); **Durability & backup** (both mounts and local scratch are ephemeral; git and S3 have
  non-overlapping authority); **reference official docs, not training data** (doc-fetch is standing-approved);
  **record the WHY everywhere**; the **docs-cadence table**; **where unresolved items live**; the **framing
  rules**; **memory hygiene**; and **plan-first / the four pause triggers / safety** (ask before any sudo,
  mount, install, or destructive operation; surface decisions as a plain-text numbered list with a
  recommendation each — **not** the AskUserQuestion picker).
- **All memories, end to end.** `MEMORY.md` first, then every file. Load-bearing:
  - **`cloud-session-open-items`** — **your work list.** Section A must be resolved before the first
    measured cell; section B is what you build; section C is what you watch. **Add to it in the same edit
    that surfaces something new; DELETE an item when it is done** — that file holds only open items, and
    completions are recorded in the relevant doc instead.
  - **`weka-vs-lustre-cloud-project`** — what the project is and why.
  - **`weka-vs-lustre-cloud-open-decisions`** — what is still *assumed*, with an index of every place each
    assumption is referenced. Keep the index current.
  - Plus the framing, MIL, cuCIM, and UNI2-h memories.
  - **If `MEMORY.md` is missing:** run `./scripts/restore-memories.sh` yourself — the mirror is in-repo
    and the script verifies the result — then report its output and **ask the human to restart the session**
    so the memories actually load. **Do not proceed on this session's context**; that is the failure this
    check exists to catch. If the script *refuses* — empty mirror, or no `MEMORY.md` in it — **STOP and
    report**: that means the mirror itself is broken, and no restore can fix it. **Do not proceed without the
    memories** either way. (`NEW-CLOUD-SETUP.md` § 4.3 is the human-facing version of the same one-liner.)

## STEP 2 — Read the project docs

- **`PROJECT-THESIS.md`** — the question, the held-constant contract, **both deliberate asymmetries**, scope.
- **`docs/STAGES.md`** — the stage map, the comparison structure, the GPU-direct matrix, the 20× contract,
  the per-filesystem adapter table, the per-leg plan, and the **decision log D1–D16**. Read the whole
  decision log; it is where the *why* of every methodology choice lives.
- **All seven `docs/Stage-<N>-*.md` roadmaps** — methodology, per-substage rationale, caveats.
- **`docs/RUNBOOK.md`** — the runbook, **both canaries**, the silent-skip hazards, the cross-leg integrity
  gates.
- **`docs/SCRIPT-TRACKER.md`** — per-script reference, the **cross-cutting patterns** (eight hard-won ones; each
  exists because its absence caused a real failure), and the **deferred-work table** (`D-4`…`D-24`) that is
  most of your build job — plus the table above it recording what was already completed and how it was
  verified.
- **`docs/NAMING-AND-VARIABLES.md`** — **read this before touching any script.** Every path, name, and
  identifier that varies between environments, with a recommended value, split into *decide now* / *record at
  provisioning* / *derived*. Its companion `env.example.sh` → `env.sh` is how configuration reaches the
  scripts, and `./env.sh --check` validates the whole set before anything runs. **Nothing is
  hardcoded; nothing silently defaults.**
- **`docs/FILESYSTEM-MAP.md`** and **`docs/RESULTS.md`**.

## STEP 3 — Where things stand

- **Docs and methodology: complete.** Scripts: **63 files** (32 shell + 29 Python + a cuFile template +
  the GDS checklist), all syntax-clean. Mount/repo retargeting, filesystem labelling, the environment
  contract, the leg orchestrator, and the S3 sync layer were **already done on the build machine** — every
  script resolves the mount through `$FS_MOUNT`, builds its interpreter from `$CONDA_ENVS_DIR`, reads
  `$LIBCUFILE_PRELOAD`, and **aborts loudly if any of them is unset**, rather than defaulting.
- **How a cell is labelled:** the sweep drivers take **no arguments**. `record-run.sh` accepts `--fs` and
  falls back to `$LEG`; both it and `run-leg.sh` cross-check the label against `FS_MOUNT` and refuse on
  disagreement. Every pre-computed run-dir name carries the `-<leg>-` segment, which is **load-bearing**:
  `sync-to-s3.sh` and `teardown-preflight.sh` glob `runs/*-$LEG-s*/`, so a dir without it is never backed up
  and the teardown gate does not notice.
- **What is missing is exactly the deferred work in `docs/SCRIPT-TRACKER.md`'s table.** That table is the
  single register for it — the open-items memory deliberately does **not** duplicate the list, it points here.
  This is not incidental cleanup; **it is a hard prerequisite for a valid cell.**
- **Leg A is WEKA.** Leg B is FSx for Lustre, provisioned later. The instance is the same in both.

### Is this a first build or a rebuild? Route accordingly.

This prompt is pasted on **every** build — first spin-up, cost pause, and the Leg-A→Leg-B switch. The two
states differ, so establish which you are in **during 4.0** rather than assuming: `docs/cloud-setup/HANDOFF-NEXT-SESSION.md`
exists → **rebuild**; `git log` shows commits after this prompt was written → **rebuild**;
`runs/INDEX.md` has rows → **rebuild**.

| On a **rebuild** | Because |
|---|---|
| **4.1 build the environment — REDO** | the conda envs lived on ephemeral scratch. Use the pinned `*.conda-explicit.txt`, not the loose recipe: `conda_env_main` and `python_version` are held-constant contract fields |
| **4.2 datasets — RE-HYDRATE, don't re-download** | S3 holds them; the mount is what died. Byte-verify against the manifest |
| **4.3 the deferred script work — VERIFY, don't redo** | it is committed to git and arrived with the clone. Re-run its checks; only build what `docs/SCRIPT-TRACKER.md` still marks deferred |
| **4.4 open-items section A — CONTINUE** | the memory holds only what is *still* open, so it is already the correct work list |
| **4.5 baseline — only if the hardware or the mount configuration changed** | otherwise the previous leg's baseline stands, and re-taking it burns wallclock. Say which you concluded and why |
| **4.5b the blocker gate — ALWAYS** | it gates the first *measured* cell, not the first build |
| **4.6 run the leg — RESUME** | `run-leg.sh --leg $LEG` skips steps whose markers are in `runs/.leg-state/$LEG/`, which is git-tracked and therefore survived. **If the marker dir is empty on a mid-leg rebuild, stop and say so** — that means the previous teardown did not commit them, and blindly re-running would duplicate hours of cells |

**`HANDOFF-NEXT-SESSION.md` outranks this file on anything about current state.** It was written by the
previous session, which knew things this prompt cannot: what was mid-flight, what failed, and what it learned
that should change the plan.

---

## STEP 4 — What to do, in order

### 4.0 — Deep read-only discovery (FIRST; mutate nothing)

Produce a written discovery report. Cover at least:

- **Continuity:** user + sudo; repo integrity (`git status`, `git remote -v`, `git log -1` vs origin);
  **memories restored** (count the files, confirm `MEMORY.md`); `.claude/settings.json` present;
  `ssh -T git@github.com`; Hugging Face auth; miniforge present.
- **Hardware:** GPU model/count/memory; **GPU↔NUMA↔NIC affinity**; NUMA nodes and core counts; network
  interfaces, types, link rates, and addresses; EFA presence and versions. **Record how this differs from
  anything the docs assume** — those deltas drive every "re-derive" action below.
- **The WEKA mount and client:** is `/mnt/weka` mounted, with what options, and — crucially — **how many
  cores and which NICs the client is bound to.** Flag under-provisioning. Confirm the cluster is healthy,
  and **capture the provisioned configuration** (backend type/count, capacity, EC scheme, networking mode)
  into what will become the environment contract. Confirm ownership and do a tiny **recorded** read/write
  smoke test.
- **GDS stack:** tool presence, `nvidia-fs` and `libcufile` versions **and whether they match**, peer-memory
  module loaded, and what `gdscheck` reports. **Do not conclude from a config flag whether true GDS is
  active** — that is settled empirically in 4.3.
- **Local scratch + OS hygiene:** `/data/local-nvme` mounted with ≥~2 TB free; `/dev/shm` mode 1777; free
  space on `/`.
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
  | `env-create-history.txt` | **The recipe** — the actual `mamba create` / `mamba install` commands, with loose pins (`cucim=26.04.00`, `cuda-version=12.*`, `pytorch=*=cuda*`) | **Building the FIRST environment on a new instance.** It re-solves against this instance's CUDA, so it is the route most likely to succeed |
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

  Remind the human to do the **Hugging Face login** (`NEW-CLOUD-SETUP.md` § 7.2) as soon as the environments
  exist: `hf` does not exist before this step, one model is access-gated, and the failure surfaces deep inside a
  Stage-6 cell.
- **cuFile configuration for THIS instance** — instantiate the template with **this** instance's own
  addresses and the transport options the mounted filesystem needs. Follow
  `scripts/GDS-TUNING-CHECKLIST.md`, which currently carries a **`⏳ PENDING RETARGET`** banner listing what
  its rewrite must do — **rewriting it is deferred item `D-10` and is part of this step**, including adding
  the Lustre-over-EFA branch you will need for Leg B.
- **Client provisioning.** If discovery found the storage client under-provisioned, propose the fix and get
  sign-off — it is mount-disrupting, so ask first. **Then hold that configuration constant for the whole
  leg** and record it; a mid-leg change is a benchmark change and requires re-baselining.

### 4.2 — Datasets, once, into S3 — then hydrate

Download the datasets **once** to S3 via the tracked manifests in `scripts/manifests/` (they are not on this
instance and not in git). Then hydrate onto `/mnt/weka` and **byte-verify**, failing loud on any mismatch.

**Why this order matters:** S3 is what makes the datasets a *held-constant input* — Leg B hydrates the same
bytes from the same place instead of re-downloading. The hydration itself is **measured cell 1.7**, so run it
through `record-run.sh` rather than as a side task. These are slow; start them in the background and do 4.3
while they run.

### 4.3 — The deferred script work (the core build task)

Work **`D-4` … `D-24`** from the deferred-work table in `docs/SCRIPT-TRACKER.md` — the single register for
this work. **This is where the comparison's validity is won or lost.**

> ### `docs/SCRIPT-TRACKER.md` is yours, and rewriting it is part of this task
>
> The docs-audit session was **explicitly forbidden** from touching it, because it describes scripts that were
> about to change — you are the one changing them. So the tracker is stale by design until you fix it, and
> **it is not done when the scripts work; it is done when the tracker matches them.**
>
> That means, per `CLAUDE.md`:
> - **Every entry you complete comes out of the deferred table** and into the per-script reference — what it
>   does **and why**, its inputs and outputs, its caveats. A `D-n` left listed after completion gets redone.
> - **No change log.** Git is the audit trail.
> - **Any decisions become a register** — live decisions only, each justified on its own terms, never dated and
>   never as a contrast with what it replaced.
> - **Remove what no longer applies.** The tracker still carries references to the previous project era that
>   the docs session deliberately left for you.
> - The **cross-cutting patterns** stay: each one exists because its absence caused a real failure, so each is
>   a standing constraint, not history.

Priorities and traps:

- **Do not redo `D-1`/`D-2`/`D-3`/`D-12`/`D-14`** — they are complete, with what was done and how it was
  verified recorded in `docs/SCRIPT-TRACKER.md` § "Done before leaving the build machine". Re-grep to satisfy
  yourself (a hardcoded mount makes a Lustre cell silently measure WEKA and the number still looks correct),
  but the work itself is done.
- **`D-4` per-filesystem recording adapters (13 aggregators).** Write them against the **real** telemetry
  schemas. Preserve the **per-timestamp client-summing pattern** (a naive pre-aggregated mean under-reports
  by ~100×) and filter by a stable identity, never a numeric node id.
- **`D-5` derive each filesystem's consistency relation** — WEKA from the actual EC scheme, Lustre from the
  actual stripe layout. **Never port one across.** The canary cannot run without this.
- **`D-6` cuFile path accounting** as a mandatory per-cell source. **Then settle the empirical question:
  does WEKA on this instance do true GDS or fall back to compat?** Use `gdscheck` plus a recorded canary
  cell. Either answer is usable — the Stage 4 matrix is built for both — but it must be *measured*.
- **`D-7` S3 sync + per-cell watchdog + canary-aborts-the-chain** before any unattended run. A 3am canary
  failure that waits to be noticed produces hours of contaminated cells that look fine.
  **`scripts/sync-to-s3.sh` already exists** and implements both sync semantics — but it carries an
  **`UNVERIFIED AGAINST A REAL BUCKET`** banner. **Run the 7-step FIRST-RUN PROCEDURE in its header before
  trusting it, then remove the banner.** Step 6 is the one that matters: prove that a file deleted locally
  under an *archive* path does **not** disappear from S3. What is still missing is wiring `--mode run` into
  `record-run.sh`, the per-cell watchdog, and the canary abort.
- **`D-8`/`D-9` re-derive the GPU/NUMA map, the GPU-count ranges, and the core accounting** — including how
  many cores the storage client reserves, which is a per-filesystem parameter and part of that filesystem's
  reported cost (**D15**).

**Then prove the pipeline end-to-end on a throwaway Stage-0 cell** before spending real wallclock: recording
complete, both canaries functional, S3 sync verified, `INDEX.md` row correct, aggregator produces a row
pivoted on `--fs`.

### 4.4 — Resolve open-items section A

Every item in section A changes what the numbers *mean*, so resolving them after cells have run means
re-running cells. Two deserve special attention:

- **The sub-second-cell sampling question** — decide it, and apply the same decision to both legs.
- **Corpus sizing for Stage 6.B (item 5b)** — **this one must be settled before Leg A generates anything.**
  The corpus has to defeat *two* caches, and the second differs per filesystem, so sizing it needs Leg B's
  cache size even though Leg B runs later. Recommendation is in the item; surface it to the human.

### 4.5 — Baseline, then STOP for greenlight

Run the pre-cell canary, then capture the synthetic baseline **per block size** — that means the Stage 1.0
sweeps (`sweep-stage1-{seqw,seqr,randw,randr}.sh`), which are the cells every downstream "% of ceiling"
divides by. `fe-core-fio.sh` / `fe-core-kvikio.sh` are **single-cell spot checks at one fixed
configuration**, useful for a quick recorded reference point but **not** the per-block-size ceiling. Confirm
the post-cell canary is consistent. **Do not anchor on any number from any prior environment.**

**Stop and get the human's greenlight on the baseline before Step 4.6.** It becomes the denominator for
every "% of ceiling" in the leg, so a wrong baseline propagates everywhere.

Also check the **pre-committed instance revisit trigger** (**D10**) here: if the ceiling pins at line rate
across block sizes *and* the concurrency sweeps saturate on CPU cores rather than storage, the instance is
measuring itself rather than the filesystem — surface that before Leg B rather than after.

### 4.5b — THE BLOCKER GATE: close these before the first measured cell

**Do not start 4.6 until every line below is either closed or explicitly waived by the human, in writing, with
the reason recorded.** These are not cleanup. Each one either stops a cell, or — worse — lets a cell complete
and report a number that is wrong in a way nothing downstream can detect. A pre-deployment audit
were found by grep and execution rather than by reading, which is exactly why
a checklist is needed rather than a careful re-read.

| # | Blocker | Where | Closed when |
|---|---|---|---|
| 1 | **Per-filesystem recording adapters** — the current recorder set and required-stream list are the WEKA-over-InfiniBand ones, so on AWS the IB streams are empty and **every run marks `INCOMPLETE`** | `D-4` | a cell records this leg's real Primary sources and `INDEX.md` says `OK` |
| 2 | **Per-filesystem consistency relation** — the canary cannot evaluate without it, and it must be derived, never ported | `D-5` | the post-cell canary passes on a real cell, with the derivation written down |
| 3 | **cuFile path accounting** — a kvikIO cell without recorded GPU-direct-vs-bounced bytes is **incomplete** (**D8**); a config flag is not proof | `D-6` | a kvikIO cell's run dir contains the byte split |
| 4 | **The nine worker measurement bugs** — each yields a plausible wrong number: latency measured before the I/O wait, uninitialised GPU memory saved as features, per-second rates not divided by dt, and six more | open item `A.9b` | each fixed and re-verified against a real cell |
| 5 | **`LIBCUFILE_PRELOAD` located and exported** — every kvikIO driver refuses without it, and a wrong path is a silent no-op that runs the cell on the wrong libcufile | `D-10` | `env.sh --check` shows it, and the file exists |
| 6 | **GPU/NUMA/NIC map and core accounting re-derived** — the index lists in the drivers are 0-based placeholders; the reserved-core set is a per-filesystem parameter (**D15**) | `D-8`, `D-9` | measured on this instance and substituted |
| 7 | **1.7 hydration driver built** — `run-leg.sh` reports it MISSING and aborts rather than skipping | `D-13` | step 1.7 runs and the datasets byte-verify |
| 8 | **Step 4.D actually recorded** — `convert-stage4c-rawtiff.sh` never calls `record-run.sh`, so the 20× conversion produces no run dir at all | `D-15` | 4.D produces a run dir with telemetry |
| 9 | **Open-items section A resolved** (4.4) — every item there changes what the numbers *mean* | section A | each closed or waived |

**Leg-B-only, and they must be closed before Leg B's first cell, not discovered during it:**

| # | Blocker | Where |
|---|---|---|
| 9e | ⛔ **The transport this leg is actually on, evidenced** — WEKA on **DPDK** (not UDP), Lustre on **EFA** (not TCP), per **D16**. Not the mount options you passed; the client's own report. **This row is a STOP, not a caveat**: if the evidence is missing or shows the fallback, run **nothing at all** — not even the throwaway pipeline-proof cell — and report immediately. A fallback transport yields a complete, plausible dataset for a configuration this project decided not to measure, so "measure now, flag later" spends the wallclock and the money before anyone can act | `D-16`, **D16** |
| 10 | **Lustre client-side EFA configuration** — without it the client mounts over TCP, forfeiting GDS *and* the per-server-cap escape while still producing numbers. That breaks the "Lustre at maximum" fairness basis (**D7**) invisibly | `D-16` |
| 11 | **The kernel-vs-contract policy** — installing `linux-aws` can move the kernel, and `kernel` is a `MUST_MATCH` contract field, so the documented procedure can invalidate the comparison it protects | `D-17` |
| 12 | **Lustre tuning** — part of "Lustre at maximum"; skipping it understates Lustre | `D-11` |

**How to report this gate:** before 4.6, give the human the table above with each row marked
closed / waived / open, and **name the evidence** for every "closed". "Done" without evidence is what this
project's Rule 11 exists to forbid. If any row is still open, say so and stop — a leg run on an open blocker
costs more than the wait, because the cells look fine.

### 4.6 — Run Leg A

Follow the dependency-ordered plan in `docs/STAGES.md`. Every cell goes through `record-run.sh`, which takes
the filesystem from `--fs` or from `$LEG`; both canaries every sweep; fill numbers into the roadmaps as they
land — **numbers and caveats only, no narrative.**

### 4.7 — Close out Leg A

**Read `prompts/prompt-teardown-cloud.md` and do what it says** — it is the whole close-out procedure
(finish the roadmaps and `docs/RESULTS.md`, write `HANDOFF-NEXT-SESSION.md`, `./backup.sh`, the environment
contract, the verified S3 sync, then the GO/NO-GO gate), with the human owning only commit+push and the
destruction. `docs/cloud-setup/TEARDOWN-AND-REBUILD.md` § Teardown is the same sequence written for them.

Two things there that are yours specifically and cannot be recovered later: **single-leg claims stay scoped as
half an unfinished comparison**, and the handoff must carry **everything this leg taught us that should change
the next one's plan** — Leg B's roadmap is explicitly provisional, and improving it from Leg A's findings is
the point, not a deviation.

---

## Standing facts to carry

- **`--fs` is a dimension, not a fork.** One `runs/` tree; the filesystem is a run-dir segment and a
  `metadata.json` field; aggregators pivot on it.
- **Per-filesystem primaries.** WEKA: its own stats + the DPDK-path wire counters + app-level; the client's
  kernel network counters are **diagnostic**. Lustre: client `/proc/fs/lustre` + `lctl` + CloudWatch +
  app-level, **and the client's network counters ARE the data path.** Never quote a bypassed source.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell.**
- **Cold vs warm is an enforced axis, recorded as achieved, not asserted.**
- **kvikIO cells run in both cuFile modes on both filesystems** — that is what separates the filesystem
  effect from the transport effect. A cell without path accounting is incomplete.
- **`LD_PRELOAD` scoped per cell.** Nearly every sweep mixes kvikIO and cuCIM; cuCIM segfaults under a
  preloaded newer libcufile.
- **Three silent-skip hazards** (raw-TIFF converter, 6.A extractor, Tier-2 chunked conversion) reuse existing
  output **without failing loud**. Verify cleanup between runs.
- **Cross-leg integrity gates** — dataset bytes, coords, raw-TIFF dimensions, feature shapes are all
  storage-independent and must match across legs. A divergence is fail-loud.
- **MIL is canonical `batch_size=1` + `collate_MIL`**; concurrency via `num_workers`. Padded batching OOMs.
- **UNI2-h results stay internal-only** — don't strip the tags; filter before anything is externalised.
- **Git:** the human commits (one per stage) and pushes, and runs `./backup.sh` first. If you change
  memories, remind them.
- **Ephemerality:** both mounts and local scratch die with the instance, and **your context dies with it
  too.** Only git, the memory mirror, and S3 survive. Persist continuously.

## Open items to surface to the human (numbered list, a recommendation each)

1. The **discovery report** and anything broken or suboptimal — before mutating state.
2. **Corpus sizing for 6.B** (open item 5b) — needs a decision before generating anything.
3. The **baseline greenlight** (4.5) — new environment, new number; anchor on nothing prior.
3b. **The blocker gate (4.5b)** — the 9 Leg-A rows and 3 Leg-B rows, each marked closed / waived / open with
   the evidence named. Any open row means Leg A does not start.
4. Any **client-reconfigure** proposal, the **dataset plan**, and the **script adaptations** — get sign-off on
   the mutating ones.
5. Any **methodology revisit** the real hardware justifies (concurrency ranges, GPU-count sweeps, the
   instance-size trigger), per the revisability rule.

## STEP 5 — Your first response

After the reading **and** the read-only discovery, give the human: what you understand the project to be, the
results of your deep sanity-check of their bootstrap and the hardware (what is solid, what is not), how this
instance differs from anything the docs assume, and the build plan you propose — with the open items above as
a plain-text numbered list, each with a recommendation.

**Surface problems and questions first.** Then, once you have sign-off, execute in order — environment →
datasets → deferred script work → Stage-0 proof → open-items section A → baseline (**stop for greenlight**)
→ **the blocker gate (4.5b), reported row by row with evidence** → Leg A.

Do not build environments, mutate the client or filesystem, download datasets, or run any measured cell
before you have read everything, completed the read-only discovery, and gotten sign-off. **And do not run a
measured cell before the 4.5b blocker gate is reported and cleared** — a cell run on an open blocker looks
identical to a good one.
