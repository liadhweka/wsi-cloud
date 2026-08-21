# Stage 7 — Clinical inference deployment, measured identically on both filesystems

> **Every substage runs twice — WEKA (Leg A) then FSx for Lustre (Leg B) — with everything else held
> constant. The delta is the result, and a single leg is half an unfinished comparison.**
>
> Stage 7 is the deployment-shaped stage: it measures **latency and concurrency behaviour** rather than
> aggregate throughput, because a clinical deployment's SLA is written against latency.

For project-wide conventions see `../CLAUDE.md`; framing and the fairness contract `../PROJECT-THESIS.md`;
stage map and the decision register `STAGES.md`; how to run and record a cell `RUNBOOK.md`.

---

## Why this stage exists in this shape

A conventional pipeline scaffold splits "inference" and "viewer" into separate stages. Most of what those
would measure is already covered: foundation-model forward throughput in **6.A**, MIL prediction in
**6.B.3**, tissue detection in **Stage 3**, viewer-style small random reads in **1.6** and **6.C**,
end-to-end wallclock in **6.D**. Running them as written would be largely redundant.

**So Stage 7 is scoped to the six things genuinely not covered elsewhere**, and viewer reads fold into the
mixed-workload cell rather than standing alone:

| Gap | Why it matters | Sub-tier |
|---|---|---|
| **Per-slide inference *latency*** (not throughput) — "clinician clicks analyse → result in T seconds" | Every prior number is aggregate throughput, while deployment decisions are made on seconds per slide — so single-slide cold and warm latency with a phase breakdown is what this measures | 7.1 |
| **Latency degradation under concurrent inference** | 1 → many concurrent jobs. How does per-slide p99 hold? This is the SLA number | 7.2 |
| **Heatmap output write workload** | Per-slide mid-size pyramidal writes — between the small feature writes of 6.A and the bulk writes of 4.D, and unmeasured elsewhere | 7.3 |
| **Streaming loop + read-after-write visibility** | End-to-end "scanner → inference → heatmap → viewer" latency, plus how quickly a just-written file is visible to another reader | 7.4 |
| **Clinical mixed workload + endurance** | Inference + heatmap writes + viewer reads + ingest, all at once, sustained — the QoS question | 7.5 |
| **Cross-dataset validation** | CAMELYON16 at concurrency, mirroring 6.A's cross-vendor check at the inference layer | 7.6 |

**Read-after-write and mixed-workload QoS probe consistency and fairness semantics rather than bandwidth.**
Two filesystems with different metadata and locking architectures have no reason to behave identically
there, which is exactly why both are measured rather than assumed.

---

## ⚠️ Scope caveat — read before presenting Stage 7 numbers

**Stage 7 measures clinical inference over POSIX on both filesystems.** Object, SMB, and DICOMweb access
are handled by separate stacks and are **not measured here** on either side.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete.

### 7.1 — Per-slide inference latency baselines

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | The customer-quotable single-slide latency, with a per-phase breakdown (tissue detection / feature extract / MIL / heatmap write), split cold vs warm, on both data-path backends |
| **Tool** | `../scripts/inference-per-slide-stage7.py` — chains tissue detection, foundation-model feature extraction, the MIL forward, and the heatmap write, timing each phase separately |
| **Backends** | cuCIM CPU batched, and kvikIO/cuFile + raw-TIFF |
| **Source → Target** | `$FS_MOUNT` raw-TIFF (kvikIO) or canonical SVS (cuCIM) → GPU → frozen foundation-model forward → attention weights → heatmap written to `$FS_MOUNT/heatmaps/7.1/<model>-<backend>-<cache>/<slide_id>.tiff` |
| **Methodology** | 50 slides sequentially per cell, single GPU, single process, no concurrency. **Cold cells discard the page cache before each slide; warm cells allow it to carry over** — and the cache-clearing mechanism is per-filesystem and only partly under our control on managed storage, so what was actually achieved is **recorded per cell rather than asserted** (**D13**; the open-items memory carries the per-filesystem cache-clearing item). Per-phase timing via monotonic clock plus CUDA events for GPU phases |
| **Cell count** | **6 cells per leg** — cuCIM/Virchow2 cold, cuCIM/Virchow2 warm, kvikIO/Virchow2 cold, kvikIO/Virchow2 warm, cuCIM/GigaPath warm, cuCIM/UNI2-h warm `[PENDING-APPROVAL]` |
| **Why this exists** | Deployment decisions are made on "T seconds per slide", not "X slides/sec aggregate" — a different measurement from 6.A's throughput. The cold/warm split separates first-inference on a newly arrived slide from re-inference on one already read; that gap is storage-visible, and both regimes occur in production |
| **Why one model carries most cells** | Virchow2 is the lightest of the three and carries no licence restriction, so per-cell wallclock is shortest and results externalise cleanly. The other two get a warm-cache cell each — enough to confirm the path works across models without multiplying wallclock. UNI2-h cells stay internal-only per the `uni2h-conditional-use-status` memory |
| **Recorded per cell** | Per-cell p50/p95/p99/mean per-slide latency, per-phase decomposition, filesystem-side read rate and **% of the block-size-matched ceiling** — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

