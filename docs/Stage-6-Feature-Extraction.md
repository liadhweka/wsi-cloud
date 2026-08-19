# Stage 6 — Feature extraction & downstream MIL, measured identically on both filesystems

> **Every substage runs on both filesystems** — WEKA (Leg A) then FSx for Lustre (Leg B) — with everything
> else held constant. The delta is the result, and **a single leg is half an unfinished comparison.**
>
> Stage 6 is the largest stage: four substages covering four distinct I/O personalities, drawn from what
> production WSI research pipelines run.

For project-wide conventions see `../CLAUDE.md`; what we measure and why `../PROJECT-THESIS.md`; the stage
map and the decision register `STAGES.md`; how to run and record a cell `RUNBOOK.md`. Stage 4 supplies both
data paths and the raw-TIFF artifact; Stage 5 supplies the DDP scaling context.

---

## What Stage 6 measures

**Four I/O personalities, plus one integrating bookend:**

| Substage | Workload | I/O personality | The question it answers |
|---|---|---|---|
| **6.A** | Foundation-model feature extraction | Random tile reads at production rates, single pass, GPU-compute-heavy per step (large frozen ViT forward) | Does each filesystem keep production extractors fed, across the dominant open-weight model families, at scale? |
| **6.B** | Small-file / metadata stress | Random reads of many small per-slide feature files; no compute; metadata plus small-block I/O | How does each filesystem's metadata path handle the downstream-training file-I/O pattern that pegs legacy NAS metadata servers? |
| **6.C** | Concurrent multi-workload | All four real workloads at once: ingest + extract + MIL training + viewer | Can each filesystem serve all four simultaneously on one namespace without QoS interference, sustained over hours? |
| **6.D** | End-to-end pipeline timing | Composed from the above | How long does the complete pipeline take, per filesystem? |

**6.B and 6.C probe axes no other substage covers** — small-file metadata behaviour, and fairness when four
real workloads share one namespace. Everywhere else in the project measures one workload at a time against
bulk- or tile-shaped I/O.

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
- **Multi-client scaling.** Single-client study on both sides (`../PROJECT-THESIS.md` §9).
- **Model precision as an axis.** AMP FP16 is the standard production setting and is held constant. We
  *do* vary **feature-file** bit-width (FP32 vs FP16 on disk) in 6.B — a storage question, not a compute one.
- **Convergence-based MIL training.** 6.B.3 trains on synthetic labels for throughput. No accuracy claim.

---

## ⚠️ The cold-cache problem — and a sequencing consequence that affects Leg A

This is the most important methodological issue in Stage 6, and it has to be resolved **before Leg A
generates its corpus.**

**The problem.** 6.B.2's production-scale cells are specified **cold** — every read forced through the
filesystem rather than served from cache. But there are **two** caches between the workload and the
disks, and both have to be counted when a corpus is sized to be cold:

1. **The client's page cache** — the instance has 768 GiB of RAM.
2. **The filesystem's own server-side cache** — and this is where it gets asymmetric. FSx's file-server
   cache follows from the provisioned tier and capacity (**D7**); WEKA's follows from the backend instance
   type and count we choose. **Fetch the FSx per-TiB figure at provisioning rather than recalling it**
   ([SSD storage performance characteristics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html)),
   and record the WEKA backends' aggregate RAM at spin-up. **The two are not equal and are not under common
   control.**

**So a corpus that is genuinely cold on one filesystem may be partly warm on the other** — which would
produce a difference that looks like a filesystem property but is actually a cache-size artifact.

**The consequence for sequencing.** To be cold on both legs, the corpus must exceed the client page cache
**plus the larger of the two server-side caches.** But **Leg A runs first**, and its corpus is generated
before Lustre exists. Two ways out, and the choice must be made deliberately:

- **(a) Size the corpus up front using both filesystems' cache sizes** — requires knowing the FSx tier and
  capacity before Leg A's corpus generation, i.e. deciding Leg B's provisioning early even though it is
  provisioned later. **Recommended:** the FSx configuration is already fixed by **D7** (maxed), so its cache
  size is computable in advance, and it keeps **one identical corpus definition** across both legs —
  preserving the held-constant contract.
- **(b) Generate a differently-sized corpus per leg** — breaks the held-constant contract on the very
  substage where the comparison is most sensitive. **Not recommended.**

**Either way, "cold" must be verified per cell, not asserted** (**D13**). Cache-clearing on the client is
straightforward; the server side is only partly under our control on managed storage. **Record what was
actually achieved** and state the residual uncertainty rather than labelling a cell cold on faith.

**RESOLVED (ratified 2026-08-16, route (a)): the 6.B production-scale corpus is 3.0 TiB — one identical
definition on both legs.** *Why 3.0 TiB:* it must exceed the client page cache (768 GiB) plus the larger of
the two server-side caches — WEKA's confirmed 1536 GiB backend RAM against FSx's ~721 GiB at
PERSISTENT-1000 × 26.4 TiB (both fetched, not recalled) — so the floor is 2304 GiB and 3.0 TiB carries
~30% margin. The per-`(N_files, file_size, dtype)` grid inside that envelope is still fixed at substage
entry against the measured 6.A Tier 2 file-size distribution (the tile-count open item). "Cold" remains
verified per cell, never asserted (**D13**).

