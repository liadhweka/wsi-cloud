# Stage 5 — Training data pipeline, measured identically on both filesystems

> **Every cell runs on both filesystems** — WEKA (Leg A) then FSx for Lustre (Leg B) — with everything else
> held constant. The delta is the result, and **a single leg is half an unfinished comparison.**
>
> Stage 5 builds directly on Stage 4's two production data paths, so **Stage 4's closeout is load-bearing
> here**: 4.C supplies the kvikIO path's characterisation, 4.B the cuCIM-CPU path's, and Stage 1.0 supplies
> the block-size-matched ceilings every "% of ceiling" divides by.

For project-wide conventions see `../CLAUDE.md`; what we measure and why `../PROJECT-THESIS.md`; the stage
map and the decision register `STAGES.md`; how to run and record a cell `RUNBOOK.md`.

---

## What Stage 5 measures

The **training data pipeline** — where a GPU-bound training job actually consumes tiles from storage at
production rates. The structural pattern:

```
WSI on storage → reader opens → DataLoader workers → random tile sampling across many slides
  → batch assembled → model forward + backward + optimizer step → loop
```

Stage 4 measures what each filesystem can **deliver**. Stage 5 measures whether a real training loop can
**consume** it, and how that holds up as GPU count rises. The two questions are genuinely different: a step
cannot begin until its whole batch has arrived and, under DDP, cannot finish until every rank's has — so a
filesystem can supply tiles at a high aggregate rate and still stall a multi-GPU job. That is why this stage
records the per-step latency **distribution** and not only the rate.

The customer pain point it is modelled on: legacy NAS deployments running CNN DDP training on WSI data
plateau at a handful of GPUs of useful scaling because DataLoader workers stall waiting for storage. Stage 5
puts that pattern under measurement on each filesystem — a real training loop, real storage, and the
per-step evidence needed to say where any scaling loss actually lives.

**Concurrency comes from `num_workers` and rank count, not batch size.** That is the axis that varies
storage pressure, and it is the one swept.

---

## ⚠️ Scope caveat — read before presenting Stage 5 numbers

**Stage 5 measures real PyTorch DDP training on POSIX**, fed by either the kvikIO/cuFile raw-TIFF path or
the cuCIM CPU-batched SVS path. Object access is out of scope on both sides.

**Single-client study.** Both filesystems scale aggregate throughput with client count; Stage 5 measures
**one client**. Any aggregate extrapolation must say so explicitly.

---

## What Stage 5 deliberately does NOT cover

Bounded on purpose, with the reasoning recorded so a future session can see it was a choice rather than an
omission:

- **One model architecture (ResNet-50), not a model sweep.** ResNet-50 is the **storage-stressing** choice:
  small model, fast steps, high demand per unit of compute — so the storage path is where it can bind.
  Larger transformer-class models are compute-dominant, which gives the storage path slack and *reduces*
  the discrimination between two filesystems. Foundation-model-class compute is covered in Stage 6.
- **One dataset (TCGA-BRCA).** Cross-vendor consistency on the storage path is established in Stage 4
  (and re-checked in 6.A / 7.6). Adding CAMELYON16 here would double cell count without changing what the
  scaling curve says.
- **No convergence training.** We measure throughput, not accuracy. The optimiser runs against a synthetic
  label derived from tile position — enough to make the backward pass real, with no expectation of
  meaningful loss reduction. Stated plainly so nobody reads the loss curve as a result.
- **No mixed-precision sweep.** AMP is on (standard production setting); it is not an axis we vary.
- **No backend ablation beyond the two Stage 4 production paths.**

---

## Attribution discipline (Stage 5-specific, non-negotiable)

Scaling curves invite narrative explanations. **A scaling falloff must be attributed to a measured cause,
not a plausible story.** Concretely:

1. **Locate any efficiency loss in the per-phase split before naming it.** The per-step CSV carries
   dataload / forward / backward / optimiser separately. If efficiency drops with rank count, the loss must
   be visible in a specific phase.
