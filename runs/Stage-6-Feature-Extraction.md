# Stage 6 — Feature extraction & downstream MIL, measured identically on both filesystems

> **STATUS — read first.** Nothing has run. Every number below is **`[PENDING]`** and every interpretation
> section is **`[STORY PENDING RESULTS]`**.
>
> **Every substage runs on both filesystems** — WEKA (Leg A) then FSx for Lustre (Leg B) — with everything
> else held constant. The delta is the result.
>
> Stage 6 is the largest stage: four substages covering four distinct I/O personalities, and the one that
> maps most directly onto what production WSI research pipelines actually do.

For project-wide conventions see `../CLAUDE.md`; framing and the fairness contract `../PROJECT-THESIS.md`;
stage map and decision log **D1–D15** `STAGES.md`; runbook `README.md`. Stage 4 supplies both data paths
and the raw-TIFF artifact; Stage 5 supplies the DDP scaling context.

---

## What Stage 6 measures

**Four I/O personalities, plus one integrating bookend:**

| Substage | Workload | I/O personality | The question it answers |
|---|---|---|---|
| **6.A** | Foundation-model feature extraction | Random tile reads at production rates, single pass, GPU-compute-heavy per step (large frozen ViT forward) | Does each filesystem keep production extractors fed, across the dominant open-weight model families, at scale? |
| **6.B** | Small-file / metadata stress | Random reads of many small per-slide feature files; no compute; metadata plus small-block I/O | How does each filesystem's metadata path handle the downstream-training file-I/O pattern that pegs legacy NAS metadata servers? |
| **6.C** | Concurrent multi-workload | All four real workloads at once: ingest + extract + MIL training + viewer | Can each filesystem serve all four simultaneously on one namespace without QoS interference, sustained over hours? |
| **6.D** | End-to-end pipeline timing | Composed from the above | How long does the complete pipeline take, per filesystem? |

**6.B and 6.C are structurally the most discriminating substages in the project.** Their axes — small-file
metadata behaviour and concurrent-workload fairness — are not bandwidth-bound, so they remain informative
even though bandwidth is expected to be capped by the client (see `STAGES.md` § comparison structure).
That is a statement about *where information can live*, not a prediction about which filesystem wins.

The models: **UNI2-h** (ViT-H/14, 1536-dim) · **Virchow2** (ViT-H, 1280-dim) · **GigaPath** tile encoder
(ViT-G/14, 1536-dim). Tiles are a uniform **256 px @ 20×** for all three (**D1–D3**).

---

## ⚠️ Scope caveat — read before presenting Stage 6 numbers

**Both legs measure POSIX access.** Object access is out of scope on both sides.

**Deliberately not covered**, with reasons recorded so these read as choices rather than omissions:

- **GigaPath's LongNet slide-level aggregator.** Its tile encoder is in scope as a frozen feature
  extractor; the slide-level aggregator is a different model architecture with a different I/O profile.
- **Pretraining or fine-tuning.** All three models run in `eval()` mode. Fine-tuning is an enormous compute
  workload and would not change the storage axis.
- **Multi-magnification extraction.** Adding a second magnification means regenerating coords and
  raw-TIFF at another level for marginal comparison value. The base 20× is fixed by **D1**.
- **Multi-client scaling.** Single-client study on both sides (`../PROJECT-THESIS.md` § scope).
- **Model precision as an axis.** AMP FP16 is the standard production setting and is held constant. We
  *do* vary **feature-file** bit-width (FP32 vs FP16 on disk) in 6.B — a storage question, not a compute one.
- **Convergence-based MIL training.** 6.B.3 trains on synthetic labels for throughput. No accuracy claim.

---

## ⚠️ The cold-cache problem — and a sequencing consequence that affects Leg A

This is the most important methodological issue in Stage 6, and it has to be resolved **before Leg A
generates its corpus.**

**The problem.** 6.B.2's headline cells are supposed to be **cold** — every read forced through the
filesystem rather than served from cache. But there are now **two** caches between the workload and the
disks, and they are of comparable size:

1. **The client's page cache** — the instance has 768 GiB of RAM *(subject to change with instance)*.
2. **The filesystem's own server-side cache** — and this is where it gets asymmetric. A maxed FSx at
   PERSISTENT-1000 carries roughly **27.3 GiB of file-server cache per TiB provisioned** (order ~680 GiB
   at 25 TiB), while WEKA's backend caching depends on the backend instance type and count we choose.
   **The two numbers are not equal and are not under common control.**

**So a corpus that is genuinely cold on one filesystem may be partly warm on the other** — which would
produce a difference that looks like a filesystem property but is actually a cache-size artifact.

