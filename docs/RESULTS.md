# RESULTS — the cross-stage synthesis

**This document holds findings and what they mean.** It is the one place the WEKA-vs-Lustre story is told
across stages, and it is the repository's deliverable in prose form.

**It is written after results exist.** Leg A (WEKA) is complete through every substage; Leg B (FSx for
Lustre) has not run. What follows is the contract this document is written under, then the per-stage record
of what Leg A established — **single-leg findings, recorded plainly and claimed narrowly** (`../PROJECT-THESIS.md`
§10), with the head-to-head delta and the cost-to-complete comparison assembled here once Leg B's numbers
exist. Headline costs come from the publication-time reprice; per-cell as-run prices are already recorded.

---

## The rule that keeps this document honest

**Numbers live in exactly one place.** Per-cell results belong in the stage roadmap, beside the methodology
that produced them. This file quotes only a **headline figure with a pointer to the cell it came from**, and
**never reproduces a per-cell table.**

*Why:* two copies of a number drift, and the stale one is invisible — it looks exactly like the current one.
A pointer cannot go stale in that way; at worst it dangles, which is visible.

## What each finding must carry

- **The number, and the cell it came from** — stage, substage, and the run-dir name.
- **Both filesystems, or an explicit statement that only one leg has run.** A single leg's numbers are half an
  unfinished comparison (`../PROJECT-THESIS.md` §10). Present them as strong but incomplete, leave explicit
  room for the other leg, and say that the consolidated comparison is built later. This is not a licence to
  soften the numbers — record them plainly; it is the *claim* that stays scoped.
- **Both asymmetries, stated on the page** (`../PROJECT-THESIS.md` §5). A reader's first question is what the
  other side was running; the answer must already be there.
- **The cost to complete, in both recorded bases** — infra-only and all-in, each named where quoted, with
  the software input's asymmetry stated per **D7** (FSx software-inclusive; WEKA at the dated public
  Marketplace rate) — alongside the throughput or latency figure it belongs to. It is the figure the buyer
  actually faces, and the only place the provisioning asymmetry stops being a caveat and becomes arithmetic.
  Which basis leads the writeup is a writing-time choice made with both present. **Headline costs come from
  the publication-time reprice** (`../PROJECT-THESIS.md` §4; `../prompts/prompt-reprice-at-publication.md`):
  one fresh dated snapshot applied to both legs' recorded wallclocks, with the as-run prices retained per
  cell as provenance.
- **Which axis was decisive, as a finding.** No metric was designated primary in advance, so what turned out
  to discriminate between the two architectures is itself a result worth stating.
- **The caveats that change how the number is read** — cache state achieved, the I/O path proven, whether the
  cell was client-bound, and which sources were quoted.

## Provisioning fairness — the statement every externalized form carries

This is contract-level framing, recorded so it is **stated, not discovered by a reviewer**. The ruling
decisions are **D7** (fairness basis), **D15** (per-filesystem core accounting), **D20** (the WEKA backend
configuration), and `../PROJECT-THESIS.md` §5.1/§9. It is written per §10: recorded facts and design
rationale only.

**Neither filesystem is the artificial constraint, and on the WEKA leg that is verifiable arithmetic from
recorded data.** The backends' aggregate sustained network capability is **300 Gbps** (8 × i8ge.6xlarge at
37.5 Gbps sustained each, captured at spin-up — `STAGES.md` **D20**), against a client whose physical line
rate is **200 Gbps** (environment contract `per_client_ceiling_gbps`, basis instance-line-rate) and whose
demonstrated storage draw peaked at **~11.0 GiB/s ≈ 94 Gbps** of reads (the 1.0b large-block plateau,
`Stage-1-Ingest.md`) and **8.48 GiB/s app-level writes ≈ 106 Gbps on the wire** after the measured 5+2 EC
amplification (1.0a peak × the calibrated 1.456 relation). **The floor multiples: ~3.2× the demonstrated
read demand, ~2.8× the highest measured write demand (larger still at every other point of the write
grid), 1.5× the physical NIC.**

**The denominator is not circular.** The obvious rejoinder — "the client's 'demonstrated capability' was
measured against these very backends, so if they were the constraint the multiple computes itself" — is
refuted by recorded attribution evidence: the band-calibration read cells deliberately read just-written,
**backend-RAM-resident** files, taking the drives out of the path entirely, and sustain **10.85–10.88
GiB/s** on this cluster (`runs/2026-08-16-03*-calib-seqr-*`; an attribution use of diagnostic cells, not a
storage-performance quote) — statistically the same rate as the cold 1.0b plateau. The same client config
hits the same ceiling with and without the storage media in the path, so the plateau belongs to the client
stack, not the backends.

