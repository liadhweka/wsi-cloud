# Stage 4 — Patching / tile extraction, measured identically on both filesystems

> **Every substage runs on both filesystems** — WEKA (Leg A) then FSx for Lustre (Leg B) — with
> everything else held constant. The delta is the result, and **a single leg is half an unfinished
> comparison.**
>
> Stage 4 consumes the 20× coords from **3.0** and, for the GPU-direct path, the 20× raw-TIFF from
> **4.D**. Both are regenerated per leg on the filesystem under test.

For project-wide conventions and recording philosophy see `../CLAUDE.md`; framing and the fairness contract
`../PROJECT-THESIS.md`; stage map and the decision register `STAGES.md`; runbook `RUNBOOK.md`; the coord
generator `Stage-3-Tissue-Detection.md`.

---

## What Stage 4 measures

**Stage 4 is where the three tile-delivery strategies of a WSI pipeline differ structurally, and it
benchmarks them side by side.** WSI training pipelines feed billions of 256×256 tiles to GPU-bound
foundation models, and how those tiles get from storage to GPU takes three fundamentally different shapes:

- **Strategy A — pre-extract (4.A).** Do the I/O-heavy work once up front: decompose every WSI into
  tiles written to per-slide HDF5. Training-time reads are then large and sequential. The pre-extraction
  itself is a write-heavy, compute-mixed one-shot workload.
- **Strategy B — on-the-fly (4.B).** Keep WSIs as-is; the data loader seeks into a slide and reads each
  tile as needed. No preprocessing cost, full flexibility, and it matches how modern foundation-model
  pipelines actually run. Its access pattern is **random small reads across many large files, in parallel,
  from many workers.**
- **Strategy C — GPU-direct (4.C, fed by 4.D).** Convert WSIs to uncompressed raw TIFF, then stream tile
  byte-ranges from storage straight into GPU memory via kvikIO/cuFile, bypassing CPU JPEG decode. This is
  the path where the two filesystems' transports differ, and the one that reads **uncompressed** byte
  ranges — sequentially over a whole level (4.C.1) and randomly from 4.B's coord pools (4.C.2).

Layered on top are two backend axes: **OpenSlide vs cuCIM-CPU** within Strategy B, and **GDS vs
cuFile-compat** within Strategy C.

---

## ⚠️ Scope caveat — read before presenting Stage 4 numbers

**All Stage 4 substages measure POSIX access** — OpenSlide expects filesystem paths, cuCIM's `CuImage`
opens a local file, and kvikIO's `CuFile` reads a local raw-TIFF. Object access is out of scope for this
project on both sides (`../PROJECT-THESIS.md` §9).

---

## The GPU-direct experimental design — how the asymmetry is made analysable

This is the methodological core of Stage 4, and it is worth stating precisely, because a naive version of
this comparison would confound two variables at once.

**The situation.** Lustre-over-EFA supports GPUDirect Storage. WEKA's own materials claim GDS support on
AWS while the transport analysis says ENA is not RDMA-capable, so the matrix is **designed on the
expectation that the WEKA leg runs in cuFile compat mode — and a single Phase-0 cell confirms that
empirically before the matrix is committed** (**D8**; `../PROJECT-THESIS.md` §5.2). A straight "Lustre
GPU-direct vs WEKA GPU-direct" comparison would vary *both* the filesystem *and* the transport, and no
single number could tell you which caused the difference.

**The design.** cuFile's compat mode is available on **both** filesystems. So every applicable cell is run
in **both modes on both filesystems**, giving a 2×2 that decomposes cleanly:

| | cuFile **compat** (bounce buffer, POSIX under the hood) | cuFile **GDS** (direct to GPU memory) |
|---|---|---|
| **WEKA** | ✅ | ✅ *if achievable — determined empirically (**D8**)* |
| **Lustre** | ✅ | ✅ |

Which yields three separable readings:

1. **Lustre-compat vs WEKA-compat** → the **pure filesystem comparison** at an identical code path,
   identical artifact, identical API. No transport difference. This is the cleanest apples-to-apples number
   in the GPU-direct block.
2. **Lustre-GDS vs Lustre-compat** → the **pure GDS effect**, isolated within one filesystem.
3. **Lustre-GDS vs WEKA-best** → the **deployment-reality question**: what a customer actually gets on
   each, given what each can do on AWS.