---

## Strategy framing

Each substage answers a question no earlier stage touches, and its output feeds the next.

- **6.A** — three models × two data paths × a GPU-count sweep on the cross-stage subset (Tier 1), then
  production scale on the full cohort (Tier 2), then a cross-dataset check (Tier 3).
- **6.B** — **B.1** generate a controlled synthetic corpus; **B.2** stress it; **B.3** train a real
  attention-MIL classifier on the *real* 6.A features. B.2 gives controlled scale, B.3 grounds it in the
  actual production workload — **both are needed**, because B.2 alone invites "synthetic, not real" and B.3
  alone cannot reach controlled scale.
- **6.C** — solo baselines → pairs → triples → all four → endurance. The intermediate tiers exist so that
  if interference appears at all-four-up, we can already say **which pair causes it**.
- **6.D** — the end-to-end bookend, **composed constructively** from measured per-phase numbers.

**Sequencing per leg:** Phase 0 → smoke → 6.A Tier 1 → Tier 3 → Tier 2 → **6.B.3** (real features now
exist) → 6.B.1 → 6.B.2 → 6.C ascending tiers → 6.D → closeout. *Why 6.B.3 before 6.B.1/2:* it uses the
real features Tier 2 just produced, lands the real-workload number sooner, and smoke-tests that pipeline
before committing the synthetic corpus's disk footprint.

**GPU sweep N ∈ {1, 2, 4}** — the instance has 4 GPUs (**D10**), matching Stage 5 for cross-stage
comparability. NUMA-aware assignment with the map re-derived per instance (**D15**).

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All substages are ⏳ on both legs.

### 6.A — Foundation-model feature extraction

For every tile in every tissue-detected slide, run a frozen foundation-model ViT and write a per-slide
`.pt` holding an `[N_tiles × D]` feature tensor.

#### 6.A Tier 1 — Scaling sweep on the 50-slide subset

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 12/12 cells OK + 6 D18 rep cells; canary PASS on all; cache declarations reconciled CONSISTENT on every cell) · ⏳ Leg B |
| **Leg A results (`s6.A-extract-summary.csv`; 50-slide BRCA subset)** | **kvikIO tiles/s, N=1→2→4:** Virchow2 272→498→**971** (efficiency 91.5%/89.3%), GigaPath 227→415→**800** (91.4%/88.1%), UNI2-h `[PENDING-APPROVAL]` 276→507→**964** (91.8%/87.3%). **cuCIM comparator at N=4:** 859 / 729 / 873 → **kvikIO/cuCIM ≈ 1.10–1.13×** in the foundation-model regime — far narrower than Stage 5's 1.55×, exactly the compute-heavier balance point this tier exists to locate. GPU utilization 95–98% (kvikIO) vs 88–89% (cuCIM); the cells are **GPU-compute-bound by design** — fs-side reads at peak sit at ~2% of the block-size-matched read ceiling, so these numbers characterise whether each filesystem keeps extractors fed (it does: utilization stays ≥95% on the kvikIO path at N=4), not storage limits. **D18 reps at each model's N=4 peak:** medians 956 / 800 / 963 with **1.7% / 0.6% / 0.7% spreads**. Path proof per cell and per rep: `gds_engaged=none` — all bytes bounced (D8). Canary read ratios 1.05–1.08, all PASS; kvikIO cells declared `cold` (per-slide discard, achieved recorded), cuCIM cells `warm` (no discard mechanism — steady-state residency), all reconciled CONSISTENT. |
| **Goal** | The tiles/sec curve across GPU count for each model, on both data paths, on the cross-stage subset |
| **Step** | Run the frozen model over the tile stream from the selected data path and write one `.pt` per slide — `../scripts/extract-features-foundation-stage6.py` |
| **Backends** | (a) kvikIO/cuFile + raw-TIFF. (b) cuCIM CPU batched |
| **Source → Target** | `$FS_MOUNT` raw-TIFF or canonical SVS (per backend) → GPU → frozen ViT forward → per-slide accumulate → `$FS_MOUNT/features/6.A/<model>/<dataset>/<slide-id>.pt` |
| **Methodology** | Same DDP mechanics as Stage 5 (spawn, `channels_last`, `cudnn.benchmark`, AMP FP16, CUDA-event timing, no inter-phase host syncs) — the compute knobs are **mandatory here for the same reason as in 5.A**: under-optimised compute understates the demand the pipeline places on storage, flattering both filesystems (`Stage-5-Training.md` decision register). Single pass through the slide pool; each rank takes a **disjoint partition** — DDP here is data-parallel for throughput only, since the model is frozen. **Cleanup before each cell** wipes that model's output dir, because skip-on-existing would otherwise short-circuit every cell after the first and silently produce a meaningless number |
| **Cell count** | **3 models × 3 N (kvikIO)** + **3 models × one N (cuCIM comparator)**, **plus the mode-controlled paired cell on any leg where both cuFile modes are available.** Stated as a composition rather than a total, because whether that last cell exists follows from that leg's answer to the **D8** question |
| **cuFile mode** | Best available mode per filesystem, plus one mode-controlled paired cell — the same reduction as Stage 5.A, for the same reason (Stage 4.C already characterises the full mode grid; `STAGES.md` records the reduction) |
| **Why this exists** | Establishes each filesystem's supply curve for the heaviest production model class, and does it across three models so the result is not tied to one model's compute profile. The cuCIM comparator quantifies the migration trade-off in the foundation-model regime, where compute per step is far heavier than in Stage 5 — a different balance point between storage and compute |
| **Why the cuCIM comparator sits at one N rather than the full sweep** | Its scaling curve is already established in Stage 5.B for the same reader; here it functions as a data-path comparator at a fixed scale. Recorded as a scoping choice |
| **⚠ `LD_PRELOAD` scoped per cell** | Mixed kvikIO/cuCIM sweep — set the preload on kvikIO cells only |
| **Sweep driver** | `../scripts/sweep-stage6a-extract.sh` · **Aggregator** `../scripts/aggregate-stage6a-extract.py` |
| **Recorded per cell** | tiles/sec per (model × backend × N), scaling efficiency, kvikIO/cuCIM ratio per N, filesystem-side read mean/peak and **% of the block-size-matched ceiling**, GPU utilisation — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

