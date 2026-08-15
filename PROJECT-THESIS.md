# PROJECT THESIS — WEKA vs Lustre for a whole-slide-imaging pipeline on AWS

**This document is the source of truth.** Everything else in this repository is aligned to it; where anything
disagrees, this file wins and the other thing is a bug. It defines **what we measure and why** — never what the
result will be, and never what happens to be true today.

---

## 1. The question

**For a whole-slide-imaging / digital-pathology pipeline on AWS, how do WEKA and Lustre compare — stage by
stage, across every axis we can measure, and at what cost to complete the same work?**

**Who it is for.** A platform team choosing the storage layer under a pathology AI pipeline. They are not
buying GB/s; they are buying the ability to run a pipeline within a time and a budget. So the comparison has to
answer both halves — how each filesystem behaves under each stage's access pattern, and what each configuration
costs to finish the job.

**Both are parallel filesystems built for HPC**, addressed over POSIX, running the same workload on the same
client. This is a genuine head-to-head, not a demonstration.

---

## 2. The comparison structure

**Two sequential legs, one workload, one client.**

| | |
|---|---|
| **Leg A** | WEKA, self-managed on EC2, mounted at `/mnt/weka` |
| **Leg B** | FSx for Lustre, managed, mounted at `/mnt/lustre` |
| Client | one GPU instance type, held constant across both legs |
| Pipeline | ingest → cataloging → tissue detection → patching → training → foundation-model feature extraction and MIL → clinical inference |

The legs run at **different times on a rebuilt instance** — the instance is deliberately destroyed between
them. That is the defining constraint of this project's methodology, and §3 is the response to it.

**Leg B's plan is provisional until Leg A's results exist.** Improving it from what Leg A taught us is the
point, not a deviation.

---

## 3. The held-constant contract

Exactly one thing changes between legs: **the filesystem under the mount point.**

**Held constant:** the compute instance (type, region, AZ, AMI) · the workload code (one script commit) · the
datasets and their byte contents · the magnification contract · the model set · the recording harness's metric
definitions.

**Varied:** the filesystem, its mount, its provisioning and tuning (§5), and **the telemetry sources
collected**, which are filesystem-specific by necessity (§7).

**Because the legs run at different times, this is enforced mechanically rather than by care.** A
machine-readable **environment contract** is written at the end of Leg A — instance type, region/AZ, AMI,
kernel, driver and library versions, dataset byte-manifest, script commit — and **Leg B verifies it before its
first cell.** Fields are split into those that **must match** and those **expected to differ** (everything
filesystem-specific, which is the variable under test); a verifier ignoring that split would either fail on
everything or catch nothing. **A mismatch is a fail-loud condition, not a footnote** — without it, "were these
two legs even comparable?" is unanswerable at exactly the moment it matters most.

An unrecorded fact is treated as **unverifiable, therefore failed**: a null cannot be shown to have matched.

---

## 4. Measurement: no metric is designated primary

**Every cell reports the full measurement set.** Throughput, operations per second, latency and its
percentiles, metadata rates, concurrency scaling, and wallclock — all of it, on every cell where it is
meaningful.

*Why nothing is designated primary:* **choosing the decisive axis in advance would be a prediction.** These are
two different architectures, and where they diverge is precisely what the project exists to discover. Naming a
headline metric up front pre-decides that, and it is story-before-results in the same way that pre-assigning a
winner is. **Which axis turns out to be decisive is a result.**

### Cost to complete — the derived comparative figure

**Cost and wallclock are measured on every cell, and cost-to-complete is calculated from them** — per cell and
per leg:

> **infra-only cost = (instance $/hr + filesystem $/hr) × measured wallclock**
> **all-in cost = (instance $/hr + filesystem $/hr + storage-software $/hr) × measured wallclock**

**Both figures are recorded per cell, on both legs** — record to maximum granularity, decide the presentation
at writing time. The software input is not symmetric, and the data says so instead of hiding it: FSx's service
rate is software-inclusive, so its `software_usd_per_hr` is **0 with that stated basis**; WEKA's is the
**public AWS Marketplace rate** (citable; a negotiated price is not), dated like every other price.

