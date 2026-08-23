# Stage 1 — Ingest (scanner-to-storage), measured identically on both filesystems

> **Every substage here runs twice: once on WEKA (Leg A), once on FSx for Lustre (Leg B), with
> everything else held constant.** The WEKA-vs-Lustre delta is the result. A single leg's numbers are
> half an unfinished comparison and must never be presented as final.
>
> **One substage is deliberately single-filesystem:** **1.8** (FSx-native S3 import) has no WEKA
> counterpart and is excluded from the head-to-head — see below.

For project-wide conventions and recording philosophy, see `../CLAUDE.md`. For the framing and fairness
contract, `../PROJECT-THESIS.md`. For the stage map, per-leg plan, and the decision register,
`STAGES.md`. For how to run and record a cell, both canaries, and failure recovery, `RUNBOOK.md`.

---

## What Stage 1 measures

The "scanner-to-storage" workload. Real pathology labs produce slides at scanner output (typically 1–2
minutes per slide, 1–1.5 GiB SVS files), which land on storage and become available to every downstream
pipeline — cataloging, tissue detection, training, inference, viewer. Stage 1 measures **how fast each
filesystem absorbs that feed via POSIX**, isolated from any downstream processing.

The customer pain point: legacy NAS plateaus at a few GiB/s ingest under realistic concurrent-stream
loads, forcing a second fast tier. Stage 1 measures whether either filesystem removes that need — and, in
the head-to-head, whether they differ in doing so.

### What "20×" means for Stage 1

**Nothing direct.** Stage 1 does no tiling — it moves whole `.svs`/`.tif` files. The 20× coord contract
(`STAGES.md`, **D1–D5**) changes coordinate space and tile counts in Stages 3–7, not the bytes Stage 1
moves. **Stage 1 is magnification-irrelevant throughout.** It is included because ingest is a real
customer workload and because 1.0a–d anchor every downstream "% of ceiling" denominator.

---

## ⚠️ Protocol scope caveat — read before presenting Stage 1 numbers

**Every Stage 1 substage measures POSIX ingest, not SMB.** Real-world pathology scanners are typically
Windows-based and write to shared storage via SMB, not via a POSIX filesystem driver.

This matters for how the numbers are described, and it is worth being precise about the two sides:
WEKA supports SMB natively (per `docs.weka.io → Additional Protocols → SMB Support`: SMB 2/3, SMB
Multichannel, SMB Direct/RDMA), while Lustre has no native SMB service — an SMB gateway would have to be
layered on. **That difference is a feature-set observation, not something this project measures**, and it
must not be presented as a measured result. Protocol stacks differ in metadata semantics (chatty SMB
open/close vs POSIX), per-op overhead, and caching, so SMB-ingest performance is **not interchangeable**
with POSIX-ingest performance on either filesystem.

### Why SMB is out of scope — explicit, conscious decision

1. **The infrastructure to do it cleanly isn't in scope.** Doing SMB ingest properly would require
   standing up an SMB endpoint on each side (including a gateway on the Lustre side, which has no native
   equivalent) plus a Windows client to drive realistic Windows-side writes. Adding that would dilute
   focus from the stages where this comparison's value lies — **and it would introduce a genuine
   asymmetry we could not hold constant**, since the two SMB paths would not be architecturally
   comparable.
2. **Ingest is not where this comparison concentrates.** The focus is the WSI ML/data-pipeline workloads
   — Stage 4 (tile extraction), Stage 5 (training pipeline), Stage 6 (foundation-model extraction and
   small-file/metadata stress), Stage 7 (inference). Those are read-dominated and intrinsically POSIX
   (PyTorch DataLoaders, cuCIM, MONAI all run on Linux against POSIX mounts), so protocol is not a
   variable there.
3. **The synthetic write ceiling (1.0a) is protocol-independent.** It bounds what each filesystem's write
   path can absorb regardless of what protocol is layered on top, so an SMB stack on either side cannot
   exceed it.

### What Stage 1 IS valid for

- The protocol-independent **write-path ceiling** of each filesystem (1.0a).
- **Linux-based ingest pipelines** (real in research labs).
- **Multi-stage workflows where SMB is upstream and POSIX is downstream** — scanner → SMB share → Linux
  gateway → POSIX write to shared storage. Common at scale, because POSIX is faster end-to-end on Linux,
  so the last leg is often POSIX even when the scanners are Windows.

### What Stage 1 is NOT a substitute for

- **Windows-scanner-direct-SMB ingest** — the canonical upstream lab workflow. This project does not
  measure it and does not claim to, on either filesystem.

**When presenting any real-data ingest number, say "POSIX" alongside it.**

---

## Strategy framing

Stage 1 has three complementary methodologies, not competing ones:

- **Synthetic ceiling (1.0a–d).** `fio` against an isolated scratch directory. Establishes what the write
  and read paths absorb with no application in the way. *Why first:* real-data numbers are uninterpretable
  without an isolated-storage anchor, and every downstream "% of ceiling" divides by one of these cells.
- **Bulk staged ingest (1.5, 1.7).** Real WSI files copied onto the filesystem — from instance-local NVMe
  (1.5, `fpsync` at varying concurrency) and from S3 (1.7). No WAN bottleneck in either case, so the
  signal is the filesystem's write path. Closest to the actual scanner-to-storage path most labs run.
- **Mixed concurrent (1.6).** Ingest and read simultaneously — the operationally realistic state, where a
  scanner feeds while pathologists read existing slides.

**Dataset staging is not a comparison cell.** The WAN download from GDC and the CAMELYON open-data bucket
happens **once, before either leg**, into our own S3 bucket. *Why:* it measures a WAN link and an external
service, not a filesystem, so running it per-leg would burn hours to produce a number about neither
filesystem — and it would put different bytes on the two sides. Staging once into S3 makes the datasets a
**held-constant input**, byte-verified, identical in both legs.