#### 6.A Tier 2 — Production scale (full 1064-slide cohort)

| | |
|---|---|
| **Status** | ⏳ both legs — the long pole of the stage |
| **Goal** | The production-scale number: features extracted from the full cohort, all GPUs, per model, per filesystem |
| **Dataset** | The **uniform 1064-slide cohort** (`../scripts/manifests/tcga-brca-full40x-stage4a-format.tsv`) per **D5**, with the fail-loud mpp guard as defence in depth |
| **Pre-cell prep — chunked raw-TIFF conversion** | The kvikIO path needs raw-TIFF resident, and the full cohort's raw-TIFF does not fit at once. So: convert a chunk → extract → delete the chunk → advance. The cuCIM path skips this (reads canonical SVS) |
| **Conversion sharing** | The multi-model orchestrator converts **once per chunk**, then extracts for each model in turn before deleting the chunk. *Why:* a per-model orchestrator would convert the cohort three times, and conversion is a large fraction of per-chunk wallclock — so sharing it is not a micro-optimisation but a structural one |
| **Cell count** | **3 cuCIM (per model) + 1 multi-model kvikIO (three models sharing the chunked conversion) = 4 cells per leg** |
| **Methodology** | Same DDP and reader logic as Tier 1, across all 1064 cohort slides at the full GPU count. Per-slide `.pt` to `$FS_MOUNT/features/6.A/<model>/brca_full/`. Cleanup-before-cell as in Tier 1 |
| **Why this exists** | Subset numbers invite "does this hold at my dataset's scale?" The full-cohort cells answer it directly, on both filesystems, for all three models and both data paths |
| **⚠ Capacity + hygiene** | Chunked conversion means transient raw-TIFF plus permanent features on the filesystem under test. **Confirm headroom per leg first.** Existing non-empty output is skipped rather than rebuilt, so a leftover chunk from an aborted run would be silently reused — **verify chunk cleanup between runs** |
| **Output-count gate** | 1064 slides × 3 models = **3192 `.pt` files per leg**; verify the count and a zero-failure/zero-leaked-chunk condition before accepting the cell |
| **Recorded per cell** | per-model steady-state tiles/sec (both backends), kvikIO/cuCIM ratio at production scale, filesystem-side read sustained and % of the matched ceiling, per-chunk convert-vs-extract split — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cross-leg integrity check** | Feature file **count, per-slide tile count, and tensor shape** are storage-independent and must match between legs. A divergence means the legs did not process equivalent inputs — **fail loud**, as with the Stage 3 coord gate |

#### 6.A Tier 3 — Cross-dataset validation (CAMELYON16)

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | Cross-vendor format consistency in the foundation-model regime |
| **Cell count** | **3 cells per leg** — three models at a mid GPU count, kvikIO, CAMELYON16 50-slide subset |
| **Methodology** | Identical to the matching Tier 1 cells except the dataset. CAMELYON16 is native 20× so it uses `--patch_level 1 --patch_size 256` per the coord contract — no resize. A mid GPU count is chosen because this is a **consistency check, not a throughput peak**, so it does not need the full sweep |
| **⚠ Long-tail sensitivity** | CAMELYON16's per-slide tile counts vary more than BRCA's, so at multi-rank scale the **slowest rank dominates wallclock**. Two consequences: collective timeouts must be generous enough to tolerate the straggler (a too-short default will kill an otherwise valid cell), and the throughput number should be read alongside the tile-count distribution rather than on its own |
| **Why this exists** | Closes the "what about non-TCGA data?" question at the feature-extraction layer, and — because the dataset ratio is driven by tile-count distributions rather than storage — doubles as a **sanity check on the comparison itself**: the ratio should be similar on both filesystems |
| **Recorded per cell** | tiles/sec per model, and the CAMELYON16/BRCA ratio against the matching Tier 1 cells — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

**6.A per leg: Tier 1's composition above + 4 Tier 2 + 3 Tier 3.** Wallclock recorded, not estimated.

