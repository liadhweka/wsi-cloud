# Stage 5 — Training data pipeline, measured identically on both filesystems

> **STATUS — read first.** Nothing has run. Every number below is **`[PENDING]`** and every interpretation
> section is **`[STORY PENDING RESULTS]`**.
>
> **Every cell runs on both filesystems** — WEKA (Leg A) then FSx for Lustre (Leg B) — with everything else
> held constant. The delta is the result.
>
> Stage 5 builds directly on Stage 4's two production data paths, so **Stage 4's closeout is load-bearing
> here**: 4.C supplies the kvikIO path's characterisation, 4.B the cuCIM-CPU path's, and Stage 1.0 supplies
> the block-size-matched ceilings every "% of ceiling" divides by.

For project-wide conventions see `../CLAUDE.md`; framing and the fairness contract `../PROJECT-THESIS.md`;
stage map and decision log **D1–D15** `STAGES.md`; runbook `README.md`.

---

## What Stage 5 measures

The **training data pipeline** — where a GPU-bound training job actually consumes tiles from storage at
production rates. The structural pattern:

```
WSI on storage → reader opens → DataLoader workers → random tile sampling across many slides
  → batch assembled → model forward + backward + optimizer step → loop
```

Stage 4 measures what each filesystem can **deliver**. Stage 5 measures whether a real training loop can
**consume** it, and how that holds up as GPU count rises. The two questions are genuinely different: a
filesystem can supply tiles faster than any single model consumes them and still stall a multi-GPU job,
because what matters at scale is per-step latency distribution, not aggregate bandwidth.

The customer pain point: legacy NAS deployments running CNN DDP training on WSI data plateau at a handful
of GPUs of useful scaling because DataLoader workers stall waiting for storage, and GPU utilisation drops.
Stage 5 produces the hard numbers — GPU utilisation and scaling efficiency under real training load — for
each filesystem.

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

**GPU count sweep: N ∈ {1, 2, 4}** — the instance has 4 GPUs *(subject to change; `g6e.48xlarge` would
extend this to {1,2,4,8})*. **NUMA-aware GPU assignment**, with the topology map re-derived on the real
instance rather than assumed (**D15**, open item 14).

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

Standard `record-run.sh` with **per-filesystem source adapters** (**D12**), plus three Stage-5 additions:

1. **Per-training-step CSV — PRIMARY.** The trainer emits one row per step to
   `<run-dir>/training-steps.csv`: `step_idx, t_step_start, t_step_end, step_duration_ms, t_dataload_ms,
   t_forward_ms, t_backward_ms, t_optimizer_ms, samples, loss`. Everything customer-facing derives from
   this — samples/sec, GPU stall time (step duration minus compute phases), and the **dataload latency
   distribution (p50/p95/p99)** that the attribution discipline depends on.
2. **`nvidia-smi` — PRIMARY.** GPU utilisation under training load *is* the customer-facing story: a fed
   pipeline holds utilisation high, a stalled one does not.
3. **NCCL collective times** — secondary, but **load-bearing for attribution**: an efficiency loss that
   lives in collectives is a DDP effect, not a storage effect, and without this the two are
   indistinguishable.

### Primary sources

| Source | What it captures | Role |
|---|---|---|
| **Per-step training CSV** | Per-step wallclock and phase split, samples, loss | **The cross-leg headline** plus the attribution evidence |
| **`nvidia-smi`** (1 Hz per GPU) | Utilisation, memory, power, temperature | GPU-fed-vs-stalled demonstration |
| **Filesystem-side read bytes** | WEKA `Read`; Lustre `/proc/fs/lustre` OSC + CloudWatch OST | Confirms the delivery rate implied by app-level metrics |
| **Filesystem-side operation counters** | WEKA `Ops/s`; Lustre MDC RPCs | Matters most early in a cell, when few slide handles are cached and open/close traffic is higher. **Within-leg only** |
| **Wire counters for the path in use** | WEKA: DPDK-path counters. Lustre: client network counters (**primary on that leg**) | Cross-source consistency |
| **`sar -u` over application-available cores** | Per-core CPU, reserved set excluded per **D15** | cuCIM cells: the decode-CPU saturation curve. kvikIO cells: expected low, and *how* low is part of the path's value |