**The consequence for sequencing.** To be cold on both legs, the corpus must exceed the client page cache
**plus the larger of the two server-side caches.** But **Leg A runs first**, and its corpus is generated
before Lustre exists. Two ways out, and the choice must be made deliberately:

- **(a) Size the corpus up front using both filesystems' planned cache sizes** — requires knowing the FSx
  tier and capacity before Leg A's corpus generation, i.e. deciding Leg B's provisioning early even though
  it is provisioned later. **Recommended:** the FSx configuration is already fixed by **D7** (maxed), so
  its cache size is computable in advance, and it keeps one identical corpus across both legs — preserving
  the held-constant contract.
- **(b) Generate a differently-sized corpus per leg** — breaks the held-constant contract on the very
  substage where the comparison is most sensitive. **Not recommended.**

**Either way, "cold" must be verified per cell, not asserted** (**D13**). Cache-clearing on the client is
straightforward; the server side is only partly under our control on managed storage. **Record what was
actually achieved** and state the residual uncertainty rather than labelling a cell cold on faith.

*Tracked as an open item; must be resolved before the first 6.B.1 generation run.*

---

## Strategy framing

Each substage answers a question no earlier stage touches, and its output feeds the next.

- **6.A** — three models × two data paths × a GPU-count sweep on the cross-stage subset (Tier 1), then
  production scale on the full cohort (Tier 2), then a cross-dataset check (Tier 3).
- **6.B** — **B.1** generate a controlled synthetic corpus; **B.2** stress it (the metadata/small-file
  headline); **B.3** train a real attention-MIL classifier on the *real* 6.A features. B.2 gives controlled
  scale, B.3 grounds it in the actual production workload — **both are needed**, because B.2 alone invites
  "synthetic, not real" and B.3 alone cannot reach controlled scale.
- **6.C** — solo baselines → pairs → triples → all four → endurance. The intermediate tiers exist so that
  if interference appears at all-four-up, we can already say **which pair causes it**.
- **6.D** — the end-to-end bookend, **composed constructively** from measured per-phase numbers.

**Sequencing per leg:** Phase 0 → smoke → 6.A Tier 1 → Tier 3 → Tier 2 → **6.B.3** (real features now
exist) → 6.B.1 → 6.B.2 → 6.C ascending tiers → 6.D → closeout. *Why 6.B.3 before 6.B.1/2:* it uses the
real features Tier 2 just produced, lands the real-workload number sooner, and smoke-tests that pipeline
before committing the synthetic corpus's disk footprint.

**GPU sweep N ∈ {1, 2, 4}** — the instance has 4 GPUs *(subject to change)*, matching Stage 5 for
cross-stage comparability. NUMA-aware assignment with the map re-derived per instance (**D15**).

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All substages are ⏳ on both legs.

### 6.A — Foundation-model feature extraction

For every tile in every tissue-detected slide, run a frozen foundation-model ViT and write a per-slide
`.pt` holding an `[N_tiles × D]` feature tensor.

#### 6.A Tier 1 — Scaling sweep on the 50-slide subset

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | The tiles/sec curve across GPU count for each model, on both data paths, on the cross-stage subset |
| **Tool** | `lib/extract-features-foundation-stage6.py` — DDP wrapper loading each model in frozen eval mode, fed by either the kvikIO reader or the cuCIM CPU-batched reader, writing per-slide `.pt`. Self-launches via `mp.spawn`; AMP FP16 + `channels_last` + `cudnn.benchmark` |
| **Backends** | (a) kvikIO/cuFile + raw-TIFF. (b) cuCIM CPU batched |
| **Source → Target** | `$FS_MOUNT` raw-TIFF or canonical SVS (per backend) → GPU → frozen ViT forward → per-slide accumulate → `$FS_MOUNT/features/6.A/<model>/<dataset>/<slide-id>.pt` |
| **Methodology** | Same DDP mechanics as Stage 5 (spawn, `channels_last`, AMP, CUDA-event timing, no inter-phase host syncs). Single pass through the slide pool; each rank takes a **disjoint partition** — DDP here is data-parallel for throughput only, since the model is frozen. **Cleanup before each cell** wipes that model's output dir, because the extractor's skip-on-existing logic would otherwise short-circuit every cell after the first and silently produce a meaningless number |
| **Cell count** | **3 models × 3 N (kvikIO) = 9**, plus **3 models × one N (cuCIM comparator) = 3** → **12 cells per leg** |
| **cuFile mode** | Best available mode per filesystem, plus one mode-controlled paired cell — the same reduction as Stage 5.A, for the same reason (Stage 4.C already characterises the full mode grid) |
| **Why this exists** | Establishes each filesystem's supply curve for the heaviest production model class, and does it across three models so the result is not tied to one model's compute profile. The cuCIM comparator quantifies the migration trade-off in the foundation-model regime, where compute per step is far heavier than in Stage 5 — a different balance point between storage and compute |
| **Why the cuCIM comparator sits at one N rather than the full sweep** | Its scaling curve is already established in Stage 5.B for the same reader; here it functions as a data-path comparator at a fixed scale. Recorded as a scoping choice |
| **⚠ `LD_PRELOAD` scoped per cell** | Mixed kvikIO/cuCIM sweep — set the preload on kvikIO cells only |
| **Sweep driver** | `lib/sweep-stage6a-extract.sh` · **Aggregator** `lib/aggregate-stage6a-extract.py` |
| **Headline results** | `[PENDING]` — tiles/sec per (model × backend × N), scaling efficiency, kvikIO/cuCIM ratio per N, filesystem-side read mean/peak and **% of the block-size-matched ceiling**, GPU utilisation, cross-source canary |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