---

### 6.B — Small-file / metadata stress

#### 6.B.1 — Synthetic feature-file corpus generation

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Type** | A one-shot generation pass rather than a benchmark cell — but **wrapped in `record-run.sh` anyway**, because the sustained write is itself a recordable workload and comes free |
| **Step** | Write a synthetic `.pt` corpus at a specified `(N_files, file_size, dtype)` — `../scripts/generate-synthetic-features-stage6b.py` |
| **Grid** | **File sizes bracket the real 20× feature distribution** (~40–65 MB/slide at ~8–15K tiles), **fixed at substage entry against the actual 6.A Tier 2 file-size distribution** rather than guessed. `N_files` spans small to production scale; `dtype ∈ {FP32, FP16}`. Stored at `$FS_MOUNT/features-6.B-synthetic/` |
| **Why synthetic rather than real files** | The I/O pattern — small-file random reads plus metadata operations — is what differentiates storage architectures, and embedding *content* is irrelevant to it. Synthetic gives controlled scale, a controlled size distribution, and a controlled bit-width, none of which the real corpus provides |
| **⚠ Corpus sizing is the cold-cache decision** | The production-scale corpus **must exceed the client page cache plus the larger of the two filesystems' server-side caches** — see the cold-cache section above. **This makes corpus sizing a cross-leg decision that must be made before Leg A generates anything**, and it must produce **one identical corpus definition for both legs** |
| **Why FP16 is an axis** | Halving file size changes the metadata-to-bytes ratio, which is precisely the balance that a metadata-heavy workload is sensitive to. Low marginal cost, directly relevant axis |
| **Recorded per cell** | generation wallclock, sustained write throughput, total bytes, resulting file-size distribution — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cache-regime disclosure (required output)** | At substage entry, record **which B.2 cells will be cache-served and which genuinely cold**, per filesystem, given the measured cache sizes. Framing must state which regime each number represents — a cache-served number presented as storage throughput would be wrong on either side |

#### 6.B.2 — File-I/O stress sweep

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | Small-file random-read throughput and operation rate at production concurrency, across file size, concurrency, access pattern, and bit-width |
| **Step** | Read the corpus per an access pattern at a given concurrency, deserialising through `torch.load` exactly as production does (host-side unpickling included), timing each load — `../scripts/read-feature-files-stage6b.py` |
| **Sweep grid** | **(a) Saturation:** mid-scale corpus × file size × concurrency × pattern × dtype — the main curve. **(b) Production scale:** large corpus × high concurrency × random × FP32 — **the genuinely cold cells**. **(c) File-size sensitivity:** fixed concurrency across the size tiers |
| **Access patterns** | **random** — uniform file choice per read, modelling the production MIL DataLoader. **batched-shuffled** — per-epoch shuffle, sequential within it, modelling a single training epoch. **sequential** — directory order, the best case for prefetch heuristics, which sets an upper reference. *Why three:* a metadata path's behaviour is pattern-sensitive, and reporting only the friendliest or only the harshest pattern would misrepresent both filesystems |
| **Methodology** | **Clear caches before each cell** to the extent achievable per filesystem, **and record what was achieved** (**D13**). Time-bounded cells with ramp plus steady state. Per-file-load latency sampled |
| **⚠ Comparability of the two rate axes** | Aggregate files/sec is app-level and therefore **comparable across legs by construction**. **Filesystem-reported operation rate is not** — the two filesystems count operations under their own semantics, so treat it as **within-leg only** until counter semantics are verified equivalent and that verification is recorded (`Stage-2-Cataloging.md`) |
| **Why this exists** | This is the workload that exercises the metadata path directly — many small files, a high metadata-to-bytes ratio, at the concurrency a production MIL DataLoader generates — and it is **structurally non-bandwidth-bound**, so it isolates that path from the bulk-transfer axes the earlier stages cover |
| **Recorded per cell** | cold-cache read throughput at production scale, operation-rate peak, the saturation curve across all four axes, pattern sensitivity, bit-width sensitivity, per-cell cache-regime label — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

#### 6.B.3 — Real attention-MIL training on real 6.A features