**The `% of ceiling` rule (Phase 0, `STAGES.md`).** Throughput is block-size-dependent, so every downstream
"% of ceiling" divides by the Stage-1.0 cell at the **matching block size** — never a mismatched-block
ceiling, which would make a mid-block workload look artificially high or low. **The ceiling cell's own cache
regime is recorded alongside it, because every downstream percentage inherits the denominator's
contamination:** a cache-inflated ceiling silently deflates every stage that divides by it, and the deflation
is invisible in the later stage's own numbers, which stay internally consistent. That is why the read
ceilings (1.0b, 1.0d) are **cold by construction** — see their cache-discipline rows.

---

## Recording — Stage 1's changes to the source table

Every cell runs through `record-run.sh`. **`RUNBOOK.md` owns the per-cell measurement set, the cost
inputs, the operational source table with its per-filesystem split, and both canaries.** That split is
mandatory and **is not the same on both legs** (**D12**) — using one leg's table for the other produces
confidently wrong numbers. Stage 1 changes the base table in one place, and names the cells one of its
exceptions covers:

- **The change: client network counters are Primary on *both* legs for 1.7.** The base table has them
  diagnostic on the WEKA leg because DPDK bypasses the kernel network stack — but 1.7's *source* traffic
  is S3 over the kernel TCP stack whichever filesystem is the target, so on that cell they measure a real
  data path on both sides.
- **Where `sar -d` is not ~zero:** 1.4's smoke `fio`, 1.5's staging prep run and its sweep cells, and
  1.6's write side — every Stage 1 cell with local NVMe on one end. That is the base table's local-disk
  exception rather than a change to it: on those cells the block-device counters are how we confirm the
  **source** — not the filesystem — was not the limit, which is the headroom 1.4 exists to provide.

The cross-source canary's general rules are in `RUNBOOK.md`. Stage 1 adds one: **at the small block sizes
of 1.0c/1.0d, per-op overhead shifts the wire-vs-app ratio away from its large-block value on both
filesystems**, so the band is derived at the block size under test rather than inherited from the
large-block cell. The mixed-phase band (1.6) is a separate derivation again — see the engineering note
below.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete.

### 1.0a — Synthetic upper bound, sequential write

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 35/35 cells OK, canary PASS on all) · ⏳ Leg B |
| **Leg A results (app-level fio, peak over jobs per bs; per-cell data in the run dirs / `s1.0a-seqw-summary-<leg>.csv`)** | 4k: 1.08 GiB/s (282k IOPS) · 64k: **8.48 GiB/s** · 256k: 4.91 GiB/s · 1M: 5.39 GiB/s · 4M: 5.64 GiB/s — every peak at jobs=64 (grid top). *Caveats:* the 64k > large-block non-monotonicity is recorded, not explained — but note the paired wire measurement: at 64k the client wire/app ratio measured ≈1.04 versus ≈1.46 at 1M/4M (see 1.0c's caveat), i.e. the EC amplification visible on the client wire is block-size-dependent; the two observations are mutually consistent and no mechanism was verified. Large-block writes track the calibration probes (~5.2–5.6 GiB/s app, wire ×1.456 per the 5+2 relation). Cells are single-shot (D18 knee/peak repeats still to run). |
| **Tool** | `fio` (version recorded at run time) |
| **Source → Target** | host RAM → filesystem scratch (`$FS_MOUNT/benchmarks/fio-scratch/`) |
| **Methodology** | 5 block sizes (4K, 64K, 256K, 1M, 4M) × 7 concurrency levels (1–64 jobs) = **35 cells**. Each cell: steady state + ramp, libaio + `--direct=1` + `--unlink=1`, iodepth=1 (sequential-bandwidth recipe). |
| **Why this exists** | Anchors every real-data Stage 1 number against "what does this filesystem's write path absorb from this client, in isolation?" Without it, "real ingest = X GiB/s" is uninterpretable. It is also the **protocol-independent** ceiling that bounds any SMB stack layered on top. |
| **Why identical on both** | `fio` is filesystem-agnostic — same grid, same flags, same scratch layout, only `$FS_MOUNT` differs. This is the cleanest apples-to-apples cell in the project. |
| **Sweep driver** | `../scripts/sweep-stage1-seqw.sh` |
| **Aggregated output** | `s1.0a-seqw-summary-<leg>.csv` |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`). |

### 1.0b — Synthetic upper bound, sequential read

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 36/36 cells OK, canary PASS on all) · ⏳ Leg B |
| **Leg A results (app-level fio, peak over jobs per bs; `s1.0b-seqr-summary-<leg>.csv`)** | 4k: 1.29 GiB/s (339k IOPS) · 64k: 8.92 GiB/s · 256k: 10.71 GiB/s · **1M/4M: ~11.0 GiB/s** — the large-block plateau matches the measured 4-FE-core client capability (~94 Gbps), far below the 200 Gbps line rate, so the ceiling is the client's realistic-production FE config, not the network or the backends (**D10 trigger does not fire**). Warm-reference evidence: first-half 3.99 GiB/s vs second-half 6.21 GiB/s (×1.56) at jobs=4 — the server cache serves at a distinguishable rate, so the grid's cold labels rest on a measurement. *Data-validity note (attaches to two cells):* `seqr-bs1M-jobs8` and the warmref lost their first recordings to the 2026-08-16 root-volume ENOSPC and were re-run ~30 min later under the identical construction (originals renamed `-FAILED-enospc*`; the scan corpus's cold construction is history-independent). |
| **Tool** | `fio` |
| **Source → Target** | filesystem → host RAM |
| **Methodology** | Same grid as 1.0a (5 bs × 7 jobs = 35 cells), `--rw=read`, iodepth=1, **plus one cold reference cell = 36**. Reads run against a corpus **staged ahead of the timed window and left in place across cells**; the cache-discipline row below sets its sizing and the cell ordering, and both are part of the methodology rather than a refinement of it. |
| **Why this exists** | The read counterpart to 1.0a. Ingest itself cares little about read-back, but **every later stage is read-dominated**, so the read ceiling is needed up front. Read-vs-write asymmetry is also architecturally informative: WEKA's erasure coding amplifies writes on the wire while reads are not amplified, whereas Lustre's striping behaves differently again — the shape of that asymmetry is a real difference between the two designs. |
| **Cache discipline (D13)** | **Cold by construction** (**D13** route 1) — the strongest discipline available, because this is a cell every downstream "% of ceiling" divides by, and both sides carry substantial server-side cache on top of the client's own RAM, so an unlabelled read number is ambiguous and the ambiguity is asymmetric. Four requirements: **(1) sizing** — the working set exceeds **the larger of the two server-side caches**, per **D13**: FSx's from its documented file-server cache per TiB at the provisioned tier and capacity, WEKA's from the backends' aggregate RAM, **both fetched at provisioning, never recalled**. The requirement binds at **every point in the grid, single-job cells included** — that is where a small per-job set is trivially absorbed — so it is each *cell's* working set that must clear the cache, not the aggregate across the grid. Because the corpus is retained rather than unlinked, **its footprint is a capacity input on both sides** — and on FSx capacity is simultaneously a performance knob (**D7**), so it is settled at provisioning, not discovered mid-sweep. **(2) staging** — the corpus is staged ahead of the timed window and **not unlinked and recreated between cells**, so no cell reads bytes the filesystem absorbed seconds earlier; `--direct=1` reaches only the client's page cache and says nothing about the server's. **(3) evidence** — **one cold reference cell** at a single (block size, concurrency) point (**D13** route 2), as the measurement that the sizing worked, run as cold as the mechanism actually reaches (`RUNBOOK.md` records what each clearing step clears) with the residual server-side uncertainty stated. **(4) ordering** — cell order **reversed or randomised**, so warmth does not rise monotonically with concurrency and the two effects stay separable. Cache state is **recorded as achieved** per cell, never asserted. |
| **How the driver implements it** (ratified 2026-08-15) | Cells read the **pre-staged shared scan corpus** (`prep-stage1-read-corpora.sh`; `STAGE1_SEQ_CORPUS_GIB`, ≥ ~2× the larger server cache — a sequential scan over a corpus larger than an LRU cache continuously evicts the data just ahead of the read pointer, so scans stay cold even re-read across cells), in a **single pass per cell** (no `time_based` — a fast job would otherwise wrap onto its own just-read slice), with **per-cell offset rotation** so consecutive low-rate cells never start on each other's head bytes, in a **fixed de-ordered sequence** committed in the driver. The evidence cell is a **warm reference** (route 2, direction inverted because this grid's default regime is cold): 64 GiB of the corpus head read twice, whose second pass is deliberately server-cache-served — its split-window contrast is the measurement that the cache exists, serves at a distinguishable rate, and is therefore genuinely absent from the cold cells. The driver refuses without the staging marker and cross-checks staged sizes against the env parameters. |
| **Sweep driver** | `../scripts/sweep-stage1-seqr.sh` |
| **Aggregated output** | `s1.0b-seqr-summary-<leg>.csv` |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`), plus the cache state achieved. |

