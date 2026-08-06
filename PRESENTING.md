# Presentation script — WEKA vs Lustre for the WSI pipeline on AWS

> **STATUS: BUILD PHASE. Nothing has been measured.** Every number is `[PENDING]` and every interpretation
> is `[STORY PENDING RESULTS]`.
>
> **Until results land, this is a methodology script — what we will measure and why — not a narrative.**
> It is written so that someone who has never seen the project can present any section from this file
> alone. When results arrive, the interpretation sections fill in **from the numbers**, and this document is
> updated **in place** (history lives in git and in the per-stage decision logs).

---

## ⚠️ Read this first — three rules that govern everything below

### 1. Results precede story

There is no thesis here about who wins. This document contains **no predicted outcome, no expected
magnitude, and no pre-assigned "headline" stage.** What it does contain, everywhere, is **why we measure
each thing the way we do** — because that is what makes a number evaluable, and a stakeholder who cannot
evaluate the method cannot trust the result.

**Whatever the benchmark produces is what gets reported, including cells where WEKA loses.** Provisioning
Lustre at maximum capability raises that possibility. That is the accepted trade: a weakness found here is
one a customer does not find later, in front of us.

### 2. Each leg is half an unfinished comparison

The project runs in two sequential legs — **Leg A: WEKA**, then **Leg B: FSx for Lustre** — followed by the
synthesis. A single leg's numbers mean little in isolation; their entire force is the head-to-head.
**Present single-leg findings as strong-but-incomplete**, leave explicit room for the other leg, and say
that the decisive comparison is built later. This is not a licence to soften a finding — record the numbers
plainly; it is the **claim** that stays scoped.

### 3. Both deliberate asymmetries are stated wherever results appear

A skeptical listener's first question is *"what was the other side running?"* The answer must already be on
the slide.

**Asymmetry 1 — provisioning.** **Lustre is provisioned at maximum capability; WEKA at a realistic
production configuration; cost for both is reported alongside.** Why: beating a competitor's *best*
configuration is worth far more than beating one we sized ourselves, and it forecloses the objection that
whoever picked the tier picked the winner. The headline phrasing is *"WEKA at a typical production
configuration versus FSx for Lustre at maximum."*

"Maximum" is defined per axis, because one axis is capped by the client and the others are not: top SSD
throughput tier; capacity high enough that the filesystem's own disk throughput exceeds what the client can
consume; **user-provisioned high metadata IOPS** (provisioned independently of capacity — the axis where a
maxed Lustre is most formidable); and EFA enabled. WEKA is also sized so that it is not the constraint —
a "realistic" configuration that starves the client would produce a sizing artifact, not a finding.

**Asymmetry 2 — transport and GPU-direct.** Lustre over EFA supports GPUDirect Storage; WEKA on AWS runs
DPDK over ENA, which is not RDMA-capable, so compat-mode fallback is **expected** — and is **verified
empirically per cell, not assumed from documentation**. We do **not** drop the GPU-direct path to force
symmetry, because that asymmetry is precisely the choice a customer faces on AWS. Instead the experiment is
designed so the asymmetry becomes analysable — see Stage 4.

### And one framing consequence worth stating up front

**Raw bandwidth is expected to be capped by the client instance, not by either filesystem** — both are sized
above it. So **a tie on a pure bandwidth cell says something about the instance, not about either
filesystem**, and must never be presented as a finding about either. The axes that carry information are
**metadata, IOPS, small-file behaviour, concurrency, and latency.** Say this before showing any bandwidth
chart; it prevents the most likely misreading of the whole project.

---

## TL;DR — the project in 60 seconds

`[STORY PENDING RESULTS]`

What can be said today, factually:

- **The question.** For a modern whole-slide-imaging / digital-pathology pipeline on AWS, how does WEKA
  compare to Lustre — same GPU instance, same workload code, same datasets, only the mount changes?
- **The method.** The real seven-stage pipeline (ingest → cataloging → tissue detection → patching →
  training → foundation-model feature extraction and MIL → clinical inference), run identically on both
  filesystems, recorded exhaustively, at the literature-standard 20× magnification.