#### 6.A Tier 2 — Production scale (full 1073-slide cohort)

| | |
|---|---|
| **Status** | ⏳ both legs — the long pole of the stage |
| **Goal** | The production-scale number: features extracted from the full cohort, all GPUs, per model, per filesystem |
| **Dataset** | The **uniform 1073-slide cohort** (`manifests/tcga-brca-full40x-stage4a-format.tsv`) per **D5**, with the fail-loud mpp guard as defence in depth |
| **Pre-cell prep — chunked raw-TIFF conversion** | The kvikIO path needs raw-TIFF resident, and the full cohort's raw-TIFF does not fit at once. So: convert a chunk → extract → delete the chunk → advance. The cuCIM path skips this (reads canonical SVS) |
| **Conversion sharing** | The multi-model orchestrator converts **once per chunk**, then extracts for each model in turn before deleting the chunk. *Why:* a per-model orchestrator would convert the cohort three times, and conversion is a large fraction of per-chunk wallclock — so sharing it is not a micro-optimisation but a structural one |
| **Cell count** | **3 cuCIM (per model) + 1 multi-model kvikIO (three models sharing the chunked conversion) = 4 cells per leg** |
| **Methodology** | Same DDP and reader logic as Tier 1, across all 1073 cohort slides at the full GPU count. Per-slide `.pt` to `$FS_MOUNT/features/6.A/<model>/brca_full/`. Cleanup-before-cell as in Tier 1 |
| **Why this exists** | Subset numbers invite "does this hold at my dataset's scale?" The full-cohort cells answer it directly, on both filesystems, for all three models and both data paths |
| **⚠ Capacity + hygiene** | Chunked conversion means transient raw-TIFF plus permanent features on the filesystem under test. **Confirm headroom per leg first.** The converter skips existing non-empty output, so a leftover chunk from an aborted run would be silently reused — **verify chunk cleanup between runs** |
| **Expected output count** | 1073 slides × 3 models = **3219 `.pt` files per leg**; verify the count and a zero-failure/zero-leaked-chunk condition before accepting the cell |
| **Headline results** | `[PENDING]` — per-model steady-state tiles/sec (both backends), per-cell wallclock, kvikIO/cuCIM ratio at production scale, filesystem-side read sustained and % of the matched ceiling, per-chunk convert-vs-extract split, cross-source canary |
| **Cross-leg integrity check** | Feature file **count, per-slide tile count, and tensor shape** are storage-independent and must match between legs. A divergence means the legs did not process equivalent inputs — **fail loud**, as with the Stage 3 coord gate |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

#### 6.A Tier 3 — Cross-dataset validation (CAMELYON16)

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | Cross-vendor format consistency in the foundation-model regime |
| **Cell count** | **3 cells per leg** — three models at a mid GPU count, kvikIO, CAMELYON16 50-slide subset |
| **Methodology** | Identical to the matching Tier 1 cells except the dataset. CAMELYON16 is native 20× so it uses `--patch_level 1 --patch_size 256` per the coord contract — no resize. A mid GPU count is chosen because this is a **consistency check, not a throughput peak**, so it does not need the full sweep |
| **⚠ Long-tail sensitivity** | CAMELYON16's per-slide tile counts vary more than BRCA's, so at multi-rank scale the **slowest rank dominates wallclock**. Two consequences: collective timeouts must be generous enough to tolerate the straggler (a too-short default will kill an otherwise valid cell), and the throughput number should be read alongside the tile-count distribution rather than on its own |
| **Why this exists** | Closes the "what about non-TCGA data?" question at the feature-extraction layer, and — because the dataset ratio is driven by tile-count distributions rather than storage — doubles as a **sanity check on the comparison itself**: the ratio should be similar on both filesystems |
| **Headline results** | `[PENDING]` — tiles/sec per model, and the CAMELYON16/BRCA ratio against the matching Tier 1 cells |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

