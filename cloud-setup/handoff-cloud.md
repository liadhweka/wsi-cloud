# Project handoff — WEKA vs Lustre on AWS (fresh cloud instance → build → run Leg A)

You are a fresh Claude Code session on a **newly provisioned AWS GPU instance**, working in this repo.
Assume commands run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance, same workload code, same datasets, **only the filesystem
under the mount point changes.** It runs as two sequential legs — **Leg A: WEKA (now)**, **Leg B: FSx for
Lustre (later)** — followed by the head-to-head synthesis.

**Nothing has been benchmarked. Every number in the repo is `[PENDING]`.** You are the first session to run
a cell.

**What the human has already done** (per `cloud-setup/NEW-CLOUD-SETUP.md`): provisioned the instance, the S3
bucket + IAM role, and the WEKA cluster; created the user, wired SSH↔GitHub, installed Claude, cloned this
repo, restored the memories, authenticated to Hugging Face, and mounted WEKA at `/mnt/weka`. A **prior
env-prep session** (`cloud-setup/prompt-env-prep-cloud.md`) verified the GPU/CUDA/GDS/networking stack,
installed miniforge, and provisioned `/data/local-nvme`.

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
  (every cell wraps in `runs/lib/record-run.sh`; time series not point estimates; multiple sources; **both
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
    that surfaces something new; move finished items to Resolved with the date.**
  - **`weka-vs-lustre-cloud-project`** — what the project is and why.
  - **`weka-vs-lustre-cloud-open-decisions`** — what is still *assumed*, with an index of every place each
    assumption is referenced. Keep the index current.
  - Plus the framing, MIL, cuCIM, and UNI2-h memories.
  - **If `MEMORY.md` is missing, STOP** and tell the human to run the restore block in
    `cloud-setup/NEW-CLOUD-SETUP.md` § B8. Do not proceed without the memories.

## STEP 2 — Read the project docs

- **`PROJECT-THESIS.md`** — the question, the held-constant contract, **both deliberate asymmetries**, scope.
- **`runs/STAGES.md`** — the stage map, the comparison structure, the GPU-direct matrix, the 20× contract,
  the per-filesystem adapter table, the per-leg plan, and the **decision log D1–D15**. Read the whole
  decision log; it is where the *why* of every methodology choice lives.
- **All seven `runs/Stage-<N>-*.md` roadmaps** — methodology, per-substage rationale, caveats.
- **`runs/README.md`** — the runbook, **both canaries**, the silent-skip hazards, the cross-leg integrity
  gates.
- **`SCRIPT-TRACKER.md`** — per-script reference, the **cross-cutting patterns** (eight hard-won ones; each
  exists because its absence caused a real failure), and the **`D-1` … `D-14` deferred-work table** that is
  most of your build job.
- **`FILESYSTEM-MAP.md`** and **`PRESENTING.md`**.

## STEP 3 — Where things stand

- **Docs and methodology: complete.** Scripts: **59 files, syntax-clean, copied intact — and still targeting
  a different environment and a single filesystem.**
- **What is missing is exactly the deferred work in `SCRIPT-TRACKER.md`'s table and section B of the
  open-items memory.** That is not incidental cleanup; **it is a hard prerequisite for a valid cell.**
- **Leg A is WEKA.** Leg B is FSx for Lustre, provisioned later. The instance is the same in both.

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

- **Python environments** from `cloud-setup/env-specs/` onto `/data/local-nvme/conda-envs/`. **Use conda, not
  pip, for cuCIM.** Verify imports (torch+CUDA, cupy, cucim, kvikio, openslide, tifffile, h5py, timm,
  transformers) and that the visible GPU count matches the hardware.
- **cuFile configuration for THIS instance** — instantiate the template with **this** instance's own
  addresses and the transport options the mounted filesystem needs. Follow
  `runs/lib/GDS-TUNING-CHECKLIST.md`, which currently carries a **`⏳ PENDING RETARGET`** banner listing what
  its rewrite must do — **rewriting it is deferred item `D-10` and is part of this step**, including adding
  the Lustre-over-EFA branch you will need for Leg B.
- **Client provisioning.** If discovery found the storage client under-provisioned, propose the fix and get
  sign-off — it is mount-disrupting, so ask first. **Then hold that configuration constant for the whole
  leg** and record it; a mid-leg change is a benchmark change and requires re-baselining.

### 4.2 — Datasets, once, into S3 — then hydrate

Download the datasets **once** to S3 via the tracked manifests in `runs/manifests/` (they are not on this
instance and not in git). Then hydrate onto `/mnt/weka` and **byte-verify**, failing loud on any mismatch.

**Why this order matters:** S3 is what makes the datasets a *held-constant input* — Leg B hydrates the same
bytes from the same place instead of re-downloading. The hydration itself is **measured cell 1.7**, so run it
through `record-run.sh` rather than as a side task. These are slow; start them in the background and do 4.3
while they run.

### 4.3 — The deferred script work (the core build task)

Work `D-1` … `D-14` from `SCRIPT-TRACKER.md` / open-items section B. **This is where the comparison's
validity is won or lost.** Priorities and traps:

- **`D-1` mount retargeting to `$FS_MOUNT` (36 files) is the highest-severity item.** A hardcoded mount makes
  a Lustre cell silently measure WEKA, and the number still looks correct — there is no failure signal. Do
  this thoroughly and grep to prove it.
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

Run the pre-cell canary, then capture the synthetic baseline **per block size** (`runs/lib/fe-core-fio.sh`,
`fe-core-kvikio.sh`). Confirm the post-cell canary is consistent. **Do not anchor on any number from any
prior environment.**

**Stop and get the human's greenlight on the baseline before Step 4.6.** It becomes the denominator for
every "% of ceiling" in the leg, so a wrong baseline propagates everywhere.

Also check the **pre-committed instance revisit trigger** (**D10**) here: if the ceiling pins at line rate
across block sizes *and* the concurrency sweeps saturate on CPU cores rather than storage, the instance is
measuring itself rather than the filesystem — surface that before Leg B rather than after.

### 4.6 — Run Leg A

Follow the dependency-ordered plan in `runs/STAGES.md`. Every cell through `record-run.sh` with `--fs weka`;
both canaries every sweep; fill numbers into the roadmaps as they land — **numbers and caveats only, no
narrative.**

### 4.7 — Close out Leg A

1. Fill in the roadmaps and `PRESENTING.md` — **still scoped as half an unfinished comparison.**
2. **Write the environment contract** to S3: instance type, region/AZ, AMI, kernel, driver/CUDA versions,
   dataset byte-manifest, script commit, and both filesystems' provisioned configuration.
3. `./backup.sh`, **verified S3 sync**, and tell the human it is ready for the stage commit — **they commit
   and push; never do it autonomously.**
4. **Write the Leg B handoff prompt**, including everything Leg A taught you that should change Leg B.

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
→ Leg A.

Do not build environments, mutate the client or filesystem, download datasets, or run any measured cell
before you have read everything, completed the read-only discovery, and gotten sign-off.