*Why this matters more than either input alone:* it is the figure the buyer actually faces, and it is the only
place where the deliberate provisioning asymmetry (§5) stops being a caveat and becomes arithmetic. "Lustre at
maximum versus WEKA at a realistic production configuration" is a fairness claim a skeptical reader can argue
with; *what each configuration cost to complete the same pipeline* is a number.

Prices are **fetched from the vendor's current pricing, never recalled, and stamped with the date checked** —
cloud prices change without notice, and a stale price silently rewrites the conclusion.

**Run-to-run variance is measured, not assumed away.** Cloud performance drifts — noisy neighbours, network
weather, allocation luck — and the two legs run days apart on rebuilt hardware, so a cross-leg delta must be
shown to exceed the noise before it is a finding. Three mechanisms, identical on both legs (STAGES.md
**D18**): a **fixed stability-canary pair** interleaved across each leg, whose spread is that leg's empirical
noise band — a delta is quoted only where it clears both legs' bands; **N=3 repeats of headline cells** (the
per-leg knee and pinned-peak cells, plus designated short headline cells), reported as median with spread; and
for long cells, a **split-window check** — first-half versus second-half agreement from the already-recorded
timeline — as internal stability evidence at zero added wallclock.

---

## 5. Two deliberate asymmetries, stated wherever results appear

A reader's first question is what the other side was running. The answer must already be on the page — naming
these is what makes the result credible.

### 5.1 Provisioning

**Lustre is provisioned at maximum capability. WEKA is provisioned at a realistic production configuration.
Cost is reported alongside both.**

*Why deliberately unequal:* beating a competitor's best configuration is worth far more than beating one we
sized ourselves, and a comparison that under-provisioned the other side would be worthless the moment anyone
looked. **Cost-to-complete (§4) is what keeps this honest** — the asymmetry is quantified rather than excused.

**Both sides must be sized so that neither is the constraint**, above what the client can drive. A filesystem
provisioned below the client's capability measures its own sizing rather than its architecture, and any delta
that follows is a sizing artifact. This is a **provisioning requirement**, not a prediction about results.

### 5.2 Transport and the GPU-direct path

Each filesystem is measured on its intended transport: **WEKA over DPDK, Lustre over EFA.** Both stacks have a
working lower-performance fallback that engages *without erroring* — a UDP-mode WEKA client, and a Lustre
client that mounts over TCP when the FSx-specific EFA client configuration is absent.

**A fallback transport is a stop, not a caveat.** It mounts cleanly, serves data, and reports plausible numbers
for a configuration this project decided not to measure; measuring first and flagging later spends the
wallclock and the money before anyone can act. Each leg's transport is **evidenced from the client's own
report** — never inferred from the mount options passed — and recorded per leg.

**The GPU-direct matrix runs both cuFile modes on both filesystems**, so the filesystem effect is separated
from the transport effect rather than confounded with it. The matrix is designed on the expectation that the
WEKA leg's transport does not support true GPU-direct and runs in compat mode; **a single Phase-0 cell confirms
that empirically before the matrix is committed**, because the vendor's materials and the transport analysis do
not agree, and one cell converts an assumption into evidence.

**Prove the I/O path per cell.** Record cuFile's own accounting of GPU-direct versus bounced bytes as a
first-class source. **A configuration flag is not proof of behaviour** — a cell that quietly fell back, or
quietly didn't, silently poisons the comparison.

---

## 6. Cold versus warm is an enforced axis

Both sides carry substantial cache — the client's own RAM, and each filesystem's server-side cache, which
differ between them. **Any warm cell risks measuring cache rather than storage**, and a corpus genuinely cold
on one side may be partly warm on the other, producing a **cache-size artifact that looks like a filesystem
difference.**

So: cache state is **recorded as achieved per cell, not asserted**; the mechanism for reaching a cold state is
determined and documented per filesystem, including whichever server-side component is outside our control on a
managed service; and where a corpus must exceed cache, it is sized against **both** filesystems' cache so that
one identical corpus definition serves both legs. Per-leg corpus sizes would break the held-constant contract
on exactly the substage most sensitive to it.

---

## 7. Recording is per-filesystem, because the primaries invert

"If it isn't recorded, it didn't happen." Re-running costs hours-to-days and real money; over-capture is cheap.
Per cell: raw tool output verbatim, run metadata, the exact configuration, results with context, and the cache
state achieved. **Time series, not point estimates** — capture the timeline and derive aggregates from it.