The Lustre leg's floor follows from the same **D7** rule at provisioning — tier maximum, with per-TiB
throughput × capacity clearing the client's line rate — verified against fetched, dated figures in that
leg's contract before its first cell, and quoted here in the same form once they exist. **Floors are
compared against demonstrated client demand on both legs**, and on the Lustre side there is no sizing
judgment left to attack at all: the tier is the maximum purchasable (**D7**), so the only floor question
there is arithmetic, not a choice we made.

**The aggregate and capacity asymmetries between the two backends are deliberate and stated.** The WEKA
leg's 300 Gbps / 67.46 TB usable (**D20**) and whatever the D7-maximum FSx configuration provides at
provisioning are not matched to each other and are not meant to be: both are **unreachable at single-client
scale**, both are **priced into their leg's recorded per-cell cost inputs**, and they follow from D7's
asymmetric bases — Lustre at maximum capability, WEKA at a realistic production configuration — with
cost-to-complete carrying the difference as arithmetic rather than caveat.

**Why the floor points this way — the objection, preempted.** "Shouldn't the client exceed the filesystem
under test?" That inversion is correct for an **aggregate-capability** benchmark, which this is not
(`../PROJECT-THESIS.md` §9): the unit of analysis is the **per-client experience** — the pathology
workstation, the inference node, the unit that scales. So the filesystems are sized to never be the
artificial constraint, and **the client's ceiling is not a purchasing artifact but a property of the
filesystem under test**: the same physical instance peaks differently under each client stack — a
reserved-core DPDK data path on WEKA versus a kernel-thread EFA client on Lustre — and that difference,
with its CPU cost (**D15**'s core accounting) and its dollar cost (**D7**'s cost inputs), is part of what
is being measured. With both backends floored above client capability, a cross-leg delta can only mean the
client-side architectures deliver differently — which is the buyer's question.

**The client's WEKA-side configuration is itself on the realistic-production basis:** 4 FRONTEND cores,
with their hyperthread siblings excluded from application accounting (`FS_CLIENT_RESERVED_CORES`, **D15**)
— a production-shaped choice that is **priced and recorded, not hidden**. A larger FE reservation would
raise the client's own ceiling, which is exactly why the reservation is reported as part of WEKA's cost
and the measured-versus-documented ceiling is quoted beside the results (**D7**). **The citable basis for
4 cores** (fetched 2026-08-19): WEKA's `num_cores` defaults to 1, but the vendor's own performance
documentation states *"if the client uses a 100 Gbps NIC or above, mounting the WEKA filesystem with more
than one core is required to maximize client throughput"* [docs.weka.io → performance tests], and in
VF-based configurations *"num_cores usually matches the number of configured network devices"*
[docs.weka.io → mount filesystems] — this deployment configured **4 network devices, hence 4 FRONTEND
cores** (environment contract `weka_client_cores`/`weka_client_nics` = 4/4), i.e. 4 of 48 physical cores
≈ 8% reserved: neither the bare default (documented as unable to maximize a ≥100 Gbps client) nor a
benchmark-special maximum, but the documented pairing rule applied to the deployed network layout. **The
Lustre client reserves nothing by design** — no core reservation exists anywhere in FSx's documented
client model; its tuning surface is RPC/LRU/statahead parameters [docs.aws.amazon.com → FSx Lustre
performance, performance tips; fetched 2026-08-19] — which is exactly the client-architecture asymmetry
**D15** prices rather than hides.

## The GPU-direct statement (whitepaper-facing, per §10)

**At single-client scale on this project's instance class (`g6e.24xlarge`), neither stack offers a true
GPU-direct path — a simplification of the story, and itself a quotable finding.** WEKA-over-ENA:
**measured** — Leg A's Phase-0 cell (strict-GDS open refused; every byte bounced, from cuFile's own
accounting) and 20/20 Stage-4.C cells recording `gds_engaged=none`. FSx-over-EFA: **documented platform
constraint** — GDS requires a P5/P5e/P5en/P6-B200 client instance
[docs.aws.amazon.com → FSx for Lustre → EFA-enabled file systems; checked 2026-08-20], and the
held-constant client is not in the set; EFA itself (and its per-client-cap escape) is unaffected. Leg B's
per-cell path accounting verifies the expectation rather than assuming it; a contradiction would be a
finding. Consequence for the reader: the kvikIO comparison between the legs is **compat-vs-compat — an
identical code path on both sides** — and the cuFile-mode axis (kvikio-POSIX vs cuFile-bounce) is a real
two-path measurement on both legs, not a GDS proxy.

## What must never appear here

- A figure quoted from a source the filesystem in use bypasses (`../PROJECT-THESIS.md` §7).
- A predicted outcome, an expected magnitude, or a narrative written before the measurement exists.
- A Leg-A result presented as though the comparison were finished — which will be tempting the moment Leg A
  produces good numbers.