### Diagnostic-only

`sar -d`; client network counters **on the WEKA leg only** (primary on the Lustre leg);
filesystem-reserved cores on the WEKA leg (count reported as cost per **D15**).

### Cross-source consistency canary

Per **D12**, derived per filesystem. Within each leg:
- App-level samples/sec × per-tile bytes reconciles with filesystem-side read bytes, with an allowance for
  cache effects and decode buffering — **the allowance is stated per cell, not applied silently.**
- Wire counters track filesystem-side reads at that filesystem's derived read relation.
- GPU utilisation at N=1 establishes the no-DDP-overhead reference; behaviour at higher N is the signal.
- Collective time rising with rank count is expected and is *not* a storage finding.

**Cache caveat that will bite here (D13):** on a long cell the working set warms, which can depress
filesystem-side read means and inflate ratio checks. Label cells and record cache state; do not "fix" a
ratio by widening a band without saying so.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All cells are ⏳ on both legs.

### 5.A — kvikIO/cuFile + raw-TIFF + ResNet-50 DDP scaling

| | |
|---|---|
| **Status** | ⏳ both legs — needs 4.D raw-TIFF, 3.0 coords, Phase 0 ceilings |
| **Tool** | PyTorch + an in-process DataLoader reusing the random-mode reader logic from `lib/read-tiles-kvikio.py`; `torchvision` ResNet-50 (no pretrained weights — throughput, not convergence); AMP autocast + GradScaler; `cudnn.benchmark=True`; `channels_last`. Versions recorded at run time |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca-rawtiff/` (the 50-slide subset from 4.D) → GPU memory via kvikIO → model step. No persistent output |
| **Methodology** | **PyTorch DDP**, trainer self-launches N ranks via `torch.multiprocessing.spawn` with `MASTER_ADDR=127.0.0.1` and a free port. Each rank runs one in-process kvikIO reader — **not** forked DataLoader workers, because kvikIO's internal async pipelining already supplies that parallelism and forking would split cuFile handles for no supply-side gain. Random tile sampling from the same 20× coord pool 4.C uses. Per-rank batch 256 → effective batch 256 × N. AMP FP16 → cross-entropy against a synthetic position-derived label → backward (DDP AllReduce folded into backward) → SGD step. Per-phase timing via **CUDA events** (no host syncs between phases; one sync per step). **5 min ramp + 20 min steady state per cell.** NUMA-aware GPU assignment, map re-derived per instance |
| **Why `mp.spawn` rather than `torchrun`** | `torchrun`'s rendezvous binds its store to the resolved hostname, which on many hosts (cloud instances included) maps to an address not bound to any local interface — producing an opaque "no route to host". Self-launching with an explicit loopback master address removes that failure mode entirely. **`spawn`, not `fork`**, because forked CUDA workers inherit a partially-initialised CUDA context. Environment-independent robustness choice, so it carries to any instance |
| **Trainer-correctness requirements (all three are load-bearing)** | `cudnn.benchmark=True`, `channels_last` memory format, and **CUDA-event phase timing rather than per-phase `cuda.synchronize()`**. *Why they matter for a storage benchmark:* without them the compute phase runs several times slower than optimal, which **understates the demand a production pipeline places on storage** — the measurement would flatter both filesystems and compress the difference between them |
| **cuFile mode** | Best available mode per filesystem, plus one mode-controlled paired cell — see the scoping note above |
| **⚠ `LD_PRELOAD` scoped per cell** | Set only on kvikIO cells, never on cuCIM cells (ABI clash segfaults cuCIM's first read). Since 5.A and 5.B run in the same sweep, this sweep is mixed by construction |
| **Sweep driver** | `lib/sweep-stage5-training.sh` · **Trainer** `lib/train-resnet50-stage5.py` · **Aggregator** `lib/aggregate-stage5-training.py` |
| **Aggregated output** | `s5-training-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` — samples/sec aggregate and per-rank, scaling vs N=1, scaling efficiency, GPU stall %, filesystem-side read mean/peak, GPU utilisation mean/min, and the per-phase CUDA-event split at each N |
| **Cross-source validation** | `[PENDING]` |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 5.B — cuCIM CPU batched + ResNet-50 DDP scaling

| | |
|---|---|
| **Status** | ⏳ both legs — needs 3.0 coords, Phase 0 ceilings |
| **Tool** | Same trainer with `--backend cucim_batched_cpu`. In-process reader uses cuCIM's batched CPU `read_region(locations_list, batch_size, num_workers, device='cpu', prefetch_factor)` with within-batch coord sorting for read locality |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca/` canonical SVS → host RAM (cuCIM CPU decode) → device copy → model. Same 50-slide subset, same 20× coord pool |
| **Methodology** | Identical DDP setup, model, AMP, `channels_last`, and cell duration as 5.A. Differences: the reader backend; **no `LD_PRELOAD`** (ABI clash); reads canonical SVS rather than raw-TIFF. Reader configured at the Stage 4.B peak `(batch_size, num_workers)` for that filesystem, **recorded per cell** — a peak config found on one filesystem is not assumed optimal on the other |
| **Why this exists** | It is the path most existing WSI pipelines run today, so it answers the migration question directly: *what would moving to the GPU-direct path actually gain?* The migration has real cost — converting slides to raw TIFF and engineering a custom reader — so the per-N comparison against 5.A is what tells a customer whether that cost is worth paying. Asking it on two filesystems additionally reveals whether the answer is filesystem-dependent |
| **Why the reader config is re-tuned per filesystem rather than copied** | The peak `(batch_size, num_workers)` reflects an interaction between decode concurrency and storage latency. Copying one filesystem's optimum onto the other would handicap whichever side has a different optimum — a fairness bug that would look like a filesystem difference |
| **Headline results** | `[PENDING]` — cuCIM samples/sec per N, paired 5.A samples/sec, the kvikIO/cuCIM ratio at every N, efficiency curves for both backends, GPU stall %, per-phase split, application-available-core CPU |
| **Cross-source validation** | `[PENDING]` — note that slide-header page-cache warming can depress the filesystem-side read mean on later steps and inflate ratio checks; record cache state rather than widening bands silently |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