- **Why the full pipeline rather than a storage microbenchmark.** Each stage stresses storage differently —
  large sequential reads, random small-block reads, metadata storms, small-file corpora, mixed concurrent
  load. A comparison that measures only peak bandwidth answers almost none of the questions a pathology
  platform team actually has.
- **Status.** Docs and methodology complete; environment not yet provisioned; **no cell has run.**

---

## How this project is organised

**One variable changes: the filesystem.** Held constant and recorded: the compute instance (type, region,
AZ, AMI), the workload code (a single commit), the datasets and their byte contents, the magnification
contract, the model set, and the recording harness. Varied: the mount.

Because the legs run at different times, that is enforced **mechanically** rather than by trust: Leg A
writes a machine-readable **environment contract** (instance type, region/AZ, AMI, kernel, driver and CUDA
versions, dataset byte-manifest, script commit) which **Leg B verifies before its first cell.** A mismatch
is a fail-loud condition. Without it, *"were these two legs even comparable?"* is unanswerable at exactly
the moment it matters most.

**The 20× magnification contract.** Every stage that tiles slides produces a uniform **256 px at 20×** tile.
Why 20×: it is the dominant published standard for the foundation models we run — UNI/UNI2-h, Virchow2, and
Prov-GigaPath all specify ~0.5 µm/px — and **no model requires 40×**. So our numbers are directly
comparable to the literature and to what customers run. Slides whose native pyramid lacks a 20× level are
read at the nearest native level and resized, which is exactly what the standard tooling does internally.

**Recording is per-filesystem.** The recording *philosophy* is identical on both legs — time series not
point estimates, multiple independent vantage points, verify the capture before trusting the run. The
*sources* are not: WEKA's client kernel-bypasses the network stack, so kernel network counters are
diagnostic there — while on a Lustre client **those same counters are the data path.** Using one leg's
source table for the other would produce confidently wrong numbers, so each leg has its own adapter, and
the cross-source consistency relation is **derived per filesystem, never ported.**

**Cold versus warm is an enforced axis.** Both filesystems carry substantial cache — a maxed FSx's
file-server cache is comparable in size to the instance's own RAM — and they cache *differently*. So every
read-heavy cell is labelled cold or warm with **cache state recorded as achieved, not asserted.** An
unlabelled read number is ambiguous, and the ambiguity is asymmetric.

---

## Stage 1 — Ingest (scanner to storage)

**WSI context.** Pathology scanners produce slides continuously — typically 1–2 minutes and 1–1.5 GiB per
slide — which must land on storage and become immediately available to every downstream pipeline. Legacy NAS
plateaus at a few GiB/s under realistic concurrent-stream load, which is what forces labs into a second fast
tier.

**What we do.** Synthetic ceilings with `fio` across seven concurrency levels: five block sizes
(4K–4M) for the sequential write and read pairs, and three small block sizes (4K/16K/64K) at deeper queue
depth for the random-write and random-read IOPS pairs. Then real-data ingest: bulk copy from local
NVMe at varying parallelism, S3-to-filesystem hydration, and a mixed cell running ingest and reads
simultaneously.

**Why this way.** The synthetic ceilings come first because **real-data numbers are uninterpretable without
an isolated-storage anchor** — and because every downstream "% of ceiling" in the project divides by one of
these cells, **matched by block size**. Throughput is strongly block-size-dependent, so a single "ceiling"
number would make mid-block workloads look artificially high or low.

The **head-to-head ingest cell is S3 → filesystem hydration**, using the identical tool and flags on both
sides. Why: it is a real workload we run anyway (it is how the datasets get onto each filesystem), a
same-region source removes the WAN bottleneck that would otherwise dominate, and using the same mechanism on
both sides is what makes it a *filesystem* comparison rather than a mechanism comparison.

**One cell is deliberately not head-to-head.** FSx offers a native S3 import with no WEKA equivalent.
Including it in the comparison would pit a feature against its absence; omitting it entirely would understate
Lustre, which the fairness basis forbids. So it is measured, labelled a **single-filesystem capability
cell**, and presented as "what FSx can additionally do" — never as a delta.