**6.A total: 19 cells per leg** (12 Tier 1 + 4 Tier 2 + 3 Tier 3). Wallclock recorded, not estimated.

---

### 6.B — Small-file / metadata stress

#### 6.B.1 — Synthetic feature-file corpus generation

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Type** | A one-shot generation pass rather than a benchmark cell — but **wrapped in `record-run.sh` anyway**, because the sustained write is itself a recordable workload and comes free |
| **Tool** | `lib/generate-synthetic-features-stage6b.py` — writes synthetic `.pt` files at a specified `(N_files, file_size, dtype)`, with tile count computed to hit the target size |
| **Grid** | **File sizes bracket the real 20× feature distribution** (~40–65 MB/slide at ~8–15K tiles), **fixed at substage entry against the actual 6.A Tier 2 file-size distribution** rather than guessed. `N_files` spans small to production scale; `dtype ∈ {FP32, FP16}`. Stored at `$FS_MOUNT/features-6.B-synthetic/` |
| **Why synthetic rather than real files** | The I/O pattern — small-file random reads plus metadata operations — is what differentiates storage architectures, and embedding *content* is irrelevant to it. Synthetic gives controlled scale, a controlled size distribution, and a controlled bit-width, none of which the real corpus provides |
| **⚠ Corpus sizing is the cold-cache decision** | The production-scale corpus **must exceed the client page cache plus the larger of the two filesystems' server-side caches** — see the cold-cache section above. **This makes corpus sizing a cross-leg decision that must be made before Leg A generates anything**, and it must produce **one identical corpus definition for both legs** |
| **Why FP16 is an axis** | Halving file size changes the metadata-to-bytes ratio, which is precisely the balance that a metadata-heavy workload is sensitive to. Low marginal cost, directly relevant axis |
| **Headline results** | `[PENDING]` — generation wallclock, sustained write throughput, total bytes, resulting file-size distribution |
| **Cache-regime disclosure (required output)** | At substage entry, record **which B.2 cells will be cache-served and which genuinely cold**, per filesystem, given the measured cache sizes. Framing must state which regime each number represents — a cache-served number presented as storage throughput would be wrong on either side |

#### 6.B.2 — File-I/O stress sweep

| | |
|---|---|
| **Status** | ⏳ both legs — **the metadata/small-file headline substage** |
| **Goal** | Small-file random-read throughput and operation rate at production concurrency, across file size, concurrency, access pattern, and bit-width |
| **Tool** | `lib/read-feature-files-stage6b.py` — reads `.pt` files per an access pattern, optionally deserialising via `torch.load` (production behaviour, including host-side unpickling), timing each load, emitting a per-file-load latency CSV. Multi-process via `Pool` (host-only; no CUDA in the parent) |
| **Sweep grid** | **(a) Saturation:** mid-scale corpus × file size × concurrency × pattern × dtype — the main curve. **(b) Production scale:** large corpus × high concurrency × random × FP32 — **the genuinely cold cells** that produce the storage-bandwidth number. **(c) File-size sensitivity:** fixed concurrency across the size tiers |
| **Access patterns** | **random** — uniform file choice per read, modelling the production MIL DataLoader. **batched-shuffled** — per-epoch shuffle, sequential within it, modelling a single training epoch. **sequential** — directory order, the best case for prefetch heuristics, which sets an upper reference. *Why three:* a metadata path's behaviour is pattern-sensitive, and reporting only the friendliest or only the harshest pattern would misrepresent both filesystems |
| **Methodology** | **Clear caches before each cell** to the extent achievable per filesystem, **and record what was achieved** (**D13**). Time-bounded cells with ramp plus steady state. Per-file-load latency sampled. **Headline metrics: aggregate files/sec AND the filesystem-side operation rate** — with the cross-leg caveat from `Stage-2-Cataloging.md` applying to the latter |
| **Why this exists** | This is the workload that separates a distributed-metadata architecture from a metadata-server-bottlenecked one, at the scale where the difference appears. It is also **structurally non-bandwidth-bound**, so it stays informative under a client-capped ceiling |
| **Headline results** | `[PENDING]` — cold-cache read throughput at production scale, operation-rate peak, the saturation curve across all four axes, pattern sensitivity, bit-width sensitivity, per-cell cache-regime label, cross-source canary on every cold cell |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

#### 6.B.3 — Real attention-MIL training on real 6.A features