---

## Tool inventory used in Stage 5

| Tool | Version | Source | Used in |
|---|---|---|---|
| `PyTorch` + `torchvision` | record at run time | conda | 5.A, 5.B |
| `kvikio` | record at run time | RAPIDS conda | 5.A |
| `cuCIM` | record at run time | RAPIDS conda | 5.B |
| `cupy`, `tifffile` | record at run time | conda | 5.A |
| `train-resnet50-stage5.py` | live | `lib/` | 5.A, 5.B |
| `sweep-stage5-training.sh` · `aggregate-stage5-training.py` | live | `lib/` | full stage |
| `record-run.sh` | live | `lib/` | every cell |

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
| 50-slide subset manifest | `manifests/tcga-brca-stage4a-subset.tsv` (seed=42) | both — defines the sampled slides |

## Decision log (Stage 5-scoped)

- **2026-07-31 — Two backends head to head (kvikIO/cuFile and cuCIM CPU batched), full sweep on both.**
  *Why:* they are Stage 4's two production paths, and the migration question ("what does moving to
  GPU-direct buy?") is only answerable with both curves. A single comparator point cannot show whether the
  ranking changes with scale.
- **2026-07-31 — 5.A runs each filesystem in its best available cuFile mode, plus one mode-controlled
  paired cell.** *Why:* Stage 4.C already characterises the GDS-vs-compat delta across the full mode ×
  filesystem grid; repeating it at every rank count would multiply cells for information we already have.
  The paired cell preserves the link back to 4.C so a cross-leg training difference can be checked against
  the read-level mode difference. Recorded as a scoping choice so it is not mistaken for an omission.