- A UNI2-h number in anything that leaves the building, until the Mahmood Lab approval lands.

## Shape

One section per stage, in stage order, each in the same shape: what the stage asked, what the head-to-head
showed, the cost to complete, and the caveats. A consistent shape is what keeps the synthesis compressible as
it grows, and it makes a missing piece visible rather than merely absent.

**Losses get reported.** Provisioning Lustre at maximum raises the chance of them, and a weakness found here
is one a customer does not find later.

---

# The per-stage record — Leg A (WEKA)

Every figure below is one leg of an unfinished comparison and is claimed as such. Numbers are headlines with
pointers; the per-cell tables, methodology and full caveats live in the stage roadmap named in each section.
The third foundation model (UNI2-h) ran throughout Leg A alongside Virchow2 and GigaPath; **its numbers are
internal-only pending Mahmood Lab approval and are deliberately not reproduced in this document** — the
roadmap rows carry them tagged.

## Stage 1 — Ingest (`Stage-1-Ingest.md`)

**Asked:** what the scanner-to-storage path delivers — synthetic ceilings first (the denominators for every
downstream "% of ceiling"), then real files, mixed load, and cloud hydration. **Protocol scope caveat on the
page there: POSIX ingest only, no SMB** — read it before quoting any Stage-1 number outward.