| | |
|---|---|
| **Status** | ⏳ both legs — needs 6.A Tier 2 features |
| **Goal** | The Phase-2 workload in its production training context: what storage sees when a real MIL classifier consumes real feature files at realistic worker counts |
| **Tool** | `lib/train-mil-stage6b.py` — gated-attention MIL (Tanh × Sigmoid → softmax → weighted-sum slide feature → linear classifier), `DataLoader(batch_size=1, collate_fn=collate_MIL, num_workers=N)`, per-step CSV with CUDA-event phase timing |
| **⚠ Architecture — `batch_size=1` + `collate_MIL`, non-negotiable** | Canonical CLAM trains **one slide per forward step** and never builds a padded `[B, max_N, D]` batch tensor. Verified against `mahmoodlab/CLAM`: `get_split_loader` always sets `batch_size=1, collate_fn=collate_MIL`; the model forward takes a 2-D `[N, D]` bag. **The padded design OOMs** — the batch tensor inflates to the largest-bag slide in each batch and WSI bag-size distributions are wide. **The storage-concurrency axis is `num_workers`, not `batch_size`**: `num_workers=32` means 32 slides read concurrently regardless of batch size. (`canonical-clam-mil-bs1` memory; magnification-independent) |
| **Source** | Real features from 6.A Tier 2 on the same leg (1073 `.pt` per model, ~40–65 MB each at 20×) |
| **Grid** | **3 models × `num_workers ∈ {4, 16, 32}` = 9 cells per leg.** UNI2-h cells tagged `[PENDING-APPROVAL-DO-NOT-EXTERNALIZE]` |
| **Methodology** | Canonical CLAM `bs=1`; each DataLoader worker prefetches one slide via `torch.load`. Time-bounded cells with ramp plus steady state. Per-step CSV including `n_tiles_in_step`, since per-step work varies with bag size |
| **⚠ Expect a cache-dominated regime, and say so** | The full-cohort feature corpus at 20× is roughly 1073 × ~50 MB ≈ **~55 GB**, which fits comfortably in the instance's RAM. So after the first pass this workload will be largely **memory-served on both filesystems**. That is not a flaw — it is what production looks like at this corpus size — but it means **B.3's storage signal lives in the cold first pass and the low-`num_workers` cells**, and its headline is **MIL throughput**, not storage bandwidth. The cold storage-bandwidth headline belongs to 6.B.2, whose corpus is deliberately sized past cache |
| **Why this exists** | B.2 alone invites the "synthetic, not real" objection. B.3 answers it with a real classifier over real foundation-model features, so the two together cover controlled scale *and* production fidelity |
| **Headline results** | `[PENDING]` — slides/sec and tiles/sec per model per `num_workers`, saturation knee, per-step phase split, cold-pass filesystem-side read, the cache-served regime boundary, cross-source canary |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

---

### 6.C — Concurrent multi-workload

Four real workloads on one filesystem simultaneously: **scanner ingest** (bulk copy at a fixed
"scanner pace"), **feature extraction** (the 6.A pattern), **MIL training** (the 6.B.3 pattern at its
saturation knee), and **viewer load** (small-block random reads).

**The metric is per-workload retention: concurrent throughput ÷ that workload's own solo throughput on the
same filesystem.** *Why same-filesystem:* the question is how much each filesystem degrades its own
workloads under contention — a fairness property. Comparing one filesystem's concurrent number against the
other's solo number would conflate contention behaviour with raw speed. **The retention percentages are
what compare across legs**, with absolutes reported alongside.

| Tier | Cells per leg | Content | Why it exists |
|---|---|---|---|
| **1 — Solo baselines** | 4 | Each workload alone at the **exact config used in the concurrent tiers** | These are the denominators for every retention figure, so they must be measured at the identical config rather than borrowed from an earlier stage where a parameter may differ. Also a drift canary: they should reconcile with the same leg's earlier stages |
| **2 — Pair-wise** | 4 | extract+ingest · extract+MIL · MIL+viewer · extract+viewer | Isolates **which pair** causes interference, if any. Without this, an all-four-up result is a single number with no diagnosis |
| **3 — Triple-up** | 2 | extract+MIL+ingest · extract+MIL+viewer | Separates "adding ingest" from "adding viewer" — the two have completely different I/O shapes |
| **4 — All four** | 1 | All simultaneously, sustained | The realistic-lab configuration |
| **5 — Endurance** | 1 | All four, sustained for hours | **The differentiator.** A short cell proves no instantaneous interference; hours prove no QoS drift, no resource leak, and no degradation as caches warm and working sets shift |

