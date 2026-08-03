# Stage 1 — Ingest (scanner-to-storage), measured identically on both filesystems

> **STATUS — read first.** Nothing has run. Every number below is **`[PENDING]`**, and every
> interpretation section is **`[STORY PENDING RESULTS]`**. This doc records what we will do, in what
> order, with which tools, against which datasets, and **why** — not what we expect to find.
>
> **Every substage here runs twice: once on WEKA (Leg A), once on FSx for Lustre (Leg B), with
> everything else held constant.** The WEKA-vs-Lustre delta is the result. A single leg's numbers are
> half an unfinished comparison and must never be presented as final.
>
> **One substage is deliberately single-filesystem:** **1.8** (FSx-native S3 import) has no WEKA
> counterpart and is excluded from the head-to-head — see below.

For project-wide conventions and recording philosophy, see `../CLAUDE.md`. For the framing and fairness
contract, `../PROJECT-THESIS.md`. For the stage map, per-leg plan, and decision log **D1–D14**,
`STAGES.md`. For how to run a benchmark and recover from failures, `README.md`.

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

**The `% of ceiling` rule (D7 / Phase 0).** Throughput is block-size-dependent, so every downstream
"% of ceiling" divides by the Stage-1.0 cell at the **matching block size** — never a mismatched-block
ceiling, which would make a mid-block workload look artificially high or low.

---

## Recording approach (Stage 1-specific)

Standard `record-run.sh` infrastructure, with **per-filesystem source adapters** (`STAGES.md` **D12**).
Sources are split **Primary** (headline numbers and cross-source ratios) and **Diagnostic-only** (capture
for context, never presented as a throughput number). The split is mandatory and **differs per
filesystem** — using one side's table for the other produces confidently wrong numbers.

### Primary sources