### 1.0c — Synthetic upper bound, random write IOPS

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 21/21 cells OK, canary PASS on all) · ⏳ Leg B |
| **Leg A results (peak over jobs per bs; `s1.0c-randw-summary-<leg>.csv`)** | 4k: **519k IOPS** (1.98 GiB/s, p99 1.9 ms) at jobs=64 · 16k: 347k IOPS (5.29 GiB/s) at jobs=32 · 64k: 147k IOPS (8.98 GiB/s) at jobs=64. *Caveat — a measured per-bs wire-relation shift, flagged for the writeup and the Leg-B comparison:* write wire/app measured **1.364 at 4k jobs=64** and **1.044 at 64k jobs=64**, versus ≈1.46 at 1M/4M — the client-wire EC amplification is block-size-dependent on this leg. All cells PASS the calibrated bands (the small-bs widening applied, named in each verdict); the per-bs relation itself is recorded as data. Candidate explanations (client-vs-backend EC fan-out path by write size; the documented high-op-rate counter under-report, this file's engineering notes) were **not** discriminated between — no mechanism claim. |
| **Tool** | `fio` |
| **Source → Target** | host RAM → filesystem |
| **Methodology** | 3 block sizes (4K, 16K, 64K) × 7 concurrency = **21 cells**. iodepth=8 (IOPS recipe), `--rw=randwrite`. Same runtime/ramp as 1.0a/b. |
| **Why this exists** | Sequential and random writes hit the metadata path differently. Stage 2 (cataloging) and Stage 6 (feature extraction) write many small files to distinct paths — closer to random than sequential. **This is also the first cell that probes the metadata architectures against each other:** Lustre concentrates metadata on MDTs with independently provisioned metadata IOPS, while WEKA distributes it — a structural difference that a bandwidth test cannot see. |
| **Sweep driver** | `../scripts/sweep-stage1-randw.sh` |
| **Aggregated output** | `s1.0c-randw-summary-<leg>.csv` |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`) — including the metadata-operation rates this pattern generates. |

### 1.0d — Synthetic upper bound, random read IOPS

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 22/22 cells OK, canary PASS on all) · ⏳ Leg B |
| **Leg A results (peak over jobs per bs; `s1.0d-randr-summary-<leg>.csv`)** | 4k: **625k IOPS** (2.39 GiB/s, p99 1.2 ms) at jobs=64 · 16k: 276k IOPS (4.22 GiB/s) at jobs=8 · 64k: 55k IOPS (3.36 GiB/s) at jobs=2. **D18 reps (fresh ledger-claimed reserve regions 21–24):** peak 628k/625k/627k (0.5% spread); knee (jobs=32) 607k/622k/618k (2.4%). *Caveats:* 16k/64k peaks land at LOW job counts — higher-jobs cells ran slower under the one-touch construction (smaller disjoint per-job slices); recorded as the curve shape, not explained. All cells cold by construction (one-touch regions, ledger-tracked); the warm reference re-read served at a distinguishably higher rate per its run dir. |
| **Tool** | `fio` |
| **Source → Target** | filesystem → host RAM |
| **Methodology** | Same grid as 1.0c (3 bs × 7 jobs = 21 cells), iodepth=8, `--rw=randread`, **plus one cold reference cell = 22**. As in 1.0b, reads run against a corpus **staged ahead of the timed window and left in place across cells**; the cache-discipline row below sets its sizing and the cell ordering. |
| **Why this exists** | **The defining access pattern for Stage 5 (training).** A multi-GPU PyTorch DataLoader does exactly this: random small-block reads at high concurrency across many large WSI files. This ceiling directly bounds Stage 5, and random-vs-sequential read differential at a given block size is a structural property of each filesystem rather than a tuning artifact. |
| **Cache discipline (D13)** | **Cold by construction** (**D13** route 1), on 1.0b's four requirements — sizing past **the larger of the two server-side caches** (FSx from its documented file-server cache per TiB at the provisioned tier and capacity, WEKA from the backends' aggregate RAM, both fetched at provisioning), a corpus **staged ahead of the timed window and not unlinked and recreated between cells**, **one cold reference cell** at a single (block size, concurrency) point as the evidence (**D13** route 2), and **reversed or randomised cell order** so warmth does not track concurrency. Cache state **recorded as achieved** per cell. **This is the most exposed cell in Stage 1:** a small-block random working set is the easiest thing for a large file-server cache to absorb entirely, so the sizing requirement does more work here than anywhere else — and it is also a denominator for Stage 5. |
| **How the driver implements it** (ratified 2026-08-15) | **One-touch regions, not a shared corpus** — the corpus-exceeds-cache rule is insufficient here: under steady-state LRU, uniform random reads over corpus C with server cache S are cache-served at ≈ S/C, and the two legs' caches differ, so a shared corpus produces **asymmetric hit rates** — the exact cache-size artifact D13 exists to prevent. Each cell reads its **own pre-staged region** (`STAGE1_RANDR_REGION_GIB` × `STAGE1_RANDR_REGIONS`), every block **at most once across the whole sweep** (fio's random map within per-job disjoint slices; cells stop at min(one-touch complete, 600 s), never `time_based`) — cold with **no cache-behavior assumptions**, identically on both legs. Staging-write warmth is flushed by the prep's eviction pass. **D18 repeats claim fresh reserve regions** through a ledger (`runs/.leg-state/$LEG/randr-region-claims`) — a repeat re-reading its first run's region would measure that run's cache. The evidence cell is a **warm reference** (route 2, inverted): a deliberate re-read of the last grid cell's just-touched region, the most cache-resident bytes available; its delta against the grid is what the construction rests on, and it doubles as the server-cache-served random-read rate. Fixed de-ordered cell order; refuses without the staging marker. |
| **Sweep driver** | `../scripts/sweep-stage1-randr.sh` |
| **Aggregated output** | `s1.0d-randr-summary-<leg>.csv` |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`), plus the cache state achieved. |

