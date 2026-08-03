# Project thesis — WEKA vs Lustre for the WSI pipeline, on AWS

> **Status: BUILD PHASE. No benchmark has run. Every number in this repo is `[PENDING]`.**
> This document defines what we are measuring and why. It deliberately contains **no findings, no
> predictions, and no customer story** — those follow the results, never the reverse.

---

## The question

**For a modern whole-slide-imaging / digital-pathology pipeline running on AWS, how does WEKA compare
to Lustre?** Both filesystems, both POSIX, both mounted by the *same* GPU instance running the *same*
workload against the *same* datasets. The deliverable is the head-to-head delta, stage by stage.

The pipeline is the real one, not a synthetic proxy: ingest → cataloging → tissue detection → patching
→ training → foundation-model feature extraction + MIL → clinical inference. Each stage stresses storage
differently — large sequential reads, random small-block reads, metadata storms, small-file corpora,
mixed concurrent load — and a storage comparison that only measures peak bandwidth answers almost none
of the questions a pathology platform team actually has.

## Why this is a fair comparison, and where it is deliberately not

The comparison holds one thing constant and varies one thing:

**Held constant** — the compute instance, the workload code, the datasets and their byte contents, the
magnification contract, the model set, the recording harness, the region and AZ.
**Varied** — the filesystem under the mount point.

Two asymmetries are real, deliberate, and stated up front rather than discovered later. Naming them is
what makes the result credible; hiding them is what would make it worthless.

### Asymmetry 1 — the transport, and GPUDirect Storage

The two filesystems reach the same instance NIC by different paths, because each vendor's own fast path
*is* different:

- **WEKA on AWS** uses DPDK over ENA — kernel-bypass, but ENA is not RDMA-capable, so the true
  GPU-direct path (NIC → GPU memory, no bounce buffer) is expected to be unavailable. *Expected*, not
  assumed: this is resolved empirically on the real client with `gdscheck -p` plus a recorded canary
  cell, not from documentation. WEKA's own materials claim GDS support on AWS; the transport analysis
  suggests compat-mode fallback. We measure it.
- **FSx for Lustre** supports GPUDirect Storage on EFA-enabled file systems with EFA-enabled clients,
  which is also what escapes a 5 Gbps-per-client-per-OSS cap.

**We do not drop the GPU-direct path to force symmetry.** We run it on both sides and let the difference
be part of the measurement — because it is precisely the choice a customer faces. `kvikIO`/cuFile runs on
WEKA in compat mode, so the *same application code* and the *same raw-TIFF artifact* execute on both
filesystems; only the underlying transport differs, which is the thing under test.

The measurement matrix, per applicable stage:

| | POSIX (native reads) | kvikIO / cuFile |
|---|---|---|
| **WEKA** | ✅ | ✅ (compat mode expected — verified per cell) |
| **Lustre** | ✅ | ✅ (true GDS over EFA) |

Both filesystems get a plain-POSIX cell as well as a kvikIO cell. This matters in both directions:
kvikIO-in-compat-mode stacks a bounce buffer and the cuFile layer on top of POSIX and may be *slower
than the filesystem's own native path*, so without the POSIX cell we would understate whichever side
falls back. Every cell records which path it actually took — cuFile's own accounting of GPU-direct vs
bounced bytes is a first-class recorded source, because a configuration flag is not proof of behavior.

### Asymmetry 2 — the provisioning basis

**Lustre is provisioned at maximum capability. WEKA is provisioned at a realistic production
configuration. Cost for both is reported alongside the results as a stated fact.**

*Why:* a win against a competitor's best configuration is worth far more than a win against one we
sized ourselves, and it forecloses the objection that whoever picked the tier picked the winner. It
also makes the cost comparison meaningful rather than circular. The asymmetry is stated in the headline
of every result — "WEKA at a typical production configuration vs FSx for Lustre at maximum" — because
the first question any skeptical reader asks is what the other side was running, and the answer has to
be already on the page.

"Maximum" is defined per axis, because one axis is capped by the client and the others are not:

| Axis | Maxed how | Note |
|---|---|---|
| Throughput tier | `PERSISTENT-1000` (top SSD tier: 1000 MBps/TiB disk, 2600 MBps/TiB network) | |
| Capacity | ≥ 25 TiB | At 1000 MBps/TiB, 25 TiB is where FSx disk throughput reaches the client's ~25 GB/s. Below that FSx is the constraint and any delta is a sizing artifact. |
| Metadata IOPS | User-provisioned, high (Persistent-2 allows up to 192,000, independent of capacity) | The axis where a maxed Lustre is most formidable — and where the comparison is most informative. |
| Network | EFA-enabled file system + EFA-mounted client | Also the GDS prerequisite, and what escapes the 5 Gbps-per-OSS cap. |