**Protocol caveat to state up front.** All of this is **POSIX**, not SMB. Real scanners are typically Windows
and write via SMB. WEKA has a native SMB stack; Lustre does not (it would need a gateway) — which is a
feature-set observation, **not something we measured.** SMB is out of scope on both sides, partly because the
two SMB paths would not be architecturally comparable and would introduce an asymmetry we could not hold
constant. What Stage 1 *is* valid for: the protocol-independent write ceiling, Linux-based ingest pipelines,
and the very common pattern where SMB is upstream and the last leg into shared storage is POSIX.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-1-Ingest.md`

---

## Stage 2 — Cataloging & metadata extraction

**WSI context.** Every slide's metadata — per-level dimensions, microns-per-pixel, magnification, scanner
properties, colour profile — is needed for indexing, QC, pipeline routing, and LIMS/PACS integration. The I/O
is tiny per slide but repeated across thousands of files, so **the metric is operations per second, not bytes
per second.** This is where legacy NAS metadata servers bottleneck: a single metadata server caps
throughput no matter how many parallel readers you add.

**What we do.** Extract properties for two full datasets via OpenSlide at four concurrency levels, single-pass
per cell, writing a JSON sidecar per slide.

**Why this stage matters for this comparison specifically.** The two filesystems solve metadata
**differently**: Lustre concentrates it on dedicated metadata targets with IOPS provisioned independently of
capacity, while WEKA distributes it across all backends with no separate tier. **This is the stage most
directly affected by the fairness basis** — Lustre gets its high provisioned metadata IOPS precisely so the
comparison is against its best configuration.

**A caveat that constrains what we may claim.** App-level throughput (slides/sec, per-slide latency) **is**
comparable across legs — identical work on identical files. **Filesystem-reported operation counts are
not**, automatically: each filesystem counts "operations" under its own semantics, so the syscalls OpenSlide
issues are identical while the reported counts need not be. So app-level throughput is the cross-leg
headline, and filesystem-reported ops/s is a **within-leg diagnostic** unless counter equivalence is
explicitly verified. This does not weaken the stage — the customer question is answered at app level — it
just forbids one specific invalid comparison.

**A second axis worth watching.** The two datasets have different on-disk layouts (one nested per slide, one
flat), which changes how many metadata operations an `open()` requires. They are reported separately and
never averaged, because whether the two filesystems are affected differently by directory nesting is itself
a metadata-architecture question.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-2-Cataloging.md`

---

## Stage 3 — Tissue detection (and the coord generator)

**WSI context.** Most of a slide is empty glass — typically 50–70%, sometimes over 90% for needle biopsies.
Before anything else, a pipeline segments foreground and records which tile coordinates contain tissue.

**What we do.** Run the standard CLAM tissue detector across two full datasets at three concurrency levels,
producing per-slide coordinate lists that **gate Stages 4 through 7 on that leg.**

**Why this stage is in a storage benchmark at all.** Its I/O profile is small **by construction** — read the
header and a low-resolution thumbnail, threshold and clean up, write a small coordinate file. That is a
property of the algorithm, not a prediction about either filesystem. It earns its place as the counterpart
to Stage 2: one stage leans on the metadata path, the other on compute, and together they bracket the
pipeline's load profile. Whether either filesystem becomes visible here is `[STORY PENDING RESULTS]` — the
recording is nearly free, so we measure rather than assume, and storage being busier than the algorithm
implies would be a finding to chase.

**A comparability caveat that first bites here.** This stage's headline is a **CPU saturation curve**, and
**the two clients consume CPU differently**: the WEKA client reserves dedicated cores for its data path, the
Lustre client does not. On one identical instance, the cores available to the application therefore differ
between legs. So we record **cores reserved, cores available, and total** for every cell, compute saturation
over *application-available* cores, and report the reservation as part of WEKA's cost. Both ways of ignoring
this are wrong: hiding the reservation flatters Lustre's parallelism, excluding it from WEKA's cost flatters
WEKA's efficiency.

