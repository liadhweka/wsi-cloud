# RESULTS — the cross-stage synthesis

**This document holds findings and what they mean.** It is the one place the WEKA-vs-Lustre story is told
across stages, and it is the repository's deliverable in prose form.

**It is written after results exist.** Nothing has been measured yet, so what follows is the contract this
document is written under — not an outline waiting to be filled. An empty section reserved for a finding that
does not exist is a placeholder, and placeholders rot.

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
