# Script tracker — per-script reference for `runs/lib/`

> **63 files** (59 copied intact + `sync-to-s3.sh`, `env-contract.py`, `run-leg.sh`,
> `teardown-preflight.sh` — new), all
> syntax-clean. Nothing has run.
>
> **Configuration comes from the environment, never from hardcoded literals.** Every variable is enumerated
> in **`cloud-setup/NAMING-AND-VARIABLES.md`** with its recommended value, and set via
> **`cloud-setup/env.example.sh`** → `env.sh` (which has a `--check` mode that validates before anything
> runs). **Read that doc before editing any script** — it is the single source of truth for names, and the
> reason `$FS_MOUNT` exists.
>
> The remaining retargeting and per-filesystem adapter work is listed under **Deferred work** below.

For *what* each stage is see `runs/STAGES.md`; for how to run a cell `runs/README.md`; for where things live
`FILESYSTEM-MAP.md`; for the rules `CLAUDE.md`.

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

### ✅ Done before leaving the build machine (2026-08-03)

These were mechanical rather than environment-dependent, so they were completed here to shorten the cloud
session's critical path — and because each has a **silent** failure mode that a guard can convert into a loud
one.

| # | Work | What was done | Verification |
|---|---|---|---|
| **D-1** | Mount retargeting to `$FS_MOUNT` | `/mnt/liad` → `${FS_MOUNT}` in **25 shell files**; the **7 real Python argparse defaults** across 4 files rewritten to derive from `FS_MOUNT` | `grep`: **0 files** retain the old mount path |
| **D-2** | Repo-root retargeting | The hardcoded `REPO=` line in **28 shell files** replaced with derivation from the script's own location; 14 further files cleaned of other absolute paths | `grep`: **0 files** retain the old repo path |
| **D-3** | `--fs` plumbing | `record-run.sh` now **requires** `--fs {weka\|lustre}`, puts it in the run-dir name and as a first-class `metadata.json` field — **and cross-validates it against `FS_MOUNT`**, refusing to record a run whose label might not match the filesystem written to | All four paths tested: missing, invalid, mismatched, agreeing |
| **D-12** | Environment contract | `env-contract.py` — `write` / `verify` / `show`, with the **held-constant vs expected-to-differ field split** that makes verification meaningful | Round-tripped: 0 violations, unrecorded fields correctly reported as *unverifiable* and failing |
| **D-14** | Leg orchestrator | `run-leg.sh` — 21 steps in dependency order, with all four unattended guards | `--list`, `--dry-run`, and both refusal paths tested |

**The safety property common to all of them:** an unset or inconsistent mount now **aborts loudly** instead of
defaulting. That converts this project's worst failure mode — *silently measures the wrong filesystem while
the number still looks correct* — into *refuses to run*.

### ⏳ Still deferred — genuinely needs the real environment

| # | Work | Scope | Why it can't be done yet |
|---|---|---|---|
| **D-4** | **Per-filesystem recording adapters** | `record-run.sh`, `parse-results.py`, **13 aggregators** that assume one filesystem's telemetry | Each filesystem exposes different primary sources with different **schemas** (**D12**). Requires the real stats output to write against |
| **D-5** | **Per-filesystem consistency relation** | The canary logic in the aggregators | Must be derived from the actual EC scheme (WEKA) and the actual stripe layout (Lustre) — neither exists yet |
| **D-6** | **cuFile path accounting as a recorded source** | `record-run.sh` + the kvikIO readers | Needs the real cuFile/nvidia-fs stats format. Every kvikIO cell must record GPU-direct-vs-bounced bytes or it is incomplete (**D8**) |
| **D-7** | **During-run sync, watchdog, canary-abort** | `record-run.sh` | **Partly done:** `sync-to-s3.sh` exists and `run-leg.sh` syncs after every step. Still needed: per-**cell** sync inside `record-run.sh`, the per-cell watchdog timeout, and making the canary abort the chain |
| **D-8** | **GPU/NUMA map + DDP ranges** | `run-multiproc-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6a-extract.sh`, `sweep-stage7-clinical.sh` | The GPU↔NUMA↔NIC map must be re-derived on the real instance; GPU-count sweeps follow its GPU count |
| **D-9** | **Core accounting** | Aggregators computing CPU headlines | The reserved-core exclusion set is a **per-filesystem parameter** (**D15**), and the reserved count is only measurable on the real client |
| **D-10** | **cuFile config + env paths** | **20 files** reference conda/cuFile/CUDA paths — now via variables, but the *values* are unknown | Includes rewriting `GDS-TUNING-CHECKLIST.md` (bannered) and generating `cufile.json` with this instance's own addresses |
| **D-11** | **Lustre tuning** | Stripe layout + client tunables | Needs FSx (Leg B). **Part of "Lustre at maximum" (D7)** — skipping it would understate Lustre and break the fairness basis |
| **D-13** | **1.7 hydration driver** | New `sweep-stage1-hydrate.sh` | Needs the real bucket. `run-leg.sh` reports this step as **MISSING and aborts** rather than skipping it |

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
   per-second sums. Filter by a stable identity (hostname + role) — **never** a numeric process/node id,
   which is reassigned on reinstall. ⏳ **The pattern generalises to both legs; the filter does not** (D-4).
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
   aggregators — don't regress them.
