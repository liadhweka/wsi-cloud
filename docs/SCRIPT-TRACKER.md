# Script tracker — per-script reference for `../scripts/`

> **Configuration comes from the environment, never from hardcoded literals.** Every variable is enumerated
> in **`NAMING-AND-VARIABLES.md`** with its recommended value, and set via **`../env.example.sh`** → `env.sh`
> (which has a `--check` mode that validates before anything runs). **Read that doc before editing any
> script** — it is the single source of truth for names, and the reason `$FS_MOUNT` exists.
>
> The remaining per-filesystem adapter and environment-value work is listed under **Deferred work** below.
> Retargeting itself is complete — see the two "Done" tables.

For *what* each stage is see `STAGES.md`; for how to run a cell `RUNBOOK.md`; for where things live
`FILESYSTEM-MAP.md`; for the rules `../CLAUDE.md`.

---

## How to read this doc

Every entry gives **what it does**, **why it exists** (the methodology rationale, not just the mechanics),
its **inputs → outputs**, and any **caveats** — the non-obvious behaviour that costs debugging time if
forgotten. Scripts are grouped by stage, after the cross-stage infrastructure they all depend on.

**Deferred work is marked `⏳ DEFER`** and is also tracked in the `cloud-session-open-items` memory, so it
cannot be lost by living only here.

---

## ⚠️ Deferred work — what must change before anything runs

None of this could be done meaningfully before the environment exists. All of it is a **hard prerequisite**
for a valid cell.

### ✅ Done before leaving the build machine

These were mechanical rather than environment-dependent, so they were completed here to shorten the cloud
session's critical path — and because each has a **silent** failure mode that a guard can convert into a loud
one.

| # | Work | What was done | Verification |
|---|---|---|---|
| **D-1** | Mount retargeting to `$FS_MOUNT` | `/mnt/liad` → `${FS_MOUNT}` in **25 shell files**; the **7 real Python argparse defaults** across **4 files** rewritten to derive from `FS_MOUNT`, each with a fail-loud guard | `grep`: **0 files** retain the old mount path; the 4 Python files exit with `FATAL: FS_MOUNT is unset` |
| **D-2** | Repo-root retargeting | The hardcoded `REPO=` line in **28 shell files** replaced with derivation from the script's own location; 14 further files cleaned of other absolute paths | `grep`: **0 files** retain the old repo path |
| **D-3** | Filesystem labelling | `record-run.sh` **requires** the filesystem, takes `--fs {weka\|lustre}` and **falls back to `$LEG`** when the flag is absent (so the argument-free sweep drivers work), puts it in the run-dir name and as a first-class `metadata.json` field, and **cross-validates it against `FS_MOUNT`** | All paths tested: neither set, invalid, `--fs` vs `FS_MOUNT` mismatch, `LEG` vs `FS_MOUNT` mismatch, agreeing — each exits 2 with the right message |
| **D-12** | Environment contract | `env-contract.py` — `write` / `verify` / `show`, with the **held-constant vs expected-to-differ field split** that makes verification meaningful | Round-tripped: 0 violations, unrecorded fields correctly reported as *unverifiable* and failing |
| **D-14** | Leg orchestrator | `run-leg.sh` — 22 steps in dependency order, with all five unattended guards | `--list`, `--dry-run`, and every refusal path tested (incl. the **D16** transport gate: unset, wrong-transport, waived, correct) |

### ✅ Done during the pre-deployment audit

Found by auditing the above against the actual code. Each was a case of the mechanism being right in one
place and missing in others — the class of defect that produces a plausible-looking wrong number.