2. **Distinguish storage stall from collective overhead.** A loss that lives in NCCL collective time is a
   DDP-communication effect and says nothing about the filesystem; a loss that lives in dataload latency
   (p95/p99, not the mean) is a storage-path effect. Capture both so the distinction is decidable.
3. **Distinguish latency from bandwidth.** A dataload phase can grow while bandwidth is nowhere near any
   ceiling — that is queueing, not saturation, and the two have completely different customer
   implications. Only call something a bandwidth limit if the bandwidth number supports it.
4. **Do not carry an attribution across filesystems.** The same efficiency drop can have different causes
   on the two sides, and asserting a shared cause would be exactly the kind of unmeasured narrative this
   rule exists to prevent.

*Why this is written down:* it is the single easiest place in the project to produce a confident,
plausible, wrong conclusion — and a wrong attribution here would propagate into the customer story for
both filesystems.

---

## Strategy framing

Two blocks, head to head, on each filesystem:

- **5.A — kvikIO/cuFile + raw-TIFF + ResNet-50 DDP**, sweeping GPU count. The GPU-direct data path.
- **5.B — cuCIM CPU batched + ResNet-50 DDP**, same sweep. The path most existing pipelines run today.

**5.B is a full sweep, not a single comparator cell.** *Why:* the interesting question is not just "which
backend is faster" but **whether the ranking changes with rank count** — and a ranking cannot be traced
across scale from a single point. Since the same question is then asked on a second filesystem, the full
curve is what makes the cross-leg comparison meaningful.

**GPU count sweep: N follows the instance's GPU count** — N ∈ {1, 2, 4} on `g6e.24xlarge` (**D10**, which
also carries the pre-committed trigger for revisiting the instance). **NUMA-aware GPU assignment**, with
the topology map re-derived on the real instance rather than assumed — a **D10** consequence, tracked as
deferred item `D-8` against this stage's sweep driver.

### cuFile mode scoping for 5.A — a deliberate reduction

Stage 4.C runs the full cuFile-mode × filesystem grid (**D8**), which characterises the GDS-vs-compat delta
thoroughly at the read level. Repeating that full grid across every rank count here would multiply Stage 5's
cell count for information Stage 4 already provides.

**So Stage 5.A runs each filesystem in its best available cuFile mode** (GDS where achievable, compat
otherwise), **plus one mode-controlled paired cell at a single rank count** on any filesystem where both
modes are available. *Why:* the best-mode cells answer Stage 5's actual question (does training consume
what storage supplies, at scale), while the paired cell provides the link back to 4.C so a reader can tell
whether a cross-leg training difference tracks the read-level mode difference or is something new. The
reduction is recorded here so it is visible as a scoping choice, not an oversight.

**Sequencing per leg:** verify provisioning + capture ceilings (Phase 0) → pre-flight smoke (single GPU,
short, proves the trainer works end to end) → 5.A ascending N → 5.B ascending N → attribution pass →
closeout.

---

## Recording approach (Stage 5-specific)

The per-cell measurement set, the cost inputs, the operational source table and both canaries are in
[`RUNBOOK.md`](RUNBOOK.md); the primaries **invert between legs** (`../PROJECT-THESIS.md` §7, **D12**).
Only Stage 5's **changes** to that base are recorded here.

**Added — per-training-step CSV, Primary.** The trainer emits one row per step to
`<run-dir>/training-steps.csv`: `step_idx, t_step_start, t_step_end, step_duration_ms, t_dataload_ms,
t_forward_ms, t_backward_ms, t_optimizer_ms, samples, loss`. *Why primary:* everything this stage measures
derives from it — samples/sec, GPU stall time (step duration minus the compute phases), and the **dataload
latency distribution (p50/p95/p99)** the attribution discipline runs on. A mean dataload time cannot
separate queueing from saturation; the distribution can.