### 7.2 — Latency under concurrent inference load

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | The SLA number: how per-slide p99 holds as concurrency rises |
| **Tool** | The same per-slide worker, orchestrated as N parallel processes by `../scripts/orchestrate-clinical-deployment-stage7.sh` |
| **Methodology** | 30-minute sustained cell per concurrency level. Each process consumes a **disjoint** slide chunk from the full-cohort manifest, so no process idles and none duplicates work. Per-process latency CSVs merged for the cell's percentiles. Backend: kvikIO + raw-TIFF; model Virchow2; warm cache (production-realistic — a clinical deployment processes many slides per shift). **Per-process inference batch size declines as N rises** to keep per-GPU memory bounded; the exact schedule is **re-derived for the instance's GPU memory** rather than carried over as a constant |
| **Cell count** | **4 cells per leg**: N ∈ {1, 4, 16, 64} |
| **Input dependency (ratified 2026-08-15)** | The full-cohort raw-TIFF this grid reads **exists at rest: 4.D converts and retains all 1064 slides** (Stage-4 register). The N=64 cell's disjoint chunks are what forced the decision — 64 processes need ≥64 slides. |
| **Why these N values** | 1 re-baselines against 7.1; 4 models a lab floor; 16 a busy clinical service; 64 a deliberate saturation stress that oversubscribes the GPUs. **At the high end the cell measures storage and queueing behaviour, not GPU throughput** — framed that way rather than presented as a throughput result |
| **Why per-slide latency stays the metric even as batch size changes** | A clinical SLA is written against wallclock per slide, not throughput per process. Varying batch size to fit memory does not change what the customer cares about, and holding batch size fixed would simply OOM at high N |
| **Recorded per cell** | Per-slide p50/p95/p99/mean per N, filesystem-side read rate and % of the matched ceiling, GPU utilisation and peak memory, cross-source canary — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

### 7.3 — Heatmap output write characterisation