8. **Idle-robust active-window mean.** Throughput headlines use a trimmed active-window mean rather than a
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
**⏳ DEFER:** `--fs` flag (D-3); per-filesystem recorders (D-4); cuFile path accounting (D-6); during-run S3
sync, per-cell watchdog, canary-abort (D-7).

### `parse-results.py` — raw CSVs → `results.json`
**What.** Reads a run dir's `raw/` time series and writes aggregate statistics.
**Why.** Independent of the wrapper, so a parser fix or a new derived metric never requires re-running the
benchmark — which matters when a cell costs hours.
**Caveats.** Overwrites `results.json` in place; raw data untouched. Implements the active-window mean.
**⏳ DEFER:** per-filesystem source schemas (D-4).

### `aggregate-sweep.py` — generic sweep aggregator
**What.** Rolls N run dirs into a summary CSV, including block-size × concurrency grids.
**Why.** The `fio` sweeps share one shape, so one generic aggregator serves all of them.
**Caveats.** The only aggregator taking an **explicit glob**; the per-stage ones self-locate via `__file__`.
**⏳ DEFER:** `--fs` pivot (D-3).

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
environment against a reference contract before the next leg's first cell; `show` prints one readably.
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

### `run-leg.sh` — unattended leg orchestrator ⭐ NEW (`D-14`)
**What.** Drives one whole leg's sweeps in dependency order: 21 steps, `--dry-run`, `--list`, `--from`,
`--only`.
**Why.** A leg is many hours of sweeps that must run in a fixed order because each stage produces inputs the
next consumes. Driving that by hand overnight invites a missed step or a silently-continued failure.
**It orchestrates SWEEPS, not cells** — per-cell recording and failure isolation stay with `record-run.sh`.
**The four guards, each with its reason:** (1) **abort the chain on any step failure** — later steps consume
earlier outputs, so continuing would build cells on missing inputs; (2) **checkpoint + resume** via per-step
done-markers, so a crash re-runs only what is missing; (3) **S3 sync after every step**, because both mounts
and local scratch are ephemeral; (4) **tee everything** — on an overnight run the log is the only forensic
record.
**Caveats.** Refuses to start without `FS_MOUNT`/`S3_BUCKET`, and **refuses if `--leg` disagrees with
`FS_MOUNT`**. A step whose driver does not exist yet is reported **MISSING and aborts** rather than being
skipped — *a leg with a hole in it looks complete in `INDEX.md`*, which is the failure this prevents. Two
steps are currently MISSING by design: 1.7 (`D-13`) and 6.B.1 (needs the corpus-size decision, open item 5b).

### `teardown-preflight.sh` — prove nothing is lost, before tearing down ⭐ NEW
**What.** Checks seven things and prints **GO / NO-GO**: nothing in flight · live memories mirrored · git clean
**and pushed** · environment contract complete **and in S3** · **every local run dir's raw telemetry present in
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
**⏳ DEFER:** mount (D-1), repo root (D-2), `--fs` (D-3).

### `chain-stage1-bcd.sh` — sweep chainer
**What.** Runs several Stage-1 sweeps back to back unattended.
**Why.** The precedent for leg-level chaining (D-14) — cells are already isolated, so chaining is safe.

### `fe-core-fio.sh` · `fe-core-kvikio.sh` — shared cell helpers
**What.** Single-cell helpers for a `fio` cell and a kvikIO cell, used for baselines and quick checks.
**Why.** Phase 0 needs the ceiling captured **per block size** without standing up a whole sweep.
**⏳ DEFER:** `fe-core-kvikio.sh` carries cuFile env paths (D-10) and needs path accounting (D-6).

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
any sustained mean is ill-defined — a sampling limit, not a recording failure. The app-level headline is
unaffected. ⏳ **Resolve the sampling approach before the first cell and apply it identically to both legs.**
**⏳ DEFER:** ops-counter comparability across legs is unresolved — app-level throughput is the cross-leg
headline until counter semantics are verified equivalent.

---

## Stage 3 — Tissue detection