*Why this matters:* it converts an unavoidable asymmetry from a confound into a measurement. If the Phase-0
cell shows WEKA supporting true GDS, row 1 of the table fills in and the design becomes a full 2×2 with
nothing wasted — which is why it is built so that either answer is usable, rather than around one answer.

**Plus the plain-POSIX cells (4.B) on both filesystems**, because cuFile-compat stacks a bounce buffer and
the cuFile layer on top of POSIX and may be **slower than each filesystem's own native path**. Without
4.B, we would understate whichever side falls back.

**Prove the path, per cell (D8).** Every kvikIO cell records cuFile's own accounting of GPU-direct vs
bounced bytes (`CUFILE_STATS`, `/proc/driver/nvidia-fs/stats`). **A configuration flag is not proof of
behaviour** — a compat-mode setting being enabled does not tell you which path a given read took, and a
cell that quietly fell back (or quietly didn't) would silently poison the comparison. This is a hard gate,
not a nice-to-have: a kvikIO cell without path accounting is an incomplete cell.

---

## Recording — Stage 4's changes to the base source set

The operational source table, the per-filesystem split, both canaries, and the full per-cell measurement
set (including the cost inputs) live in `RUNBOOK.md`. This section records only what **Stage 4** changes,
and why.

- **`nvidia-smi` becomes primary from Stage 4 onward.** Stages 1–3 do no GPU work. Here it is the evidence
  for GPU stall-vs-fed in 4.B and for the GPU-memory footprint of kvikIO buffers in 4.C — both load-bearing
  for reading whether a cell was storage-bound or pipeline-bound.
- **cuFile path accounting is primary on every 4.C cell**, and a cell without it is incomplete (**D8**).
- **Per-core CPU over application-available cores is primary in 4.A and 4.B**, where JPEG decode competes
  with I/O for the same cores: it is what distinguishes "workers saturating CPU on decode" from "CPU idle
  while the GPU works". The reserved-core exclusion set is a per-filesystem parameter (**D15**).

**What these sources may be compared across legs.** App-level tile rates are comparable across legs by
construction — same reader, same coords, same tiles, only `$FS_MOUNT` differs. **Filesystem-reported
operation counts are not**: WEKA and Lustre each count operations under their own semantics, so 4.B's
operation counts are **within-leg only** until the counter semantics are verified equivalent and that
verification is recorded (`Stage-2-Cataloging.md` carries the caveat).

**Which consistency relation applies differs by substage.** 4.B and 4.C read only; 4.A and 4.D read
their sources while they write, so both directions are on the wire at once. WEKA's erasure-coding
write amplification applies to the write side and has no read-side equivalent; Lustre's relation
follows from the stripe layout in use either way (**D12**). A mixed read+write cell therefore takes
the wider band `RUNBOOK.md` requires for one, widened deliberately rather than silently. Each
substage's table below names the check it runs.

**Phase 0 is a hard gate.** No bandwidth-relevant Stage 4 cell runs before that leg's provisioning is
verified against the fairness basis (**D7**) and the Stage 1.0 synthetic ceilings are captured **per block
size** — every "% of ceiling" in 4.A/4.B/4.C divides by the **block-size-matched** cell, because a
mismatched-block denominator makes a mid-block workload look artificially high or low.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete.

### 4.A — Strategy A: pre-extract tiles to per-slide HDF5

| | |
|---|---|
| **Status** | ⏳ both legs — needs 3.0 coords |
| **Tool** | `openslide-python` + `h5py`. Reads the 20× tile coords produced by 3.0 |
| **Source → Target** | `$FS_MOUNT/data/<dataset>/<slide-id>.svs` + `$FS_MOUNT/tissue-detection/3.0/<dataset>/n64/patches/<slide-id>.h5` → `$FS_MOUNT/patches/4.A/<dataset>/n<N>/<slide-id>.h5` |
| **Methodology** | **2-D sweep:** datasets ∈ {TCGA-BRCA, CAMELYON16} × concurrency ∈ {1, 8, 64} = **6 cells per leg**, **concurrency outer descending** (n=64 first) so the cheap cells validate the methodology before the long-pole n=1 cell. **50-slide random subset per dataset (seed=42)**, manifests in `../scripts/manifests/<dataset>-stage4a-subset.tsv`. Per slide: open the SVS, read the 20× coords, read each patch honouring the coord contract (BRCA 512 px @ 40× resized to 256 px @ 20×; CAM16 256 px @ 20× native), JPEG-encode at q=85, append to a vlen-bytes HDF5 with coords + metadata attrs. Concurrency via `multiprocessing.Pool(processes=N)`. Single-pass per cell. |
| **Why this exists** | The legacy-storage-friendly extraction pattern, and the baseline against which Strategies B and C are read. It is the one Stage 4 path whose training-time reads are large and sequential, which is why a customer's existing pipeline often already runs on it — so measuring it is what makes the A-vs-B-vs-C contrast a measurement rather than an assumption. It also produces a **mixed write + compute** profile that neither 4.B nor 4.C covers. |
| **Why identical on both** | Same subset manifests, same coords, same encode settings, same concurrency grid, same output layout. Only `$FS_MOUNT` differs. |
| **Subsetting rationale** | Full BRCA at n=1 is infeasible in wallclock, and 4.A's outputs are **not consumed by 4.B/4.C/5/6**, so subsetting bounds cost without affecting any downstream stage. Recorded here so the subset is not mistaken for a sampling limitation of the measurement. |
| **Sweep driver** | `../scripts/sweep-stage4a-patches.sh` · **Extractor** `../scripts/extract-tiles-to-hdf5.py` · **Aggregator** `../scripts/aggregate-stage4a-patches.py` |
| **Aggregated output** | `s4.A-patches-summary.csv` |
| **Recorded per cell** | tiles/sec per concurrency and dataset, app-level write throughput vs the block-size-matched write ceiling, strong-scaling efficiency n=1→8→64, CPU, failures, total output bytes — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cross-source check** | mixed read+write — each direction at its per-filesystem relation (**D12**), at the widened band a mixed cell requires (`RUNBOOK.md`) |

### 4.A.2 — WebDataset format alternative

| | |
|---|---|
| **Status** | ⏳ DEFERRED (both legs) |
| **Why deferred** | WebDataset tar shards are a real foundation-model training format, but the Stage 4 contrast is **A vs B vs C**, not HDF5-vs-WebDataset *within* A. Adding it would vary the output format while holding the strategy fixed — a different question, and one that does not discriminate between the two filesystems. Revisit only if a customer asks specifically about WebDataset shards. |

### 4.B — Strategy B: on-the-fly tile reads (CPU backends, both filesystems)

| | |
|---|---|
| **Status** | ⏳ both legs — needs 3.0 coords + Phase 0 ceilings |
| **Tool** | **OpenSlide** per-tile CPU reader with `multiprocessing.Pool` (represents MONAI / Slideflow / CLAM / Trident) **and cuCIM batched CPU** (`CuImage.read_region(locations_list, batch_size, num_workers, prefetch_factor, device='cpu')` — the documented production API). Per `docs.rapids.ai/api/cucim/stable` and `github.com/rapidsai/cucim` |
| **Source → Target** | `$FS_MOUNT/data/<dataset>/…` → host RAM. No persistent output — reads consumed in place |
| **Methodology** | **Tiered CPU-only sweep**, 2 datasets × 2 backends. **Tier 1:** OpenSlide N ∈ {1,4,16,64,256} and cuCIM N ∈ {1,4,16,64} at locked (batch_size, num_workers). **Tier 2** (adaptive from Tier 1 knees): 2-D cuCIM (N × num_workers), batch_size sensitivity, OpenSlide N fine-grain. **Tier 3** (conditional): push past Tier 1's max toward each filesystem's read ceiling. Each cell time-based (~60 s + 10 s ramp); workers draw random (slide, x, y) from that dataset's 20× coord pool; LRU(8) slide-handle cache per worker; seed=42. |
| **Why this exists** | This is the pattern modern WSI pipelines actually run, and the one that stresses storage the way training does — random small reads across many large files from many parallel workers. Two production variants are covered because both exist in the wild: per-tile OpenSlide (what most existing pipelines do) and cuCIM's batched CPU API (higher throughput per process). |
| **Why identical on both** | Same coord pools, same backends and versions, same tier structure, same seeds, same cache policy. Only `$FS_MOUNT` differs. |
| **cuCIM `read_region(device='cuda')` is ruled out — library defect, filesystem-independent, do not re-investigate** | Three issues, all internal to cuCIM: it pre-allocates one GPU buffer spanning the whole byte range between the lowest and highest tile offsets in a batched call (fine for clustered reads, OOMs for random ones); the nvImageCodec decoder module is not bundled in the conda binaries (source-only); and the API is marked not-yet-supported upstream. **This is a cuCIM bug, not a property of either filesystem** — it will behave the same on WEKA and Lustre, so it is **not a comparison axis and must never be reported as a storage finding for either side.** The OSS ecosystem cross-check (MONAI / Slideflow / CLAM / Trident all use CPU per-tile reads) corroborates dropping the axis. The GPU-direct story routes to 4.C via kvikIO, exactly as NVIDIA's own reference code does. Version-sensitive: re-verify against the installed cuCIM before treating the specifics as current. |
| **Cache discipline (D13)** | **Load-bearing here specifically**, and the one Stage-4 cell where the crossover is itself the object of study. The canonical corpus far exceeds either side's cache, so at corpus level these cells are **cold by construction** (**D13** route 1) — but that is not the risk here. The risk is that at high worker counts the *repeatedly re-drawn subset* of the coord pool becomes page-cache- and/or file-server-cache-resident, at which point the cell measures cache rather than storage — and because the two filesystems cache differently, **the crossover falls at a different worker count on each**, which is exactly why it is characterised per filesystem rather than assumed shared. So: cache state **recorded as achieved** per cell, **cold reference cells** (**D13** route 2) at the worker counts where the crossover is expected to sit, and cell order not ascending in worker count — otherwise warmth and concurrency rise together and the crossover cannot be located at all. |
| ⚠ **Standing constraint — the driver cannot currently produce a cold cell** | `sweep-stage4b-tilesread.sh` sets `TIER3_DROP_CACHES=0`, hardwiring off the only cold mechanism it has, and justifies it with a claim about a *previous host's* RAM. Until that is re-derived and re-enabled, no 4.B cell can be labelled cold, and the crossover this substage exists to characterise cannot be measured. **Do not run 4.B as it stands.** Tracked in the open-items memory (the read-sweep driver item). |
| **Sweep driver** | `../scripts/sweep-stage4b-tilesread.sh` · **Reader** `../scripts/read-tiles-onthefly.py` · **Aggregator** `../scripts/aggregate-stage4b-tilesread.py` |
| **Aggregated output** | `s4.B-tilesread-summary.csv` |
| **Recorded per cell** | tiles/sec per backend/dataset/concurrency, **cold** filesystem-side read bytes, operation counts, application-available-core CPU, cuCIM-vs-OpenSlide multiplier, batch_size/num_workers sensitivity, and the warm-vs-cold crossover per filesystem — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cross-source check** | app-level tile-rate × tile-bytes must reconcile with filesystem-side read bytes at that filesystem's derived read relation |

### 4.C — Strategy C: kvikIO / cuFile reads from 20× raw-TIFF (both filesystems, both modes)

| | |
|---|---|
| **Status** | ⏳ both legs — needs 4.D raw-TIFF + Phase 0 ceilings |
| **Tool** | `kvikIO` (RAPIDS wrapper over NVIDIA's cuFile API) + `tifffile` for TIFF metadata + `cupy` for GPU buffers. Reads via `kvikio.CuFile(fname,'r').pread(buf, file_offset=N)` returning `IOFuture`s for async pipelining. Modelled on NVIDIA's published reference (`cucim/examples/python/gds_whole_slide/demo_implementation.py`) and the [NVIDIA digital-pathology GDS blog](https://developer.nvidia.com/blog/accelerating-digital-pathology-workflows-using-cucim-and-nvidia-gpudirect-storage/) |
| **Source → Target** | `$FS_MOUNT/data/{tcga-brca,camelyon16}-rawtiff/<slide-id>.tiff` (from 4.D) → GPU memory (pre-allocated CuPy tile buffers) |
| **Methodology** | **Two blocks under one umbrella.** <br><br>**4.C.1 — faithful reference replication.** Sequential full-level-0 read of each subset slide via `CuFile.pread()` with `n_buffer` async pipelining, cold cache between slides. Gives a directly comparable analogue of NVIDIA's published GDS-vs-POSIX pattern. <br><br>**4.C.2 — random-tile reads, apples-to-apples with 4.B.** Random (slide, tile-index) drawn from the **same 4.B coord pools**, mapped to the raw-TIFF tile grid via `coord // 512 → page.dataoffsets[idx]`. Time-based (~60 s + 10 s), matching 4.B so the two strategies are directly comparable. <br><br>**Common mechanics:** **every cell runs in BOTH cuFile modes (GDS and compat) on BOTH filesystems** per the experimental design above; per-cell-scoped `LD_PRELOAD` of the system libcufile; 4096-byte-aligned reads; **cuFile path accounting recorded per cell**; seed=42. <br><br>**Tier 1 — saturation curve:** `n_buffer` ∈ {1,4,16,64,256} × 2 cuFile modes × 2 blocks, BRCA. <br>**Tier 2 — bottleneck characterisation (adaptive):** cross-dataset at peak `n_buffer`; `task_size` ∈ {64KB, 256KB, 1MB, 4MB}; `num_threads` ∈ {4,8,16,32}; memory pre-registration on/off; and **multi-process scaling for 4.C.2** across the instance's GPUs with NUMA-aware assignment (map re-derived per the deferred table in `SCRIPT-TRACKER.md`, **D-8**). <br>**Tier 3 — ceiling stress (conditional):** push process count and config until filesystem-side read plateaus. <br><br>**Subset:** the same 50 BRCA + 50 CAMELYON16 manifests as 4.A. |
| **Why this exists** | It is the NVIDIA-documented GPU-direct WSI pipeline, and the **only Stage 4 path where the two filesystems' transports genuinely differ** — which is what makes it need the careful decomposition above. It is also the Stage 4 path that moves the most bytes per request, so it is the block where **D7**'s requirement that both sides be provisioned above what the client can drive is load-bearing. |
| **Why identical on both** | Same reader, same raw-TIFF artifact definition, same coord pools, same tier structure, same alignment, same seeds. What differs is exactly what is under test: the filesystem and, within it, which cuFile path is achievable. |
| **⚠ `LD_PRELOAD` must be scoped per cell** | cuCIM segfaults inside `read_region()` when a newer libcufile is `LD_PRELOAD`ed over its bundled one (ABI clash). Since this project runs kvikIO **and** cuCIM cells on both filesystems, essentially every sweep is a mixed sweep — set the preload only on kvikIO cells. Symptom if forgotten: the reader initialises cleanly, then segfaults on the first cuCIM read, which is easy to misdiagnose as a multiprocessing or cuCIM bug. Versions are era-specific — re-derive on the cloud stack. |
| **Sweep driver** | `../scripts/sweep-stage4c-kvikio.sh` · **Reader** `../scripts/read-tiles-kvikio.py` · **Multi-proc launcher** `../scripts/run-multiproc-kvikio.sh` · **Aggregator** `../scripts/aggregate-stage4c-kvikio.py` |
| **Aggregated output** | `s4.C-kvikio-summary.csv` |
| **Recorded per cell** | peak GB/s landed in GPU memory (single- and multi-process), the four-way mode × filesystem decomposition, faithful-mode full-level-0 rate, cross-dataset consistency, secondary-knob sensitivity, CPU and GPU-memory footprint, filesystem-side read peak vs the block-size-matched ceiling, **and the recorded GPU-direct-vs-bounced byte split for every cell** — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cross-source check** | app-level GB/s, filesystem-side read bytes, and the wire counters for the path in use must agree at that filesystem's derived read relation; `nvidia-smi` must show GPU-memory growth consistent with `n_buffer` × buffer size × processes |

### 4.D — 20× raw-TIFF conversion (input generation, and a measured write workload)

| | |
|---|---|
| **Status** | ⏳ both legs — gates 4.C, 5.A, the 6.A kvikIO backend, and the Stage 7 kvikIO backends |
| **Tool** | `convert-rawtiff-20x.py` (a `tifffile`-based writer) driven by `convert-stage4c-rawtiff.sh` |
| **Source → Target** | `$FS_MOUNT/data/<dataset>/<slide-id>.{svs,tif}` → `$FS_MOUNT/data/<dataset>-rawtiff/<slide-id>.tiff` |
| **Methodology** | Emits a **single-level, 256×256-tiled, uncompressed RGB-uint8 TIFF whose level-0 IS the 20× image**, so kvikIO reads level-0 byte ranges directly as 256 px @ 20× tiles and CLAM coords (level-0 px, stepping by 512) map to a tile index via `coord // 512`. Per-dataset source read follows the 20× coord contract: CAMELYON16 is read at its native 20× level with no resize; TCGA-BRCA is read at 512 px @ 40× and area-averaged down to 256 px, matching the cuCIM readers' interpolation **so both backends see the same pixels**. A **fail-loud mpp guard** refuses any stray off-mag slide. Existing non-empty output is skipped. |
| **Why a true 20× artifact rather than level-1 of a 40× file (D4)** | `cucim convert` exposes no magnification or level flag and always emits the source's 40× level-0. Keeping a 40× artifact and reading pyramid level-1 would produce a larger file, a slower conversion, and — decisively — **not the artifact a 20× GPU-direct customer actually stores.** Since a storage benchmark cares about file size and layout as well as throughput, the artifact must be the real one. |
| **Why this is measured, not just prep** | Conversion is a **sustained large-write plus large-read workload** on real data — a legitimate measurement in its own right, and one that no other Stage 4 cell covers. It is recorded as its own cell rather than run silently. |
| **⚠ Provisioning consequence (feeds D7)** | The raw-TIFF artifact is a substantial capacity cost **on both filesystems**, and on FSx capacity is simultaneously a performance knob — so this substage's footprint is an input to how both sides are sized, not an afterthought. Confirm headroom on each filesystem before starting the conversion, and record the bytes actually written as a 4.D result. |
| **⚠ Regeneration hygiene** | Existing non-empty output is skipped, so a stale artifact would be silently kept and read as if current. If the target directory ever holds output from a different magnification or a different converter version, **delete it before converting** — otherwise the GPU-direct cells read the wrong pixels and nothing fails loudly. |
| **Sweep driver** | `../scripts/convert-stage4c-rawtiff.sh` · **Converter** `../scripts/convert-rawtiff-20x.py` |
| **Recorded per cell** | conversion wallclock, sustained write and read throughput, output bytes per dataset, mpp-guard rejections — a rejection means the manifest and the cohort disagree, so investigate rather than proceed — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cross-source check** | mixed read+write — each direction at its per-filesystem relation (**D12**), at the widened band a mixed cell requires (`RUNBOOK.md`) |
| **Cross-leg integrity check** | Output byte counts and per-slide tile-grid dimensions are **storage-independent**, so they must match between legs. A divergence means the legs converted different inputs or used a different converter version — **fail loud**, as with the Stage 3 coord-equivalence gate. |

---

## Tool inventory used in Stage 4

| Tool | Version | Source | Used in |
|---|---|---|---|
| `openslide-python` / `libopenslide` | record at run time | conda | 4.A, 4.B |
| `h5py` | record at run time | conda | 4.A |
| `cuCIM` | record at run time | **conda (RAPIDS channel), not pip** — see note | 4.B (cuCIM backend), 4.D (source reads) |
| `kvikIO` | record at run time | RAPIDS conda | 4.C |
| `tifffile` | record at run time | conda | 4.C metadata, 4.D writer |
| `cupy` | record at run time | RAPIDS conda | 4.C |
| `PyTorch` | record at run time | conda | 4.B tensors; reused in 5/6/7 |
| conda env | n/a | on local NVMe scratch; Stage 4+ Python runs via the env's own interpreter | 4.A–4.D and onward |
| `record-run.sh` | live | `../scripts/record-run.sh` | every substage |

**Install note (cuCIM).** pip-distributed cuCIM wheels have been observed to crash with a libstdc++ ABI
mismatch inside `read_region()`; the RAPIDS conda channel install does not (conda manages a matched
libstdc++). **Use the conda env as the canonical Stage 4+ Python environment** and re-verify on the cloud
stack rather than assuming the same versions behave identically.

## Datasets used in Stage 4

| Dataset | Source | Scope | Used in |
|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | hydrated per leg (1.7) | 50-slide subset (4.A, 4.C); full cohort coord pool (4.B) | 4.A, 4.B, 4.D |
| CAMELYON16 (`images/`) | hydrated per leg (1.7) | as above | 4.A, 4.B, 4.D |
| **20× tile coords** | produced by 3.0 per leg | per-slide HDF5 | 4.A extracts from them; 4.B uses them as the random-read pool; 4.C maps them to raw-TIFF tile indices |
| **20× raw-TIFF** | produced by 4.D per leg | derived artifact | 4.C |

## Decision register (Stage 4-scoped)

One entry per live Stage 4 decision. Cross-stage decisions live in `STAGES.md`.

- **Every 4.C cell runs in BOTH cuFile modes on BOTH filesystems.** *Why:* this is what turns the
  unavoidable GDS asymmetry from a confound into a measurement. Compat mode exists on both sides, so
  **Lustre-compat vs WEKA-compat is a pure filesystem comparison at an identical code path**, while
  **Lustre-GDS vs Lustre-compat isolates the GDS effect** — and the two combine to answer the deployment
  question. With only one mode, a single "Lustre GPU-direct vs WEKA GPU-direct" number would vary
  filesystem and transport simultaneously and could not be attributed.
- **cuFile path accounting is a hard per-cell requirement, not an optional extra.** *Why:* a configuration
  flag does not tell you which path a read actually took, and a silently-fallen-back cell looks identical
  to a working one in the throughput data. A kvikIO cell without recorded GPU-direct-vs-bounced bytes is
  treated as incomplete.
- **Plain-POSIX cells (4.B) run on both filesystems alongside the kvikIO cells.** *Why:* cuFile-compat adds
  a bounce buffer and the cuFile layer on top of POSIX, so it may be slower than a filesystem's own native
  path — without 4.B we would understate whichever side falls back. 4.B is each filesystem's
  best-foot-forward number; 4.C-compat is the like-for-like one.
- **All three strategies (A, B, C) are benchmarked, not just the storage-heaviest.** *Why:* the three have
  genuinely different I/O shapes (one-shot write-plus-compute, random small reads, large byte-range
  streaming), and a customer's actual choice among them depends on their pipeline. Measuring only one would
  answer a narrower question than the one being asked.
- **The 20× raw-TIFF conversion is its own numbered substage (4.D), regenerated per leg and measured.**
  *Why:* the artifact definition is **D4**; numbering the conversion separately puts it in the plan as a
  gating step with its own footprint and duration, and the conversion is itself a sustained write workload
  worth recording rather than running silently.
- **cuCIM `read_region(device='cuda')` is not a comparison axis.** *Why:* it is a library defect (buffer
  allocation, unbundled decoder module, pre-GA upstream), so it is filesystem-independent and would produce
  identical failure on both sides. Reporting it as a storage result for either filesystem would be wrong.
  Do not re-investigate it per leg.
- **`LD_PRELOAD` of the system libcufile is scoped per cell — kvikIO cells only, never cuCIM cells.**
  *Why:* the ABI clash segfaults cuCIM inside its first `read_region()`, and nearly every Stage 4 sweep is
  mixed by construction, so a sweep-wide preload breaks the cuCIM cells in a way that looks like a
  multiprocessing bug.
- **4.A is subsampled to 50 slides per dataset (seed=42).** *Why:* full BRCA at n=1 is infeasible, and
  4.A's outputs feed nothing downstream, so the subset bounds cost without affecting any other stage.
- **4.A output is HDF5 with vlen JPEG bytes.** *Why:* CLAM-style and directly compatible with Stages 5/6,
  and far smaller than raw uint8.
- **`nvidia-smi` is primary from Stage 4 onward.** *Why:* it is the evidence for GPU stall-vs-fed in 4.B
  and for the kvikIO buffer footprint in 4.C — both load-bearing for interpreting whether a cell was
  storage-bound or pipeline-bound.
- **4.A.2 (WebDataset) is deferred.** *Why:* it varies output format within Strategy A rather than
  addressing the A-vs-B-vs-C contrast, and it does not discriminate between the two filesystems.
- **Cold-vs-warm is characterised per filesystem in 4.B, not assumed to cross over at the same worker
  count.** *Why:* the two filesystems cache differently, so the working-set-vs-cache crossover is itself a
  per-filesystem property; assuming a shared threshold would mislabel cells on one side.

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, cross-stage decision register (esp. **D4**, **D7**, **D8**, **D10**, **D13**, **D15**)
- `RUNBOOK.md` — the per-cell measurement set, the cost inputs, the source table, and both canaries
- `Stage-3-Tissue-Detection.md` — the 20× coord generator feeding this stage, and the coord-equivalence gate
- `Stage-2-Cataloging.md` — the cross-leg ops-counter comparability caveat, which applies to 4.B's operation counts
- `SCRIPT-TRACKER.md` — per-script reference incl. the converter and the 20× contract; the deferred table
- `../runs/INDEX.md` — append-only run history (auto-generated)