| | |
|---|---|
| **Status** | ⏳ both legs — needs 6.A Tier 2 features |
| **Goal** | The Phase-2 workload in its production training context: what storage sees when a real MIL classifier consumes real feature files at realistic worker counts |
| **Step** | Train a gated-attention MIL classifier (Tanh × Sigmoid → softmax → weighted-sum slide feature → linear classifier) over per-slide feature bags — `../scripts/train-mil-stage6b.py` |
| **⚠ Architecture — `batch_size=1` + `collate_MIL`, non-negotiable** | Canonical CLAM trains **one slide per forward step** and never builds a padded `[B, max_N, D]` batch tensor. Verified against `mahmoodlab/CLAM`: `get_split_loader` always sets `batch_size=1, collate_fn=collate_MIL`; the model forward takes a 2-D `[N, D]` bag. **The padded design OOMs** — the batch tensor inflates to the largest-bag slide in each batch and WSI bag-size distributions are wide. **The storage-concurrency axis is `num_workers`, not `batch_size`**: `num_workers=32` means 32 slides read concurrently regardless of batch size. (Magnification-independent) |
| **Source** | Real features from 6.A Tier 2 on the same leg (1064 `.pt` per model, ~40–65 MB each at 20×) |
| **Grid** | **3 models × `num_workers ∈ {4, 16, 32}` = 9 cells per leg.** UNI2-h cells tagged `[PENDING-APPROVAL-DO-NOT-EXTERNALIZE]` |
| **Methodology** | Canonical CLAM `bs=1`; each DataLoader worker prefetches one slide via `torch.load`. Time-bounded cells with ramp plus steady state. Per-step CSV including `n_tiles_in_step`, since per-step work varies with bag size |
| **⚠ The regime is set by corpus size against host RAM — size the expectation, record what was achieved** | The full-cohort feature corpus at 20× is roughly 1064 × ~50 MB ≈ **~53 GB**, which fits inside the instance's RAM. After the first pass this workload is therefore expected to run largely **memory-served on both legs** — an arithmetic consequence of corpus size against client RAM, identical on both sides, not a property of either filesystem. That is what production looks like at this corpus size, and it means **B.3's storage signal lives in the cold first pass and the low-`num_workers` cells**. Size that expectation up front, then **record the cache state achieved per cell** (**D13**) rather than asserting the regime. The corpus deliberately sized past cache is 6.B.1's |
| **Why this exists** | B.2 alone invites the "synthetic, not real" objection. B.3 answers it with a real classifier over real foundation-model features, so the two together cover controlled scale *and* production fidelity |
| **Recorded per cell** | slides/sec and tiles/sec per model per `num_workers`, saturation knee, per-step phase split, cold-pass filesystem-side read, the cache-served regime boundary — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

---

### 6.C — Concurrent multi-workload

Four real workloads on one filesystem simultaneously: **scanner ingest** (bulk copy at a fixed
"scanner pace"), **feature extraction** (the 6.A pattern), **MIL training** (the 6.B.3 pattern at its
saturation knee), and **viewer load** (small-block random reads).

**The derived figure is per-workload retention: concurrent throughput ÷ that workload's own solo throughput
on the same filesystem.** *Why same-filesystem:* the question is how much each filesystem degrades its own
workloads under contention — a fairness property. Comparing one filesystem's concurrent number against the
other's solo number would conflate contention behaviour with raw speed. **The retention percentages are
what compare across legs**, with absolutes reported alongside.

| Tier | Cells per leg | Content | Why it exists |
|---|---|---|---|
| **1 — Solo baselines** | 4 | Each workload alone at the **exact config used in the concurrent tiers** | These are the denominators for every retention figure, so they must be measured at the identical config rather than borrowed from an earlier stage where a parameter may differ. Also a drift canary: they should reconcile with the same leg's earlier stages |
| **2 — Pair-wise** | 4 | extract+ingest · extract+MIL · MIL+viewer · extract+viewer | Isolates **which pair** causes interference, if any. Without this, an all-four-up result is a single number with no diagnosis |
| **3 — Triple-up** | 2 | extract+MIL+ingest · extract+MIL+viewer | Separates "adding ingest" from "adding viewer" — the two have completely different I/O shapes |
| **4 — All four** | 1 | All simultaneously, sustained | The realistic-lab configuration |
| **5 — Endurance** | 1 | All four, sustained for hours | A short cell proves no instantaneous interference; hours prove no QoS drift, no resource leak, and no degradation as caches warm and working sets shift |

| | |
|---|---|
| **Tools** | `../scripts/orchestrate-concurrent-stage6c.sh` + `../scripts/sweep-stage6c.sh` · **Aggregator** `../scripts/aggregate-stage6c-concurrent.py` |
| **Methodology** | Workloads launched simultaneously, each emitting its own per-workload telemetry CSV; one `record-run.sh` wraps the group as a single cell. An `orchestration.log` records each workload's start / ramp-end / steady-end so per-workload windows can be aligned correctly |
| **⚠ Ingest is data-bounded** | The ingest workload exhausts its source corpus and exits before the cell deadline, after which its mean reads as zero. **Report it as "active throughout, data-bounded by source" with the active-window rate extracted from the per-second telemetry**, rather than quoting a misleading retention percentage |
| **⚠ Interference can be host-side rather than filesystem-side** | MIL training and viewer load both go through the host page cache and host CPU, so contention between them may be a **host** effect present on both filesystems. Per **D15**, host-CPU accounting differs between legs (the WEKA client reserves cores), so an apparent difference here needs the core accounting before it is attributed to the filesystem |
| **Endurance failure recovery** | Periodic checkpoint summaries mean a partial failure still yields usable partial numbers, and `record-run.sh` marks the cell `INCOMPLETE`. If endurance fails repeatedly on a leg, fall back to the shorter all-four cell **and disclose the gap** rather than quietly presenting the short cell as endurance |
| **Recorded per cell** | per-workload retention at every tier, aggregate filesystem-side read and write, % of the matched ceiling, and for the endurance cell the retention trend across the window — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

**6.C total: 12 cells per leg.** The endurance cell is the single longest item in the stage.

---

### 6.D — End-to-end pipeline timing (constructive, not a measured cell)