**Added — NCCL collective times.** Not a storage number and never quoted as one, but **load-bearing for
attribution**: an efficiency loss that lives in collectives is a DDP-communication effect, and without this
stream it is indistinguishable from a storage stall.

**`nvidia-smi`** is already Primary from Stage 4 onward; under training load it carries the fed-vs-stalled
reading that the attribution discipline arbitrates against the per-phase split.

**`sar -u` over application-available cores is Primary on both blocks** (**D15**), with the excluded core
set differing per leg. *Why on the kvikIO block too, not only the CPU backend:* on the cuCIM path the
decode CPU is what supplies the GPU, so its saturation curve over application-available cores is part of
what 5.B measures; on the kvikIO path CPU is not on the data path, so the same reading measures what that
path costs in CPU — a figure comparable across legs only over application-available cores, which is what
**D15** exists to make possible.

**cuFile path accounting is Primary on every 5.A cell** (**D8**). A 5.A cell without recorded
GPU-direct-vs-bounced bytes is incomplete: the cuFile mode a cell was configured with does not prove which
path its reads actually took.

**Filesystem-reported operation counters are within-leg only.** App-level metrics are comparable across legs
by construction; operation counts are not, because the two filesystems count operations under their own
semantics — so treat them as within-leg until the counter semantics are verified equivalent and that
verification is recorded. They matter most early in a cell, when few slide handles are cached and
open/close traffic is higher.

### Cross-source consistency canary — Stage 5 specifics

The general rules are in `RUNBOOK.md`. What is particular to this stage:

- **The app-side reconstruction is samples/sec × per-tile bytes**, reconciled against filesystem-side read
  bytes with an allowance for cache warming and decode buffering — **the allowance is stated per cell, not
  applied silently.**
- **A cell is long enough for its own working set to warm** (5 min ramp + 20 min steady state), which **can**
  depress the filesystem-side read mean later in the cell and inflate the ratio. Record cache state as
  achieved (**D13**) and state the allowance — never make a ratio pass by moving a band.
- **N=1 is the no-DDP-overhead reference** for GPU utilisation; the behaviour at higher N is what the sweep
  exists to capture. **Collective time rising with rank count is expected and is not a storage finding.**

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. Every substage runs once per filesystem.

