# Stage 7 — Clinical inference deployment, measured identically on both filesystems

> **STATUS — read first.** Nothing has run. Every number below is **`[PENDING]`** and every interpretation
> section is **`[STORY PENDING RESULTS]`**.
>
> **Every cell runs on both filesystems** — WEKA (Leg A) then FSx for Lustre (Leg B) — with everything else
> held constant. The delta is the result.
>
> Stage 7 is the deployment-shaped stage: it measures **latency and concurrency behaviour**, not aggregate
> throughput, because that is what a clinical deployment's SLA is written against.

For project-wide conventions see `../CLAUDE.md`; framing and the fairness contract `../PROJECT-THESIS.md`;
stage map and decision log **D1–D15** `STAGES.md`; runbook `README.md`.

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
| **Per-slide inference *latency*** (not throughput) — "clinician clicks analyse → result in T seconds" | Every prior number is aggregate throughput. Single-slide cold and warm latency with a phase breakdown is the deployment-decisive figure | 7.1 |
| **Latency degradation under concurrent inference** | 1 → many concurrent jobs. How does per-slide p99 hold? This is the SLA number | 7.2 |
| **Heatmap output write workload** | Per-slide mid-size pyramidal writes — between the small feature writes of 6.A and the bulk writes of 4.D, and unmeasured elsewhere | 7.3 |
| **Streaming loop + read-after-write visibility** | End-to-end "scanner → inference → heatmap → viewer" latency, plus how quickly a just-written file is visible to another reader | 7.4 |
| **Clinical mixed workload + endurance** | Inference + heatmap writes + viewer reads + ingest, all at once, sustained — the QoS question | 7.5 |
| **Cross-dataset validation** | CAMELYON16 at concurrency, mirroring 6.A's cross-vendor check at the inference layer | 7.6 |

**Read-after-write and mixed-workload QoS are especially interesting as a comparison**, because they probe
consistency and fairness semantics rather than bandwidth — and two filesystems with different metadata and
locking architectures have no reason to behave identically there. Whether they do is `[STORY PENDING
RESULTS]`.

---

## ⚠️ Scope caveat — read before presenting Stage 7 numbers

**Stage 7 measures clinical inference over POSIX on both filesystems.** Object, SMB, and DICOMweb access
are handled by separate stacks and are **not measured here** on either side.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All cells are ⏳ on both legs.

### 7.1 — Per-slide inference latency baselines

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | The customer-quotable single-slide latency, with a per-phase breakdown (tissue detection / feature extract / MIL / heatmap write), split cold vs warm, on both data-path backends |
| **Tool** | `lib/inference-per-slide-stage7.py` — chains tissue detection, the 6.A extractor in eval mode, the MIL aggregator in eval mode, and the heatmap writer. Reuses the reader classes from `extract-features-foundation-stage6.py` and the attention module from `train-mil-stage6b.py`. Emits `slide_id, t_tissue_ms, t_extract_ms, t_mil_ms, t_heatmap_write_ms, t_total_ms` |
| **Backends** | cuCIM CPU batched, and kvikIO/cuFile + raw-TIFF |
| **Source → Target** | `$FS_MOUNT` raw-TIFF (kvikIO) or canonical SVS (cuCIM) → GPU → frozen foundation-model forward → attention weights → heatmap written to `$FS_MOUNT/heatmaps/7.1/<model>-<backend>-<cache>/<slide_id>.tiff` |
| **Methodology** | 50 slides sequentially per cell, single GPU, single process, no concurrency. **Cold cells discard the page cache before each slide; warm cells allow it to carry over** — and the cache-clearing mechanism is per-filesystem and only partly under our control on managed storage, so what was actually achieved is **recorded per cell rather than asserted** (**D13**, open item 5). Per-phase timing via monotonic clock plus CUDA events for GPU phases |
| **Cell count** | **6 cells per leg** — cuCIM/Virchow2 cold, cuCIM/Virchow2 warm, kvikIO/Virchow2 cold, kvikIO/Virchow2 warm, cuCIM/GigaPath warm, cuCIM/UNI2-h warm `[PENDING-APPROVAL]` |
| **Why this exists** | Deployment decisions are made on "T seconds per slide", not "X slides/sec aggregate" — a different metric from 6.A's throughput. The cold/warm split surfaces the production reality that first-inference on a new slide costs more than re-inference, and that gap is a storage-visible quantity |
| **Why one model carries most cells** | Virchow2 is the lightest of the three and carries no licence restriction, so per-cell wallclock is shortest and results externalise cleanly. The other two get a warm-cache cell each — enough to confirm the path works across models without multiplying wallclock. UNI2-h cells stay internal-only per the `uni2h-conditional-use-status` memory |
| **Headline results** | `[PENDING]` — per-cell p50/p95/p99/mean per-slide latency, per-phase decomposition, filesystem-side read rate and **% of the block-size-matched ceiling** |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 7.2 — Latency under concurrent inference load

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | The SLA number: how per-slide p99 holds as concurrency rises |
| **Tool** | The same per-slide worker, orchestrated as N parallel processes by `lib/orchestrate-clinical-deployment-stage7.sh` |
| **Methodology** | 30-minute sustained cell per concurrency level. Each process consumes a **disjoint** slide chunk from the full-cohort manifest, so no process idles and none duplicates work. Per-process latency CSVs merged for the cell's percentiles. Backend: kvikIO + raw-TIFF; model Virchow2; warm cache (production-realistic — a clinical deployment processes many slides per shift). **Per-process inference batch size declines as N rises** to keep per-GPU memory bounded; the exact schedule is **re-derived for the instance's GPU memory** rather than carried over as a constant |
| **Cell count** | **4 cells per leg**: N ∈ {1, 4, 16, 64} |
| **Why these N values** | 1 re-baselines against 7.1; 4 models a lab floor; 16 a busy clinical service; 64 a deliberate saturation stress that oversubscribes the GPUs. **At the high end the cell measures storage and queueing behaviour, not GPU throughput** — framed that way rather than presented as a throughput result |
| **Why per-slide latency stays the metric even as batch size changes** | A clinical SLA is written against wallclock per slide, not throughput per process. Varying batch size to fit memory does not change what the customer cares about, and holding batch size fixed would simply OOM at high N |
| **Headline results** | `[PENDING]` — per-slide p50/p95/p99/mean per N, filesystem-side read rate and % of the matched ceiling, GPU utilisation and peak memory, cross-source canary |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 7.3 — Heatmap output write characterisation