| | |
|---|---|
| **Tool** | `lib/orchestrate-concurrent-stage6c.sh` + `lib/sweep-stage6c.sh` · **Aggregator** `lib/aggregate-stage6c-concurrent.py` |
| **Methodology** | Workloads launched simultaneously by the orchestrator, each emitting its own per-workload telemetry CSV; one `record-run.sh` wraps the group as a single cell. An `orchestration.log` records each workload's start / ramp-end / steady-end so the aggregator can align per-workload windows correctly |
| **⚠ Ingest is data-bounded** | The ingest workload exhausts its source corpus and exits before the cell deadline, after which its mean reads as zero. **Report it as "active throughout, data-bounded by source" with the active-window rate extracted from the per-second telemetry**, rather than quoting a misleading retention percentage |
| **⚠ Interference can be host-side rather than filesystem-side** | MIL training and viewer load both go through the host page cache and host CPU, so contention between them may be a **host** effect present on both filesystems. Per **D15**, host-CPU accounting differs between legs (the WEKA client reserves cores), so an apparent difference here needs the core accounting before it is attributed to the filesystem |
| **Endurance failure recovery** | The orchestrator emits periodic checkpoint summaries so a partial failure still yields usable partial numbers, and `record-run.sh` marks the cell `INCOMPLETE`. If endurance fails repeatedly on a leg, fall back to the shorter all-four cell as the headline **and disclose the gap** rather than quietly presenting the short cell as endurance |
| **Headline results** | `[PENDING]` — per-workload retention at every tier, aggregate filesystem-side read and write, % of the matched ceiling, cross-source canary, and for the endurance cell the retention trend across the window |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

**6.C total: 12 cells per leg.** The endurance cell is the single longest item in the stage.

---

### 6.D — End-to-end pipeline timing (constructive, not a measured cell)

| | |
|---|---|
| **Status** | ⏳ both legs — **composed from measured per-phase numbers, not run as a separate cell** |
| **Why constructive** | The phases are strictly sequential by design with no shared-resource interaction, so the measured per-phase wallclocks compose to the end-to-end number **exactly**. Running it live would spend many hours largely repeating Tier 2 work to produce a number we can already compute, and would add no new insight. The remaining value of running it — proving the orchestrator works end to end — is a **productisation** concern, not a measurement one |
| **Composition** | Tissue detection (3.0, full cohort) + 6.A Tier 2 extraction (per model, per backend) + 6.B.3 MIL training to one epoch. The kvikIO path additionally includes the one-time raw-TIFF conversion, **amortised across the three models** since they share it |
| **Cells executed** | **0** |
| **Tool** | `lib/pipeline-end-to-end-stage6d.sh` — retained as the productisation template · `lib/aggregate-stage6d.py` |
| **⚠ Composition hygiene** | Every component must come from **the same leg's** recorded run dirs. Mixing phases across legs would produce a number describing neither filesystem — and it would be easy to do by accident, since the aggregator globs run dirs |
| **Headline results** | `[PENDING]` — one end-to-end figure per backend per filesystem, with the per-phase breakdown |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

---

## Recording approach (Stage 6-specific)

Over-capture by default — Stage 6 is the largest stage and re-running a cell is expensive. Standard
`record-run.sh` with **per-filesystem source adapters** (**D12**), plus:

### New primary sources

| Source | File | Substage | Captures |
|---|---|---|---|
| Per-extraction-step CSV | `extraction-steps.csv` | 6.A | Step index, timing, dataload vs forward split, samples per rank, world size, slide id, cumulative tiles. (No backward/optimiser — frozen eval) |
| Per-file-load latency CSV | `per-file-latencies.csv` | 6.B.2, 6.B.3 | Worker, file path and size, load latency, dtype, pattern — sampled |
| Per-step MIL training CSV | `training-steps.csv` | 6.B.3 | Stage-5 schema plus `n_tiles_in_step` |
| Per-workload telemetry CSV | `workload-<name>.csv` | 6.C | One per concurrent workload, 1 s resolution |
| Workload-coordination log | `orchestration.log` | 6.C | Per-workload start / ramp-end / steady-end for window alignment |

### Promoted to primary for Stage 6

- **`nvidia-smi`** — the extractors hold high GPU memory; GigaPath in particular.
- **Filesystem-side operation counters** — **primary for 6.B**, where the metadata story lives (within-leg;
  see the `Stage-2-Cataloging.md` cross-leg caveat).
- **Memory statistics** — **primary for 6.B**: `torch.load` deserialises into host RAM, so memory pressure
  is a real axis and the **corpus-versus-cache boundary determines which regime a cell is in.**
- **`sar -u` over application-available cores** (**D15**) — primary for 6.B.3 (host-bound) and 6.C (where
  host-CPU contention is a candidate interference channel).
- **Wire counters for the path in use** — per **D12**, different on each leg.

### Cross-source canaries — derived per filesystem

- **6.A:** wire counters track filesystem-side reads at that filesystem's derived read relation; per-rank
  app throughput × embedding bytes per tile reconciles with filesystem-side **write** volume (the `.pt`
  output); per-source timelines align.
- **6.B:** wire counters track reads; the filesystem-side operation rate reconciles with app file-loads/sec
  times the per-file operation count; file-load p99 is sane against the viewer-tolerance reference.