- **Synthetic ceilings (1.0a–d):** app-level write peak **8.48 GiB/s** (64k; non-monotonic vs large blocks,
  recorded with its paired wire measurement) · read plateau **~11.0 GiB/s ≈ 94 Gbps** at 1M/4M — attributed
  to the client FE stack, not backends or network (**D10 trigger evaluated at leg close: does not fire**) ·
  random 4k: **519k write / 625k read IOPS** (read peak's D18 reps: 0.5% spread). 1.0a cells are single-shot
  (D18 knee/peak repeats not run — recorded caveat there).
- **Real-file bulk copy (1.5):** **2,402 MiB/s** at n=64, saturating from n=4 — **~44% of the 1M synthetic
  write ceiling**: per-file rsync/fpsync machinery bounds the path before the filesystem does.
- **Mixed ingest+read (1.6):** ingest holds its solo ~2,400 MiB/s through moderate concurrent read load,
  degrading only at the top of the read sweep (−21% at 4k jobs=64; −28% at 64k jobs=64 while readers pull
  6.2 GiB/s); viewer-class 4k reads hold **~2 ms p99 under full-rate ingest**; read-side wire relation REPORT_ONLY by declared construction (the 4.D-class read
  amplification under bulk write, up to 1.676 recorded).
- **S3 hydration (1.7):** full 1.79 TiB in **3,913 s at `max_concurrent_requests=16`** — S3-fetch-bound; the
  filesystem holds easy headroom at every concurrency, so this characterises the ingest *pipeline*.

## Stage 2 — Cataloging (`Stage-2-Cataloging.md`)

**Asked:** metadata/header-read behaviour at scale — the workload that hits open()/stat paths, not bandwidth.
**Headline:** knee at **n=64 on every curve**; BRCA 858 slides/s cold / **1,825 warm** at the knee, with the
**cold/warm gap ~1.5–2× everywhere** (dentry/attribute caches serve `open()` client-side — why the cold arms
drop caches at level 3). By design no ceiling-relative figure exists here, and filesystem-reported ops/s
stays within-leg until cross-leg counter semantics are verified equivalent (that stage's standing caveat).

## Stage 3 — Tissue detection (`Stage-3-Tissue-Detection.md`)

**Asked:** the 20× coord-generation pass that gates everything downstream — a real mixed compute/metadata
read workload. **Headline:** the full TCGA-BRCA cohort at n=64 in **105 s (10.77 slides/s)**, filesystem-side
ops sustained to **18.1k ops/s**; compute-leaning as designed (CPU 82–87% at n=64). **Completeness is the
integrity anchor:** 1131/1133 BRCA (two documented zero-tissue slides) + 399/399 CAM16, identical across all
n, captured as the `coords-3.0` fingerprint — the Leg-B coord-equivalence gate.

## Stage 4 — Patching / tile extraction (`Stage-4-Patching.md`)

**Asked:** the three tile-access strategies plus the raw-TIFF input generation — and the leg's GPU-direct
determination. **Headlines:**

- **4.A pre-extract:** peak **7,716 tiles/s** (CAM16 n=64); JPEG-encode CPU dominates at high n.
- **4.B on-the-fly reads:** **cuCIM 22,047 vs OpenSlide 12,895 tiles/s ≈ 1.7×** at each backend's own BRCA
  peak (D18 reps recorded: 4.0% / 10.7% spreads); decode CPU shapes the top of both curves on this leg.
- **4.C kvikIO grid:** **20/20 cells record `gds_engaged=none`** — the per-cell empirical half of the
  GPU-direct statement above. cuFile-bounce random peak **5.62 GB/s** (reps 0.5% spread) ≈ **49% of the
  block-size-matched read ceiling** single-reader; kvikio-POSIX caps at ~half its bounce peak and its top
  cell is ~40% page-cache-served (no O_DIRECT on that path — recorded, and why bounce is the quotable mode).
- **4.D raw-TIFF conversion:** BRCA full cohort **15.7 h at PARALLEL=4, 5.90 TB written** — decode-bound,
  write rates far under ceiling; origin of the leg's read-amplification finding class (workload read
  amplification 1.22–1.74 under concurrent write, later confirmed by the mixed-band calibration).

## Stage 5 — Training data pipeline (`Stage-5-Training.md`)

**Asked:** does the filesystem keep DDP ranks fed, and does the read path change training throughput?
**Headline:** kvikIO **1,038 → 3,695 samples/s** at N=1→4 (**92.4% / 89.0% scaling**), dataload **p99 ≈ p50
at every N — no storage tail**; the N=4 efficiency loss is DDP-collective time, not dataload. cuCIM runs
**1.55× slower at every N** with the whole gap in dataload — attributed to decode CPU, not storage (the
working set is page-cache-resident and the stall persists). No Stage-5 number is a storage-throughput figure.

## Stage 6 — Feature extraction, MIL, stress and QoS (`Stage-6-Feature-Extraction.md`)

**Asked:** the production foundation-model pipeline end-to-end, then storage-shaped stress, then QoS under
concurrent mixes. **Headlines:**

- **6.A extraction:** Virchow2 **971** / GigaPath **800** tiles/s at N=4 kvikIO (D18 rep spreads ≤1.7%);
  **kvikIO/cuCIM narrows to 1.10–1.13×** in the GPU-compute-bound foundation-model regime (vs Stage 5's
  1.55×); full-cohort cuCIM holds ~10% *above* subset rates; the multimodel chunked cell ran **26.1 h**
  (15.9 h convert / 10.3 h extract across all three models — the measured argument for conversion sharing).
- **6.B.1 corpus generation:** 6.08 TB / 236,500 files in **2,161 s** (fs-side write mean 2.81 GB/s, the
  3.0 TiB corpus at 3.17 GB/s; 335 files/s peak create rate).
- **6.B.2 file-IO stress:** genuinely cold 3.0 TiB corpus: **128 files/s = 6.4 GB/s of random 50 MB reads at
  n=64 ≈ 58% of the matched read ceiling**, plateauing beyond with p99 climbing to 11 s — past the knee added
  concurrency buys queueing; the cache-served saturation tier's constraint is host CPU, not storage.
- **6.B.3 MIL:** saturation knee at `num_workers=16` for all models (memory-served — MIL-throughput numbers,
  not storage bandwidth; the cold-pass storage signal is recorded separately).
- **6.C concurrent QoS:** **no workload loses more than ~11% under any mix and the filesystem is never the
  contended resource** — extract fully retained (100–102%), viewer worst case 89.1% (all-four while ingest
  is live) recovering to 96.5% in the endurance window, ingest undegraded.

## Stage 7 — Clinical inference deployment (`Stage-7-Clinical-Inference-Deployment.md`)

**Asked:** the customer-facing per-slide latency story under deployment-shaped load. **Headlines:**

- **Per-slide p50 ≈ 36 s (Virchow2), COLD ≈ WARM on both read backends** — inference latency is
  compute-dominated at ViT-H scale; the filesystem's share of the customer-facing number is ~5%, mostly the
  heatmap write. The Stage-5 read-path difference vanishes under per-slide latency.
- **N=4 is the deployment sweet spot:** p50 35.6 s (better than N=1), GPU 93.8%; higher N queues as designed
  — storage never approaches ceiling (fs-side reads peak ~198 MiB/s across the grid).
- **Heatmap formats span 119× in output size** (425 KB → 50.7 MB/slide); writer-bound, reported as renderer
  properties beside the fs-side rates.
- **Scanner-pace loop (7.4.a):** keeps up with a ~1,440-slides/day scanner on one GPU (queueing ~5 ms).
  **Read-after-write visibility (7.4.b): mean 0.61 ms, p99 1.07 ms** against a recorded 1 ms resolution
  floor — a just-written heatmap is readable by another process effectively immediately (single-client scope).
- **Full clinical mix + endurance (7.5):** inference p50 **36.50 s within ~2.5% of the uncontended baseline
  while ingest wrote 2.4 GiB/s concurrently**; 4-h endurance p50 drift **0.05%** — no QoS drift, no leak.
  The clinical-shaped QoS answer matches 6.C's training-shaped one.
- **CAM16/BRCA p50 ratio 1.06** — format-agnostic at the inference layer (7.6).