### 5.A — kvikIO/cuFile + raw-TIFF + ResNet-50 DDP scaling

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 3/3 cells + smoke OK; canary PASS; cache `warm` reconciled CONSISTENT) · ⏳ Leg B |
| **Leg A results (`s5.A-training-summary.csv`)** | **1,038 → 1,919 → 3,695 samples/s** at N=1→2→4 (scaling efficiency **92.4% / 89.0%**), GPU stall 5.7% → 8.3%. Per-phase attribution: dataload p50 14→23 ms with **p99 ≈ p50 at every N** (no storage tail — the filesystem keeps every rank fed), forward flat at ~90 ms, backward 142→162 ms — **the N=4 efficiency loss lives in the +20 ms of DDP-collective time folded into backward, not in dataload**. cuFile path proof per cell: all bytes bounced, `gds_engaged=none` (D8; best-available mode = bounce on this leg, no mode-paired cell exists per the composition rule). fs-side reads real throughout (wire/app 1.071, canary PASS all three cells). **D18 stability: split-window agreement ≤0.3% on every cell** — the long-cell mechanism; no repeats run. *Caveat:* cells declare and reconcile `warm` (steady-state by construction); Stage 5 measures consumption and scaling, and no Stage-5 number is a storage-throughput figure. |
| **Tool** | PyTorch + an in-process DataLoader reusing the random-mode reader logic from `../scripts/read-tiles-kvikio.py`; `torchvision` ResNet-50 (no pretrained weights — throughput, not convergence); AMP autocast + GradScaler; `cudnn.benchmark=True`; `channels_last`. Versions recorded at run time |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca-rawtiff/` (the 50-slide subset from 4.D) → GPU memory via kvikIO → model step. No persistent output |
| **Methodology** | **PyTorch DDP**, trainer self-launches N ranks via `torch.multiprocessing.spawn` with `MASTER_ADDR=127.0.0.1` and a free port. Each rank runs one in-process kvikIO reader — **not** forked DataLoader workers, because kvikIO's internal async pipelining already supplies that parallelism and forking would split cuFile handles for no supply-side gain. Random tile sampling from the same 20× coord pool 4.C uses. Per-rank batch 256 → effective batch 256 × N. AMP FP16 → cross-entropy against a synthetic position-derived label → backward (DDP AllReduce folded into backward) → SGD step. Per-phase timing via **CUDA events** (no host syncs between phases; one sync per step). **5 min ramp + 20 min steady state per cell.** NUMA-aware GPU assignment, map re-derived per instance |
| **Why `mp.spawn` rather than `torchrun`** | `torchrun`'s rendezvous binds its store to the resolved hostname, which on many hosts (cloud instances included) maps to an address not bound to any local interface — producing an opaque "no route to host". Self-launching with an explicit loopback master address removes that failure mode entirely. **`spawn`, not `fork`**, because forked CUDA workers inherit a partially-initialised CUDA context. Environment-independent robustness choice, so it carries to any instance |
| **Trainer-correctness requirements (all three are load-bearing)** | `cudnn.benchmark=True`, `channels_last` memory format, and **CUDA-event phase timing rather than per-phase `cuda.synchronize()`**. *Why they matter for a storage benchmark:* without them the compute phase runs several times slower than optimal, which **understates the demand a production pipeline places on storage** — the measurement would flatter both filesystems and compress the difference between them |
| **cuFile mode** | Best available mode per filesystem, plus one mode-controlled paired cell — see the scoping note above |
| **⚠ `LD_PRELOAD` scoped per cell** | Set only on kvikIO cells, never on cuCIM cells (ABI clash segfaults cuCIM's first read). Since 5.A and 5.B run in the same sweep, this sweep is mixed by construction |
| **Sweep driver** | `../scripts/sweep-stage5-training.sh` · **Trainer** `../scripts/train-resnet50-stage5.py` · **Aggregator** `../scripts/aggregate-stage5-training.py` |
| **Aggregated output** | `../runs/s5.A-training-summary.csv` — the aggregator rolls 5.A and 5.B cells into that one file, tagged by a `substage` column |
| **Recorded per cell** | samples/sec aggregate and per-rank, scaling vs N=1, scaling efficiency, GPU stall %, filesystem-side read mean/peak, GPU utilisation mean/min, and the per-phase CUDA-event split at each N — plus the full measurement set and cost inputs (`RUNBOOK.md`) |

### 5.B — cuCIM CPU batched + ResNet-50 DDP scaling

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 3/3 cells OK; cache `warm` reconciled CONSISTENT) · ⏳ Leg B |
| **Leg A results (`s5.A-training-summary.csv`, `substage=5.B` rows)** | **670 → 1,258 → 2,345 samples/s** at N=1→2→4 (efficiency 93.9% / 87.5%), GPU stall 37.5–40.5%. **kvikIO/cuCIM ratio ≈ 1.55× at every N** (1.55/1.53/1.58) — the ranking does not change with rank count on this leg, and the whole gap lives in dataload: p50 149→176 ms versus kvikIO's 14–23 ms, with forward/backward identical between backends (same model). *Attribution (per the discipline):* the 5.B stall is **decode-CPU-bound, not storage** — the 50-slide SVS working set is client-page-cache-resident from N=1's pass onward (the N=2/N=4 canary reports no-verdicts because fs-side reads are too small to ratio — the documented warm-cell sampling limit, recorded as a judgement), so storage is not even on the N=2/N=4 data path and the stall persists anyway. D18: split-window agreement ≤0.1% on every cell. *Caveat:* reader config fixed at the 4.B Tier-3 peak (nw=16, bs=64) per the driver; the re-tune-per-filesystem rule binds on Leg B. |
| **Tool** | Same trainer, cuCIM CPU-batched reader backend. The in-process reader uses cuCIM's batched CPU `read_region(locations_list, batch_size, num_workers, device='cpu', prefetch_factor)` with within-batch coord sorting for read locality |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca/` canonical SVS → host RAM (cuCIM CPU decode) → device copy → model. Same 50-slide subset, same 20× coord pool |
| **Methodology** | Identical DDP setup, model, AMP, `channels_last`, and cell duration as 5.A. Differences: the reader backend; **no `LD_PRELOAD`** (ABI clash); reads canonical SVS rather than raw-TIFF. Reader configured at the Stage 4.B peak `(batch_size, num_workers)` for that filesystem, **recorded per cell** — a peak config found on one filesystem is not assumed optimal on the other |
| **Why this exists** | It is the path most existing WSI pipelines run today, so it answers the migration question directly: *what would moving to the GPU-direct path actually gain?* The migration has real cost — converting slides to raw TIFF and engineering a custom reader — so the per-N comparison against 5.A is what tells a customer whether that cost is worth paying. Asking it on two filesystems additionally reveals whether the answer is filesystem-dependent |
| **Why the reader config is re-tuned per filesystem rather than copied** | The peak `(batch_size, num_workers)` reflects an interaction between decode concurrency and storage latency. Copying one filesystem's optimum onto the other would handicap whichever side has a different optimum — a fairness bug that would look like a filesystem difference |
| **Recorded per cell** | cuCIM samples/sec per N, paired 5.A samples/sec, the kvikIO/cuCIM ratio at every N, efficiency curves for both backends, GPU stall %, per-phase split, application-available-core CPU — plus the full measurement set and cost inputs (`RUNBOOK.md`) |
| **Cross-source check** | slide-header page-cache warming can depress the filesystem-side read mean on later steps and inflate ratio checks; record cache state rather than widening bands silently |