**A free integrity check.** Two slides are known to yield no tissue under the detector's default parameters —
real tool behaviour, independent of storage and magnification. Because completeness and per-slide tile counts
are storage-independent, they must be **identical on both legs**; a divergence proves the legs did not
process the same inputs and invalidates everything downstream.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-3-Tissue-Detection.md`

---

## Stage 4 — Patching / tile extraction

**WSI context.** This is where storage stops being an afterthought. Training pipelines feed billions of
256×256 tiles to GPU-bound models, and how those tiles get from storage to GPU has three fundamentally
different shapes — which we benchmark side by side:

- **Pre-extract.** Do the I/O-heavy work once, writing tiles to per-slide files. Training reads are then
  sequential and friendly to any storage.
- **On-the-fly.** Keep slides as they are and read each tile when needed. No preprocessing cost, full
  flexibility, and how modern pipelines actually run — but punishing on storage: random small reads across
  many large files from many parallel workers.
- **GPU-direct.** Convert to uncompressed raw TIFF, then stream tile byte ranges straight into GPU memory
  via cuFile, bypassing CPU decode entirely.

**Why all three.** Their I/O shapes are genuinely different, and which one a customer uses depends on their
pipeline. Measuring only the storage-heaviest would answer a narrower question than the one being asked.

**The GPU-direct experiment — the methodological core of this stage.** A naive "Lustre GPU-direct versus
WEKA GPU-direct" comparison would vary **both** the filesystem **and** the transport, and no single number
could attribute the difference. But **cuFile's compat mode runs on both filesystems**, so every applicable
cell runs in **both modes on both sides**, which separates three readings:

1. **Lustre-compat vs WEKA-compat** → the **pure filesystem comparison**: identical code path, identical
   artifact, identical API, no transport difference. The cleanest apples-to-apples number in the project.
2. **Lustre-GDS vs Lustre-compat** → the **pure GDS effect**, isolated inside one filesystem.
3. **Lustre-GDS vs WEKA-best** → the **deployment-reality** question: what a customer actually gets on each.

Plus a plain-POSIX cell on both sides, because compat mode adds a bounce buffer and the cuFile layer on top
of POSIX and may be **slower than a filesystem's native path** — without it we would understate whichever
side falls back. If WEKA turns out to support true GDS, the grid simply fills in and nothing is wasted.

**And we prove which path each cell took.** Every cuFile cell records the filesystem's own accounting of
GPU-direct versus bounced bytes. **A configuration flag is not proof of behaviour**, and a cell that quietly
fell back looks identical to a working one in the throughput data. A cell without path accounting is treated
as incomplete.

**A cost worth naming.** The raw-TIFF artifact is a real capacity cost on **both** filesystems (order ~7 TB
at the full cohort), and on FSx capacity is simultaneously a performance knob — so it is an input to how both
sides are sized, not an afterthought. Its conversion is measured as a workload in its own right.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-4-Patching.md`

---

## Stage 5 — Training data pipeline

**WSI context.** A GPU-bound training job consumes tiles continuously: random sampling across many slides,
batches assembled by parallel workers, forward/backward/optimiser, repeat. Legacy NAS deployments plateau at
a handful of GPUs of useful scaling because workers stall waiting for storage and GPU utilisation collapses.

**What we do.** Real PyTorch DDP training of a CNN, fed by each of Stage 4's two production data paths,
swept across GPU count on both filesystems.

**Why this is a different question from Stage 4.** Stage 4 measures what each filesystem can **deliver**;
Stage 5 measures whether a real training loop can **consume** it, and how that holds up as GPU count rises.
A filesystem can supply tiles faster than any single model consumes them and still stall a multi-GPU job,
because what matters at scale is the **per-step latency distribution**, not aggregate bandwidth.

**Why a small, fast model rather than a large one.** ResNet-50 is the **storage-stressing** choice: small
model, fast steps, high demand per unit of compute, so the storage path is where it can bind. A
compute-dominant model gives storage slack and actively *reduces* discrimination between two filesystems —
the opposite of what this project needs. Heavier model compute is covered in Stage 6.