| | |
|---|---|
| **Status** | ⏳ both legs — **composed from measured per-phase numbers, not run as a separate cell** |
| **Why constructive** | The phases are strictly sequential by design with no shared-resource interaction, so the measured per-phase wallclocks compose to the end-to-end number **exactly**. Running it live would spend many hours largely repeating Tier 2 work to produce a number we can already compute, and would add no new insight. The remaining value of running it — proving the orchestrator works end to end — is a **productisation** concern, not a measurement one |
| **Composition** | Tissue detection (3.0, full cohort) + 6.A Tier 2 extraction (per model, per backend) + 6.B.3 MIL training to one epoch. The kvikIO path additionally includes the one-time raw-TIFF conversion, **amortised across the three models** since they share it |
| **Cells executed** | **0** |
| **Tools** | `../scripts/pipeline-end-to-end-stage6d.sh` — retained as the productisation template · `../scripts/aggregate-stage6d.py` |
| **⚠ Composition hygiene** | Every component must come from **the same leg's** recorded run dirs. Mixing phases across legs would produce a number describing neither filesystem — and it would be easy to do by accident, since the aggregator globs run dirs |
| **Composed output** | One end-to-end figure per backend per filesystem, with the per-phase breakdown, and the leg cost that follows from the composed wallclock (`RUNBOOK.md`) |

---

## Recording — Stage 6's changes to the base

The per-cell measurement set, the cost inputs, the operational source table and both canaries live in
`RUNBOOK.md`; the rule that the **primaries invert between legs** is `../PROJECT-THESIS.md` §7 and **D12**.
Neither is restated here. **Over-capture by default** — Stage 6 carries the highest per-cell cost in the
project, so a missing metric means re-running hours of work. This stage changes the base as follows.

### Streams this stage adds

| Source | File | Substage | Captures |
|---|---|---|---|
| Per-extraction-step CSV | `extraction-steps.csv` | 6.A | Step index, timing, dataload vs forward split, samples per rank, world size, slide id, cumulative tiles. (No backward/optimiser — frozen eval) |
| Per-file-load latency CSV | `per-file-latencies.csv` | 6.B.2, 6.B.3 | Worker, file path and size, load latency, dtype, pattern — sampled |
| Per-step MIL training CSV | `training-steps.csv` | 6.B.3 | Stage-5 schema plus `n_tiles_in_step` |
| Per-workload telemetry CSV | `workload-<name>.csv` | 6.C | One per concurrent workload, 1 s resolution |
| Workload-coordination log | `orchestration.log` | 6.C | Per-workload start / ramp-end / steady-end for window alignment |

### Promotions, and why each one

- **Filesystem-side operation counters → primary in 6.B**, because that is where the metadata behaviour
  lives and the operation rate is the axis being swept. **Within-leg only** until counter semantics are
  verified equivalent — see the comparability note in 6.B.2 and `Stage-2-Cataloging.md`.
- **Memory statistics → primary in 6.B**, because `torch.load` deserialises into host RAM: the
  corpus-versus-cache boundary is what decides which regime a cell is in, and that boundary has to be
  visible in the record rather than inferred afterwards.
- **`sar -u` over application-available cores** (**D15**) **→ primary in 6.B.3 and 6.C.** 6.B.3 is
  host-bound, and in 6.C host-CPU contention is a candidate interference channel that would otherwise be
  misattributed to the filesystem.
- **`nvidia-smi` stays primary** (as from Stage 4 onward), here for the **memory footprint** axis: the
  extractors hold a lot of GPU memory, GigaPath most of the three.
- **cuFile path accounting is primary on every kvikIO cell** — 6.A's kvikIO backend is this stage's
  GPU-direct path, and a configuration flag is not proof of which path a read took (**D8**).

### Cross-source canary — the Stage 6-specific reconciliations

The general canary rules are in `RUNBOOK.md`, and the expected relation is derived per filesystem and never
ported across (**D12**). What is specific to this stage:

- **6.A:** per-rank app throughput × embedding bytes per tile reconciles with filesystem-side **write**
  volume (the `.pt` output) — a read-side-only check would miss a truncated or partially-written tensor.
- **6.B:** the filesystem-side operation rate reconciles with app file-loads/sec times the per-file
  operation count, which is the check that the workload is actually metadata-dominated rather than
  cache-served. The **file-load p99 check** asks exactly one thing: **does the read path keep its consumer
  fed.** At concurrency `C` the loader supplies a file roughly every p99 ÷ `C`, so the tail is sane for this
  substage precisely when that interval sits inside the **per-step time 6.B.3 measured on the same leg** at
  the nearest worker count — i.e. when the read path does not stall the step it feeds. Both inputs are
  measured on that leg, so no external figure enters and no cross-leg contamination is possible.
  **Fallback, where that leg has no 6.B.3 step time yet:** judge p99 against **6.B.2's own
  lowest-concurrency cell** as the uncontended reference — self-referential, but it still catches a
  pathological tail. **Not judged against a "viewer-tolerance" figure:** viewer tolerance is a 1.6 / 6.C /
  7.x concept, where the consumer is a pathologist panning and zooming, whereas 6.B.2 is a
  training-DataLoader workload — and importing a number nobody in this project owns would make a canary's
  verdict rest on an unsourced constant. This criterion is **6.B-specific and therefore lives here**;
  `RUNBOOK.md` carries only the canary rules that generalise across stages.