- **2026-07-31 — ResNet-50, not a larger model.** *Why:* it is the **storage-stressing** choice — small
  model, fast steps, high demand per unit compute. A compute-dominant model gives storage slack and
  actively *reduces* discrimination between two filesystems, which is the opposite of what this project
  needs. Larger-model compute is covered in Stage 6.
- **2026-07-31 — GPU sweep N ∈ {1, 2, 4}** *(subject to change with the instance)*. *Why:* the instance has
  4 GPUs; the scaling *shape* is the signal, so the range follows the hardware. A larger instance would
  extend it to {1,2,4,8}.
- **2026-07-31 — Custom in-process DataLoader reusing the Stage 4 readers, not a higher-level pipeline
  framework.** *Why:* a framework layer sits between us and the storage path and would add its own
  scheduling behaviour to every measurement. Reusing the validated Stage 4 reader code keeps the storage
  path direct and minimises new, unaudited engineering.
- **2026-07-31 — One rank = one in-process reader, not forked DataLoader workers (5.A).** *Why:* kvikIO's
  internal async pipelining already provides read parallelism; forking would split cuFile handles and force
  a different multiprocessing start method for no supply-side gain.
- **2026-07-31 — TCGA-BRCA only.** *Why:* cross-vendor consistency on the storage path is established
  elsewhere (Stage 4, 6.A, 7.6); adding a second dataset here doubles cells without changing the scaling
  conclusion.
- **2026-07-31 — No convergence training; synthetic label.** *Why:* the measurement is throughput. Stated
  explicitly so the loss curve is never read as a result.
- **2026-07-31 — `cudnn.benchmark`, `channels_last`, and CUDA-event phase timing are mandatory.** *Why:*
  without them compute runs several times slower than optimal, which **understates the demand placed on
  storage** — flattering both filesystems and compressing the difference between them. A
  trainer-correctness issue with direct consequences for the storage measurement.
- **2026-07-31 — `mp.spawn` with an explicit loopback master, not `torchrun`.** *Why:* avoids rendezvous
  binding to a hostname that may not resolve to a local interface — an opaque failure that costs debugging
  time on any new host. `spawn` rather than `fork` because forked CUDA workers inherit a broken context.
- **2026-07-31 — cuCIM reader config re-tuned per filesystem, not copied across legs.** *Why:* the optimum
  reflects an interaction between decode concurrency and storage latency; imposing one side's optimum on the
  other would create a fairness bug that reads as a filesystem difference.
- **2026-07-31 — Attribution discipline (above) is non-negotiable.** *Why:* this is the easiest place in the
  project to produce a confident, plausible, wrong conclusion, and a wrong attribution here would propagate
  into the customer story for both filesystems.

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage 5 roadmap created for the WEKA-vs-Lustre comparison. Retained: two-backend head-to-head design, full sweep on both blocks, ResNet-50 rationale, single-dataset scope, throughput-not-convergence framing, the three trainer-correctness requirements, `mp.spawn` launch, per-cell `LD_PRELOAD` scoping, per-step CSV as primary. **Added:** per-leg framing; the **attribution discipline** section (generalised from what was a stage-specific re-derivation protocol into a standing rule about measured-vs-narrative causes); cuFile-mode scoping for 5.A with its rationale; per-filesystem reader re-tuning as a fairness requirement; per-filesystem recording adapters; **D13** cache caveat; **D15** core accounting. **Changed:** GPU sweep is now N ∈ {1,2,4} to match the 4-GPU instance. **Removed:** all inherited results, outcome buckets, and magnitude expectations. |

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, decision log (esp. **D8** GPU-direct, **D13** cache, **D15** cores)
- `Stage-4-Patching.md` — supplies both data paths, the raw-TIFF artifact, and the full cuFile-mode grid this stage reduces from
- `Stage-1-Ingest.md` — the block-size-matched ceilings every "% of ceiling" divides by
- `lib/read-tiles-kvikio.py` · `lib/read-tiles-onthefly.py` — the readers whose logic the trainer reuses
- `../SCRIPT-TRACKER.md` — per-script reference and deferred cloud-session TODOs
- `README.md` — operational runbook and both canaries