- **6.C:** per-workload throughput reconciles with the per-workload telemetry, and the sum reconciles with
  the filesystem-side aggregate, each within a **stated** tolerance.
- **6.D:** per-phase wallclock × per-phase bandwidth reconciles with phase bytes moved.

**Any canary failure beyond its stated tolerance stops the substage.** On an unattended chain, mechanically.

---

## Tool inventory

| Tool | Substage |
|---|---|
| `extract-features-foundation-stage6.py` · `sweep-stage6a-extract.sh` · `aggregate-stage6a-extract.py` | 6.A |
| `run-stage6a-tier2-chunked-multimodel.sh` | 6.A Tier 2 |
| `convert-rawtiff-20x.py` (mpp guard) | 6.A Tier 2 chunked conversion (also 4.D) |
| `generate-synthetic-features-stage6b.py` | 6.B.1 |
| `read-feature-files-stage6b.py` · `sweep-stage6b-stress.sh` | 6.B.2 |
| `train-mil-stage6b.py` (canonical `bs=1`) · `sweep-stage6b-mil.sh` | 6.B.3 |
| `aggregate-stage6b.py` | 6.B |
| `orchestrate-concurrent-stage6c.sh` · `sweep-stage6c.sh` · `aggregate-stage6c-concurrent.py` | 6.C |
| `pipeline-end-to-end-stage6d.sh` · `aggregate-stage6d.py` | 6.D |

All need the per-filesystem adapter work (deferred item `D-4`). Mount retargeting is done (`D-1`). Per-cell
`LD_PRELOAD` scoping applies to every sweep mixing kvikIO and cuCIM.

## Datasets

| Dataset | Source | Used in |
|---|---|---|
| TCGA-BRCA canonical SVS | hydrated per leg (1.7) | 6.A cuCIM path, 6.D |
| TCGA-BRCA 20× raw-TIFF (subset) | 4.D per leg | 6.A Tier 1 kvikIO |
| TCGA-BRCA 20× raw-TIFF (full cohort, chunked + transient) | generated per chunk in Tier 2 | 6.A Tier 2 kvikIO |
| CAMELYON16 20× raw-TIFF (subset) | 4.D per leg | 6.A Tier 3 |
| 20× CLAM coords | 3.0 per leg | 6.A, 6.D |
| 1073-slide cohort manifest | `manifests/tcga-brca-full40x-stage4a-format.tsv` | 6.A Tier 2, 6.B.3, 6.D |
| 50-slide subset manifests | `manifests/` | 6.A Tier 1, Tier 3 |
| **Synthetic feature corpora** | 6.B.1 per leg | 6.B.2 |
| **Real 6.A features** | 6.A per leg | 6.B.3, 6.D, and Stage 7.3 |

**Confirm capacity per leg before Tier 2 and before 6.B.1** — the synthetic corpus is deliberately sized
past cache and is the largest single footprint in the project after raw-TIFF.

## Risks / known unknowns

- **Corpus sizing versus two caches** — the cold-cache problem above. Unresolved corpus sizing would
  invalidate 6.B.2's headline on one or both legs.
- **Tile-count assumptions** — the per-slide tile counts that drive feature file sizes and Tier 2 wallclock
  come from magnification arithmetic, not measurement. **Confirm from the real 3.0 coords** before sizing
  the 6.B.1 grid or committing Tier 2 wallclock.
- **GigaPath memory footprint** — the largest of the three models may need a reduced batch size. If so,
  note it as a per-model adjustment in that run's README; throughput is reported per second so the
  comparison stays valid, but the adjustment must be **identical on both legs**.
- **Chunked-conversion leakage** — an aborted Tier 2 run can leave chunks behind, and skip-on-existing
  would silently reuse them. Verify cleanup between runs.
- **Long-tail rank imbalance** on CAMELYON16 — generous collective timeouts, and read throughput alongside
  the tile-count distribution.
- **6.C orchestration is the most engineering-heavy part of the stage** — four concurrent workloads with
  clean per-workload telemetry windows. Dry-run before the all-four tier on each leg.
- **UNI2-h stays internal-only** — don't strip the tags; filter before anything is externalised.

## Decision log (Stage 6-scoped)

- **2026-07-31 — Three foundation models (UNI2-h, Virchow2, GigaPath), not one.** *Why:* production labs
  use them interchangeably depending on task and cancer type, so a single-model result invites "what about
  model X?". They also span a useful range of compute weight and embedding dimension, which changes the
  storage-to-compute balance — so three models test whether a filesystem result is model-dependent.
  Licensing: Virchow2 and GigaPath are Apache-2.0; UNI2-h is CC-BY-NC-ND, so its cells stay internal-only.