- **6.C:** the sum of the per-workload rates reconciles with the filesystem-side aggregate — a concurrent
  cell is the one place where per-workload telemetry can double-count or drop a stream unnoticed.
- **6.D:** per-phase wallclock × per-phase bandwidth reconciles with phase bytes moved.

**The p99 check's primary reference exists by the time it is needed.** The per-leg sequence above runs
**6.B.3 → 6.B.1 → 6.B.2**, so that leg's measured per-step time is already recorded when 6.B.2 starts —
which is what makes the primary route the normal one and the self-referential fallback the exception.

**Standing constraint — the p99 criterion is not evaluated in code yet.** `aggregate-stage6b.py` emits both
inputs (`lat_p99_ms` plus concurrency per 6.B.2 cell; `step_duration_ms_mean` / `_p95` per 6.B.3 cell) but
never joins the two tiers, so the sweep as it stands yields the inputs and no verdict — and a canary whose
criterion nobody computes passes silently. **Wire the join and the pass/fail before the first 6.B.2 cell is
accepted.** *(Deferred script work: `SCRIPT-TRACKER.md`; tracked in the open-items memory.)*

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
| `orchestrate-concurrent-stage6c.sh` · `sweep-stage6c.sh` · `aggregate-stage6c-concurrent.py` | 6.C |
| `aggregate-stage6b.py` | 6.B |
| `pipeline-end-to-end-stage6d.sh` · `aggregate-stage6d.py` | 6.D |

All of these need the per-filesystem adapter work tracked as deferred item `D-4` in `SCRIPT-TRACKER.md`.
**Per-cell `LD_PRELOAD` scoping applies to every sweep mixing kvikIO and cuCIM** — set it on kvikIO cells,
never on cuCIM cells; the ABI clash segfaults cuCIM's first read.

## Datasets

| Dataset | Source | Used in |
|---|---|---|
| TCGA-BRCA canonical SVS | hydrated per leg (1.7) | 6.A cuCIM path, 6.D |
| TCGA-BRCA 20× raw-TIFF (subset) | 4.D per leg | 6.A Tier 1 kvikIO |
| TCGA-BRCA 20× raw-TIFF (full cohort, chunked + transient) | generated per chunk in Tier 2 | 6.A Tier 2 kvikIO |
| CAMELYON16 20× raw-TIFF (subset) | 4.D per leg | 6.A Tier 3 |
| 20× CLAM coords | 3.0 per leg | 6.A, 6.D |
| 1064-slide cohort manifest | `../scripts/manifests/tcga-brca-full40x-stage4a-format.tsv` | 6.A Tier 2, 6.B.3, 6.D |
| 50-slide subset manifests | `../scripts/manifests/` | 6.A Tier 1, Tier 3 |
| **Synthetic feature corpora** | 6.B.1 per leg | 6.B.2 |
| **Real 6.A features** | 6.A per leg | 6.B.3, 6.D, and Stage 7.3 |

**Confirm capacity per leg before Tier 2 and before 6.B.1** — the synthetic corpus is deliberately sized
past cache and is the largest single footprint in the project after raw-TIFF.

## Risks / known unknowns

- **Corpus sizing versus two caches** — the cold-cache problem above. Unresolved corpus sizing would
  invalidate 6.B.2's cold cells on one or both legs. *(Open-items memory: the 6.B corpus-sizing item.)*
- **Tile counts — MEASURED from the real 3.0 coords (Leg A, n64; fingerprint `coords-3.0.json`):** BRCA
  1131 slides / **12,186,434 tiles** (mean 10,775, median 10,342, p10 2,475, p90 19,489, max 67,268);
  CAM16 399 / 4,610,687 (mean 11,556, max 55,852 — the wider tail the Tier-3 straggler warning assumes).
  Inside the 8–15K/slide assumption band, so the ~40–65 MB feature-file bracket holds (1536-dim fp32 lands
  ≈66 MB at the mean) and the 6.B.3 real corpus stays far under host RAM. Tier-2 scale: the 1064-slide
  cohort carries 11,753,865 tiles (from the same fingerprint), ×3 models ≈ 35.3M tile-forwards per leg.
- **Chunk size for Tier 2** — it decides whether the chunked conversion fits on the provisioned capacity at
  all, so it is re-derived per leg's capacity and then held **identical on both legs**, since chunk size
  changes the write/delete cadence the filesystem sees. *(Open-items memory: the `CHUNK_SIZE` item.)*
- **GigaPath memory footprint** — the largest of the three models may need a reduced batch size. If so,
  note it as a per-model adjustment in that run's README; throughput is reported per second so the
  comparison stays valid, but the adjustment must be **identical on both legs**.
- **Chunked-conversion leakage** — an aborted Tier 2 run can leave chunks behind, and skip-on-existing
  would silently reuse them. Verify cleanup between runs.
- **Long-tail rank imbalance** on CAMELYON16 — generous collective timeouts, and read throughput alongside
  the tile-count distribution.