| # | Work | What was wrong | What was done |
|---|---|---|---|
| **A-1** | Run-dir names lacked the filesystem segment | **9 drivers** pre-computed run-dir names as `<ts>-s<stage>-<name>`, with no `-<leg>-`. `sync-to-s3.sh` and `teardown-preflight.sh` both glob `runs/*-$LEG-s*/`, so **every cell from those sweeps would never reach S3 and the teardown gate would still say GO** | `${LEG}` inserted into all **21** pre-computed names; a `: "${LEG:?…}"` guard added to all 9 drivers |
| **A-2** | Pre-computed run dir never handed to the wrapper | `sweep-stage4c-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6c.sh` and `sweep-stage6a-extract.sh`'s `smoke()` interpolated `$run_dir/…` into the child's arguments but never set `RECORD_RUN_DIR` — so the child `mkdir -p`'d an **orphan directory** and wrote the cell's app-level primary source there, outside the run dir (cross-cutting pattern **#4**, applied in 6 places and missing in 4) | `RECORD_RUN_DIR="$run_dir"` added to all 4; invariant now checked mechanically |
| **A-3** | `0_README.md` was always empty | `record-run.sh` referenced `${REPO}`, which D-2 removed. Under `set -u` the heredoc redirection failed, so the file was created at **0 bytes on every run** | Derives `REPO_ROOT` from its own location; title and `INDEX.md` line now carry the `-<fs>-` segment and match the dir exactly |
| **A-4** | Conda interpreter path hardcoded | `CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604` literal in **16 drivers** — documented nowhere, and it happens to match the *planned* value, so it would work until it silently didn't | New `CONDA_ENVS_DIR` (Table 1) + fail-loud derivation from `$CONDA_ENV_MAIN` / `$CONDA_ENV_ALT` |
| **A-5** | libcufile path hardcoded to another machine | `LIBCUFILE_117=/usr/local/cuda-13.2/…/libcufile.so.1.17.0` in **8 files**, and **5 of them never checked the file exists** — a missing preload is a silent no-op, so the GPU-direct cells would run on the conda-bundled libcufile and still report numbers | All 8 read the documented `$LIBCUFILE_PRELOAD`, refuse if unset, and verify the file exists |
| **A-6** | Local-scratch paths hardcoded | `/data/local-nvme/...` literals for the fpsync source and the 4.B pool cache in 5 drivers | Derived from `$SCRATCH_DIR`, fail-loud |
| **A-7** | Prior-environment results and narrative inside recorded notes | Cell `--note` strings — written into every run's `metadata.json` and `0_README.md` — carried measured figures from another environment, a previous host's NUMA/NIC map, WEKA-only source lists, and pre-assigned conclusions (one asserted an outcome outright). A `../PROJECT-THESIS.md` §10 framing violation embedded in the results themselves | All notes rewritten leg-agnostic, with the methodology *why* kept and every prior number and expectation removed |
| **A-8** | Contract never reached S3 | `sync-to-s3.sh` had no `env-contracts/` path, yet `teardown-preflight.sh` NO-GOes without it and Leg B fetches Leg A's contract from there | Added, with archive (never-delete) semantics |
| **A-9** | Duplicated held-constant field list had drifted | `teardown-preflight.sh` checked **9** fields against the contract's **17** — it would call a contract "complete" that `env-contract.py write` had itself rejected | Imports `MUST_MATCH` from `env-contract.py`; one source of truth |
| **A-10** | `runs/.leg-state/` markers had no durable home | `run-leg.sh`'s per-step done-markers are the only thing that stops a resumed leg re-running completed steps, and `teardown-preflight.sh` NO-GOes on a dirty tree — so they were neither committed nor synced, and died with the instance. A rebuilt `run-leg.sh` would silently redo hours of sweeps into duplicate run dirs while the rebuild doc claimed it "picks up where it stopped" | **git-tracked** — git is authoritative for small text (`../CLAUDE.md`), and teardown step 5's `git add -A` captures them at exactly the point they need capturing |
| **A-11** | `run-leg.sh` could not execute 7 of its steps | It invoked each driver bare, but seven dispatch on `$1` and exit 2 with a usage message when given none — the chain would have aborted at step 4.C. `--from`/`--only` were also unvalidated, so a typo silently skipped every step and exited **0** | Each step carries its target with the choice justified inline; the runner word-splits it; both selectors validated against the step-id list. **A missing step surfaced in the process: `sweep-stage6a-extract.sh tier3` existed but nothing ran it**, so 6.A Tier 3 was absent from every leg — now step `6.A.3`. 22 steps |
| **A-12** | Stage-7 aggregator matched zero cells | Its regex anchored `-s7-` to the timestamp and its glob missed `-s7.N-`. Partly *caused* by `A-1`: it was the only aggregator anchoring on the timestamp, which is why the re-verification pass exists | Stage part unanchored, sub-stage optional, glob widened; 5 naming cases tested |
| **A-13** | Four smaller confirmed defects | `sweep-stage1-mixed.sh` called `fio` at `/usr/local/bin/fio` while all four siblings use bare `fio` and apt installs `/usr/bin/fio`; `inference-per-slide-stage7.py` silently defaulted to GPU 2 (an index encoding a previous machine's NIC adjacency); `sweep-stage6b-stress.sh` understated `b2c` as 3 cells and `all` as 24 (really 4 and 25); both Tier-2 orchestrators justified `CHUNK_SIZE` with another environment's capacity | Path made bare; the GPU pin now **refuses** rather than defaulting (all four callers pin it explicitly); counts corrected; capacity figures removed and re-derivation tracked as open item **9d** — the *value* still needs the real capacity |

**The safety property common to all of them:** an unset or inconsistent mount now **aborts loudly** instead of
defaulting. That converts this project's worst failure mode — *silently measures the wrong filesystem while
the number still looks correct* — into *refuses to run*.

### ⏳ Still deferred — genuinely needs the real environment

| # | Work | Scope | Why it can't be done yet |
|---|---|---|---|
| **D-4** | **Per-filesystem recording adapters** | `record-run.sh`, `parse-results.py`, **13 aggregators** that assume one filesystem's telemetry | Each filesystem exposes different primary sources with different **schemas** (**D12**). Requires the real stats output to write against |
| **D-5** | **Per-filesystem consistency relation** | The canary logic in the aggregators | Must be derived from the actual EC scheme (WEKA) and the actual stripe layout (Lustre) — neither exists yet |
| **D-6** | **cuFile path accounting as a recorded source** | `record-run.sh` + the kvikIO readers. **`aggregate-stage4c-kvikio.py` is the concrete consumer:** its `gds_engaged` column is hardcoded `"unknown"` and stays that way until this source exists — so closing D-6 has a defined finish line, namely that column carrying a recorded value | Needs the real cuFile/nvidia-fs stats format. Every kvikIO cell must record GPU-direct-vs-bounced bytes or it is incomplete (**D8**) |
| **D-7** | **During-run sync, watchdog, canary-abort** | `record-run.sh` | **Partly done:** `sync-to-s3.sh` exists and `run-leg.sh` syncs after every step. Still needed: per-**cell** sync inside `record-run.sh`, the per-cell watchdog timeout, and making the canary abort the chain |
| **D-8** | **GPU/NUMA map + DDP ranges** | `run-multiproc-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6a-extract.sh`, `sweep-stage7-clinical.sh` | The GPU↔NUMA↔NIC map must be re-derived on the real instance; GPU-count sweeps follow its GPU count |
| **D-9** | **Core accounting** | Aggregators computing CPU-saturation figures | The reserved-core exclusion set is a **per-filesystem parameter** (**D15**), and the reserved count is only measurable on the real client |
| **D-10** | **cuFile config + env VALUES** | ~20 files reference conda/cuFile/CUDA paths. They now genuinely read documented variables (`$CONDA_ENVS_DIR`, `$LIBCUFILE_PRELOAD`, `$CUFILE_ENV_PATH_JSON`) and refuse if unset — audit items `A-4`/`A-5`; before that they were literals from another machine. What remains is the **values** | Leg A's values are set by the bootstrap (`LIBCUFILE_PRELOAD` located and exported; a compat-mode `cufile.json` generated per instance). Remaining: rewrite `../scripts/GDS-TUNING-CHECKLIST.md` (bannered) incl. a Lustre-over-EFA branch, and Leg B's cufile config |
| **D-11** | **Lustre tuning** | Stripe layout + client tunables | Needs FSx (Leg B). **Part of "Lustre at maximum" (D7)** — skipping it would understate Lustre and break the fairness basis |
| **D-13** | **1.7 hydration driver** | New `sweep-stage1-hydrate.sh` | Needs the real bucket. `run-leg.sh` reports this step as **MISSING and aborts** rather than skipping it. On completion it must write `runs/.leg-state/$LEG/hydration-complete` — the bootstrap's re-hydration guard keys on that marker |
| **D-15** | **Make step 4.D actually recorded** | `convert-stage4c-rawtiff.sh` | It is `run-leg.sh` step 4.D and its own header calls it a recorded cell, but it **never invokes `record-run.sh`** — no run dir, no telemetry, no `INDEX.md` row, no S3 sync for the 20× conversion the roadmap treats as a measured workload. It also does not fail loud when zero slides resolve from the manifest. Wrapping it changes what a substage produces, so it needs the owner's nod |
| **D-16** | **Lustre client-side EFA configuration** | `../prompts/prompt-lustre-cluster-cloud.md` | The documented Leg-B flow enables EFA on the instance and the file system and installs the generic EC2 EFA software, but nothing yet runs AWS's FSx-Lustre EFA client setup — so the client would mount over TCP, forfeiting GDS **and** the per-server-cap escape while still producing numbers. That breaks the "Lustre at maximum" basis (**D7**) invisibly. Needs the current AWS FSx-Lustre client docs, plus a gate that `lnetctl net show` lists an `efa` net |
| **D-17** | **Leg-B kernel-vs-contract policy** | `../prompts/prompt-lustre-cluster-cloud.md` | The documented Lustre client install pulls `linux-aws`, which can move the kernel, and `kernel` is a `MUST_MATCH` contract field — so the Leg-B procedure can invalidate the comparison the contract exists to protect; any OS upgrade can too. Decide: pin the kernel and install the matching `lustre-client-modules-$(uname -r)`, or re-baseline both legs |
| **D-19** | **Substage 1.8 has no implementation and no marker** | `Stage-1-Ingest.md` | The FSx-native S3 import is the only substage with neither a driver row, a "no implementation" note, nor a deferred id. It is a Lustre-leg capability cell excluded from the head-to-head, so omitting it breaks no cross-leg comparison and would go unnoticed. Build it in Leg B or record a decision not to |
| **D-20** | **`prove-recording.sh`** | new script in `../scripts/` | The rebuild checklist and `../prompts/handoff-cloud.md` both say to run a throwaway Stage-0 cell and confirm **five** things by eye — recording complete, both canaries functional, S3 sync verified, the `INDEX.md` row correct, an aggregator emitting an `fs`-pivoted row — with no command given. It runs on every rebuild before wallclock is spent, and five eyeball checks is where one gets skipped. One script, a named non-zero exit per failed assertion. Needs the real environment: it runs an actual cell end to end |
| **D-21** | **A contract-verified marker `run-leg.sh` refuses without** | `env-contract.py`, `run-leg.sh` | The rebuild runs `env-contract.py verify` as "the gate", then starts the leg **without checking the gate ever ran or passed.** Phase 1 (safe): `verify` writes `runs/.leg-state/$LEG/contract-verified` on PASS and unlinks it on FAIL; `run-leg.sh` warns loudly when it is absent or older than the contract. Phase 2 — promoting that to a refusal — **needs explicit ratification**, since it can abort a leg |
| **D-22** | **`verify-conda-env.sh`** | new script in `../scripts/`, beside `restore-memories.sh` — the other bootstrap script | The rebuild asks for nine imports plus a visible-GPU count to be checked by hand every time. Script the **verification only** — imports, GPU count vs `nvidia-smi`, `python_version` against the reference contract, non-zero on drift — environment *creation* lives in the bootstrap, whose smoke test is import-only and warn-only — this script is the fail-loud verification it lacks |
| **D-23** | **`sync-to-s3.sh --self-test`** | `../scripts/sync-to-s3.sh` | Its header carries a seven-step manual first-run procedure, including the one that matters: prove a file under a MIRROR path disappears when deleted locally and a file under an ARCHIVE path does **not**. Mechanise it under a namespaced `_selftest/` prefix, print (don't run) the cleanup command, and make removing the file's `UNVERIFIED` banner conditional on it passing. Needs the real bucket |
| **D-24** | **Cross-leg artifact fingerprints** | new `capture`/`compare` in `../scripts/`, defined in `STAGES.md` | `RUNBOOK.md` declares four cross-leg integrity gates — same slides producing coords and same per-slide tile counts; same raw-TIFF byte counts and tile-grid dimensions; same feature file count, per-slide tile count and tensor shapes — each "fail-loud and invalidates downstream comparison", and **nothing computes or compares them.** A declared gate that no code implements is worse than no gate: it reads as covered. Propose the per-artifact-class fingerprint definitions for ratification now; build after Stage 3.0 has real output |
| **D-25** | **Stage 6.C's 4-GPU partition** | `orchestrate-concurrent-stage6c.sh` | 6.C pins MIL to GPU 0 "to stay out of the extract workload's GPUs" while extract requests 4 — an isolation that is arithmetically impossible on a 4-GPU instance. Decide the partition (extract on 3 + MIL on 1, or accept sharing and delete the isolation claim); either way the retention denominators change, so it is a methodology call, not a tuning one |
| **D-26** | **The dangling `Q<n>` decision-citation scheme** | 29 citations across 12 scripts | Scripts cite locked decisions as `Q1`–`Q13`; **zero `Q<n>` identifiers survive anywhere in `docs/`**. Every one of those citations is unresolvable. Either reintroduce stable ids into the per-stage registers or rewrite the citations to name the decision — a convention call either way |
| **D-27** | **`--compat-mode` knob for the Stage-5 trainer and Stage-6 extractor** | `train-resnet50-stage5.py:480`, `extract-features-foundation-stage6.py:636`, their drivers | Both hardcode `compat_mode="off"` citing a **previous environment's** "Stage 4.C winner", with no CLI knob — so **`STAGES.md`'s mode-controlled paired cell for 5.A/6.A cannot be run at all**, and a leg where GDS is unachievable has no way to request compat. The reader classes already validate `off\|on\|auto`; adding the flag needs no target value. Only the per-leg *value* is a cloud input |
| **D-28** | **Stage 7.2 reads full-cohort raw-TIFF that no step produces** | `sweep-stage7-clinical.sh:227-232`, `convert-stage4c-rawtiff.sh` | 7.2 is configured against the 1073-slide cohort through the kvikIO/raw-TIFF backend, but 4.D converts only the subset and 6.A Tier 2's chunks are transient. Either 4.D retains the full cohort (order ~7 TB — a capacity input, **D7**/**D4**) or 7.2 runs on the subset. Record the choice in the Stage-4 and Stage-7 roadmaps |
| **D-29** | **Per-cell destinations for core accounting and cache state** | `record-run.sh` | **D15** core accounting and **D13** cache-state-as-achieved have **no field to be recorded into**. The destinations can be created now (documented variables + metadata fields); only the values are cloud inputs. Until then both requirements are unmeetable by any cell |
| **D-30** | **`record-run.sh`'s OK/INCOMPLETE verdict enforces none of RUNBOOK's per-cell requirements** | `record-run.sh:394-422` | A cell missing cost inputs, cache state, core accounting or cuFile path proof is still stamped `OK`. Decide what blocks versus warns — same shape as **D-21** phase 2, and it should be decided with it |
| **D-31** | **The environment contract omits the 20 workload-shape variables** | `env-contract.py:48-72` | `docs/NAMING-AND-VARIABLES.md` Table 5 declares them identical-across-legs, but the contract records none. **Do not simply append them to `MUST_MATCH`:** `verify()` pushes a null-vs-null pair into `unrecorded` and returns FAILED, so the normal case (both legs on defaults) would fail. Needs a tri-state or a defaults-aware comparison |
| **D-32** | **`dataset_manifest_sha` hashes the manifest, not the dataset bytes** | `env-contract.py:174-175` | The held-constant field "the datasets and their byte contents" is therefore asserted, never verified. Full rehashing costs hours of leg wallclock, so the cheaper options (file count + total bytes + newest mtime; or a sampled hash) are a methodology call |
| **D-33** | **Stage 7's `## 7.1` headline grid is structurally always empty** | `aggregate-stage7-clinical.py` | The grid filters on `cell_name.startswith('7.1')`, but `RUN_NAME_RE` strips the stage segment, so a `record-run.sh`-named dir `…-s7.1-baseline-…` yields `cell_name='baseline-…'` and never matches. 7.2 only appears because its driver pre-computes a `-s7-7.2-…` dir, leaving the sub-tier inside the name. Either match on the recorded `stage` field or stop stripping the segment — but the two naming shapes must be reconciled first, which is why this is not a one-line fix |

> **Nothing was deleted.** An earlier plan assumed GPUDirect Storage would be dropped, which would have
> removed the kvikIO / raw-TIFF / cuFile scripts. **GDS is retained and asymmetric by design** (**D8**), so
> the entire library carries forward — including `read-tiles-kvikio.py`, `run-multiproc-kvikio.sh`,
> `sweep-stage4c-kvikio.sh`, `aggregate-stage4c-kvikio.py`, `convert-rawtiff-20x.py`,
> `convert-stage4c-rawtiff.sh`, `fe-core-kvikio.sh`, `GDS-TUNING-CHECKLIST.md`, and
> `cufile-full-rdma.template.json`.

---

## Cross-cutting patterns (learned the hard way — preserve these)

These recur across scripts and each one exists because its absence caused a real failure.

1. **Per-timestamp client summing, not a pre-aggregated mean.** An aggregator that reads a pre-aggregated
   filesystem-side metric can under-report by ~100×, because that metric averages across **all** rows in the
   stats stream including many idle server-side rows. **Correct pattern:** re-read the raw stats CSV, filter
   to the client's own rows, sum across the client's processes **per timestamp**, then aggregate the
   per-second sums. Filter by a stable identity — **role** (`Mode=="client"`; this cluster runs exactly one
   client container by design) — never a hostname or a numeric process/node id, both reassigned on rebuild or
   reinstall. ⏳ **The pattern generalises to both legs; the source schema does not** (D-4).
2. **`setsid` + process-group kill, never `pkill -f`.** A `-f` pattern matches the wrapper shell and the
   recording wrapper too (their argv contain the pattern string), so the signal kills the whole chain —
   producing duplicate `INDEX.md` entries and a spurious `INCOMPLETE` on a cell whose data is fine.
3. **Per-cell `LD_PRELOAD` scoping.** Set the system libcufile only on kvikIO cells. cuCIM links libcufile
   internally even for CPU reads and segfaults on an ABI mismatch. Nearly every sweep here is mixed.
4. **Pre-computed run dir via `RECORD_RUN_DIR`.** When a driver needs the run-dir path *before* invoking the
   wrapper (to pass output paths into the wrapped command), it exports `RECORD_RUN_DIR` and the wrapper uses
   it instead of generating its own timestamp — eliminating a caller/wrapper timestamp race.
5. **Cleanup-before-cell where a script skips existing output.** Three places reuse output *without failing
   loud*: the raw-TIFF converter, the 6.A extractor, and Tier-2 chunked conversion. Without a wipe, every
   cell after the first short-circuits and reports a plausible-looking meaningless number.
6. **Generous collective timeouts for ragged workloads.** Datasets with wide per-slide tile-count
   distributions make the slowest rank dominate; a short default collective timeout kills an otherwise valid
   multi-rank cell.
7. **Parser idioms that bite.** Lowercase CSV headers; `;`-delimited `sar` output; unit suffixes inside
   numeric telemetry fields; **cumulative wire counters requiring diff/dt**. All handled in the existing
   aggregators — don't regress them. **The dt is read from the samples' own timestamps, never assumed from
   the nominal sample rate** — see `parse-results.py` for why a rate divided by an assumed interval is a
   silent, systematic overstatement.
8. **Idle-robust active-window mean.** Throughput aggregates use a trimmed active-window mean rather than a
   whole-window mean, because a storage-idle setup or model-load phase inside the recording window otherwise
   dilutes the number badly. Keep the naive full-window value alongside so both remain visible.

---

## Cross-stage infrastructure

### `record-run.sh` — the recording wrapper
**What.** Wraps any benchmark command: pre-run snapshot → start all recorders → run the command with
stdout/stderr tee'd → stop recorders cleanly → post-run snapshot → parse raw CSVs into `results.json` →
append one line to `INDEX.md`. Derives the runs root from its own location on disk, so the tree it writes
into is determined by where the script physically lives.
**Why.** "If it isn't recorded, it didn't happen." One wrapper means every cell in the project is recorded
identically, and per-cell failure is isolated — a bad cell goes `INCOMPLETE` without taking down the sweep.
**I/O.** `--stage`, `--run-name`, `--note`, then `--` and the command → a fully populated run dir.
**Caveats.** Honours `RECORD_RUN_DIR`. Marks `INCOMPLETE` if the command returns non-zero **or** any required
stream has fewer than two lines.
**⏳ DEFER:** per-filesystem recorders (D-4) — the current recorder set and the required-stream list are the
WEKA-over-InfiniBand ones, so on AWS the IB streams are empty and **every run marks `INCOMPLETE` until D-4
lands**; cuFile path accounting (D-6); during-run S3 sync, per-cell watchdog, canary-abort (D-7).

### `parse-results.py` — raw CSVs → `results.json`
**What.** Reads a run dir's `raw/` time series and writes aggregate statistics.
**Why.** Independent of the wrapper, so a parser fix or a new derived metric never requires re-running the
benchmark — which matters when a cell costs hours.
**Cumulative counters become rates by dividing by the dt read from each sample pair's own `timestamp`** —
never by the nominal sample rate. *Why the division is load-bearing:* the recorders sleep 1 s **plus** loop
overhead, and under load a sample slips further; treating the raw delta as a per-second rate then overstates
every wire-counter rate by exactly the slip. Those rates feed the cross-source consistency canary, where the
error inflates the wire side of the ratio and can either mask a real inconsistency or manufacture a false
one. A pair whose dt is missing, unparseable or non-positive is **dropped, not guessed**.
**Output schema.** Each delta-aggregated group carries a **`_sample_interval_s`** block (count / mean / min /
max), so the sampling actually achieved is visible rather than assumed to be 1 Hz — the same slip that
corrupts a rate also tells a reader how much to trust the series. Recorder stamps are second-resolution, so a
sub-second slip is quantised away; that residual is an open item, not silently absorbed.
**Caveats.** Overwrites `results.json` in place; raw data untouched. Implements the active-window mean.
**⏳ DEFER:** per-filesystem source schemas (D-4).

### `aggregate-sweep.py` — generic sweep aggregator
**What.** Rolls N run dirs into a summary CSV, including block-size × concurrency grids.
**Why.** The `fio` sweeps share one shape, so one generic aggregator serves all of them.
**Caveats.** The only aggregator taking an **explicit glob**; the per-stage ones self-locate via `__file__`.
**⏳ DEFER:** the `--fs` pivot. `metadata.json` carries the `fs` field already; teaching the aggregators to
group on it is part of the per-filesystem adapter work (D-4).

### `build-tcga-manifest.py` — dataset manifest builder
**What.** Queries the GDC API and emits a download manifest TSV.
**Why.** Makes the dataset selection reproducible and auditable rather than an undocumented download.
**Caveats.** Used once during pre-leg staging into S3, not per leg.

### `sync-to-s3.sh` — the durability layer ⭐ NEW
**What.** Pushes everything teardown-critical to S3. Three modes: `--mode full` (called by `backup.sh`),
`--mode run --run-dir <path>` (one run's raw telemetry), `--mode datasets --src <path>`. Plus `--dry-run`.
**Why.** Instance-local scratch and **both filesystem mounts are ephemeral** — they die with the instance and
the cluster, and the instance is rebuilt between legs. Without this, a teardown destroys every run's raw time
series. git covers all the small text; S3 covers the heavy write-once data git cannot hold.
**Why two sync semantics — the whole point of the script.** **MIRROR** (`--delete`) for docs and the memory
mirror, where local is genuinely authoritative and git backs it independently, so an exact reflection is
safe. **ARCHIVE** (never `--delete`) for telemetry and datasets, because we will want to reclaim local disk
by pruning old telemetry and a delete-sync would then **destroy the only remaining copy**.
**Why NOT `--no-overwrite` for the archive group,** even though it sounds safer: telemetry CSVs **grow**
while a run is in flight, and that flag only transfers files absent at the destination — so the first sync
would upload a partial CSV and no later sync would ever fix it. Default comparison (size differs *or* source
newer) is what handles growing files. Documented in the script header so it isn't "improved" back.
**I/O.** Config entirely from the environment (`S3_BUCKET`, `LEG`, `AWS_REGION`) — nothing hardcoded.
**Caveats.** Fails early and loudly on missing credentials or an unreachable bucket, so a sweep does not
discover at 4am that hours of telemetry had nowhere to land. **Every guard path exits non-zero**, which is
what lets a sweep chain abort on a failed sync. Verifies object count after syncing rather than assuming
success (Rule 11).
**⏳ `UNVERIFIED AGAINST A REAL BUCKET`** — written before the environment existed. Its header carries a
**7-step FIRST-RUN PROCEDURE**; run it before trusting the script and then remove the banner. **Step 6 is the
one that matters:** create a throwaway file under an *archive* path, sync, delete it locally, sync again, and
confirm it does **not** disappear from S3. Also tracked as open item `D-7`.

### `env-contract.py` — cross-leg comparability enforcement ⭐ NEW (`D-12`)
**What.** `write` collects every environment fact into JSON at the end of a leg; `verify` compares the current
environment against a reference contract before the next leg's first cell; `show` prints one readably; **`env`
emits it back as `env.sh`-shaped `export` lines** for the rebuild.
**Why `env` exists.** `env.sh` is gitignored, so it is **lost on every rebuild**; the bootstrap regenerates it
and merges the previous leg's held-constant fields by consuming this emit programmatically. A hand
transcription step here would put a typo in front of the one artifact whose whole purpose is proving the two
legs matched. **Held-constant fields are emitted live; leg-specific fields are emitted COMMENTED** — on a
cross-leg rebuild those describe the *other* filesystem, and this leg's setup writes the new ones (the
bootstrap on WEKA; the cluster prompt on Lustre).
Fields absent from the contract are emitted as a commented placeholder saying so, never invented.
*Caveat:* **paste the output over the placeholders, do not `>>` append.* `env.sh`'s `--check` block sits at the
bottom of the file and runs before anything appended after it, so appended values source correctly and are
still reported `MISSING`.
**Why.** The two legs run at **different times on a rebuilt instance**. Anything that drifts — AMI, driver,
dataset bytes, script commit — is **indistinguishable from a filesystem difference** once the numbers exist.
This makes comparability a mechanical check rather than a judgement call.
**The load-bearing design decision:** fields are split into **`MUST_MATCH`** (instance type, region/AZ, AMI,
kernel, driver/CUDA/cuFile versions, GPU/CPU/memory, script commit, dataset manifest hash, env name, Python)
and **`MAY_DIFFER`** (everything filesystem-specific — mount, backend config, EC scheme, FSx tier, stripe
layout, client cores/NICs). *Why it matters:* a verifier that ignored the distinction would either fail on
everything or catch nothing, since the filesystem fields are **supposed** to differ — they are the variable
under test.
**Caveats.** Facts are collected automatically where possible and read from the environment otherwise;
anything unavailable is recorded as **null, never guessed**. `verify` treats a null on a held-constant field
as **unverifiable → FAILED**, because *an unrecorded fact cannot be shown to have matched*. `write` also exits
non-zero when held-constant fields are missing, so an incomplete contract cannot pass unnoticed.
**`env.sh` is reconciled against instance metadata, not trusted.** `instance_type`, `aws_region`, `aws_az`,
`ami_id` and `instance_id` are fetched from **both** `env.sh` and IMDS; **metadata wins** and any disagreement
is recorded in `source_conflicts`. *Why metadata wins:* `env.sh` is a generated
file that can still drift or be hand-edited between rebuilds, and a wrong value there would flow into Leg A's
contract, be emitted into Leg B's `env.sh` from that same contract, and then be compared against itself by
`verify` — matching, and hiding exactly the drift the contract exists to catch. `write` warns on a conflict; `teardown-preflight.sh` NO-GOes on one, because `env.sh` is
what the next instance is rebuilt from. A contract predating the check reports *unverified*, not *agrees*.
**Third field list, `RECOVERY_ONLY` (`s3_bucket`).** Comparing it proves nothing — you must already know the
bucket to have fetched the contract — but without it the recovery artifact could not rebuild the file it is the
recovery source for. It is invisible to `verify` and to `write`'s completeness check, which both iterate the
other two lists.

### `run-leg.sh` — unattended leg orchestrator ⭐ NEW (`D-14`)
**What.** Drives one whole leg's sweeps in dependency order: **22 steps**, `--dry-run`, `--list`, `--from`,
`--only`. Each step carries its driver **and that driver's target** where the driver dispatches on `$1`
(4.C `tier1`, 5 `all`, 6.A `tier1`, 6.A.3 `tier3`, 6.B.3 `all`, 6.B.2 `all`, 6.C `all`, 7 `all`) — the runner
word-splits the command, and `--from`/`--only` are validated against the step-id list so a typo cannot
silently skip the whole leg.
**Why.** A leg is many hours of sweeps that must run in a fixed order because each stage produces inputs the
next consumes. Driving that by hand overnight invites a missed step or a silently-continued failure.
**It orchestrates SWEEPS, not cells** — per-cell recording and failure isolation stay with `record-run.sh`.
**The five guards, each with its reason:** (1) **abort the chain on any step failure** — later steps consume
earlier outputs, so continuing would build cells on missing inputs; (2) **checkpoint + resume** via per-step
done-markers, so a crash re-runs only what is missing; (3) **S3 sync after every step**, because both mounts
and local scratch are ephemeral; (4) **tee everything** — on an overnight run the log is the only forensic
record; (5) **refuse a leg on the wrong transport** — WEKA must be on DPDK and Lustre on EFA (**D16**), read
from `FS_TRANSPORT`, recorded from client evidence — the bootstrap writes it on the WEKA leg, the cluster
prompt verifies it (and records it on Leg B). Unset refuses too, because an
unrecorded transport cannot be shown to be the right one. Overridable only by a written reason in
`runs/.leg-state/$LEG/transport-waiver`, which is then echoed into the log. *Why here:* this is the unattended
entry point, and the fallback transports (UDP / TCP) mount cleanly and report plausible numbers, so an
instruction followed hours earlier is not evidence.
**Caveats.** Refuses to start without `FS_MOUNT`/`S3_BUCKET`, and **refuses if `--leg` disagrees with
`FS_MOUNT`**. A step whose driver does not exist yet is reported **MISSING and aborts** rather than being
skipped — *a leg with a hole in it looks complete in `INDEX.md`*, which is the failure this prevents. Two
steps are currently MISSING by design: 1.7 (`D-13`) and 6.B.1 (needs the corpus-size decision, open item 5b).

### `teardown-preflight.sh` — prove nothing is lost, before tearing down ⭐ NEW
**What.** Checks nine things and prints **GO / NO-GO**: nothing in flight · live memories mirrored · **the
next-session handoff prompt written and dated today** · git clean **and pushed** · environment contract complete
**and in S3** · **`env.sh` agreeing with instance metadata** · **every local run dir's raw telemetry present in
S3** · nothing else stranded on ephemeral storage · rebuild inputs (AMI, type, region/AZ) recorded.
**Why it VERIFIES rather than tears down.** Terminating the instance and deleting filesystems is irreversible,
so it stays a human action. The part worth automating is not the destruction — it is **proving** nothing is
lost, because that is the part a person does badly: it is easy to assume a sync worked, and impossible to
eyeball whether some run dir exists only on a disk about to disappear. A script that destroyed *and* had a bug
in its own verification would be the worst possible tool.
**The check that matters** is the per-run S3 comparison: `raw/` is gitignored, so S3 is its only home, and a
silently-failed sync is invisible until you look for data that no longer exists. `--quick` skips exactly that
check, so **never use it before a real teardown**.
**Caveats.** Exits non-zero on NO-GO, deliberately — never wire it into an automated teardown that ignores the
exit code. Companion checklist: `cloud-setup/TEARDOWN-AND-REBUILD.md`.

### `restore-memories.sh` — mirror → live memory dir ⭐ NEW
**What.** Copies `claude-memory-mirror/` into `~/.claude/projects/<slug>/memory/` and **verifies** the result.
`--check` verifies without changing anything. Bootstrap rather than benchmark, but it lives in `../scripts/`
with everything else that is executed rather than read.
**Why it is a script and not four lines in the checklist.** It runs on **every** instance build — at least
twice, once per leg — and its failure mode is **silent**: `rsync` into the wrong directory succeeds, and a
fresh Claude session then starts with no memories and **no error**, proceeding to redo settled decisions. On an
ephemeral instance the mirror is the only continuity that exists. The manual version also asked the operator to
eyeball "expect ~20 files", which is exactly the check people skip.
**So it: derives the slug from the repo path** rather than trusting a typed one; **refuses** on a missing or
empty mirror or a mirror with no `MEMORY.md` (better than producing an empty memory dir); and **diffs** the
result afterwards.
**Caveats.** **Direction matters — restore *before* ever running `backup.sh`**, which mirrors the other way and
would otherwise overwrite the mirror from an empty live dir (it refuses in that case; correct ordering makes
the refusal moot). *Extra* files in the live dir are reported but **not** a failure — that is the live dir
being ahead after a session wrote new memories; *missing* or *differing* files are fatal.

### `bootstrap-instance.sh` — the automated client build ⭐ NEW

**What.** The Terraform `clients_custom_data_post_mount` payload: builds the whole client on first boot —
dnf packages, the pinned NVIDIA/CUDA-12.9 stack (chosen so `nvidia-fs` and the system `libcufile` are
version-matched), local-NVMe RAID0+XFS scratch, WEKA login via Secrets Manager and mount verification,
`env.sh` generated from instance evidence (IMDS plus the client's own transport report → `FS_TRANSPORT`),
`LIBCUFILE_PRELOAD` located and exported, the compat-mode `cufile.json`, both conda envs from
`env-specs/` with smoke tests, HF token + model prefetch from SSM, memory restore, and the S3 dataset
hydration guard.

**Why.** A rebuild is `terraform apply` plus `claude /login` and nothing else — every manual step in a
rebuild is a place the two legs can silently diverge, and the environment contract can only verify what a
build records mechanically.

**Caveats.** The env smoke tests are **import-only and warn-only** (`WSI-WARN`; the boot continues) —
fail-loud verification is `D-22`. The re-hydration guard keys on
`runs/.leg-state/$LEG/hydration-complete`, which only the `D-13` hydrate driver will write. Boot progress
lands in the instance log; the SSM deploy-key step must report the fixed key installed (next-rebuild
verification, open-items memory).

### `prefetch-datasets-to-s3.sh` — one-time dataset staging ⭐ NEW

**What.** Stages TCGA-BRCA (per-file fetch from the GDC data API over HTTPS, manifest-driven,
**md5-verified per file**, failed files removed and retried) and CAMELYON16 (open-data bucket copy) into
`s3://$S3_BUCKET/datasets/`. Resumable; skips objects already present.

**Why.** The WAN pull happens **once, before either leg** — it measures a WAN link, not a filesystem — and
S3 is then the per-leg hydration source (1.7), so both legs read byte-identical datasets (**D6**).

**Caveats.** Consumes the gdc-manifest-format TSVs from `build-tcga-manifest.py`. Not a measured cell.
Requires local staging space under `$SCRATCH_DIR`.

### `teardown-prep.sh` — the pre-destroy orchestrator ⭐ NEW

**What.** Runs the teardown sequence mechanically: `backup.sh` (memories → mirror → S3 sync), boot-log
archive, `git commit` + `git push` (fail-loud — an unpushed repo dies with the instance), then hands off to
`teardown-preflight.sh` as the GO/NO-GO gate and echoes its verdict.

**Why.** The teardown checklist's order is load-bearing and a human runs it under time pressure; scripting
the preparation makes the steps unskippable, while the **destruction itself stays human** — this script
never terminates anything.

**Caveats.** Gated on the preflight, which demands the next-session handoff written and dated — so the
handoff must exist before this runs. The commit it makes is the human-initiated teardown commit, not an
autonomous one. First real teardown must also run `sync-to-s3.sh`'s FIRST-RUN procedure (open-items
memory).

---

## Stage 1 — Ingest

### `sweep-stage1-{seqw,seqr,randw,randr}.sh` — synthetic ceiling sweeps
**What.** Four `fio` drivers: sequential write, sequential read, random write IOPS, random read IOPS. Block
size × concurrency grids; sequential grids at iodepth=1, IOPS grids at iodepth=8.
**Why.** These anchor the whole project: **every downstream "% of ceiling" divides by one of these cells at
the matching block size.** Throughput is strongly block-size-dependent, so a single ceiling number would make
mid-block workloads look artificially high or low. They are also the cleanest apples-to-apples cells in the
project, since `fio` is filesystem-agnostic.
**I/O.** Host RAM ↔ `$FS_MOUNT/benchmarks/fio-scratch/` → per-cell run dirs.
**Caveats.** `--unlink=1` cleans per cell. Read sweeps need a layout phase before the timed window.
**⏳ DEFER:** nothing driver-side — mount, repo root and filesystem labelling are all done. The remaining
work for these cells is in the aggregator: per-filesystem sources (D-4) and the consistency relation (D-5).

### `chain-stage1-bcd.sh` — sweep chainer
**What.** Runs several Stage-1 sweeps back to back unattended.
**Why.** The precedent for leg-level chaining (D-14) — cells are already isolated, so chaining is safe.

### `fe-core-fio.sh` · `fe-core-kvikio.sh` — shared cell helpers
**What.** Single-cell helpers for a `fio` cell and a kvikIO cell, used for baselines and quick checks.
**Why.** Phase 0 needs the ceiling captured **per block size** without standing up a whole sweep.
**⏳ DEFER:** `fe-core-kvikio.sh` needs cuFile path accounting (D-6) and the GPU pinning order (D-8).
**⚠ Neither is the Phase-0 ceiling capture** — each runs ONE fixed configuration, while every downstream
"% of ceiling" divides by the **block-size-matched** Stage 1.0a–d cell. Use the Stage 1.0 sweeps for that.

### `sweep-stage1-fpsync.sh` + `aggregate-stage1-fpsync.py` — bulk local→filesystem copy
**What.** Sweeps parallel-copy concurrency over the real corpus from local NVMe.
**Why.** The clean write-path benchmark on **real WSI files with real metadata operations**, closest to the
scanner-to-storage path labs actually run. Comparison against the synthetic ceiling shows how much of the
write path is reachable with real files rather than one scratch stream.
**Caveats.** Needs a local source faster than the filesystem's write ceiling, or the source is the bottleneck
and the cell measures the wrong thing. The aggregator implements pattern **#1**.

### `sweep-stage1-mixed.sh` + `aggregate-stage1-mixed.py` — mixed ingest + read
**What.** Fixed-rate ingest running concurrently with a swept random-read `fio` grid; captures **both** sides.
**Why.** The operationally realistic state — a scanner feeding while clinicians read. Answers two questions
at once: can readers work at acceptable latency during ingest, and does reader load throttle ingest?
**Caveats.** Uses pattern **#2** (`setsid` + process-group kill). **Mixed cells need wider canary bands than
single-direction cells**, and the bands must be re-derived per filesystem — the wire carries payload plus
acknowledgements in both directions, and at small block sizes the non-payload share is material.
**⏳ DEFER:** the fixed ingest rate is set as a **fraction of each leg's own write ceiling**, not an absolute
— so it is parameterised from that leg's 1.5 curve.

---

## Stage 2 — Cataloging

### `extract-slide-properties.py` — per-slide metadata extractor
**What.** Opens each slide via OpenSlide, dumps properties plus derived fields as a JSON sidecar, times it.
**Why.** OpenSlide is the literature standard and handles both formats, so the measurement is comparable to
published work. Concurrency via a persistent worker pool.
**Caveats.** Writes to a **separate** output directory — the canonical dataset dir stays read-only so both
legs read byte-identical inputs.

### `sweep-stage2-properties.sh` + `aggregate-stage2-properties.py`
**What.** Dataset × concurrency grid, single pass per cell.
**Why.** Single-pass matches how a real cataloging job runs and keeps the unit of work identical across legs.
**Caveats.** **High-concurrency cells finish in under a second**, so 1 Hz recorders capture 1–3 samples and
any sustained mean is ill-defined — a sampling limit, not a recording failure. The app-level rate is
unaffected. ⏳ **Resolve the sampling approach before the first cell and apply it identically to both legs.**
**⏳ DEFER:** ops-counter comparability across legs is unresolved — until counter semantics are verified
equivalent, **the app-level rate is the only cross-leg-comparable source** here and the filesystem-reported
ops/s is within-leg only.

---

## Stage 3 — Tissue detection

### `sweep-stage3-tissue-detection.sh` + `aggregate-stage3-tissue-detection.py`
**What.** Drives the CLAM tissue detector across datasets × concurrency, producing the 20× coordinate lists
that gate Stages 4–7. Concurrency is external: the manifest is round-robin split into chunks and N detector
instances run in parallel into one output dir.
**Why.** Round-robin splitting guarantees no two chunks share a slide, so parallel instances cannot collide.
Per-dataset tiling arguments implement the 20× contract (**D2**). `--stitch` is omitted because its
visualisation output is not consumed downstream.
**Caveats.** CPU saturation is computed over **application-available** cores, and **the excluded core set
is a per-filesystem parameter** (**D15**) — WEKA reserves cores, Lustre does not. Two slides are expected to
yield no tissue under default parameters: real tool behaviour, storage- and magnification-independent, and
therefore a **cross-leg integrity check**.
**⏳ DEFER:** core accounting (D-9) — the reserved-core exclusion set must be measured on the real client
before this stage's CPU-saturation curve means anything.

---

## Stage 4 — Patching

### `extract-tiles-to-hdf5.py` + `sweep-stage4a-patches.sh` + `aggregate-stage4a-patches.py`
**What.** Reads each slide's coords, extracts and JPEG-encodes each tile, appends to a per-slide HDF5.
**Why.** The pre-extract strategy baseline. HDF5 with variable-length JPEG bytes is CLAM-style, directly
compatible with Stages 5–6, and far smaller than raw uint8.
**Caveats.** Concurrency is swept **outer-descending** so cheap cells validate the methodology before the
long-pole serial cell. Subset-limited (50 slides/dataset, fixed seed) because a serial full-cohort cell is
infeasible and 4.A's output feeds nothing downstream.

### `read-tiles-onthefly.py` + `sweep-stage4b-tilesread.sh` + `aggregate-stage4b-tilesread.py`
**What.** Random-tile reads from slides via either OpenSlide per-tile or cuCIM batched CPU, selected by flag.
Time-based cells; per-worker LRU slide-handle cache; p99 per-tile latency.
**Why.** The on-the-fly strategy — the pattern modern pipelines actually run, and the one that stresses
storage the way training does. Two backends because both exist in production.
**Slide paths are resolved through an index built once, before the clock starts** — in **both** the OpenSlide
and cuCIM workers. *Why it cannot be lazy:* resolution sits on the cache-miss branch of the timed loop, which
fires on roughly one iteration in eight (`P_NEW_SLIDE`), and resolving by walking the corpus put a full
directory scan plus per-directory existence probes **inside the measurement window** — a metadata workload,
on the axis where the two filesystems differ most, contaminating the cell that exists to isolate the
tile-read path. The index preserves the original probe order (flat `.tif`, flat `.svs`, subdir `.svs`, subdir
`.tif`), so which file wins for a given slide id is unchanged.
**Caveats.** cuCIM's GPU `read_region` is **ruled out** — a library defect (buffer allocation spanning the
whole offset range, unbundled decoder, pre-GA upstream), therefore **filesystem-independent and not a
comparison axis**; never report it as a storage finding for either side. **Cache discipline is load-bearing
here** (**D13**): at high worker counts the coord pool can become cache-resident, and the two filesystems
cache differently, so the crossover must be characterised per filesystem rather than assumed shared.

### `convert-rawtiff-20x.py` + `convert-stage4c-rawtiff.sh` — the 20× raw-TIFF writer
**What.** Writes a single-level, 256-tiled, uncompressed TIFF whose **level-0 is the 20× image**, so cuFile
reads level-0 byte ranges directly as tiles and coords map to a tile index by integer division. Per-dataset
read path; **fail-loud mpp guard** rejecting off-magnification slides.
**Why.** The standard converter has no magnification/level flag and always emits the source's 40× level-0.
Keeping a 40× artifact and reading pyramid level-1 would be ~4× larger, ~4× slower to produce, and — the
decisive point — **not the artifact a 20× GPU-direct customer stores** (**D4**). Matching the readers'
resize interpolation means both backends see the same pixels.
**Caveats.** **Idempotent skip on existing non-empty output** — so a stale artifact from another magnification
or converter version is **silently reused**. Delete before regenerating. The output is a large capacity cost
on both filesystems (order ~7 TB at full cohort) and thus a sizing input to **D7**.

### `read-tiles-kvikio.py` + `run-multiproc-kvikio.sh` + `sweep-stage4c-kvikio.sh` + `aggregate-stage4c-kvikio.py`
**What.** cuFile reads of tile byte ranges straight into GPU buffers, in two modes: a faithful sequential
full-level read, and random-tile reads drawn from the **same coord pools as 4.B** for apples-to-apples
comparison. Tiered sweep over pipelining depth, task size, thread count, pre-registration, and multi-process
scaling.
**Why.** The GPU-direct path, and the only Stage 4 path where the two filesystems' transports genuinely
differ. Sharing 4.B's coord pools is what makes the strategies directly comparable.
**Per-tile latency is stamped inside the drain**, once each future has actually returned, so it spans
**submit → observed completion** and therefore includes queueing behind earlier futures in the same batch.
For a pipelined reader that is the honest customer-facing quantity — but **it is not the isolated service
time of one read and must never be quoted as one.** A single clock read taken before the drain would subtract
the submit time from a stamp taken before any I/O had been waited on, excluding the I/O wait entirely and
leaving a latency figure that measured submit overhead alone.
**The aggregator reports the requested cuFile mode and the achieved path as separate columns.**
`cufile_mode_requested` is read off the run-dir name and says only what the cell was **asked** to do;
**`gds_engaged` is `"unknown"`** until cuFile's own GPU-direct-versus-bounced byte accounting is wired in
(D-6). *Why it is not derived from the mode:* doing so restates the request as though it were evidence —
precisely the "a configuration flag is not proof of behaviour" failure **D8** forbids — and a cell that
silently fell back to compat, or silently did not, would look identical in the CSV either way. An absent
answer is visible; a fabricated one is not.
**Caveats.** Reads must be block-aligned. **Every cell runs in both cuFile modes on both filesystems** so the
filesystem effect and the transport effect are separable (**D8**). **`LD_PRELOAD` scoped per cell** (pattern
#3). The aggregator implements all four parser idioms (pattern #7), including diff/dt on cumulative counters.
**⏳ DEFER:** path accounting is mandatory per cell (D-6); NUMA-aware GPU assignment (D-8); cuFile config
(D-10).

### `cufile-full-rdma.template.json` · `GDS-TUNING-CHECKLIST.md`
**What.** A parameterised cuFile configuration template, and a doc-grounded verify → measure → tune procedure.
**Why.** On a GDS-capable transport the cuFile config lists the client's own network addresses and transport
options; the WEKA leg runs a bootstrap-generated compat-mode config with no address list. The template plus
checklist keep the GDS-side procedure reproducible instead of folkloric.
**⏳ DEFER:** every value is environment-specific (D-10); the checklist needs a Lustre-over-EFA section.

---

## Stage 5 — Training

### `train-resnet50-stage5.py` + `sweep-stage5-training.sh` + `aggregate-stage5-training.py`
**What.** Real DDP training with an in-process reader (kvikIO or cuCIM CPU batched by flag), emitting a
**per-step CSV** with the dataload / forward / backward / optimiser split.
**Why.** Stage 4 measures what storage delivers; this measures whether a training loop **consumes** it at
scale. The per-step phase split is what makes a scaling falloff *attributable* rather than narrated.
**Caveats — three trainer-correctness requirements, all load-bearing for the storage measurement:**
`cudnn.benchmark`, `channels_last`, and **CUDA-event phase timing rather than per-phase host syncs**. Without
them compute runs several times slower than optimal, which **understates the demand placed on storage** and
flatters both filesystems. Self-launches ranks via `mp.spawn` with an explicit loopback master rather than a
launcher whose rendezvous binds to a resolved hostname that may not be on a local interface; `spawn` not
`fork`, because forked CUDA workers inherit a broken context. One rank = one in-process reader on the kvikIO
path (its internal pipelining already provides the parallelism). The cuCIM reader configuration is **re-tuned
per filesystem, never copied** — the optimum reflects a decode-vs-storage-latency interaction, so imposing
one side's optimum on the other is a fairness bug that reads as a filesystem difference.
**⏳ DEFER:** NUMA-aware GPU pinning order (D-8); cuFile env values (D-10). The GPU-count *range* is set:
N ∈ {1, 2, 4} on both blocks, matching the 4-GPU instance.

---

## Stage 6 — Feature extraction, MIL, concurrency, end-to-end

### `extract-features-foundation-stage6.py` + `sweep-stage6a-extract.sh` + `aggregate-stage6a-extract.py`
**What.** DDP wrapper loading three foundation models in frozen eval mode, fed by either data path, writing
per-slide feature tensors. Emits a per-extraction-step CSV.
**Why.** The 2024-onward production workload. Three models because production labs use them interchangeably
and they span a useful range of compute weight, which shifts the storage-to-compute balance.
**It refuses to save any slide whose embedding buffer was not completely filled.** The buffer is
`torch.empty`, so a row the batch loop never reached still holds whatever was previously in that GPU memory;
saving it writes **uninitialised memory to disk as a feature vector**, under a header claiming `n_tiles` real
rows. Such a file loads cleanly, has the right shape and dtype, and trains without error — nothing
downstream can detect it, which is why this is a refusal rather than a warning.
**Output schema.** The summary carries **`n_slides_incomplete_refused`**, and the process **exits non-zero**
whenever it is above zero, so no driver can mark the step done on a feature set that is missing slides.
**Caveats.** **Cleanup-before-cell is mandatory** (pattern #5) — the extractor skips existing output, so
without a wipe every cell after the first short-circuits and reports a plausible-looking meaningless number.
Ranks take **disjoint** partitions (the model is frozen, so DDP is throughput-only). The largest model may
need a reduced batch size — if so, apply it **identically on both legs** or it becomes a fake filesystem
difference.

### `run-stage6a-tier2-chunked.sh` · `run-stage6a-tier2-chunked-multimodel.sh` — production-scale orchestrators
**What.** Convert a chunk of slides to raw-TIFF → extract → delete the chunk → advance. The multi-model
variant converts **once per chunk** and extracts for all models before deleting.
**Why.** Full-cohort raw-TIFF does not fit at once, and conversion is a large share of per-chunk wallclock —
so sharing it across models is structural, not a micro-optimisation.
**Caveats.** An aborted run **leaves chunks that get silently reused**. Verify cleanup between runs.

### `generate-synthetic-features-stage6b.py`
**What.** Writes a synthetic feature-file corpus at a specified file count, size, and dtype.
**Why.** The differentiating I/O pattern is small-file reads plus metadata operations, for which embedding
*content* is irrelevant — synthetic gives controlled scale, size distribution, and bit-width, none of which
the real corpus provides.
**Caveats — the most consequential sizing decision in the project.** The corpus must exceed **the client page
cache plus the larger of the two filesystems' server-side caches**, or a cell that is cold on one leg is
partly warm on the other and the difference looks like a filesystem property. ⏳ **Size it before Leg A
generates anything, using both filesystems' cache sizes, and use one identical definition on both legs.**

### `read-feature-files-stage6b.py` + `sweep-stage6b-stress.sh`
**What.** Reads feature files under a specified access pattern, optionally deserialising (production
behaviour), timing each load; multi-process, host-only.
**Why.** The metadata / small-file substage — structurally **not** bandwidth-bound, so it stays
discriminating even under a client-capped ceiling. Three access patterns because metadata-path behaviour is
pattern-sensitive and reporting only the friendliest or harshest would misrepresent both filesystems.
**The client page cache is dropped once, in a throwaway child of the parent, before the worker pool exists.**
A drop issued from inside a pool worker races every other worker: they are already reading by then, so the
cache is warm when it fires and the eviction lands in the middle of their measurement — the worst of both,
since the cell is then neither cold nor undisturbed. The child exists to keep the parent CUDA-free: the
discard helper lives in cucim, whose import pulls in the CUDA stack.
**Output schema.** The summary carries **`client_page_cache_discarded`** — the state **achieved**, not
requested (**D13**). `null` = not attempted; `false` = attempted and failed, which makes the cell **warm**
and it must be labelled warm rather than called cold with a caveat. Client page cache only — it says nothing
about the filesystem's server-side cache, the other half of the cold-state question.
**Caveats.** Caches cleared before each cell **to the extent achievable, and recorded as achieved** (**D13**).

### `train-mil-stage6b.py` + `sweep-stage6b-mil.sh` + `aggregate-stage6b.py`
**What.** Attention-MIL training over real extracted features at **`batch_size=1` with `collate_MIL`**;
`num_workers` is the swept axis.
**Why.** Verified against upstream CLAM: one slide per forward step, 2-D bag input, never a padded batch —
which **OOMs**, because padding inflates to the largest bag in the batch and WSI bag-size distributions are
wide. **Storage concurrency comes from `num_workers`, not `batch_size`.**
**Caveats.** The real feature corpus fits comfortably in instance RAM, so this workload is largely
**memory-served on both filesystems** after its first pass — what it measures is **MIL throughput, not
storage bandwidth**, and the cold storage number belongs to the synthetic corpus. Say so rather than letting
a reader infer a storage result.

### `orchestrate-concurrent-stage6c.sh` + `sweep-stage6c.sh` + `aggregate-stage6c-concurrent.py`
**What.** Launches up to four concurrent workloads, each emitting its own telemetry CSV, plus an
`orchestration.log` of start / ramp-end / steady-end for window alignment.
**Why.** Concurrent heterogeneous load on one namespace is where storage architectures diverge, and no
single-workload measurement surfaces it. Pair and triple tiers exist so an all-four result is
**diagnosable** rather than a single number with no cause.
**Caveats.** Uses pattern **#2**. Retention is computed against **same-filesystem** solo baselines re-measured
at the exact concurrent config. The ingest workload is **data-bounded** — it exhausts its source and exits, so
report it as "active throughout" with the active-window rate, not a retention percentage. Interference between
the training and viewer workloads may be a **host** effect present on both legs; per **D15**, host-CPU
accounting differs between legs, so check the core accounting before attributing it to the filesystem.

### `pipeline-end-to-end-stage6d.sh` + `aggregate-stage6d.py`
**What.** Sequential end-to-end orchestration, and the aggregator that composes the bookend from measured
per-phase numbers.
**Why.** The phases are strictly sequential with no shared-resource interaction, so measured per-phase
wallclocks compose **exactly** — running it live would repeat the long-pole stage for hours and add no
insight. Retained as the productisation template.
**Caveats.** **Every component must come from the same leg's run dirs.** The aggregators glob run dirs, so
mixing legs is easy to do by accident and would produce a number describing neither filesystem.

---

## Stage 7 — Clinical inference deployment

### `inference-per-slide-stage7.py`
**What.** Chains tissue detection → feature extraction → MIL → heatmap write for one slide, emitting a
per-phase latency row. Reuses the Stage 6 readers and MIL module.
**Why.** Deployment decisions are made on seconds-per-slide, not aggregate throughput — a different metric
from every earlier stage. The MIL aggregator runs **untrained in eval mode** because forward cost is identical
regardless of training state and we are measuring latency, not accuracy.
**Caveats.** Per-cell `LD_PRELOAD` scoping; exposes a start barrier for the orchestrator. Heatmap content is
**real attention weights** — zero marginal cost since the forward already runs, and it produces the artifact a
production system actually writes.

### `orchestrate-clinical-deployment-stage7.sh` + `sweep-stage7-clinical.sh` + `aggregate-stage7-clinical.py`
**What.** Runs N concurrent inference jobs and/or the four-way clinical mixed workload; per-cell driver;
aggregator over all sub-tiers.
**Why.** Concurrent jobs consume **disjoint** slide chunks, mirroring production (each clinician runs their
own slide) and preventing both idle processes and duplicated work from distorting the percentiles.
**Caveats.** Per-process batch size declines as concurrency rises to bound GPU memory — **the schedule is
instance-specific and must be re-derived**. Per-slide wallclock remains the metric regardless, since that is
what an SLA is written against. High-concurrency cells deliberately oversubscribe the GPUs and therefore
measure storage and queueing, not GPU throughput.

### `read-after-write-stage7.py`
**What.** A writer process emitting a tiled TIFF with **synthetic content**, and a reader polling that path
for visibility and then reading the first chunk.
**Why.** Read-after-write visibility is a **consistency** property, not a bandwidth one, and the two
filesystems have different metadata architectures — so there is no reason to assume they behave the same.
**Why the content is synthetic and not a real inference output.** Visibility depends on the file's size, its
tile structure and the fsync-then-rename ordering — not on what the pixels contain. Running the per-slide
inference chain to produce real heatmap pixels would add tens of seconds of orthogonal latency to every
iteration and dilute the quantity being measured. It is the one Stage-7 writer that is not a real forward,
and that exception is what this paragraph exists to justify.
**Caveats — a correctness requirement, not a style choice.** The writer must **write to a temporary name,
fsync, then rename.** Without it the file exists at zero length the moment it is opened, the reader's
existence check fires at creation, and the result is a plausible-looking number that measures nothing.
**Artifact size is requested, never assumed.** `--bytes-per-write` sizes the pixel grid through an assumed
deflate ratio that this content does not obey — the pattern is a small base tiled up by `np.repeat` and
compresses far harder — so the **achieved** size is `stat()`'d and both are recorded
(`bytes_per_write_target`, `bytes_written_mean_achieved`, `bytes_written_target_ratio`), with a **loud
warning** when they diverge past 2×. It matters because visibility latency depends on the artifact's real
size and tile geometry: an artifact an order of magnitude smaller than a production heatmap answers the
question for a file nobody writes. Per the Stage 7 decision the artifact is sized and tiled from a
**measured 7.3 output on the same leg** — pass that size in, and let the target-vs-achieved check confirm it.
**Output schema.** `visibility_latency_resolution_floor_ms` = the poll interval. The reader can only observe
the file on a poll boundary, so **any latency at or under it is quantisation, not measurement** — recorded so
nobody reads a sub-interval p50 as a real number. Recording the floor is unambiguous; **tightening the
interval is a tuning judgment against CPU cost and stays open.**
**Single-client scope:** writer and reader are processes on one instance; cross-client consistency would need
a second instance.

### `streaming-loop-stage7.sh`
**What.** Synthetic-scanner cadence driving the full arrival → inference → heatmap → viewer loop with
per-slide event timestamps.
**Why.** The end-to-end workflow bookend, and it captures cross-slide queueing if inference falls behind the
emitter — which a per-slide latency number alone would hide.

---

## Manifests (`../scripts/manifests/`)

| File | What | Used by |
|---|---|---|
| `tcga-brca-full40x-stage4a-format.tsv` | **The 1073-slide uniform-magnification cohort** (**D5**) | 6.A Tier 2, 6.B.3, 7.2/7.3/7.5, 6.D |
| `tcga-brca-stage4a-subset.tsv` · `camelyon16-stage4a-subset.tsv` | 50-slide subsets, fixed seed — the cross-stage anchor | 4.A, 4.C, 5, 6.A Tier 1/3, 7.1/7.6 |
| `tcga-brca-full.tsv` · `camelyon16-full.tsv` | Full download manifests | One-time staging into S3 |
| `tcga-brca-full-stage4a-format.tsv` | Full cohort before the magnification-uniformity exclusion | Retained for traceability — **not** the cohort of record |
| `tcga-brca-pilot.tsv` | Small pilot set | Smoke tests |

**These are filesystem-agnostic and carry over unchanged** — they are part of what makes the datasets a
held-constant input across legs (**D6**).

---

## Cross-references

`../CLAUDE.md` (rules, recording, durability) · `../PROJECT-THESIS.md` (the question, both asymmetries, and
the framing rule, §10) · `STAGES.md` (the cross-stage decision register) · `RUNBOOK.md` (how to run a cell,
both canaries, silent-skip hazards) · `FILESYSTEM-MAP.md` (paths) · `NAMING-AND-VARIABLES.md` (every name and
its recommended value) · `RESULTS.md` (findings) · the per-stage roadmaps (methodology and per-cell results) ·
`cloud-session-open-items` memory (the running tracker, including every `⏳ DEFER` above).