---

## Tool inventory used in Stage 5

| Tool | Version | Source | Used in |
|---|---|---|---|
| `PyTorch` + `torchvision` | record at run time | conda | 5.A, 5.B |
| `kvikio` | record at run time | RAPIDS conda | 5.A |
| `cuCIM` | record at run time | RAPIDS conda | 5.B |
| `cupy`, `tifffile` | record at run time | conda | 5.A |
| `train-resnet50-stage5.py` | live | `../scripts/` | 5.A, 5.B |
| `sweep-stage5-training.sh` · `aggregate-stage5-training.py` | live | `../scripts/` | full stage |
| `record-run.sh` | live | `../scripts/` | every cell |

**Environment per cell** (set by the sweep driver): the conda env prefix; `LD_PRELOAD` of the system
libcufile **on kvikIO cells only**; the cuFile config path; thread caps (`OMP_NUM_THREADS`,
`MKL_NUM_THREADS`) to avoid PyTorch thread oversubscription; `NCCL_DEBUG` at warning level, raised only
when collective attribution needs it; and the per-cell GPU subset. **All values re-derived on the real
instance** — none are portable constants.

## Datasets used in Stage 5

| Dataset | Source | Used in |
|---|---|---|
| TCGA-BRCA **20× raw-TIFF** subset | produced by 4.D per leg (50 slides) | 5.A |
| TCGA-BRCA canonical SVS | hydrated per leg (1.7); 50-slide subset sampled | 5.B |
| **20× CLAM coords (BRCA)** | produced by 3.0 per leg | both — random (slide, coord) sampling |
| 50-slide subset manifest | `../scripts/manifests/tcga-brca-stage4a-subset.tsv` (seed=42) | both — defines the sampled slides |

## Decision register (Stage 5-scoped)

One entry per **live** decision scoped to this stage, with its why. Cross-stage decisions live in
`STAGES.md`.

- **Two backends head to head (kvikIO/cuFile and cuCIM CPU batched), full sweep on both.** *Why:* they are
  Stage 4's two production paths, and the migration question ("what does moving to GPU-direct buy?") is only
  answerable with both curves. A single comparator point cannot show whether the ranking changes with scale.