### 1.4 — Local NVMe scratch provisioning

| | |
|---|---|
| **Status** | ⏳ smoke-proof per instance build (the RAID itself is built by the instance bootstrap; not a comparison cell) |
| **Tool** | the instance bootstrap (`mdadm` + `mkfs.xfs` + fstab, unattended at boot); `fio` for the smoke proof |
| **Methodology** | Built by the bootstrap at every instance boot: the local NVMe devices (2 × 1900 GB on `g6e.24xlarge`) in RAID-0 → XFS → mounted at `/data/local-nvme` with `noatime,nofail`, owned by the benchmark user. Subdirs: `conda-envs/ fpsync-source/ staging/ runs/`. 1.4's own work is the recorded smoke `fio` that proves the source headroom. |
| **Why this exists** | Prerequisite for 1.5: a bulk-copy benchmark needs a **local source comfortably faster than the filesystem's write ceiling**, or the source becomes the bottleneck and the cell measures the wrong thing. A smoke `fio` confirms that headroom before 1.5 runs. |
| **⚠ Ephemeral** | Instance store **dies with the instance** and is re-provisioned on every rebuild — including between legs. Nothing that matters may rest here (`../CLAUDE.md` → Durability). It is scratch, not storage. |
| **Held-constant note** | Because the instance is identical in both legs, the local tier is identical too — so 1.5's source is not a cross-leg variable. Re-run the smoke `fio` per build and record it, to prove that. |
| **Recorded per build** | The smoke `fio` result that establishes the source headroom, recorded like any other cell. |