**The discipline that protects this stage.** Scaling curves invite plausible narratives, so a falloff must be
attributed to a **measured** cause: located in the per-phase split before it is named; storage stall
distinguished from collective-communication overhead (a loss living in collectives says nothing about the
filesystem); latency distinguished from bandwidth (a growing dataload phase at low bandwidth is queueing, not
saturation, and the two have opposite customer implications); and never assumed to have the same cause on
both filesystems. This is the easiest place in the project to produce a confident, plausible, wrong
conclusion.

**A fairness detail worth mentioning if asked.** The reader configuration is **re-tuned per filesystem**
rather than copied, because the optimum reflects an interaction between decode concurrency and storage
latency — imposing one side's optimum on the other would be a fairness bug that reads as a filesystem
difference.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-5-Training.md`

---

## Stage 6 — Feature extraction & downstream MIL

**WSI context.** This is what 2024-onward production WSI research actually does: run a frozen foundation
model over every tissue tile of every slide to produce per-slide feature tensors, then train a lightweight
classifier on those features. We cover the three dominant open-weight models — **UNI2-h** `[PENDING-APPROVAL]`, **Virchow2**, and
**GigaPath**'s tile encoder — because production labs use them interchangeably depending on task and cancer
type, and because they span a useful range of compute weight, which changes the storage-to-compute balance.

> ⚠ **UNI2-h rows are internal-only** and carry a `[PENDING-APPROVAL-DO-NOT-EXTERNALIZE]` tag in the run
> notes. **Filter them out before any of this leaves the building.** Virchow2 and GigaPath carry no such
> restriction, which is also why Virchow2 carries most of the per-model cells.

**Four distinct I/O personalities, in four substages:**

- **6.A — Extraction.** Random tile reads at production rates with heavy GPU compute per step. Swept across
  GPU count on the cross-stage subset, then run at **full 1073-slide cohort scale**, then cross-checked on a
  second dataset from a different scanner vendor.
- **6.B — Small-file / metadata stress.** Random reads of many small per-slide feature files: no compute,
  pure metadata plus small-block I/O. A controlled synthetic corpus for scale, **and** a real attention-MIL
  classifier over the real extracted features for fidelity — both, because synthetic alone invites "not
  real" and real alone cannot reach controlled scale.
- **6.C — Concurrent multi-workload.** Ingest, extraction, MIL training, and viewer load **all at once** on
  one namespace, then sustained for hours.
- **6.D — End-to-end timing.** Composed from the measured per-phase numbers.

**Why 6.B and 6.C are structurally the most informative substages here.** Their axes — small-file metadata
behaviour and concurrent-workload fairness — are **not bandwidth-bound**, so they remain discriminating even
though raw bandwidth is expected to be client-capped. That is a statement about where information can live,
not a prediction about which filesystem wins.

**The measurement subtlety that matters most.** 6.B's headline cells must be genuinely **cold**, and there
are **two** caches to defeat, not one: the client's page cache, **and** the filesystem's own server-side
cache — which is comparable in size to the instance's RAM on a maxed FSx, and differs between the two
filesystems. A corpus sized to beat only client RAM could be cold on one side and partly warm on the other,
producing a **cache-size artifact that looks exactly like a filesystem difference.** So the corpus is sized
against both filesystems' cache sizes, one identical definition used on both legs, and "cold" is **recorded
as achieved, not asserted.**

**Related, and stated up front rather than discovered later:** the *real* feature corpus is small enough to
fit comfortably in instance RAM, so the real-MIL substage will be largely memory-served on **both**
filesystems after its first pass. That is what production looks like at that corpus size — but it means that
substage's headline is **MIL throughput, not storage bandwidth**; the cold storage number comes from the
synthetic corpus, which is deliberately sized past cache.

**Why 6.C includes pair and triple tiers, not just all-four.** They are what make an all-four result
*diagnosable*: without them, interference is a single number with no attributable cause. And retention is
measured against each filesystem's **own** solo baseline, because the question is how much each degrades its
own workloads under contention — the **retention percentages** are what compare across legs.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-6-Feature-Extraction.md`