- **6.C orchestration is the most engineering-heavy part of the stage** — four concurrent workloads with
  clean per-workload telemetry windows. Dry-run before the all-four tier on each leg.
- **UNI2-h stays internal-only** — don't strip the tags; filter those rows before anything is externalised.

## Decision register (Stage 6-scoped)

One entry per live Stage 6 decision: what we do, and why it is right on its own terms. Cross-stage decisions
live in `STAGES.md`.

- **Three foundation models (UNI2-h, Virchow2, GigaPath), not one.** *Why:* production labs use them
  interchangeably depending on task and cancer type, so a single-model result invites "what about model X?".
  They also span a useful range of compute weight and embedding dimension, which changes the
  storage-to-compute balance — so three models test whether a filesystem result is model-dependent.
  Licensing: Virchow2 and GigaPath are Apache-2.0; UNI2-h is CC-BY-NC-ND, so its cells stay internal-only.
- **GigaPath's tile encoder only; LongNet aggregator out of scope.** *Why:* different architecture,
  different I/O profile, and not needed for the storage question.
- **Dataset scale: 50-slide subset (Tier 1) + full 1064-slide cohort (Tier 2) + CAMELYON16 subset
  (Tier 3).** *Why:* the subset preserves cross-stage comparability with Stages 4 and 5; the full cohort
  answers the production-scale question; the cross-dataset tier closes the non-TCGA objection.
- **Synthetic corpus for 6.B.2, real features for 6.B.3, both required.** *Why:* the differentiating I/O
  pattern is small-file reads plus metadata operations, for which embedding content is irrelevant — so
  synthetic gives controlled scale, size distribution, and bit-width. But synthetic alone invites dismissal,
  so B.3 grounds it in a real classifier over real features.
- **The 6.B corpus must exceed the client cache plus the larger server-side cache, and must be one identical
  definition across legs.** *Why:* see the cold-cache section. Per-leg corpus sizes would break the
  held-constant contract on the substage most sensitive to it.
- **FP32 and FP16 feature files both measured.** *Why:* halving file size changes the metadata-to-bytes
  ratio, which is exactly what a metadata-heavy workload is sensitive to. Low cost, directly relevant.
- **Three access patterns in 6.B.2.** *Why:* metadata-path behaviour is pattern-sensitive; reporting only
  the friendliest or only the harshest pattern would misrepresent both filesystems.
- **6.B.2's file-load p99 is judged against 6.B.3's measured per-step time on the same leg, with 6.B.2's own
  lowest-concurrency cell as the fallback reference, and the criterion lives in this stage's canary rather
  than `RUNBOOK.md`.** *Why:* what a tail latency means here is whether the read path stalls the step it
  feeds, so the only defensible yardstick is the demand the consumer actually places on it — and 6.B.2's
  consumer is a training DataLoader, not a pathologist panning a viewer. Both inputs are measured on the same
  leg, which makes the criterion evaluable without importing a constant nobody in this project owns; a canary
  whose verdict rests on an unsourced number is worse than no criterion at all. The per-leg sequence puts
  6.B.3 ahead of 6.B.2, so the primary reference normally exists when the check runs, and the self-referential
  fallback keeps the check evaluable on a leg where it does not. It stays in this file because it is specific
  to one substage's consumer; `RUNBOOK.md` holds only what generalises.
- **MIL is canonical CLAM `bs=1` + `collate_MIL`; concurrency via `num_workers`.** *Why:* verified against
  upstream CLAM, and the padded-batch alternative OOMs on wide bag-size distributions. `num_workers` is the
  storage-concurrency axis.
- **6.C retention is measured against same-filesystem solo baselines, re-measured at the exact concurrent
  config.** *Why:* retention is a fairness property of each filesystem; borrowing a baseline from an earlier
  stage risks a config mismatch that would silently distort every retention figure.
- **6.C includes pair and triple tiers, not just all-four.** *Why:* they are what make an all-four result
  *diagnosable* — without them, interference is a single number with no attributable cause.
- **6.D is constructive, not a measured cell.** *Why:* the phases are strictly sequential with no
  shared-resource interaction, so measured per-phase numbers compose exactly. Running it live would repeat
  Tier 2 for hours and add no insight; the orchestrator's end-to-end validation is a productisation concern.
  Components must come from the same leg.
- **Cleanup-before-cell in 6.A is mandatory.** *Why:* existing output is skipped rather than rebuilt, so
  without a wipe every cell after the first would short-circuit and report a meaningless number that looks
  plausible.

## Cross-references

- `../CLAUDE.md` · `../PROJECT-THESIS.md` · `STAGES.md` (decision register) · `RUNBOOK.md`
- `Stage-4-Patching.md` — both data paths, the raw-TIFF artifact, the full cuFile-mode grid
- `Stage-5-Training.md` — DDP mechanics, the attribution discipline, cuFile-mode scoping precedent
- `Stage-2-Cataloging.md` — the cross-leg operation-counter comparability caveat
- `Stage-7-Clinical-Inference-Deployment.md` — consumes 6.A features (7.3) and the reader/MIL modules
- `SCRIPT-TRACKER.md` — per-script reference and deferred work