### 1.5 — Bulk local→filesystem copy sweep (`fpsync`)

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 4/4 cells OK + the recorded re-stage prep; canary PASS at the EC relation on every cell) · ⏳ Leg B |
| **Leg A results (`s1.5-fpsync-summary-weka.csv`; 1.1 TiB real corpus, 1,133 files, local NVMe → filesystem)** | n=1: **706 MiB/s** (26.1 min) → n=4: 2,382 → n=16: 2,397 → n=64: **2,402 MiB/s** (7.7 min) — the curve saturates at n=4 and stays flat to n=64, at **~44% of the 1M-block synthetic write ceiling**: with real slide files the per-file rsync/fpsync machinery (checksums, metadata, per-file streams over 1 GB-scale files) bounds the path well before the filesystem does, which is the real-files-vs-synthetic gap this substage exists to measure. Write wire/app 1.418–1.457 vs the calibrated 5+2 center 1.4 — canary PASS on every cell. *Data-validity note:* the first attempt's four cells ran without the driver's D-30 cache-regime declaration (renamed `-FAILED-undeclared-cache-regime`); the numbers here are the same-day full re-run under the fixed driver. |
| **Tool** | `fpsync` (version recorded at run time) |
| **Source → Target** | `/data/local-nvme/fpsync-source/tcga-brca/` → `$FS_MOUNT/data/fpsync-target/n<N>/` |
| **Methodology** | TCGA-BRCA full corpus staged to local NVMe first via its own recorded prep run. Sweep: **`fpsync -n N` ∈ {1, 4, 16, 64}**, full corpus per cell, each cell writing to its own per-N subdir (cleaned pre-cell). Per-cell isolation via `record-run.sh`. |
| **Why this exists** | The clean write-path benchmark on **real WSI files** with no WAN in the way — the closest analogue to the scanner-to-storage workflow labs actually run. Comparison against the synthetic 1.0a ceiling shows how much of each filesystem's write capability is reachable with real files and real metadata operations rather than a single scratch stream. The concurrency grid spans the saturation curve: `n=1` is single-stream-bound; `n=16/64` tests whether per-worker overhead caps below the storage ceiling. |
| **Why identical on both** | Same corpus (byte-verified from S3), same `-n` grid, same defaults, same target layout. Only `$FS_MOUNT` differs. |
| **Sweep driver** | `../scripts/sweep-stage1-fpsync.sh` · **Aggregator** `../scripts/aggregate-stage1-fpsync.py` |
| **Aggregated output** | `s1.5-fpsync-summary-<leg>.csv` |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`), plus files transferred and bytes moved. |

### 1.6 — Mixed concurrent ingest + read

| | |
|---|---|
| **Status** | ✅ Leg A (weka; 9/9 cells OK — 8 grid + the cold reference, prep cell recorded; write canary PASS on all 9 at the calibrated mixed widening, read direction REPORT_ONLY by declared construction) · ⏳ Leg B |
| **Leg A results (`s1.6-mixed-summary-weka.csv`; fixed ingest `fpsync -n 4` — the knee of this leg's own 1.5 curve — + swept fio randread, 660 s window per cell)** | **The full 1.05 TiB corpus landed inside the window in every cell** (the window-mean 1,667 MiB/s ±2 is corpus÷window — completion evidence, constant by construction). The ingest-*rate* signal is the fs-side active write sustained: **~2,400 MiB/s — its solo 1.5 rate — up through moderate read load**, degrading to 1,908 (4k jobs=64) and **1,716 MiB/s (−28%) only at the heaviest read cell** (64k jobs=64, readers pulling 6.2 GiB/s). Read side under full-rate ingest: 4k 143 → 1,610 MiB/s (36.6k → 412k IOPS) over jobs 1→64, p99 1.97 → 4.42 ms; 64k 1,373 → **7,258 MiB/s peak at jobs=16** (6,344 at jobs=64, where p99 hits 36.4 ms) — ~9.3 GiB/s combined through the one client at 64k jobs=16. **Both customer questions answer yes on this leg:** reader load does not throttle the scanner until the read side nears its own ceiling, and viewer-class reads (4k, low jobs) hold ~2 ms p99 under full-rate ingest. Cold-ref vs warm twin 1.00/1.00/0.99 (bw/mean/p99) — the D13 route-4 exemption is confirmed, the grid stays 9 cells. Read wire relation REPORT_ONLY on every cell (4.D-class read amplification under concurrent bulk write, no calibrated analogue): recorded 1.15–1.17 at 64k, 1.45–1.49 at 4k, **1.676 at the 4k jobs=1 cold-ref** — the amplification grows as read share shrinks, consistent with the 4.D finding class. *Data-validity note:* the first cold-ref attempt predates the driver's read-exemption declaration and FAILed its canary (renamed `-FAILED-canary-readamp-exempt-gap`); the poison marker it wrote correctly refused the 8 queued cells (stubs renamed `-FAILED-poison-gate-refusal`); all 9 cells here are from the clean re-launch after the declaration fix. |
| **Tool** | `fpsync` (concurrent ingest) + `fio` (concurrent read), driven by a per-cell wrapper inside `record-run.sh` |
| **Source → Target (write side)** | `/data/local-nvme/fpsync-source/tcga-brca/` → `$FS_MOUNT/data/fpsync-target/mixed/` (cleaned per cell) |
| **Source → Target (read side)** | `$FS_MOUNT/benchmarks/fio-scratch-mixed/` (pre-staged real files, verified non-sparse) → `/dev/null`, `fio` random reads, libaio `direct=1` |
| **Methodology** | **Fixed** ingest at a moderate `fpsync -n` chosen as a realistic "scanner pace" with headroom (the exact `-n` is set from each leg's own 1.5 curve, so both sides sit at a comparable *fraction* of their own write ceiling rather than an identical absolute rate). **Swept** read: `--rw=randread --iodepth=8`, `bs ∈ {4K, 64K} × jobs ∈ {1, 4, 16, 64}` = 8 cells, **plus one cold reference cell = 9**. Read scratch pre-staged **once** per leg so each cell exercises only the random-read pattern, and cell order reversed or randomised (cache-discipline row below). |
| **Why this exists** | **Operationally the most realistic Stage 1 cell.** Two customer questions at once: *while a scanner feeds at moderate pace, can pathologists pan/zoom existing slides at viewer-acceptable latency?* (→ read p99 at low `bs`/`jobs`) and *does heavy reader load throttle the scanner?* (→ `fpsync` app-level bandwidth across the read sweep). The "no second tier needed" pitch only holds if both sides survive concurrent stress — and whether the two filesystems degrade differently under mixed load is exactly the kind of QoS difference a bandwidth test cannot surface. |
| **Why the fixed side is a fraction, not an absolute** | Pinning both legs to the same absolute ingest MB/s would load them unequally if their write ceilings differ — the slower side would be nearer saturation and look worse for a reason that has nothing to do with mixed-workload behaviour. Holding the *fraction* constant isolates the QoS question. **Both the fraction and the resulting absolute rate are recorded per cell**, so either view can be reconstructed. |
| **Cache discipline (D13) — recorded exemption + a cold reference cell** | The read grid carries **no cold/warm dimension**, by decision, under **D13** route 4. *The technical ground:* `--direct=1` removes the client page cache from the question, and 1.6 is deliberately a **mixed steady-state** cell — production is warm, so a cold mixed cell would measure a state no lab operates in. What remains is server-side cache, which cannot be cleared on a managed service, so a nominal cold arm would differ from its warm twin only by an **uncontrolled** variable — double the read grid to separate nothing. *And because an exemption must be evidenced rather than asserted, it comes with **one cold reference cell** at a single grid point* (**D13** route 2), cold to the extent the mechanism reaches (`RUNBOOK.md` records what each clearing step clears): if it matches its warm twin the exemption is confirmed cheaply; if it does not, server-side cache is material here and the grid grows. That conditional is what makes the exemption defensible instead of convenient. The read set is the driver's `--size=4G` × jobs, so the **low-concurrency cells are the ones most likely cache-resident**, and cell order is reversed or randomised for the same reason as 1.0b/1.0d — warmth must never track the swept variable. Cache state is **recorded as achieved** per cell (`RUNBOOK.md`), never asserted. |
| **How the driver implements it** | A fixed, de-ordered cell sequence committed in the script (identical on both legs, never ascending in `jobs`), whose **first entry is the cold reference cell** at (4K, jobs=1) — the grid point most likely cache-resident, so the one where cache-service would show first. Cold = `vm.drop_caches=3` with the acknowledgment written into the run dir (`cache-evidence.txt`); the server side is not clearable from the client and the residual is recorded, not hidden. Each cell declares its regime via `RECORD_CACHE_STATE`; the aggregator keeps the cold-ref as a distinct row and renders a dedicated cold-vs-warm-twin comparison block — the exemption's evidence. Every cell is attempted; the driver exits non-zero if any failed. |
| **Sweep driver** | `../scripts/sweep-stage1-mixed.sh` · **Aggregator** `../scripts/aggregate-stage1-mixed.py` |
| **Aggregated output** | `s1.6-mixed-summary-<leg>.csv` |
| **Recorded per cell** | **Both sides separately** — read-side throughput and its latency distribution, write-side `fpsync` app-level bandwidth, and the ingest fraction and the absolute rate it resolved to — plus the full measurement set and the cost inputs (`RUNBOOK.md`). A cell that recorded only one side cannot answer either customer question. |

### 1.7 — S3 → filesystem hydration (the head-to-head ingest cell)

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 4/4 cells OK, canary PASS, **final pass byte-verified: TCGA 1133 files md5+size, CAM16 1365 files size; `hydration-complete` written**) · ⏳ Leg B |
| **Leg A results (full 1.79 TiB hydration per cell; fs-side write active-window mean)** | mcr=4: 5729 s (0.31 GiB/s) · **mcr=16: 3913 s (0.45 GiB/s)** · mcr=64: 5215 s (0.34 GiB/s) · mcr=256: 5433 s (0.33 GiB/s). *Caveat, load-bearing for cross-leg reading:* the cell is **S3-fetch-bound, not filesystem-bound** — the write rates sit far below the 1.0a write ceiling at every concurrency, and raising `max_concurrent_requests` past 16 made the `aws s3 sync` side slower, not the storage. Identical tool/flags/grid run on both legs, so the comparison holds; but this cell characterises the ingest *pipeline*, with the filesystem holding easy headroom on this leg. |
| **Tool** | `aws s3 sync` / `aws s3 cp` (version recorded at run time) |
| **Source → Target** | `s3://<bucket>/datasets/{tcga-brca,camelyon16}/` (same region) → `$FS_MOUNT/data/{tcga-brca,camelyon16}/` |
| **Methodology** | `max_concurrent_requests ∈ {4, 16, 64, 256}` = **4 cells**, each a **full hydration of both prefixes** with the target wiped before it — same-region S3 transfer is free, so the grid costs only wallclock and the write workload is the measurement. The **final cell's data is kept** and byte-verified: TCGA per-file md5 + count + size against the manifest; CAMELYON16 count + per-file size (its manifest carries multipart ETags, not md5s — the staging copy into our bucket was checksummed end-to-end by S3, and that basis is recorded in the verification report). A clean verify is what writes the `hydration-complete` marker; any mismatch blocks it and fails loud. **Identical tool, identical flags, identical concurrency grid on both filesystems.** |
| **Why this exists** | This is how the datasets actually get onto each filesystem, so it is a real workload we are running anyway — and it is a legitimate large-write ingest measurement from a **same-region, high-bandwidth source**, which removes the WAN bottleneck that would otherwise dominate. It also doubles as the mechanism that makes the datasets a held-constant input (byte-verified identical bytes in both legs). |
| **Why the same method on both — load-bearing** | FSx offers a native S3 data-repository import that has no WEKA counterpart. Using it for Lustre and a plain copy for WEKA would compare **two different mechanisms**, not two filesystems. So the head-to-head cell uses plain `aws s3` on both sides, and FSx's native import is measured separately as **1.8**. |
| **Sweep driver** | `../scripts/sweep-stage1-hydrate.sh` |
| **Aggregated output** | `s1.7-hydrate-summary-<leg>.csv` |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`), plus the byte-verification result against the dataset manifest — a partial hydration that is not caught here poisons every stage that reads the corpus. |

### 1.8 — FSx-native S3 import *(Lustre leg only — NOT head-to-head)*

| | |
|---|---|
| **Status** | ⏳ Lustre leg only |
| **Tool** | FSx for Lustre data-repository association / import |
| **Methodology** | Import the same S3 dataset prefixes via FSx's native linkage, recorded with the same harness as 1.7 so the two are directly comparable **within** the Lustre leg. |
| **Why this exists, and why it is excluded from the comparison** | It is a genuine Lustre capability with no WEKA equivalent, so reporting it as part of the head-to-head would be comparing a feature against its absence. But **omitting it entirely would understate Lustre**, which the fairness basis (**D7** — Lustre at maximum capability) forbids. So it is measured, labelled a **single-filesystem capability cell**, and presented as "what FSx can additionally do," never as a delta. |
| **Presentation rule** | Any chart or table containing 1.8 must visually separate it from head-to-head cells and state that no WEKA counterpart exists. |
| **Recorded per cell** | The full measurement set and the cost inputs (`RUNBOOK.md`). |

---

## Load-bearing engineering notes (carried into the scripts)

These are hard-won implementation details that cost real debugging time. They are recorded here because
losing them means rediscovering them.

**Aggregator must sum per-timestamp across client processes, not use a pre-aggregated mean.** A naive
aggregator that reads the parser's pre-aggregated filesystem-side metric can under-report by ~100×,
because that metric is a mean across **all** rows in the stats stream — including many idle server-side
rows that dilute the client's actual throughput. The correct pattern: **re-read the raw stats CSV, filter
to the client's own rows, sum across the client's processes per timestamp, then aggregate the per-second
sums.** Filter by a stable identity — **role** (`Mode=="client"`; this cluster runs exactly one client
container by design) — never a hostname or a numeric process/node ID, both reassigned on rebuild or reinstall.

> **Per-filesystem caveat:** the *pattern* generalises to both legs, but the *filter* does not — the WEKA
> and Lustre stats streams have different schemas and different notions of "the client's rows." Each
> leg's adapter implements the same pattern against its own source, and **the filter is written against
> the live stream on the provisioned instance, never from documentation.** Neither way of getting it
> wrong raises an error: too broad a filter dilutes the number as above, and one that matches nothing
> drops the filesystem-side metric altogether — `aggregate-stage1-fpsync.py` returns `None` for the cell,
> the summary prints a dash, and the ratio check **skips** that cell rather than failing it, so a sweep
> that lost its filesystem-side source still reports every band clean.

**Mixed-workload canary bands must be wider than single-direction bands, and re-derived per filesystem.**
In a mixed read+write cell the wire counters carry more than the payload under test — read data plus write
acknowledgements in one direction, read requests plus (on WEKA) EC-amplified write data in the other. At
small block sizes the non-payload contribution is a meaningful fraction, so single-direction ratios do not
transfer. Client-side counters can also under-report against the app at extreme concurrency (internal
coalescing / counter-update lag) — that is a known measurement artifact, not a recording failure.
**Implication:** the aggregators need separate canary bands for isolated vs mixed phases, and the bands
must be derived from each filesystem's own architecture (**D12**), not copied across.

**Never use `pkill -f` to stop a backgrounded workload in a cell wrapper.** A `-f` pattern matches the
wrapper shell and the recording wrapper too (their argv contain the literal pattern string), so the signal
kills the whole chain — producing duplicate `INDEX.md` entries and a spurious `INCOMPLETE` on a cell whose
data is actually fine. **Use `setsid` plus a process-group kill (`kill -- -PGID`).** If an
`INCOMPLETE`-with-valid-data pattern ever reappears, look for a newly introduced self-matching `pkill -f`.

---

## Tool inventory used in Stage 1

| Tool | Version | Source | Used in |
|---|---|---|---|
| `fio` | record at run time | system package | 1.0a–d, 1.4 smoke, 1.6 |
| `fpsync` / `fpart` | record at run time | system package | 1.5, 1.6 |
| `aws` CLI | record at run time | system | 1.7, and the one-time dataset staging into S3 |
| `mdadm`, `mkfs.xfs` | system | system | 1.4 |
| `record-run.sh` | live | `../scripts/record-run.sh` | every substage |
| `parse-results.py` | live | `../scripts/parse-results.py` | every substage |
| `aggregate-sweep.py` | live | `../scripts/aggregate-sweep.py` | 1.0a–d |
| `weka stats realtime` | record at run time | system | every substage (WEKA leg recording) |
| `lctl`, `lfs` | record at run time | Lustre client | every substage (Lustre leg recording) |

## Datasets used in Stage 1

| Dataset | Source | Size | License | Used in |
|---|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | GDC Data Portal → staged once into our S3 bucket | ~1.05 TiB (1133 slides) | Open access | 1.5, 1.6, 1.7 |
| CAMELYON16 | `s3://camelyon-dataset` (`us-west-2`, CC0) → staged once into our S3 bucket | ~710 GiB (1197 `.tif`) | CC0 | 1.7 |