### `sweep-stage3-tissue-detection.sh` + `aggregate-stage3-tissue-detection.py`
**What.** Drives the CLAM tissue detector across datasets × concurrency, producing the 20× coordinate lists
that gate Stages 4–7. Concurrency is external: the manifest is round-robin split into chunks and N detector
instances run in parallel into one output dir.
**Why.** Round-robin splitting guarantees no two chunks share a slide, so parallel instances cannot collide.
Per-dataset tiling arguments implement the 20× contract (**D2**). `--stitch` is omitted because its
visualisation output is not consumed downstream.
**Caveats.** The CPU headline is computed over **application-available** cores, and **the excluded core set
is a per-filesystem parameter** (**D15**) — WEKA reserves cores, Lustre does not. Two slides are expected to
yield no tissue under default parameters: real tool behaviour, storage- and magnification-independent, and
therefore a **cross-leg integrity check**.
**⏳ DEFER:** D-1, D-2, D-3, D-9.

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
**Caveats.** Reads must be block-aligned. **Every cell runs in both cuFile modes on both filesystems** so the
filesystem effect and the transport effect are separable (**D8**). **`LD_PRELOAD` scoped per cell** (pattern
#3). The aggregator implements all four parser idioms (pattern #7), including diff/dt on cumulative counters.
**⏳ DEFER:** path accounting is mandatory per cell (D-6); NUMA-aware GPU assignment (D-8); cuFile config
(D-10).

### `cufile-full-rdma.template.json` · `GDS-TUNING-CHECKLIST.md`
**What.** A parameterised cuFile configuration template, and a doc-grounded verify → measure → tune procedure.
**Why.** The cuFile config must list the client's own network addresses and the transport options the
filesystem needs; a template plus a checklist keeps that reproducible instead of folkloric.
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
**⏳ DEFER:** GPU-count range follows the instance (D-8); cuFile env (D-10).

---

## Stage 6 — Feature extraction, MIL, concurrency, end-to-end

### `extract-features-foundation-stage6.py` + `sweep-stage6a-extract.sh` + `aggregate-stage6a-extract.py`
**What.** DDP wrapper loading three foundation models in frozen eval mode, fed by either data path, writing
per-slide feature tensors. Emits a per-extraction-step CSV.
**Why.** The 2024-onward production workload. Three models because production labs use them interchangeably
and they span a useful range of compute weight, which shifts the storage-to-compute balance.
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
**Why.** The metadata/small-file headline substage — structurally **not** bandwidth-bound, so it stays
discriminating even under a client-capped ceiling. Three access patterns because metadata-path behaviour is
pattern-sensitive and reporting only the friendliest or harshest would misrepresent both filesystems.
**Caveats.** Caches cleared before each cell **to the extent achievable, and recorded as achieved** (**D13**).

### `train-mil-stage6b.py` + `sweep-stage6b-mil.sh` + `aggregate-stage6b.py`
**What.** Attention-MIL training over real extracted features at **`batch_size=1` with `collate_MIL`**;
`num_workers` is the swept axis.
**Why.** Verified against upstream CLAM: one slide per forward step, 2-D bag input, never a padded batch —
which **OOMs**, because padding inflates to the largest bag in the batch and WSI bag-size distributions are
wide. **Storage concurrency comes from `num_workers`, not `batch_size`.**
**Caveats.** The real feature corpus fits comfortably in instance RAM, so this workload is largely
**memory-served on both filesystems** after its first pass — so its headline is **MIL throughput, not storage
bandwidth**, and the cold storage number belongs to the synthetic corpus. Say so rather than letting a reader
infer a storage result.

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
**What.** A writer process (inference + heatmap write) and a reader polling for visibility then reading.
**Why.** Read-after-write visibility is a **consistency** property, not a bandwidth one, and the two
filesystems have different metadata architectures — so there is no reason to assume they behave the same.
**Caveats — a correctness requirement, not a style choice.** The writer must **write to a temporary name,
fsync, then rename.** Without it the file exists at zero length the moment it is opened, the reader's
existence check fires at creation, and the result is a plausible-looking number that measures nothing.
**Single-client scope:** writer and reader are processes on one instance; cross-client consistency would need
a second instance.

### `streaming-loop-stage7.sh`
**What.** Synthetic-scanner cadence driving the full arrival → inference → heatmap → viewer loop with
per-slide event timestamps.
**Why.** The end-to-end workflow bookend, and it captures cross-slide queueing if inference falls behind the
emitter — which a per-slide latency number alone would hide.

---

## Manifests (`runs/manifests/`)

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

`CLAUDE.md` (rules, recording, durability) · `PROJECT-THESIS.md` (the question and both asymmetries) ·
`runs/STAGES.md` (**D1–D15**) · `runs/README.md` (runbook, both canaries, silent-skip hazards) ·
`FILESYSTEM-MAP.md` (paths) · the per-stage roadmaps (methodology and audit trail) ·
`cloud-session-open-items` memory (the running tracker, including every `⏳ DEFER` above).