- **5.A runs each filesystem in its best available cuFile mode, plus one mode-controlled paired cell.**
  *Why:* Stage 4.C already characterises the GDS-vs-compat delta across the full mode × filesystem grid
  (**D8**); repeating it at every rank count would multiply cells for information that grid already carries.
  The paired cell preserves the link back to 4.C so a cross-leg training difference can be checked against
  the read-level mode difference. Recorded as a scoping choice so it is not mistaken for an omission.
- **ResNet-50, not a larger model.** *Why:* it is the **storage-stressing** choice — small model, fast
  steps, high demand per unit compute. A compute-dominant model gives the storage path slack and actively
  *reduces* discrimination between two filesystems, which is the opposite of what this project needs.
  Larger-model compute is covered in Stage 6.
- **GPU sweep N follows the instance's GPU count** — {1, 2, 4} on `g6e.24xlarge` (**D10**). *Why:* the
  scaling *shape* is the signal, so the range is set by the hardware rather than chosen; if **D10**'s
  revisit trigger fires and the instance changes, the range follows it.
- **Custom in-process DataLoader reusing the Stage 4 readers, not a higher-level pipeline framework.**
  *Why:* a framework layer sits between us and the storage path and would add its own scheduling behaviour
  to every measurement. Reusing the validated Stage 4 reader code keeps the storage path direct and
  minimises new, unaudited engineering.
- **One rank = one in-process reader, not forked DataLoader workers (5.A).** *Why:* kvikIO's internal async
  pipelining already provides read parallelism; forking would split cuFile handles and force a different
  multiprocessing start method for no supply-side gain.
- **TCGA-BRCA only.** *Why:* cross-vendor consistency on the storage path is established elsewhere (Stage 4,
  6.A, 7.6); adding a second dataset here doubles cells without changing what the scaling curve says.
- **No convergence training; synthetic label.** *Why:* the measurement is throughput. Stated explicitly so
  the loss curve is never read as a result.
- **`cudnn.benchmark`, `channels_last`, and CUDA-event phase timing are mandatory.** *Why:* without them
  compute runs several times slower than optimal, which **understates the demand placed on storage** —
  flattering both filesystems and compressing the difference between them. A trainer-correctness issue with
  direct consequences for the storage measurement.
- **`mp.spawn` with an explicit loopback master, not `torchrun`.** *Why:* `torchrun`'s rendezvous can bind
  to a hostname that does not resolve to a local interface — an opaque failure that costs debugging time on
  any new host. `spawn` rather than `fork` because forked CUDA workers inherit a partially-initialised
  context.
- **cuCIM reader config re-tuned per filesystem, not copied across legs.** *Why:* the optimum reflects an
  interaction between decode concurrency and storage latency; imposing one side's optimum on the other would
  create a fairness bug that reads as a filesystem difference.
- **The attribution discipline (above) is non-negotiable.** *Why:* this is the easiest place in the project
  to produce a confident, plausible, wrong conclusion, and a wrong attribution here would propagate into the
  customer story for both filesystems.

## Cross-references

- `../PROJECT-THESIS.md` — what we measure and why: held-constant contract, both asymmetries, framing
- `../CLAUDE.md` — project rules
- `STAGES.md` — stage map, per-leg plan, cross-stage decision register (**D8** GPU-direct, **D10** instance,
  **D13** cache, **D15** cores)
- `RUNBOOK.md` — the per-cell measurement set, the cost inputs, the source table, both canaries
- `Stage-4-Patching.md` — supplies both data paths, the raw-TIFF artifact, and the full cuFile-mode grid this stage reduces from
- `Stage-1-Ingest.md` — the block-size-matched ceilings every "% of ceiling" divides by
- `../scripts/read-tiles-kvikio.py` · `../scripts/read-tiles-onthefly.py` — the readers whose logic the trainer reuses
- `SCRIPT-TRACKER.md` — per-script reference and the deferred-work table