Both are **held-constant inputs**, byte-verified identical in both legs (`STAGES.md` **D6**).

## Decision register (Stage 1-scoped)

One entry per live Stage 1 decision. Cross-stage decisions live in `STAGES.md`.

- **Dataset staging is a one-time pre-leg step into S3, not a per-leg comparison cell.** *Why:* a WAN
  download measures an external service and a network link, not a filesystem; running it per-leg would
  spend hours producing a number about neither side, and risks putting different bytes on the two
  filesystems. Staging once makes the datasets a byte-verified held-constant input.
- **The head-to-head ingest cell is S3 → filesystem hydration (1.7), using the same tool and flags on both
  sides.** *Why:* it is a real workload we run anyway, it removes the WAN bottleneck via a same-region
  source, and using the identical mechanism on both sides is what makes it a filesystem comparison rather
  than a mechanism comparison.
- **FSx-native S3 import is measured but excluded from the head-to-head (1.8).** *Why:* including it would
  compare a feature against its absence; omitting it would understate Lustre, which **D7** forbids.
  Measured, labelled a single-filesystem capability cell, never presented as a delta.
- **1.6's ingest side is pinned to a *fraction* of each leg's own write ceiling, not to an absolute rate.**
  *Why:* an identical absolute rate would load the two sides unequally if their ceilings differ,
  confounding the QoS question with a saturation difference. Both the fraction and the absolute rate are
  recorded so either view is reconstructible.