- **2026-07-31 — GigaPath's tile encoder only; LongNet aggregator out of scope.** *Why:* different
  architecture, different I/O profile, and not needed for the storage question.
- **2026-07-31 — Dataset scale: 50-slide subset (Tier 1) + full 1073-slide cohort (Tier 2) + CAMELYON16
  subset (Tier 3).** *Why:* the subset preserves cross-stage comparability with Stages 4 and 5; the full
  cohort answers the production-scale question; the cross-dataset tier closes the non-TCGA objection.
- **2026-07-31 — Synthetic corpus for 6.B.2, real features for 6.B.3, both required.** *Why:* the
  differentiating I/O pattern is small-file reads plus metadata operations, for which embedding content is
  irrelevant — so synthetic gives controlled scale, size distribution, and bit-width. But synthetic alone
  invites dismissal, so B.3 grounds it in a real classifier over real features.
- **2026-07-31 — Corpus must exceed client cache plus the larger server-side cache, and must be one
  identical definition across legs.** *Why:* see the cold-cache section. Per-leg corpus sizes would break
  the held-constant contract on the substage most sensitive to it.
- **2026-07-31 — FP32 and FP16 feature files both measured.** *Why:* halving file size changes the
  metadata-to-bytes ratio, which is exactly what a metadata-heavy workload is sensitive to. Low cost,
  directly relevant.
- **2026-07-31 — Three access patterns in 6.B.2.** *Why:* metadata-path behaviour is pattern-sensitive;
  reporting only the friendliest or only the harshest pattern would misrepresent both filesystems.
- **2026-07-31 — MIL is canonical CLAM `bs=1` + `collate_MIL`; concurrency via `num_workers`.** *Why:*
  verified against upstream CLAM, and the padded-batch alternative OOMs on wide bag-size distributions.
  `num_workers` is the storage-concurrency axis.
- **2026-07-31 — 6.C retention measured against same-filesystem solo baselines, re-measured at the exact
  concurrent config.** *Why:* retention is a fairness property of each filesystem; borrowing a baseline
  from an earlier stage risks a config mismatch that would silently distort every retention figure.
- **2026-07-31 — 6.C includes pair and triple tiers, not just all-four.** *Why:* they are what make an
  all-four result *diagnosable* — without them, interference is a single number with no attributable cause.
- **2026-07-31 — 6.D is constructive, not a measured cell.** *Why:* the phases are strictly sequential with
  no shared-resource interaction, so measured per-phase numbers compose exactly. Running it live would
  repeat Tier 2 for hours and add no insight; the orchestrator's end-to-end validation is a productisation
  concern. Components must come from the same leg.
- **2026-07-31 — Cleanup-before-cell in 6.A is mandatory.** *Why:* the extractor skips existing output, so
  without a wipe every cell after the first would short-circuit and report a meaningless number that looks
  plausible.
- **2026-07-31 — Recording: every metric that makes sense, over-capture by default.** *Why:* Stage 6 has
  the highest per-cell cost in the project; a missing metric means re-running hours of work.

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage 6 roadmap created for the WEKA-vs-Lustre comparison. Retained: three-model coverage, three-tier 6.A structure, chunked + conversion-sharing Tier 2 strategy, 6.B's three sub-tiers with synthetic-plus-real rationale, canonical `bs=1` MIL, 6.C's five ascending tiers, constructive 6.D, cleanup-before-cell, and all recording additions. **Added:** per-leg framing; the **two-cache cold-cache problem** and its cross-leg corpus-sizing consequence; same-filesystem solo baselines for 6.C retention; explicit cache-dominated-regime disclosure for 6.B.3; cross-leg integrity checks on 6.A Tier 2 output; composition-hygiene warning for 6.D; per-filesystem recording adapters and canary derivation; **D13** record-as-achieved cache discipline; **D15** core accounting for the 6.C interference channel. **Changed:** GPU sweep to N ∈ {1,2,4}; cuFile-mode scoping matched to Stage 5. **Removed:** all inherited results, outcome buckets, wallclock estimates, and magnitude expectations. |

## Cross-references

- `../CLAUDE.md` · `../PROJECT-THESIS.md` · `STAGES.md` (**D1–D15**) · `README.md`
- `Stage-4-Patching.md` — both data paths, the raw-TIFF artifact, the full cuFile-mode grid
- `Stage-5-Training.md` — DDP mechanics, the attribution discipline, cuFile-mode scoping precedent
- `Stage-2-Cataloging.md` — the cross-leg operation-counter comparability caveat
- `Stage-7-Clinical-Inference-Deployment.md` — consumes 6.A features (7.3) and the reader/MIL modules
- `../SCRIPT-TRACKER.md` — per-script reference and deferred cloud-session TODOs