| | |
|---|---|
| **Status** | ⏳ both legs — **hard dependency on 6.A full-cohort features** |
| **Goal** | Characterise the write workload from per-slide heatmap generation, across three formats spanning the realistic production range |
| **Tool** | The heatmap-writing mode of `../scripts/inference-per-slide-stage7.py` — pyramidal TIFF via `tifffile`, PNG via `Pillow`. Heatmap content is **real attention weights** from the MIL forward, rendered with production-fidelity interpolation |
| **Source → Target** | Coords + pre-extracted features + MIL attention → heatmap pixels → `$FS_MOUNT/heatmaps/7.3/<format>/<slide_id>.{tiff,png}` |
| **Methodology** | 50 slides per cell from the full-cohort manifest. Per slide: load coords and the **pre-extracted 6.A features** (this is the hard dependency — 7.3 cannot run until 6.A's full-cohort extraction has landed on that leg), run the MIL forward for attention, write the heatmap. Per-slide write latency plus the filesystem-side write time series captured. Cold-cache discipline per slide |
| **Cell count** | **3 cells per leg**: pyramidal TIFF at reduced resolution · pyramidal TIFF at full resolution · PNG overlay |
| **Why three formats** | They span roughly an order of magnitude in output size, from a fast inline web overlay to a publication-quality full-resolution pyramid. A customer picks one based on their viewer, so characterising the range is more useful than picking one — and the size spread is what makes the write workload interesting rather than trivially small |
| **Why real attention weights rather than synthetic** | The forward pass is already running for the latency measurement, so real weights cost nothing extra and produce the actual output a production system writes |
| **⚠ Writer-bound versus storage-bound** | Pyramidal TIFF writing is tile-by-tile with interpolation, so a cell's wallclock can be set by the writer rather than by storage. **Report the filesystem-side write rate alongside the wallclock**, so a slow cell is not misread as a storage result on either side |
| **Recorded per cell** | Per-cell mean/max/total bytes, per-slide write latency mean and p99, filesystem-side write rate and **% of the matched write ceiling** — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

### 7.4 — Streaming clinical loop + read-after-write visibility

| | |
|---|---|
| **Status** | ⏳ both legs — **7.4.b depends on a measured 7.3 output from the same leg** |
| **Goal** | (a) End-to-end "arrival → clinician-visible" latency per slide in a streaming scenario. (b) How quickly a just-written heatmap becomes readable by another process |
| **Tool** | (a) `../scripts/streaming-loop-stage7.sh` — a synthetic scanner emitting one slide per fixed interval into the inference loop, with per-slide event tracking. (b) `../scripts/read-after-write-stage7.py` — a writer emitting a TIFF **sized and tiled from a measured 7.3 output on the same leg, with synthetic content** (not a model forward, so the visibility latency is not diluted by a per-slide inference chain) and a reader that polls for visibility then reads the first chunk |
| **Methodology (7.4.a)** | One slide per fixed interval for a 10-slide cell, single GPU, kvikIO, warm cache. Per-slide event timestamps: arrival, inference start, inference done, heatmap written, viewer received. Captures end-to-end latency **and** any cross-slide queueing if inference falls behind the emitter |
| **Methodology (7.4.b)** | 20 slides sequentially; the reader polls at a fixed short interval for visibility, then reads. **The artifact is sized and tiled from a measured 7.3 output on the same leg** — file size and tile geometry taken from that cell's recorded writes — **with the content synthetic**; both the matched values and the 7.3 cell they came from are recorded with the cell, so the exception is evidenced rather than asserted. *Why the pixel values cannot affect what is measured:* read-after-write visibility depends on the file's size, its tile structure, and the fsync-then-rename ordering contract — not on what the pixels contain. **The writer must write to a temporary name, fsync, then rename** — without that, the file exists at zero length the moment it is opened and the reader's existence check fires at creation time, producing meaningless (even negative) latencies. Getting this wrong yields a plausible-looking number that measures nothing. The reader's first read is **warm by construction** — it reads bytes written milliseconds earlier — so it is labelled cache-served and never quoted as a storage read (**D13**) |
| **⚠ Standing constraint — the driver does not yet write a matched artifact** | `read-after-write-stage7.py` derives its file size from a target byte count and a hardcoded compression assumption rather than from a measured 7.3 output, and its poll interval quantises the visibility latency it reports. **Do not run 7.4.b as-is:** an unmatched artifact leaves the register's synthetic-writer exception unevidenced and puts an unrelated file size inside the number. The open-items memory carries both the writer's sizing work and the 7.3-lands-first ordering. **Its per-slide unlink stays** — the reader's measurement *is* the non-existent → visible transition, so D13's do-not-recreate-between-cells mechanic must not be swept across this cell |
| **Cell count** | **2 cells per leg** |
| **Why this exists** | The streaming loop is the bookend customer story — the whole workflow, not isolated components. Read-after-write visibility is a **consistency** property rather than a bandwidth one, and the two filesystems have different metadata architectures, so there is no reason to assume they behave the same. It is also the property that underwrites any "no second tier needed" claim, and it deserves a hard number rather than an assumption |
| **⚠ Single-client scope** | Writer and reader are **processes on the same client**, so this measures intra-client visibility and the fsync-then-rename ordering contract. **True cross-client consistency would need a second client instance**, which is outside this single-client study — stated as a scope limit, not glossed. If a cross-client number becomes important, it needs a second instance and a decision about whether that breaks the held-constant contract |
| **Recorded per cell** | (a) End-to-end mean and p99 per slide, plus queueing time; (b) visibility-latency distribution, first-read latency, and **the artifact's size and tile geometry alongside the 7.3 cell they were matched to** — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

### 7.5 — Clinical mixed workload + endurance

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | Concurrent ingest + inference + heatmap writes + heatmap viewing + slide viewing, all on one filesystem, then sustained for hours |
| **Tool** | The orchestrator with all four workload types and a lab-floor inference concurrency |
| **Workload mix** | **ingest** — bulk copy from local scratch into the filesystem (the 1.5 pattern; data-bounded, so it finishes and goes quiet). **inference** — several concurrent jobs, each on a disjoint slide slice. **heatmap-viewer** — small-block random reads of heatmaps *just written by the inference workload* (the production reality: a clinician opens a heatmap right after it lands). **slide-viewer** — small-block random reads of original slides (the 1.6 viewer pattern) |
| **Methodology** | A 30-minute mixed cell plus a multi-hour endurance cell. Per-workload telemetry CSVs; retention per workload measured against that workload's own solo baseline **on the same filesystem** |
| **Cell count** | **2 cells per leg** |
| **Why retention is measured against a same-filesystem solo baseline** | The question is *"how much does this filesystem degrade its own workloads under contention"* — a fairness/QoS property. Comparing one filesystem's mixed number against the other's solo number would conflate contention behaviour with raw speed. The **retention percentages are what compare across legs**, and the absolute numbers are reported alongside |
| **Why this exists** | Concurrent heterogeneous load on one namespace is not something a bandwidth benchmark can surface, and it is the clinical-shaped mix — 6.C covers the training-shaped one. Together they are the QoS evidence |
| **Recorded per cell** | Per-workload throughput and latency, retention vs solo, filesystem-side read and write rates, wire counters, application-available-core CPU, GPU utilisation, cross-source canary — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

### 7.6 — Cross-dataset inference validation (CAMELYON16)

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | Cross-vendor format consistency at the inference layer, mirroring 6.A's check |
| **Tool** | The same per-slide worker; CAMELYON16 subset manifest |
| **Methodology** | One cell at moderate concurrency, Virchow2, kvikIO, warm cache — directly comparable to the matching 7.2 cell on BRCA. CAMELYON16 uses its native-20× read path per the coord contract; both datasets yield uniform 256 px @ 20× tiles |
| **Cell count** | **1 cell per leg** |
| **Why this exists** | Cross-vendor consistency has been checked on the storage path in earlier stages; confirming it at the inference layer completes the claim that the pipeline is format-agnostic. **Any ratio between datasets is driven largely by their tile-count distributions**, which are filesystem-independent — so the ratio is also a sanity check on the comparison itself, not just a result |
| **Recorded per cell** | Per-slide latency percentiles, filesystem-side read rate, GPU utilisation, and the CAMELYON16/BRCA ratio against the matching 7.2 cell — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

---

## Recording approach (Stage 7-specific)

Over-capture by default; every cell runs through `record-run.sh` with the **per-filesystem source adapters**
(**D12**). **`RUNBOOK.md` holds the base source table, the per-filesystem Primary/Diagnostic split that
inverts between legs, both canaries, and the full per-cell measurement set including the cost inputs** — this
section records Stage 7's changes to it, and where its standing rules bite. **Every "% of ceiling" divides by
the block-size-matched Stage 1.0 cell for that leg.**

### Streams this stage adds

| Source | File | Sub-tier | Captures |
|---|---|---|---|
| Per-slide per-phase latency | `per-slide-inference-latencies.csv` | 7.1, 7.2, 7.4, 7.5, 7.6 | Per-slide phase split, backend, model, cache state |
| Per-slide heatmap write | `per-slide-heatmap-writes.csv` | 7.3, 7.4, 7.5 | Bytes, write start/end, write ms |
| Streaming-loop events | `streaming-loop-events.csv` | 7.4.a | Arrival → inference → written → viewer-received |
| Read-after-write visibility | `read-after-write-latencies.csv` | 7.4.b | Write-complete, first-visible, first-read-complete, latency |
| Per-workload telemetry | `workload-<name>.csv` | 7.5 | Per-workload per-second timeline |

### Changes to the base source table

- **Filesystem-side write and operation counters → primary.** Stage 7 carries a **real write workload**
  (heatmaps) alongside its reads, so the write path is part of the behaviour under test rather than context;
  leaving it diagnostic would leave half the cell unmeasured.
- **`sar -u` over application-available cores → primary** (**D15**). Host-CPU pressure from many concurrent
  inference processes is a real interference channel in 7.2 and 7.5, and the reserved-core set differs
  between the two clients, so the reading must be taken over the cores the application actually has.

**Where the base table's standing kvikIO rule bites:** 7.1, 7.2, 7.4, 7.5 and 7.6 all carry a kvikIO
backend, so each of those cells is incomplete without cuFile's own GPU-direct-vs-bounced accounting
(**D8**) — a configuration flag is not proof of which path a read took.

### Cross-source canaries — the stage-specific checks

The general canary rules are in `RUNBOOK.md`. Stage 7 adds:

- **7.1 / 7.2:** on **cold** cells, wire counters track filesystem-side reads at that filesystem's derived
  read relation. On **warm** cells the filesystem-side read mean is small enough that the ratio is
  noise-dominated — a sampling limit, not a consistency failure, and recorded as such.
- **7.3:** total heatmap bytes written reconcile with the filesystem-side write time series, and the
  wire-vs-write ratio follows that filesystem's own write amplification — **derived per filesystem, never
  ported across** (**D12**), because the two differ.
- **7.4.a:** streaming-loop event timestamps align with filesystem-side activity per slide.
- **7.4.b:** visibility latency is bounded and stable; an unbounded or erratic distribution is a finding,
  not noise.
- **7.5:** per-workload throughput sums to the filesystem-side aggregate within a stated tolerance, and each
  workload's retention sits within a stated band.

---

## Tool inventory (Stage 7 scripts)

| Tool | Path | Sub-tiers |
|---|---|---|
| `inference-per-slide-stage7.py` | `../scripts/` | 7.1, 7.2, 7.3, 7.4.a, 7.5, 7.6 |
| `orchestrate-clinical-deployment-stage7.sh` | `../scripts/` | 7.2, 7.5 |
| `streaming-loop-stage7.sh` | `../scripts/` | 7.4.a |
| `read-after-write-stage7.py` | `../scripts/` | 7.4.b |
| `sweep-stage7-clinical.sh` | `../scripts/` | all 7.x |
| `aggregate-stage7-clinical.py` | `../scripts/` | all 7.x |

**These tools need the per-filesystem recording adapter work (`D-4`) before they run** — see the deferred
table in `SCRIPT-TRACKER.md`, which is the reference for what each script does and takes.

## Datasets

| Dataset | Source | Used in |
|---|---|---|
| TCGA-BRCA canonical SVS | hydrated per leg (1.7) | 7.1–7.5 (cuCIM cells) |
| TCGA-BRCA **20× raw-TIFF** | produced by 4.D per leg | 7.1, 7.2, 7.4, 7.5 (kvikIO cells) |
| **20× CLAM coords** | produced by 3.0 per leg | all 7.x |
| **6.A features (full cohort)** | produced by 6.A per leg | **7.3 — hard dependency** |
| **7.3 measured heatmap profile** (size + tile geometry) | produced by 7.3 per leg | **7.4.b — the artifact it matches** |
| CAMELYON16 **20× raw-TIFF** | produced by 4.D per leg | 7.6 |
| Subset + full-cohort manifests | `../scripts/manifests/` | 7.1/7.6 subsets; 7.2/7.3/7.5 full cohort |
| **Heatmap outputs (new)** | `$FS_MOUNT/heatmaps/7.x/…` | 7.1, 7.3, 7.4, 7.5 |
| **Ingest target (new, transient)** | `$FS_MOUNT/runs-stage7-ingest-target/` | 7.5 |

**Confirm free space on each filesystem before the full-resolution heatmap cell** — it is the largest
single write in the stage.

## Risks / known unknowns

- **Per-slide latency is a composite of storage, GPU compute and heatmap rendering.** **Report the
  filesystem's share of wallclock explicitly per cell**, so no cell is read as a storage result on either
  side without the evidence for it.
- **The pyramidal writer can bound 7.3 rather than the filesystem** — see the warning in 7.3.
- **Read-after-write visibility depends on each filesystem's metadata and caching design.** No expectation
  is recorded; the point is to measure it. The single-client scope limit is stated in 7.4.
- **High-concurrency cells oversubscribe the GPUs by construction**, so they measure storage and queueing
  behaviour rather than GPU throughput. Frame accordingly.
- **Batch-size schedules and GPU-pinning maps are instance-specific** and must be re-derived, not carried
  over as constants.
- **Any CAMELYON16-versus-BRCA difference is driven largely by tile-count distribution**, which is
  filesystem-independent — so the ratio doubles as a check that both legs processed equivalent work.

## Decision register (Stage 7-scoped)

- **Stage 7 is scoped to the six measurement gaps not covered elsewhere; viewer reads fold into the mixed
  cell.** *Why:* the conventional inference/viewer split would re-measure what Stages 3, 6.A, 6.B.3, 1.6,
  6.C and 6.D already cover. Measuring only the genuine gaps keeps the stage informative and the wallclock
  defensible.
- **Roll a lightweight orchestrator; do not adopt a deployment framework.** *Why:* this is a storage
  comparison, and a framework adds packaging and scheduling engineering that competes with measurement time
  while inserting its own behaviour between us and the storage path.
- **The MIL aggregator runs untrained, in eval mode.** *Why:* we measure inference *latency*, and the forward
  computation cost is identical regardless of training state. Training a usable checkpoint would add
  engineering that changes no storage number. Stated explicitly so no accuracy claim is inferred.
- **Virchow2 carries most cells; the other two models get one warm-cache cell each.** *Why:* it is the
  lightest model, so per-cell wallclock is shortest, and it carries no licence restriction, so results
  externalise cleanly. Cross-model coverage confirms the path generalises without multiplying cells. UNI2-h
  cells stay internal-only per the `uni2h-conditional-use-status` memory.
- **Three heatmap formats spanning roughly an order of magnitude in size.** *Why:* format choice is a real
  customer variable, and the size spread is what makes the write workload non-trivial; characterising the
  range beats picking one arbitrarily.
- **Heatmaps carry real attention weights wherever the inference chain is already running** — 7.1, 7.3, 7.5,
  and 7.4.a's streaming loop, which runs the same chain. *Why:* zero marginal cost — the forward is already
  running — and it produces the artifact a production system actually writes.
- **7.4.b is the exception: its writer stays synthetic, matched to a measured 7.3 output.** *Why:* that writer
  exists only to make a file appear for another process to watch, so running the real chain there would add
  per-iteration inference latency inside the very measurement it would contaminate. **Size and tile geometry
  are taken from a measured 7.3 output on the same leg and recorded with the cell**, because read-after-write
  visibility depends on the file's size, its tile structure and the fsync-then-rename ordering — not on pixel
  values. Matching those three is what makes the exception harmless; recording the match is what makes it
  evidenced rather than asserted.
- **Concurrency axis N ∈ {1, 4, 16, 64}, with per-process batch size declining as N rises.** *Why:* the four
  levels span re-baseline → lab floor → busy service → deliberate saturation. Batch size must fall or the
  high-N cells OOM, and per-slide wallclock — the SLA metric — is unaffected by that choice. The schedule is
  re-derived for the instance's GPU memory rather than carried as a constant.
- **Concurrent jobs consume disjoint slide chunks.** *Why:* it mirrors production (each clinician runs their
  own slide) and prevents both idle processes and duplicated work from distorting the percentiles.
- **The read-after-write writer writes to a temporary name, fsyncs, then renames.** *Why:* without it the
  reader's existence check fires when the file is created at zero length, producing a plausible-looking
  number that measures nothing. A correctness requirement, not a style preference.
- **7.4.b's reader polls at 1 ms, and the poll interval is recorded as the visibility-latency resolution
  floor.** *Why 1 ms:* on the build machine, measured visibility latencies fell **below** the earlier 10 ms
  interval, so at 10 ms the cell sampled poll phase rather than visibility. Any latency at or under the
  recorded floor is still reported as quantisation, not measurement, and the cell's `sar` over
  application-available cores shows what the tighter poll itself costs — so the trade this interval makes is
  visible in the record rather than asserted.
- **7.5's mixed multi-workload cells declare `RECORD_CACHE_STATE=na-mixed-concurrent-clinical`.** *Why:* the
  cold/warm axis deliberately does not apply — the measured quantity is per-workload QoS retention against
  same-filesystem solo baselines, not a cache-regime-dependent storage rate (the same construction as 6.C's
  declaration, so the two mixed stages read identically).
- **7.5 retention is measured against a same-filesystem solo baseline.** *Why:* the question is how much
  each filesystem degrades its own workloads under contention. Cross-comparing absolute numbers would
  conflate contention behaviour with raw speed; the **retention percentages** are the cross-leg comparison.

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, decision register (esp. **D12** adapters, **D13** cache, **D15** cores)
- `RUNBOOK.md` — how to run and record a cell, the source table, both canaries
- `Stage-6-Feature-Extraction.md` — supplies the features 7.3 depends on, the reader classes, and the MIL module
- `Stage-4-Patching.md` — supplies both data paths and the raw-TIFF artifact
- `Stage-1-Ingest.md` — the block-size-matched ceilings every "% of ceiling" divides by; the viewer read pattern reused in 7.5
- `SCRIPT-TRACKER.md` — per-script reference and the deferred-work table