- **SMB ingest is out of scope on both filesystems.** *Why:* see the protocol-scope caveat — the
  infrastructure is out of scope, and the two SMB paths would not be architecturally comparable (WEKA has
  a native SMB stack; Lustre would need a gateway), so it would introduce an asymmetry we could not hold
  constant.
- **The synthetic cells (1.0a–d) run before the real-data cells.** *Why:* real-data numbers need an
  isolated-storage anchor or they are uninterpretable, and every downstream "% of ceiling" divides by a
  **block-size-matched** 1.0 cell.
- **1.7's sweep is N full passes with the target wiped before each cell, and the final pass's corpus is the
  one kept and verified.** *Why each cell is a full pass:* same-region S3 transfer is free and resumable, so
  repeating the full hydration per concurrency point costs only wallclock while keeping every cell's unit of
  work identical — a per-cell slice of the corpus would put different files (and a different size mix) under
  each concurrency point. *Why wipe-before rather than wipe-after:* the last cell then doubles as the leg's
  real hydration, and a failed byte-verify blocks the completion marker so a partial corpus cannot be
  consumed downstream. *Verification basis:* TCGA md5-per-file (the GDC manifest carries md5s); CAMELYON16
  count + size, because its manifest carries multipart ETags — the S3→S3 staging copy was checksummed by S3
  itself, and the report states that basis rather than implying an md5 check that never ran.