**A source that is bypassed for the path in use must never be quoted for a throughput, latency or IOPS
number.** This is the easiest way to publish a confidently wrong figure.

| | Primaries | Diagnostic only |
|---|---|---|
| **WEKA (DPDK over ENA)** | the filesystem's own statistics, app-level, and the wire counters for the DPDK path | kernel network counters and the block layer — both bypassed, so they under-report or read near zero; CPU-busy readings, since DPDK cores spin-poll regardless of load |
| **Lustre (FSx)** | the client's Lustre statistics, the service's own per-target metrics, app-level, **and the client's network counters — which ARE the data path here** | whichever of the above does not match the network layer actually in use; determine it, don't assume |

**Note the inversion:** the client's kernel network counters are *diagnostic* on the WEKA leg and *primary* on
the Lustre leg. "Never quote a bypassed source" cuts in opposite directions per leg, which is why the source
set is selected by filesystem rather than assumed.

**A consistency relation is derived per filesystem and never ported across.** WEKA's erasure coding implies a
specific wire-versus-application ratio, set by the scheme captured at provisioning. Lustre stripes across
targets with no default erasure coding, so its relation is different and must be derived from the actual stripe
layout. **Run the canary after every sweep** — disagreement means the instrumentation is wrong, and every
subsequent number depends on it, so fix it before continuing.

---

## 8. The filesystem is a dimension, not a fork in the code

One results tree. The filesystem appears as **`--fs {weka|lustre}`**, as a **segment in the run-directory
name**, and as a **field in each run's metadata**, so aggregators pivot on it and emit head-to-head comparisons
directly. Scripts resolve the mount through a variable derived from the leg, never a hardcoded path.

*Why one tree:* **the deliverable is the cross-filesystem delta**; separate trees would force every comparison
to be assembled by hand, and cross-leg drift is caught by the environment contract instead — made **visible**
rather than structurally prevented. *Why a variable:* a hardcoded mount makes a Lustre cell silently measure
WEKA, and the number looks correct.

---

## 9. Scope

**In scope:** WEKA versus FSx for Lustre, both over POSIX, across the WSI pipeline at the project's
magnification contract, on one client instance, with cost measured throughout.

**Out of scope:** any third filesystem or object/S3 access path; any comparison against results produced on
different hardware or different code. **This repository has one deliverable: the head-to-head synthesis.**

---

## 10. Framing

**Results precede story.** No document here may contain a predicted outcome, an expected magnitude, a
pre-assigned headline stage or metric, or a narrative built before the measurement exists. Keep the
**why-we-measure-it-this-way** — that is what makes a number evaluable, and in a competitive comparison every
choice is a place a skeptical reader looks for bias. Delete the **what-it-will-show**. An interpretation
section does not exist until there is something to interpret.

**Report losses.** Provisioning Lustre at maximum raises the chance of them, and a weakness found here is one a
customer does not find later.

**Each leg is half an unfinished comparison.** A single leg's numbers mean little in isolation; their force is
the head-to-head. Present single-leg findings as strong but incomplete, leave explicit room for the other leg,
and state that the consolidated comparison is built later. **This is not a licence to soften findings** —
record the numbers plainly; it is the *claim* that stays scoped. It is also what stops Leg A being published
alone, which will be tempting the moment Leg A produces good numbers.

**Write what is true and durable.** Not alternatives considered and dropped, not the state of things today, not
history. A document that must be updated to stay correct will eventually be wrong.

---

## 11. What would make this comparison invalid

Each of these produces a *plausible* number, which is what makes them dangerous.

1. A cell that ran against one mount while carrying the other leg's label.
2. A leg measured on a fallback transport — UDP for WEKA, TCP for Lustre.
3. Two legs whose environment contract was never written, or never verified.
4. A throughput, latency or IOPS figure quoted from a source that leg bypasses.
5. A cell whose cache state was asserted rather than recorded.
6. A GPU-direct claim resting on a configuration flag rather than on the recorded I/O path.
7. A cost figure built from a recalled or undated price.
8. Either side provisioned below what the client can drive, making the delta a sizing artifact.
9. A Leg-A result published as though the comparison were finished.