---

## Stage 7 — Clinical inference deployment

**WSI context.** The deployment end of the pipeline: a clinician requests analysis of a slide, and a result
plus a heatmap must come back. What matters here is **latency and its behaviour under concurrency**, because
that is what a clinical SLA is written against — a different metric from every throughput number earlier in
the project.

**What we do.** Six sub-tiers covering the gaps no earlier stage touches: single-slide latency with a
per-phase breakdown (cold and warm, both data paths, three models); latency as concurrency scales from one to
many; the heatmap **write** workload across three output formats; a streaming "scanner → inference → heatmap →
viewer" loop plus read-after-write visibility; a clinical mixed workload sustained for hours; and a
cross-dataset check.

**Why this shape.** A conventional scaffold would split inference and viewer into separate stages, but most
of what those measure is already covered elsewhere in this project. Scoping to the genuine gaps keeps the
stage informative and its wallclock defensible.

**Two sub-tiers are especially interesting for this comparison**, because they probe **consistency and
fairness semantics rather than bandwidth**: how quickly a just-written file becomes readable by another
process, and how the filesystem behaves with four heterogeneous workloads competing. Two filesystems with
different metadata and locking architectures have no reason to behave identically there — and those axes
survive a client-capped bandwidth ceiling.

**Caveats to have ready.** Per-slide latency is likely dominated by GPU compute and heatmap rendering rather
than storage, so **each cell reports the filesystem's share of wallclock explicitly** — otherwise a slow cell
gets misread as a storage result on either side. The pyramidal-heatmap writer may itself be the bound rather
than storage, which is a legitimate finding but must be *stated* as one. The high-concurrency cells
deliberately oversubscribe the GPUs, so they measure storage and queueing rather than GPU throughput. And the
read-after-write measurement is **single-client** — writer and reader are processes on one instance; true
cross-client consistency would need a second instance, which is outside this study.

**Numbers.** `[PENDING]` **The comparison.** `[STORY PENDING RESULTS]`

**Deeper detail:** `runs/Stage-7-Clinical-Inference-Deployment.md`

---

## The synthesis — the actual deliverable

`[STORY PENDING RESULTS — this section is written after Leg B completes.]`

What it will contain, and why in this order:

1. **The head-to-head table**, stage by stage, with both asymmetries stated in the header rather than a
   footnote, and every bandwidth-capped cell flagged as instance-limited so it is not misread.
2. **Where the two architectures actually differ**, grounded in the axes that can differ under a
   client-capped ceiling: metadata, IOPS, small-file behaviour, concurrency, latency, consistency.
3. **What GPU-direct is worth**, decomposed into the filesystem effect and the transport effect using the
   both-modes-on-both-sides design from Stage 4 — so the number is attributable rather than merely observed.
4. **Cost, reported as a stated fact** alongside the configurations that produced it. *Open item to resolve
   before this is published:* the cost figure must either price in WEKA licensing or be explicitly labelled
   infrastructure-only. "We are cheaper" with licence excluded and unlabelled is the one claim a competitor
   could dismantle in a sentence.
5. **What we did not measure**, plainly: object/S3 access, SMB and NFS, multi-client scale-out, and any
   filesystem other than these two.

---

## Pointers

| For | See |
|---|---|
| The question, held-constant contract, both asymmetries, scope | `PROJECT-THESIS.md` |
| Stage map, per-leg plan, full decision log **D1–D16** | `runs/STAGES.md` |
| Per-stage methodology and audit trail | `runs/Stage-<N>-*.md` |
| How a cell is run and recorded; both canaries | `runs/README.md` |
| What each script does | `SCRIPT-TRACKER.md` |
| Where everything lives | `FILESYSTEM-MAP.md` |
| Provisioning the environment | `cloud-setup/NEW-CLOUD-SETUP.md` (walkthrough) + `SPINUP-CHECKLIST.md` (decisions) |
| Project rules | `CLAUDE.md` |
| Run history | `runs/INDEX.md` (auto-generated) |