- **The `fio` recipe is grounded in each vendor's current performance-testing guidance at run time**
  (libaio + `--direct=1`; sequential grid at iodepth=1; IOPS grid at iodepth=8). *Why:* recipes and
  recommended flags change between versions, and `../CLAUDE.md` forbids quoting them from memory —
  re-confirm against the live docs before the first cell.
- **The synthetic read ceilings are cold BY CONSTRUCTION, via two different mechanisms because sequential
  and random access defeat a cache differently (ratified 2026-08-15).** *Why cold at all:* both filesystems
  carry substantial cache and cache differently, so an unlabelled read number is ambiguous and the ambiguity
  is asymmetric — and these are the cells every downstream "% of ceiling" divides by, so a cache-inflated
  ceiling makes every percentage in the project wrong in the flattering direction, invisibly. **1.0b
  (sequential): a shared scan corpus ≥ ~2× the larger server-side cache** — a sequential scan over a corpus
  larger than an LRU cache continuously evicts the data just ahead of the read pointer, so scans stay cold
  even when the corpus is re-read across cells; single pass per cell (never `time_based`, which would wrap a
  job onto its own just-read slice) plus per-cell offset rotation. **1.0d (random): per-cell disjoint
  ONE-TOUCH regions** — the corpus-exceeds-cache rule fails for random access, where steady-state LRU serves
  ≈ cache/corpus of uniform reads and the two legs' unequal caches make that hit rate *asymmetric*; reading
  every block at most once across the whole sweep needs no cache-behavior assumption at all. **Data written
  immediately before it is read is server-cache-resident whatever the client does** — hence both corpora are
  staged ahead by `prep-stage1-read-corpora.sh`, whose closing eviction pass flushes the staging writes'
  tail. Cell order is fixed and de-ordered; **D18 repeats consume fresh reserve regions via a ledger**, since
  a repeat re-reading its first run's region measures that run's cache. Sizes are env parameters derived
  from the fetched cache figures at provisioning (`STAGE1_SEQ_CORPUS_GIB`, `STAGE1_RANDR_REGION_GIB`,
  `STAGE1_RANDR_REGIONS`) — one identical definition serving both legs, never driver literals.
- **The frozen Stage-1.0 corpus sizes (ratified against the confirmed 1536 GiB backend RAM):
  `STAGE1_SEQ_CORPUS_GIB=3072`, `STAGE1_RANDR_REGION_GIB=256`, `STAGE1_RANDR_REGIONS=26`.** *Why these
  values:* the seq scan corpus is 2.0× the larger of the two server-side caches (WEKA's 8 × 192 GiB
  = 1536 GiB > FSx's ~721 GiB at PERSISTENT-1000 × 26.4 TiB, both fetched at provisioning), per the
  ≥ ~2× rule above; the region pool is the 21 grid cells plus 5 reserve regions for the D18 knee/peak
  repeats. One identical definition serves both legs (**D13**), so the values are carried in the
  environment contract (`stage1_*`, MUST_MATCH) — a value that lived only in the gitignored env.sh died
  with the last rebuild.
- **A reference cell is the standard evidence device wherever cache discipline rests on construction or on
  an exemption — and its direction follows the grid's default regime.** 1.6's grid is warm-by-exemption, so
  its reference is **cold**; 1.0b/1.0d's grids are cold-by-construction, so their references are **warm** — a
  deliberate re-read of just-touched bytes, showing the server cache exists and serves at a distinguishable
  rate, which is what makes "the cold cells were genuinely cold" a measurement rather than an argument. *Why
  one cell suffices:* it converts the construction from argument to measurement at a fraction of a full
  cold/warm dimension's cost — and it fails usefully: a warm reference that does NOT beat its cold twin says
  the server cache is not serving this pattern at a distinguishable rate, which changes how every cold label
  is read.
- **1.6's read side takes a recorded exemption from the cold/warm dimension, on stated grounds, evidenced by
  its cold reference cell.** *Why:* `--direct=1` removes the client page cache from the question, and 1.6 is
  deliberately a **mixed steady-state** cell — production is warm, so a cold mixed cell would measure a state
  no lab operates in. What remains is server-side cache, which cannot be cleared on a managed service, so a
  nominal cold arm would differ from its warm twin only by an uncontrolled variable: double the read grid to
  separate nothing. The exemption is **D13** route 4, which is permitted only alongside the reference cell,
  and cell order is de-ordered here too so warmth does not track `jobs`.

## Cross-references

- `../PROJECT-THESIS.md` — the question, the held-constant contract, both deliberate asymmetries
- `../CLAUDE.md` — project rules: recording, durability, how we work
- `STAGES.md` — stage map, per-leg plan, cross-stage decision register
- `RUNBOOK.md` — how to run and record a cell, both canaries, failure recovery
- `SCRIPT-TRACKER.md` — per-script reference for `scripts/`, including the deferred-work table
- `FILESYSTEM-MAP.md` — where the mounts, S3 prefixes, datasets, and scratch live
- `../runs/INDEX.md` — append-only run history (auto-generated)
- Each run dir's `0_README.md` — auto-generated description of that specific run