| | |
|---|---|
| **Status** | ⏳ both legs — **hard dependency on 6.A full-cohort features** |
| **Goal** | Characterise the write workload from per-slide heatmap generation, across three formats spanning the realistic production range |
| **Tool** | Heatmap writer (a mode of the per-slide script) using `tifffile` for pyramidal TIFF and `Pillow` for PNG. Heatmap content is **real attention weights** from the MIL forward, rendered with production-fidelity interpolation |
| **Source → Target** | Coords + pre-extracted features + MIL attention → heatmap pixels → `$FS_MOUNT/heatmaps/7.3/<format>/<slide_id>.{tiff,png}` |
| **Methodology** | 50 slides per cell from the full-cohort manifest. Per slide: load coords and the **pre-extracted 6.A features** (this is the hard dependency — 7.3 cannot run until 6.A's full-cohort extraction has landed on that leg), run the MIL forward for attention, write the heatmap. Per-slide write latency plus the filesystem-side write time series captured. Cold-cache discipline per slide |
| **Cell count** | **3 cells per leg**: pyramidal TIFF at reduced resolution · pyramidal TIFF at full resolution · PNG overlay |
| **Why three formats** | They span roughly an order of magnitude in output size, from a fast inline web overlay to a publication-quality full-resolution pyramid. A customer picks one based on their viewer, so characterising the range is more useful than picking one — and the size spread is what makes the write workload interesting rather than trivially small |
| **Why real attention weights rather than synthetic** | The forward pass is already running for the latency measurement, so real weights cost nothing extra and produce the actual output a production system writes |
| **⚠ Expect an application-side bound** | Pyramidal TIFF writing is tile-by-tile with interpolation, so the wallclock may be dominated by the writer rather than by storage. That is a legitimate finding about the workload — but it must be **stated as such**, with the filesystem-side write rate reported alongside, so a slow cell is not misread as a storage result on either side |
| **Headline results** | `[PENDING]` — per-cell mean/max/total bytes, per-slide write latency mean and p99, filesystem-side write rate and **% of the matched write ceiling** |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 7.4 — Streaming clinical loop + read-after-write visibility

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | (a) End-to-end "arrival → clinician-visible" latency per slide in a streaming scenario. (b) How quickly a just-written heatmap becomes readable by another process |
| **Tool** | (a) The orchestrator with ingest + inference workloads and a synthetic-scanner mode emitting one slide per interval, with per-slide event tracking. (b) `lib/read-after-write-stage7.py` — spawns a writer (inference + heatmap write) and a reader that polls for visibility then reads the first chunk |
| **Methodology (7.4.a)** | One slide per fixed interval for a 10-slide cell, single GPU, kvikIO, warm cache. Per-slide event timestamps: arrival, inference start, inference done, heatmap written, viewer received. Captures end-to-end latency **and** any cross-slide queueing if inference falls behind the emitter |
| **Methodology (7.4.b)** | 20 slides sequentially; the reader polls at a fixed short interval for visibility, then reads. **The writer must write to a temporary name, fsync, then rename** — without that, the file exists at zero length the moment it is opened and the reader's existence check fires at creation time, producing meaningless (even negative) latencies. Getting this wrong yields a plausible-looking number that measures nothing |
| **Cell count** | **2 cells per leg** |
| **Why this exists** | The streaming loop is the bookend customer story — the whole workflow, not isolated components. Read-after-write visibility is a **consistency** property rather than a bandwidth one, and the two filesystems have different metadata architectures, so there is no reason to assume they behave the same. It is also the property that underwrites any "no second tier needed" claim, and it deserves a hard number rather than an assumption |
| **⚠ Single-client scope** | Writer and reader are **processes on the same client**, so this measures intra-client visibility and the fsync-then-rename ordering contract. **True cross-client consistency would need a second client instance**, which is outside this single-client study — stated as a scope limit, not glossed. If a cross-client number becomes important, it needs a second instance and a decision about whether that breaks the held-constant contract |
| **Headline results** | `[PENDING]` — (a) end-to-end mean and p99 per slide, plus queueing time; (b) visibility-latency distribution and first-read latency |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

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
| **Why this cell matters disproportionately** | Concurrent heterogeneous load on one namespace is precisely where storage architectures diverge, and it is not something a bandwidth benchmark can surface. 6.C covers the training-shaped mix; this covers the clinical-shaped one. Together they are the QoS evidence |
| **Headline results** | `[PENDING]` — per-workload throughput and latency, retention vs solo, filesystem-side read and write rates, wire counters, application-available-core CPU, GPU utilisation, cross-source canary |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 7.6 — Cross-dataset inference validation (CAMELYON16)

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Goal** | Cross-vendor format consistency at the inference layer, mirroring 6.A's check |
| **Tool** | The same per-slide worker; CAMELYON16 subset manifest |
| **Methodology** | One cell at moderate concurrency, Virchow2, kvikIO, warm cache — directly comparable to the matching 7.2 cell on BRCA. CAMELYON16 uses its native-20× read path per the coord contract; both datasets yield uniform 256 px @ 20× tiles |
| **Cell count** | **1 cell per leg** |
| **Why this exists** | Cross-vendor consistency has been checked on the storage path in earlier stages; confirming it at the inference layer completes the claim that the pipeline is format-agnostic. **Any ratio between datasets is driven largely by their tile-count distributions**, so it should be similar on both filesystems — which makes it a useful *sanity check* on the comparison itself, not just a result |
| **Headline results** | `[PENDING]` — per-slide latency percentiles, filesystem-side read rate, GPU utilisation, and the CAMELYON16/BRCA ratio against the matching 7.2 cell |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

---

## Recording approach (Stage 7-specific)

Over-capture by default. Standard `record-run.sh` with **per-filesystem source adapters** (**D12**), plus
Stage-7-specific streams. **Every "% of ceiling" divides by the block-size-matched Stage 1.0 cell for that
leg.**

### New primary sources

| Source | File | Sub-tier | Captures |
|---|---|---|---|
| Per-slide per-phase latency | `per-slide-inference-latencies.csv` | 7.1, 7.2, 7.4, 7.5, 7.6 | Per-slide phase split, backend, model, cache state |
| Per-slide heatmap write | `per-slide-heatmap-writes.csv` | 7.3, 7.4, 7.5 | Bytes, write start/end, write ms |
| Streaming-loop events | `streaming-loop-events.csv` | 7.4.a | Arrival → inference → written → viewer-received |
| Read-after-write visibility | `read-after-write-latencies.csv` | 7.4.b | Write-complete, first-visible, first-read-complete, latency |
| Per-workload telemetry | `workload-<name>.csv` | 7.5 | Per-workload per-second timeline |

### Promoted to primary for Stage 7

- **`nvidia-smi`** — inference holds substantial GPU memory, and high-concurrency cells exercise memory
  pressure directly.
- **Filesystem-side read, write, and operation counters** — Stage 7 has a **real write workload** (heatmaps)
  concurrent with reads, unlike most earlier stages.
- **Wire counters for the path in use** — per **D12**, WEKA and Lustre differ here; the canaries below are
  stated in terms of whichever is the data path on that leg.
- **`sar -u` over application-available cores** (**D15**) — host-CPU pressure from many inference processes
  is a real interference channel in 7.2 and 7.5.

### Cross-source canaries — derived per filesystem

- **7.1 / 7.2:** wire counters track filesystem-side reads at that filesystem's derived read relation on
  **cold** cells; on warm cells the filesystem-side read mean is small and ratios are noise-dominated —
  **say so rather than widening the band silently.**
- **7.3:** filesystem-side write bytes × duration reconciles with total heatmap bytes; the wire-vs-write
  ratio follows that filesystem's own write amplification (**derived, not ported** — the two differ).
- **7.4.a:** streaming-loop event timestamps align with filesystem-side activity per slide.
- **7.4.b:** visibility latency is bounded and stable; an unbounded or erratic distribution is a finding,
  not noise.
- **7.5:** per-workload throughput sums to the filesystem-side aggregate within a stated tolerance;
  per-workload retention within a stated band.

**Any canary failure beyond its stated tolerance stops the sub-tier** — investigate before continuing. On an
unattended chain this abort is mechanical.

---

## Tool inventory (Stage 7 scripts)

| Tool | Path | Sub-tiers | Reuses |
|---|---|---|---|
| `inference-per-slide-stage7.py` | `lib/` | 7.1, 7.2, 7.4, 7.5, 7.6 | 6.A reader classes; 6.B.3 attention module; `tifffile` / `Pillow` writers; per-cell `LD_PRELOAD` scoping; orchestrator load barrier |
| `orchestrate-clinical-deployment-stage7.sh` | `lib/` | 7.2, 7.4, 7.5 | 6.C orchestrator patterns (deadline kill, `setsid` process groups); GPU pinning; wait-for-loaded barrier |
| `sweep-stage7-clinical.sh` | `lib/` | all 7.x | `record-run.sh` pre-computed run-dir pattern |
| `aggregate-stage7-clinical.py` | `lib/` | all 7.x | Wide-format wire-counter parsing; per-timestamp client-summing pattern (per-filesystem filter) |
| `read-after-write-stage7.py` | `lib/` | 7.4.b | fsync-then-rename write contract |

**All five need the per-filesystem recording adapter work** (open item 11) and mount retargeting to
`$FS_MOUNT` (open item 13) before they run.

## Datasets

| Dataset | Source | Used in |
|---|---|---|
| TCGA-BRCA canonical SVS | hydrated per leg (1.7) | 7.1–7.5 (cuCIM cells) |
| TCGA-BRCA **20× raw-TIFF** | produced by 4.D per leg | 7.1, 7.2, 7.4, 7.5 (kvikIO cells) |
| **20× CLAM coords** | produced by 3.0 per leg | all 7.x |
| **6.A features (full cohort)** | produced by 6.A per leg | **7.3 — hard dependency** |
| CAMELYON16 **20× raw-TIFF** | produced by 4.D per leg | 7.6 |
| Subset + full-cohort manifests | `manifests/` | 7.1/7.6 subsets; 7.2/7.3/7.5 full cohort |
| **Heatmap outputs (new)** | `$FS_MOUNT/heatmaps/7.x/…` | 7.1, 7.3, 7.4, 7.5 |
| **Ingest target (new, transient)** | `$FS_MOUNT/runs-stage7-ingest-target/` | 7.5 |

**Confirm free space on each filesystem before the full-resolution heatmap cell** — it is the largest
single write in the stage.

## Risks / known unknowns

- **Per-slide latency is likely dominated by GPU compute and heatmap rendering rather than storage.** That
  is a property of the workload, and it means Stage 7 primarily characterises the compute-and-render
  pipeline with storage as a component. **Report the filesystem's share of wallclock explicitly per cell**
  so nobody reads a slow cell as a storage result on either side.
- **The pyramidal-writer path may bound 7.3** rather than the filesystem — see the warning in 7.3.
- **Read-after-write visibility depends on each filesystem's metadata and caching design.** No expectation
  is recorded; the point is to measure it. The single-client scope limit is stated in 7.4.
- **High-concurrency cells oversubscribe the GPUs**, so they measure storage and queueing behaviour rather
  than GPU throughput. Frame accordingly.
- **Batch-size schedules and GPU-pinning maps are instance-specific** and must be re-derived, not carried
  over as constants.
- **The heavier of the two datasets will show longer per-slide latency purely from tile-count
  distribution.** Since that is filesystem-independent, it doubles as a sanity check that both legs
  processed equivalent work.

## Decision log (Stage 7-scoped)

- **2026-07-31 — Scope collapsed to six measurement gaps; viewer reads fold into the mixed cell.** *Why:*
  the conventional inference/viewer split would re-measure what Stages 3, 6.A, 6.B.3, 1.6, 6.C and 6.D
  already cover. Measuring only the genuine gaps keeps the stage informative and the wallclock defensible.
- **2026-07-31 — Roll a lightweight orchestrator rather than adopting a deployment framework.** *Why:* this
  is a storage comparison; a deployment framework adds packaging and scheduling engineering that competes
  with measurement time and inserts its own behaviour between us and the storage path.
- **2026-07-31 — MIL aggregator runs untrained in eval mode.** *Why:* we measure inference *latency*; the
  forward computation cost is identical regardless of training state. Training a usable checkpoint would add
  engineering that does not change any storage number. Stated explicitly so no accuracy claim is inferred.
- **2026-07-31 — Virchow2 carries most cells; the other two models get warm-cache cells.** *Why:* lightest
  model → shortest wallclock, and no licence restriction → clean externalisation. Cross-model coverage
  confirms the path generalises without multiplying cells. UNI2-h stays internal-only.
- **2026-07-31 — Three heatmap formats spanning ~an order of magnitude in size.** *Why:* format choice is a
  real customer variable and the size spread is what makes the write workload non-trivial; characterising
  the range beats picking one arbitrarily.
- **2026-07-31 — Real attention weights, not synthetic.** *Why:* zero marginal cost (the forward already
  runs) and it produces the artifact a production system actually writes.
- **2026-07-31 — Concurrency axis N ∈ {1, 4, 16, 64}, with per-process batch size declining as N rises.**
  *Why:* the four levels span re-baseline → lab floor → busy service → deliberate saturation. Batch size must
  fall or high-N cells OOM, and per-slide wallclock — the SLA metric — is unaffected by that choice. Schedule
  re-derived for the instance's GPU memory.
- **2026-07-31 — Concurrent jobs consume disjoint slide chunks.** *Why:* mirrors production (each clinician
  runs their own slide) and prevents both idle processes and duplicated work from distorting the percentiles.
- **2026-07-31 — Read-after-write writer uses write-to-temp, fsync, rename.** *Why:* without it the reader's
  existence check fires when the file is created at zero length, producing a plausible-looking number that
  measures nothing. A correctness requirement, not a style preference.
- **2026-07-31 — 7.5 retention is measured against a same-filesystem solo baseline.** *Why:* the question is
  how much each filesystem degrades its own workloads under contention. Cross-comparing absolute numbers
  would conflate contention behaviour with raw speed; the **retention percentages** are the cross-leg
  comparison.
- **2026-07-31 — Cold/warm cache state is recorded as achieved, not asserted.** *Why:* per **D13** the
  clearing mechanism differs per filesystem and is only partly under our control on managed storage, so
  claiming "cold" without evidence would be unsupported.
- **2026-07-31 — Recording: every metric that makes sense, over-capture by default.** *Why:* Stage 7 is the
  closing chapter of the customer story, and under-recording here would silently weaken a claim we cannot
  cheaply re-run.

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage 7 roadmap created for the WEKA-vs-Lustre comparison. Retained: the six-gap scope and its redundancy rationale, all sub-tier designs, the roll-our-own tooling choice, untrained-MIL-in-eval-mode, model allocation, three heatmap formats, real attention weights, the concurrency axis with declining batch size, disjoint slide chunks, and the fsync-then-rename write contract. **Added:** per-leg framing; read-after-write and mixed-workload QoS highlighted as consistency/fairness probes rather than bandwidth ones; per-filesystem recording adapters and per-filesystem canary derivation; the **same-filesystem solo baseline** rule for retention; **D13** record-as-achieved cache discipline; **D15** core accounting; the application-side-bound warning on 7.3; explicit single-client scope limit on 7.4.b. **Removed:** all inherited results, outcome buckets, "% of ceiling" figures against a prior ceiling, and every magnitude expectation. |

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, decision log (esp. **D12** adapters, **D13** cache, **D15** cores)
- `Stage-6-Feature-Extraction.md` — supplies the features 7.3 depends on, the reader classes, and the MIL module
- `Stage-4-Patching.md` — supplies both data paths and the raw-TIFF artifact
- `Stage-1-Ingest.md` — the block-size-matched ceilings every "% of ceiling" divides by; the viewer read pattern reused in 7.5
- `../SCRIPT-TRACKER.md` — per-script reference and deferred cloud-session TODOs
- `README.md` — operational runbook and both canaries