| Source | What it captures | Applies to |
|---|---|---|
| **App-level** (fio JSON, `fpsync`/`aws` output) | Bytes moved, files transferred, app-reported throughput | Both — the customer-facing number |
| **`weka stats realtime`** | WEKA-side per-process bandwidth, latency, IOPS | WEKA leg |
| **Wire counters for the DPDK data path** | Wire-level traffic on the WEKA data plane | WEKA leg |
| **`/proc/fs/lustre` + `lctl get_param`** | Client-side per-OSC/MDC throughput, RPCs in flight, latency | Lustre leg |
| **CloudWatch per-OST/MDT metrics** | Server-side throughput and metadata ops | Lustre leg |
| **Client network counters** | The actual data path on a Lustre client (kernel LNet over TCP, or the EFA provider's counters when EFA-mounted) | **Lustre leg — primary here** |

### Diagnostic-only sources

| Source | Why diagnostic-only |
|---|---|
| Client network counters (`sar -n DEV`) — **WEKA leg only** | WEKA's DPDK data plane bypasses the kernel network stack, so these show control-plane traffic only. **On the Lustre leg these same counters are a PRIMARY** — this is the clearest example of why the adapter is per-filesystem. |
| `sar -d` per block device | Both filesystems are network filesystems; these counters are ~zero for the mount. Useful only to confirm we are *not* accidentally writing to the instance's local disk. |
| `sar -u` per-core CPU | On the WEKA leg, DPDK poll cores show ~100% busy regardless of load. Useful for "is there NEW load on top of baseline?", not for measuring the filesystem's work. |

### Cross-source canary — derived per filesystem, never ported

After every substage, verify the **Primary**-source numbers tell a physically consistent story. **The
relation itself differs per filesystem and must be derived, not assumed** (**D12**):

- **WEKA:** erasure coding sets a wire-vs-app write amplification determined by the EC scheme captured at
  provisioning; reads carry no equivalent amplification. Derive the expected ratio from the actual scheme.
- **Lustre:** data is striped across OSTs with no default erasure coding, so the relation follows from the
  **actual stripe layout** (`lfs getstripe`) plus replication settings — derive it from the layout in use,
  and record that layout per cell.

Diagnostic sources never participate in a ratio check. Disagreement means bugged infra and is fixed
before continuing. On an unattended chain, the canary **aborts the chain** rather than waiting to be seen.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. Every substage below is ⏳ on both filesystems.

### 1.0a — Synthetic upper bound, sequential write

| | |
|---|---|
| **Status** | ⏳ both legs — anchor first |
| **Tool** | `fio` (version recorded at run time) |
| **Source → Target** | host RAM → filesystem scratch (`$FS_MOUNT/benchmarks/fio-scratch/`) |
| **Methodology** | 5 block sizes (4K, 64K, 256K, 1M, 4M) × 7 concurrency levels (1–64 jobs) = **35 cells**. Each cell: steady state + ramp, libaio + `--direct=1` + `--unlink=1`, iodepth=1 (sequential-bandwidth recipe). |
| **Why this exists** | Anchors every real-data Stage 1 number against "what does this filesystem's write path absorb from this client, in isolation?" Without it, "real ingest = X GiB/s" is uninterpretable. It is also the **protocol-independent** ceiling that bounds any SMB stack layered on top. |
| **Why identical on both** | `fio` is filesystem-agnostic — same grid, same flags, same scratch layout, only `$FS_MOUNT` differs. This is the cleanest apples-to-apples cell in the project. |
| **Sweep driver** | `lib/sweep-stage1-seqw.sh` |
| **Aggregated output** | `s1.0a-seqw-summary.csv` — pivoted by `--fs` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` — per-filesystem relation derived per **D12** |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.0b — Synthetic upper bound, sequential read

| | |
|---|---|
| **Status** | ⏳ both legs — anchor first |
| **Tool** | `fio` |
| **Source → Target** | filesystem → host RAM |
| **Methodology** | Same grid as 1.0a (5 bs × 7 jobs = 35 cells), `--rw=read`, iodepth=1. fio creates files in a layout phase before the timed window. |
| **Why this exists** | The read counterpart to 1.0a. Ingest itself cares little about read-back, but **every later stage is read-dominated**, so the read ceiling is needed up front. Read-vs-write asymmetry is also architecturally informative: WEKA's erasure coding amplifies writes on the wire while reads are not amplified, whereas Lustre's striping behaves differently again — the shape of that asymmetry is a real difference between the two designs. |
| **Cache discipline (D13)** | Run **cold and warm** variants explicitly. A maxed FSx carries file-server cache RAM comparable to the instance's own, and WEKA caches too, so an unlabelled read number is ambiguous. Cache state is recorded per cell. |
| **Sweep driver** | `lib/sweep-stage1-seqr.sh` |
| **Aggregated output** | `s1.0b-seqr-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.0c — Synthetic upper bound, random write IOPS

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `fio` |
| **Source → Target** | host RAM → filesystem |
| **Methodology** | 3 block sizes (4K, 16K, 64K) × 7 concurrency = **21 cells**. iodepth=8 (IOPS recipe), `--rw=randwrite`. Same runtime/ramp as 1.0a/b. |
| **Why this exists** | Sequential and random writes hit the metadata path differently. Stage 2 (cataloging) and Stage 6 (feature extraction) write many small files to distinct paths — closer to random than sequential. **This is also the first cell that probes the metadata architectures against each other:** Lustre concentrates metadata on MDTs with independently provisioned metadata IOPS, while WEKA distributes it — a structural difference that a bandwidth test cannot see. |
| **Sweep driver** | `lib/sweep-stage1-randw.sh` |
| **Aggregated output** | `s1.0c-randw-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` — at small block sizes per-op overhead shifts the wire ratio away from the large-block value on both filesystems; derive per side rather than assuming the large-block ratio holds. |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.0d — Synthetic upper bound, random read IOPS

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `fio` |
| **Source → Target** | filesystem → host RAM |
| **Methodology** | Same grid as 1.0c (3 bs × 7 jobs = 21 cells), iodepth=8, `--rw=randread`. fio creates files in a layout phase before reads begin. |
| **Why this exists** | **The defining access pattern for Stage 5 (training).** A multi-GPU PyTorch DataLoader does exactly this: random small-block reads at high concurrency across many large WSI files. This ceiling directly bounds Stage 5, and random-vs-sequential read differential at a given block size is a structural property of each filesystem rather than a tuning artifact. |
| **Cache discipline (D13)** | Cold and warm variants, cache state recorded — most important here, since a small-block random working set is the easiest thing for a large file-server cache to absorb entirely. |
| **Sweep driver** | `lib/sweep-stage1-randr.sh` |
| **Aggregated output** | `s1.0d-randr-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.4 — Local NVMe scratch provisioning

| | |
|---|---|
| **Status** | ⏳ one-time environment prep per instance build (not a comparison cell) |
| **Tool** | `mdadm` + `mkfs.xfs` + fstab (via `sudo`, with explicit sign-off) |
| **Methodology** | The instance's local NVMe devices (2 × 1900 GB on `g6e.24xlarge` *(subject to change)*) in RAID-0 → XFS → mounted at `/data/local-nvme` with `noatime,nofail`, owned by the benchmark user. Subdirs: `conda-envs/ fpsync-source/ staging/ runs/`. |
| **Why this exists** | Prerequisite for 1.5: a bulk-copy benchmark needs a **local source comfortably faster than the filesystem's write ceiling**, or the source becomes the bottleneck and the cell measures the wrong thing. A smoke `fio` confirms that headroom before 1.5 runs. |
| **⚠ Ephemeral** | Instance store **dies with the instance** and is re-provisioned on every rebuild — including between legs. Nothing that matters may rest here (`CLAUDE.md` → Durability & backup). It is scratch, not storage. |
| **Held-constant note** | Because the instance is identical in both legs, the local tier is identical too — so 1.5's source is not a cross-leg variable. Re-run the smoke `fio` per build and record it, to prove that. |
| **Headline results** | `[PENDING]` (smoke `fio`, per build) |

### 1.5 — Bulk local→filesystem copy sweep (`fpsync`)

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `fpsync` (version recorded at run time) |
| **Source → Target** | `/data/local-nvme/fpsync-source/tcga-brca/` → `$FS_MOUNT/data/fpsync-target/n<N>/` |
| **Methodology** | TCGA-BRCA full corpus staged to local NVMe first via its own recorded prep run. Sweep: **`fpsync -n N` ∈ {1, 4, 16, 64}**, full corpus per cell, each cell writing to its own per-N subdir (cleaned pre-cell). Per-cell isolation via `record-run.sh`. |
| **Why this exists** | The clean write-path benchmark on **real WSI files** with no WAN in the way — the closest analogue to the scanner-to-storage workflow labs actually run. Comparison against the synthetic 1.0a ceiling shows how much of each filesystem's write capability is reachable with real files and real metadata operations rather than a single scratch stream. The concurrency grid spans the saturation curve: `n=1` is single-stream-bound; `n=16/64` tests whether per-worker overhead caps below the storage ceiling. |
| **Why identical on both** | Same corpus (byte-verified from S3), same `-n` grid, same defaults, same target layout. Only `$FS_MOUNT` differs. |
| **Sweep driver** | `lib/sweep-stage1-fpsync.sh` · **Aggregator** `lib/aggregate-stage1-fpsync.py` (1-D on `n`, pivoted by `--fs`) |
| **Aggregated output** | `s1.5-fpsync-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.6 — Mixed concurrent ingest + read

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `fpsync` (concurrent ingest) + `fio` (concurrent read), driven by a per-cell wrapper inside `record-run.sh` |
| **Source → Target (write side)** | `/data/local-nvme/fpsync-source/tcga-brca/` → `$FS_MOUNT/data/fpsync-target/mixed/` (cleaned per cell) |
| **Source → Target (read side)** | `$FS_MOUNT/benchmarks/fio-scratch-mixed/` (pre-staged real files, verified non-sparse) → `/dev/null`, `fio` random reads, libaio `direct=1` |
| **Methodology** | **Fixed** ingest at a moderate `fpsync -n` chosen as a realistic "scanner pace" with headroom (the exact `-n` is set from each leg's own 1.5 curve, so both sides sit at a comparable *fraction* of their own write ceiling rather than an identical absolute rate). **Swept** read: `--rw=randread --iodepth=8`, `bs ∈ {4K, 64K} × jobs ∈ {1, 4, 16, 64}` = 8 cells. Read scratch pre-staged **once** per leg so each cell exercises only the random-read pattern. |
| **Why this exists** | **Operationally the most realistic Stage 1 cell.** Two customer questions at once: *while a scanner feeds at moderate pace, can pathologists pan/zoom existing slides at viewer-acceptable latency?* (→ read p99 at low `bs`/`jobs`) and *does heavy reader load throttle the scanner?* (→ `fpsync` app-level bandwidth across the read sweep). The "no second tier needed" pitch only holds if both sides survive concurrent stress — and whether the two filesystems degrade differently under mixed load is exactly the kind of QoS difference a bandwidth test cannot surface. |
| **Why the fixed side is a fraction, not an absolute** | Pinning both legs to the same absolute ingest MB/s would load them unequally if their write ceilings differ — the slower side would be nearer saturation and look worse for a reason that has nothing to do with mixed-workload behaviour. Holding the *fraction* constant isolates the QoS question. **Both the fraction and the resulting absolute rate are recorded per cell**, so either view can be reconstructed. |
| **Sweep driver** | `lib/sweep-stage1-mixed.sh` · **Aggregator** `lib/aggregate-stage1-mixed.py` (captures read-side `fio` **and** write-side `fpsync` bytes) |
| **Aggregated output** | `s1.6-mixed-summary.csv` (PENDING) |
| **Headline results — read side under concurrent ingest** | `[PENDING]` |
| **Headline results — write side under concurrent read** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` — see the mixed-workload canary note below |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.7 — S3 → filesystem hydration (the head-to-head ingest cell)

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `aws s3 sync` / `aws s3 cp` (version recorded at run time) |
| **Source → Target** | `s3://<bucket>/datasets/{tcga-brca,camelyon16}/` (same region) → `$FS_MOUNT/data/{tcga-brca,camelyon16}/` |
| **Methodology** | Full-prefix hydration at a swept `max_concurrent_requests`, byte-verified against the dataset manifest on completion. **Identical tool, identical flags, identical concurrency grid on both filesystems.** |
| **Why this exists** | This is how the datasets actually get onto each filesystem, so it is a real workload we are running anyway — and it is a legitimate large-write ingest measurement from a **same-region, high-bandwidth source**, which removes the WAN bottleneck that would otherwise dominate. It also doubles as the mechanism that makes the datasets a held-constant input (byte-verified identical bytes in both legs). |
| **Why the same method on both — load-bearing** | FSx offers a native S3 data-repository import that has no WEKA counterpart. Using it for Lustre and a plain copy for WEKA would compare **two different mechanisms**, not two filesystems. So the head-to-head cell uses plain `aws s3` on both sides, and FSx's native import is measured separately as **1.8**. |
| **Sweep driver** | *to be written — deferred to the cloud session (needs the real bucket, region, and IAM role)* |
| **Aggregated output** | `s1.7-hydrate-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` — note the client's network counters are a **primary** here on both legs, since the source traffic is S3 over the kernel TCP stack regardless of which filesystem is the target |
| **Head-to-head** | `[STORY PENDING RESULTS]` |

### 1.8 — FSx-native S3 import *(Lustre leg only — NOT head-to-head)*

| | |
|---|---|
| **Status** | ⏳ Lustre leg only |
| **Tool** | FSx for Lustre data-repository association / import |
| **Methodology** | Import the same S3 dataset prefixes via FSx's native linkage, recorded with the same harness as 1.7 so the two are directly comparable **within** the Lustre leg. |
| **Why this exists, and why it is excluded from the comparison** | It is a genuine Lustre capability with no WEKA equivalent, so reporting it as part of the head-to-head would be comparing a feature against its absence. But **omitting it entirely would understate Lustre**, which the fairness basis (**D7** — Lustre at maximum capability) forbids. So it is measured, labelled a **single-filesystem capability cell**, and presented as "what FSx can additionally do," never as a delta. |
| **Presentation rule** | Any chart or table containing 1.8 must visually separate it from head-to-head cells and state that no WEKA counterpart exists. |
| **Headline results** | `[PENDING]` |
| **Interpretation** | `[STORY PENDING RESULTS]` |

---

## Load-bearing engineering notes (carried into the scripts)

These are hard-won implementation details that cost real debugging time. They are recorded here because
losing them means rediscovering them.

**Aggregator must sum per-timestamp across client processes, not use a pre-aggregated mean.** A naive
aggregator that reads the parser's pre-aggregated filesystem-side metric can under-report by ~100×,
because that metric is a mean across **all** rows in the stats stream — including many idle server-side
rows that dilute the client's actual throughput. The correct pattern: **re-read the raw stats CSV, filter
to the client's own rows, sum across the client's processes per timestamp, then aggregate the per-second
sums.** Filter by a stable identity (hostname + role), **never** by a numeric process/node ID — those are
reassigned on reinstall.

> **Per-filesystem caveat:** the *pattern* generalises to both legs, but the *filter* does not — the WEKA
> and Lustre stats streams have different schemas and different notions of "the client's rows." Each
> leg's adapter implements the same pattern against its own source. **This is deferred to the cloud
> session**, which can see the real schemas.

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
| `aws` CLI | record at run time | pip/system | 1.7, and the one-time dataset staging into S3 |
| `mdadm`, `mkfs.xfs` | system | system | 1.4 |
| `record-run.sh` | live | `lib/record-run.sh` | every substage |
| `parse-results.py` | live | `lib/parse-results.py` | every substage |
| `aggregate-sweep.py` | live | `lib/aggregate-sweep.py` | 1.0a–d |
| `weka stats realtime` | record at run time | system | every substage (WEKA leg recording) |
| `lctl`, `lfs` | record at run time | Lustre client | every substage (Lustre leg recording) |

## Datasets used in Stage 1

| Dataset | Source | Size | License | Used in |
|---|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | GDC Data Portal → staged once into our S3 bucket | ~1.05 TiB (1133 slides) | Open access | 1.5, 1.6, 1.7 |
| CAMELYON16 | `s3://camelyon-dataset` (`us-west-2`, CC0) → staged once into our S3 bucket | ~710 GiB (1197 `.tif`) | CC0 | 1.7 |

Both are **held-constant inputs**, byte-verified identical in both legs (`STAGES.md` **D6**).

## Decision log (Stage 1-scoped)

- **2026-07-31 — Dataset staging is a one-time pre-leg step into S3, not a per-leg comparison cell.**
  *Why:* a WAN download measures an external service and a network link, not a filesystem; running it
  per-leg would spend hours producing a number about neither side, and risks putting different bytes on
  the two filesystems. Staging once makes the datasets a byte-verified held-constant input.
- **2026-07-31 — The head-to-head ingest cell is S3 → filesystem hydration (1.7) using the same tool and
  flags on both sides.** *Why:* it is a real workload we run anyway, it removes the WAN bottleneck via a
  same-region source, and using the identical mechanism on both sides is what makes it a filesystem
  comparison rather than a mechanism comparison.
- **2026-07-31 — FSx-native S3 import is measured but excluded from the head-to-head (1.8).** *Why:*
  including it would compare a feature against its absence; omitting it would understate Lustre, which
  **D7** forbids. Measured, labelled a single-filesystem capability cell, never presented as a delta.
- **2026-07-31 — 1.6's ingest side is pinned to a *fraction* of each leg's own write ceiling, not to an
  absolute rate.** *Why:* an identical absolute rate would load the two sides unequally if their ceilings
  differ, confounding the QoS question with a saturation difference. Both the fraction and the absolute
  rate are recorded so either view is reconstructible.
- **2026-07-31 — SMB ingest explicitly out of scope on both filesystems.** *Why:* see the protocol-scope
  caveat — the infrastructure is out of scope, and the two SMB paths would not be architecturally
  comparable (WEKA has a native SMB stack; Lustre would need a gateway), so it would introduce an
  asymmetry we could not hold constant.
- **2026-07-31 — Synthetic-first sequencing retained.** *Why:* real-data numbers need an
  isolated-storage anchor or they are uninterpretable, and every downstream "% of ceiling" divides by a
  **block-size-matched** 1.0 cell.
- **2026-07-31 — `fio` recipe grounded in each vendor's current performance-testing guidance at run
  time** (libaio + `--direct=1`; sequential grid at iodepth=1; IOPS grid at iodepth=8). *Why:* recipes and
  recommended flags change between versions, and `../CLAUDE.md` forbids quoting them from memory —
  re-confirm against the live docs before the first cell.
- **2026-07-31 — Cold-vs-warm is explicit on every read cell (1.0b, 1.0d, 1.6 read side).** *Why:* per
  **D13**, both filesystems carry substantial cache and they cache differently, so an unlabelled read
  number is ambiguous and the ambiguity is asymmetric.

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage 1 roadmap created for the WEKA-vs-Lustre comparison. Substages restructured: WAN cloud-ingest cells replaced by one-time S3 staging plus the **1.7** S3→filesystem head-to-head cell; **1.8** added as a Lustre-only capability cell; 1.0a–d, 1.4, 1.5, 1.6 retained with per-leg framing. Recording section rewritten around per-filesystem source adapters and a per-filesystem canary derivation. Load-bearing engineering notes (per-timestamp client summing, mixed-workload canary bands, process-group kill) carried forward with per-filesystem caveats. All numbers `[PENDING]`; all interpretation `[STORY PENDING RESULTS]`. |

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem source adapters, durability
- `../PROJECT-THESIS.md` — the question, the held-constant contract, both deliberate asymmetries
- `STAGES.md` — stage map, per-leg plan, decision log **D1–D14**
- `README.md` — operational runbook: how to run a cell, both canaries, failure recovery
- `../SCRIPT-TRACKER.md` — per-script reference for `lib/`, including deferred cloud-session TODOs
- `../FILESYSTEM-MAP.md` — where the mounts, S3 prefixes, datasets, and scratch live
- `INDEX.md` — append-only run history (auto-generated)
- Each run dir's `0_README.md` — auto-generated description of that specific run