**Bandwidth is expected to be client-capped for both sides at ~25 GB/s (200 Gbps).** A tie on the pure
bandwidth cells would therefore reflect the instance, not either filesystem, and must not be presented
as a finding about either. The axes that respond to provisioning — metadata, IOPS, small-file behavior,
concurrency, latency — are where the comparison carries information.

WEKA must still be sized to clear ~25 GB/s so that it, too, is not the constraint. A "realistic
production configuration" that starves the client would produce a sizing artifact, not a finding.

*(Sources: [FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html),
[SSD storage performance characteristics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html).)*

## Sequencing — two legs, then a synthesis

**Leg A: WEKA.** **Leg B: Lustre.** **Then: the synthesis.** The legs run sequentially, not side by side,
because the WEKA cluster and the FSx file system are provisioned separately and the instance is rebuilt
between them.

This buys simplicity at the cost of a new risk: **the two legs must remain comparable across time.**
That risk is managed by an explicit **environment contract** — a machine-readable record written at the
end of Leg A (instance type, region/AZ, AMI ID, kernel, driver and CUDA versions, dataset byte-manifest,
script commit) that Leg B verifies against before its first cell. Without it, "were these two legs even
comparable?" becomes unanswerable at exactly the moment it matters most.

Within a leg, cells are chained and run unattended, including overnight. Four guards make that safe:
telemetry syncs to S3 *during* the run rather than only at the end; the consistency canary runs per-cell
and *aborts the chain* on failure rather than producing a night of contaminated cells; each cell has a
watchdog timeout; and the chain resumes from checkpoint rather than restarting.

## Results precede story

This project has no thesis about who wins. Every document here records **why we measure something the
way we do** — the methodology rationale, which is what makes a number evaluable — and records **nothing
about what the numbers will show**. Sections that will eventually carry interpretation are marked
`[STORY PENDING RESULTS]` and stay that way until the results exist.

Whatever the benchmark produces is what gets reported, including cells where WEKA loses. Provisioning
Lustre at maximum raises that possibility, which is the correct trade: a weakness found here is one a
customer does not find later.

**Each leg is half of an unfinished comparison.** WEKA-leg numbers mean little in a vacuum — their force
comes entirely from the head-to-head against Leg B. No Leg-A document may imply finality.

## Environment

All values below are **assumed and subject to change** — tracked in the
`weka-vs-lustre-cloud-open-decisions` memory, which indexes every place each one is referenced so that
firming one up is a single complete pass.

| | Value | Note |
|---|---|---|
| Compute instance | `g6e.24xlarge` *(subject to change)* | 96 vCPU, 768 GiB, 4× L40S (178 GiB), 200 Gbps, 2× 1900 GB NVMe, EFA-capable. Upgrade: `g6e.48xlarge` (8× L40S, 400 Gbps). Floor: `g6e.12xlarge` (100 Gbps). |
| WEKA deployment | Self-managed on EC2, provisioned via the company's Port blueprint *(subject to change)* | A managed/marketplace WEKA would be the closer counterpart to managed FSx — standing fairness caveat. |
| Lustre deployment | AWS managed **FSx for Lustre** *(subject to change)* | Could be self-managed Lustre on EC2; affects the recording adapter and the telemetry available. |
| Durable store | One private S3 bucket, same region | Datasets, raw telemetry, environment contracts. Makes teardown lossless — see `cloud-setup/SPINUP-CHECKLIST.md`. |

**Revisit trigger for the instance:** if Leg A's synthetic ceiling pins at line rate across block sizes
*and* the `num_workers` sweep saturates on CPU cores rather than storage, the instance is measuring
itself rather than the filesystem — move up before Leg B. Pre-committed here so the call isn't made
later under sunk cost.

## What carries over, and what does not

The WSI workload harness is filesystem-agnostic — Lustre is POSIX, as wekafs is — so the pipeline
scripts, the dataset manifests, the 20×-by-the-book magnification contract, the model set, and the
recording architecture all carry over unchanged. What is new is per-filesystem: the recording adapters
(each filesystem exposes different primary telemetry, and the cross-source consistency relation must be
re-derived per filesystem rather than assumed), the provisioning, and the tuning.

**Deliberately out of scope:** object/S3 access as a measured path; SMB and NFS; multi-client scale-out
(this is a single-client study); and any comparison against filesystems other than these two.

---

*Reading order for a fresh session: this file → `runs/STAGES.md` → the relevant `runs/Stage-<N>-*.md`.
For provisioning: `cloud-setup/SPINUP-CHECKLIST.md`.*
