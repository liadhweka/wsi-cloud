# Stage 2 — Cataloging & metadata extraction, measured identically on both filesystems

> **STATUS — read first.** Nothing has run. Every number below is **`[PENDING]`** and every
> interpretation section is **`[STORY PENDING RESULTS]`**.
>
> **Every substage runs twice — once on WEKA (Leg A), once on FSx for Lustre (Leg B)** — with
> everything else held constant. The delta is the result; a single leg is half an unfinished
> comparison.
>
> Stage 2 is **magnification-independent** (header/metadata only — no tiling, no pixel reads beyond
> the slide header), so the 20× contract (**D1–D5**) does not change a single Stage 2 cell.

For project-wide conventions and recording philosophy see `../CLAUDE.md`; for framing and the fairness
contract `../PROJECT-THESIS.md`; for the stage map and decision log **D1–D15** `STAGES.md`; for how to run
a cell and recover from failures `README.md`. The read ceilings Stage 2's "% of ceiling" divides by come
from `Stage-1-Ingest.md` (1.0b / 1.0d), **matched by block size** — those must land first.

---

## What Stage 2 measures

The **metadata-stress** workload, and the stage where the two filesystems' metadata architectures are
compared most directly.

Real WSI pipelines need per-slide metadata — dimensions per pyramid level, MPP (microns per pixel),
magnification, scanner properties, ICC colour profile, vendor tags — for every slide in a dataset. This
feeds indexing, QC, pipeline routing, and PACS/LIMS integration. The I/O pattern is **tiny per slide**
(header plus tile-offset tables, typically the first few MB plus a small footer) but **repeated across
thousands of files**, so the headline metric is **operations per second, not bytes per second**.

The customer pain point: legacy NAS metadata servers bottleneck on per-file `open()`, plateauing at modest
concurrency regardless of how many parallel readers you add, because a single metadata server is the
constraint. Both filesystems under test claim to remove that constraint, and they do it **differently** —
which is precisely what makes this stage informative:

- **Lustre** concentrates metadata on dedicated **MDTs**, with metadata IOPS provisioned independently of
  capacity.
- **WEKA** distributes metadata across all backend containers, with no separate metadata tier to provision.

**This is the stage most directly affected by the fairness basis (D7).** Lustre is provisioned with
**user-provisioned high metadata IOPS** — the axis where a maxed FSx is most formidable — precisely so
that this comparison is against Lustre's best configuration rather than a default one. That provisioning
choice is recorded per cell.

---

## ⚠️ Scope caveat — read before presenting Stage 2 numbers

**Both legs measure POSIX cataloging via OpenSlide. Neither measures object-store cataloging** (S3 /
boto3 / s3fs). OpenSlide expects a filesystem path; against object storage you would need an `s3fs-fuse`
POSIX shim (adds latency to every metadata op), a pre-staged local cache (measures cache hit rate), or a
custom byte-range plugin. **Object access is out of scope for this project on both sides**
(`../PROJECT-THESIS.md` § scope).

The methodology is deliberately **symmetric and backend-agnostic** — same datasets, same OpenSlide
version, same concurrency grid, same per-slide unit of work, only `$FS_MOUNT` differs. That symmetry is
what makes the WEKA-vs-Lustre delta meaningful, and it would also let a third backend be added later
without redesigning the cell.

**When presenting, say "POSIX cataloging via OpenSlide" alongside the number**, and name which filesystem
and which provisioned configuration produced it.

---

## ⚠️ Cross-leg comparability caveat — which metrics are valid across filesystems

This is load-bearing for Stage 2 specifically, because its headline metric is an *operation count*.

- **App-level metrics ARE cross-leg comparable.** Slides/sec, total wallclock, per-slide latency
  distribution — these come from the extractor's own timing of identical work on identical files. They are
  the head-to-head numbers.
- **Filesystem-reported `ops/s` is NOT automatically cross-leg comparable.** WEKA and Lustre count and
  report "operations" using **their own counter semantics** — what each counts as one op, and at which
  layer, is not guaranteed equivalent. The number of *syscalls* OpenSlide issues per slide is identical on
  both sides, but the number each filesystem *reports* need not be.
  → **Treat filesystem-reported ops/s as a within-leg diagnostic** (a scaling curve, a saturation knee, a
  sanity check that the workload is metadata-dominated), **not as a cross-leg headline**, unless counter
  semantics are explicitly verified equivalent and that verification is recorded. If they cannot be
  reconciled, say so and lead with app-level throughput.

This does not weaken the stage — the customer-facing question ("how fast can each filesystem catalogue my
dataset?") is answered at app level. It only forbids a specific invalid comparison.

---

## Strategy framing

Stage 2 is intentionally **fast** — single-pass per cell, no looping. The whole stage runs in minutes. The
compactness is part of the point: a metadata workload spanning an entire dataset either completes in
seconds or it does not.

- **Single-pass per cell.** Each cell processes the full dataset exactly once at a given concurrency. The
  headline is "catalogued N slides in X seconds at concurrency C" — one robust number per cell rather than
  a rate derived over loops. *Why:* it matches how a real cataloging job runs (an operator triggers it and
  waits for completion), and it keeps the unit of work identical across legs.
- **Symmetric, backend-agnostic methodology** (see the scope caveat above).
- **2.1 (DSA / MongoDB) is deferred.** *Why:* DSA layers Girder + MongoDB on top of the file metadata the
  filesystem serves, so benchmarking it primarily measures Mongo's index efficiency and Girder's REST
  throughput — not the filesystem. That reasoning is filesystem-independent, so it stays deferred in both
  legs. Revisit only if a DSA-specific customer question arises.

---

## Recording approach (Stage 2-specific)

Standard `record-run.sh`, with **per-filesystem source adapters** (**D12**). The Primary/Diagnostic split
is mandatory and differs per filesystem.

### Primary sources

| Source | What it captures | Role |
|---|---|---|
| **App-level** (per-slide elapsed time, slide count, per-slide success/fail) | OpenSlide-reported per-slide latency, total wallclock, slides/sec | **The cross-leg headline.** Comes from the extractor's own per-slide timing, so it is comparable across filesystems by construction |
| **WEKA `weka stats realtime` — `Ops/s`** | WEKA-side metadata operations per second | **Within-leg headline** for the metadata story — see the comparability caveat above |
| **WEKA `weka stats realtime` — `Read` + latency** | Client-side bytes/sec and per-op latency | Header reads are MB-scale per slide; cross-check against app-level latency |
| **Lustre `/proc/fs/lustre` + `lctl get_param`** (MDC stats, RPCs in flight) | Client-side metadata RPC counts and latency | Within-leg equivalent of the above |
| **Lustre CloudWatch MDT metrics** | Server-side metadata operations | Confirms the client's view against the service's own |
| **Wire counters for the path in use** | WEKA: DPDK-path counters. Lustre: client network counters (**primary on this leg**) | Cross-source consistency |

### Diagnostic-only sources

| Source | Note |
|---|---|
| `sar -u` per-core CPU | **Genuinely relevant here:** at high concurrency the bottleneck may shift from the filesystem's metadata path to client CPU (Python overhead, libtiff header parsing). Capture it to identify which side saturates. **Interpret per D15** — the WEKA leg reserves cores for DPDK, the Lustre leg does not, so raw CPU% is not directly comparable across legs |
| `sar -d` per block device | Both are network filesystems; expect ~zero for the mount. Only useful to confirm we are not accidentally hitting local disk |
| Client network counters — **WEKA leg only** | DPDK bypasses the kernel network stack, so this is control-plane only on that leg. **On the Lustre leg it is a primary** |
| `nvidia-smi` | No GPU work in Stage 2; captured for completeness, expected idle |

### Cross-source canary

Per **D12**, derived per filesystem, never ported. Within each leg: the filesystem-side byte counter
should track app-level read volume, and the wire counter should track it at the ratio implied by that
filesystem's architecture. Stage 2 adds one structural check: **filesystem-reported ops ÷ slides/sec
should be substantially greater than 1**, because each `OpenSlide.OpenSlide(path)` triggers many internal
metadata operations (open, stat, several reads into header and tile-offset tables) rather than one. That
ratio is a property of *how OpenSlide opens a file*, so within a leg it is a good check that the intended
workload was measured — a large unexplained change means something other than the filesystem changed.

---

## ⚠️ Open methodology item — sub-second cells vs. 1 Hz recorders

**The issue.** At high concurrency, cells complete in well under a second. The 1 Hz filesystem-side
recorders then capture only 1–3 samples, and any sustained-mean metric is ill-defined with that few
samples — filesystem-side throughput/ops fields will read as zero or garbage. **This is a sample-rate
limit, not a recording failure.** The app-level headline is unaffected, because it derives from per-slide
measurements (1133 BRCA / 399 CAMELYON16 per cell) regardless of cell wallclock.

**Why it matters more here than in a single-filesystem study.** The head-to-head wants filesystem-side
evidence on **both** legs. If both legs lose filesystem-side time-series at high concurrency, the
comparison there rests on app-level alone — acceptable, but it must be a stated choice rather than a
discovery made during analysis.

**Options, with a recommendation:**
1. **Raise the recorder poll rate for short cells** (e.g. 10 Hz) — keeps single-pass methodology intact
   and yields ~3–30 samples. *Recommended.* Cost: more rows; verify the higher rate does not itself
   perturb the measurement.
2. **Pad cells by looping the dataset to fill ≥30 s** — gives clean time series but changes the unit of
   work away from "one pass, as an operator would run it," and re-reads warm data (colliding with **D13**).
3. **Accept app-level-only for sub-second cells**, documented — simplest, weakest evidence.

**Resolve in the cloud session before the first Stage 2 cell**, and record the choice here. Whatever is
chosen must be applied **identically on both legs**.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All substages are ⏳ on both legs.

### 2.0 — OpenSlide property extraction sweep

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `openslide-python` + `libopenslide` (versions recorded at run time; per `openslide.org` and `github.com/openslide/openslide-python`) |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca/` + `$FS_MOUNT/data/camelyon16/images/` → `$FS_MOUNT/cataloging/2.0/<dataset>/n<N>/<slide-id>.json` |
| **Methodology** | **2-D sweep:** datasets ∈ {TCGA-BRCA full (**1133** SVS), CAMELYON16 (**399** `.tif` under `images/` — the actual scanned WSIs; the remaining `.tif` in the dataset are masks and background-tissue overlays, intentionally not catalogued)} × concurrency ∈ {1, 8, 64, 256} = **8 cells per leg**. Per cell: open each slide via `openslide.OpenSlide(path)`, dump `slide.properties` plus derived fields (`level_count`, `level_dimensions`, `level_downsamples`) as a JSON sidecar, time the operation. Concurrency via `multiprocessing.Pool(processes=N)` with persistent workers. **Single-pass per cell.** Sidecar dirs cleaned per cell. Per-slide latency archived as CSV into each run dir. |
| **Why this exists** | The metadata-stress measurement: how many slides/sec each filesystem's metadata path sustains on real WSI data at concurrency C, and where the saturation knee sits. This is the cell that puts Lustre's dedicated-MDT-with-provisioned-IOPS design against WEKA's distributed-metadata design on identical work. |
| **Why identical on both** | Same datasets (byte-verified), same OpenSlide version, same concurrency grid, same per-slide work, same output layout. Only `$FS_MOUNT` differs. |
| **Concurrency grid rationale** | {1, 8, 64, 256} — log-spaced bookends of the saturation curve. Per-slide work is small, so the cell is latency-limited at low concurrency and the interesting saturation behaviour is at high parallelism. The grid intentionally extends past the instance's core count so that client-side oversubscription is visible as a distinct regime rather than confused with a filesystem limit. |
| **Magnification note** | **Magnification-independent** — cataloging reads only the header/metadata, does no tiling and no pixel reads at any magnification. |
| **Sweep driver** | `lib/sweep-stage2-properties.sh` |
| **Per-slide extractor** | `lib/extract-slide-properties.py` (openslide-python + `multiprocessing.Pool`, persistent workers) |
| **Aggregator** | `lib/aggregate-stage2-properties.py` — 2-D dataset × concurrency grid, pivoted by `--fs`; per-filesystem source adapter for the metadata counters |
| **Aggregated output** | `s2.0-properties-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` |
| **Cross-source validation** | `[PENDING]` |
| **Head-to-head** | `[STORY PENDING RESULTS]` |
| **Directory-layout observation to record** | The two datasets have different on-disk layouts — BRCA is nested (one subdirectory per slide, as delivered by the GDC download), CAMELYON16 is flat. Directory structure affects how many metadata operations an `open()` requires, so **the two datasets are reported separately and never averaged**, and the layout is noted alongside each number. This is also a second axis of interest in its own right: whether the two filesystems are affected differently by directory nesting is a metadata-architecture question, and it is recorded rather than predicted. |

### 2.1 — DSA / MongoDB integration

| | |
|---|---|
| **Status** | ⏳ DEFERRED (both legs) |
| **Tool** | Digital Slide Archive → Girder + MongoDB (`digitalslidearchive.github.io`, `github.com/DigitalSlideArchive`) |
| **Why deferred** | DSA layers a heavyweight metadata-store stack on top of the file-level metadata the filesystem serves, so benchmarking it primarily measures **DSA's own** performance — MongoDB index efficiency, Girder REST handler throughput, and whatever volume Mongo's storage sits on. None of that discriminates between the two filesystems under test, and it would add a large confound to a comparison whose value depends on holding everything but the mount constant. **Revisit only if a DSA-specific customer question arises** (e.g. "how does DSA behave on top of each?"). For now 2.0's OpenSlide-direct numbers are the Stage 2 deliverable. |

---

## Tool inventory used in Stage 2

| Tool | Version | Source | Used in |
|---|---|---|---|
| `openslide-python` | record at run time | pip / conda | 2.0 |
| `libopenslide` (C library) | record at run time | system package | 2.0 (transitively) |
| `python3` | record at run time | conda env | 2.0 |
| `record-run.sh` | live | `lib/record-run.sh` | every substage |
| `parse-results.py` | live | `lib/parse-results.py` | every substage |
| `aggregate-stage2-properties.py` | live | `lib/aggregate-stage2-properties.py` | 2.0 |
| `weka stats realtime` | record at run time | system | WEKA leg recording |
| `lctl`, `lfs` | record at run time | Lustre client | Lustre leg recording |

## Datasets used in Stage 2

| Dataset | Source | Size | License | Used in |
|---|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | staged from S3, hydrated per leg (Stage 1.7) | ~1.05 TiB (1133 slides) | Open access | 2.0 |
| CAMELYON16 | staged from S3, hydrated per leg (Stage 1.7) | ~711 GiB (399 catalogued under `images/`) | CC0 | 2.0 |

Both are byte-verified held-constant inputs, identical in both legs (**D6**).

## Decision log (Stage 2-scoped)

- **2026-07-31 — App-level throughput is the cross-leg headline; filesystem-reported ops/s is a
  within-leg diagnostic only.** *Why:* the two filesystems count and report "operations" under their own
  counter semantics, so absolute ops/s is not guaranteed comparable across legs even though the syscalls
  OpenSlide issues are identical. App-level slides/sec measures identical work on identical files and is
  comparable by construction. Cross-leg ops/s may be promoted **only** if counter semantics are explicitly
  verified equivalent and that verification is recorded.
- **2026-07-31 — Scope: only 2.0; 2.1 (DSA/MongoDB) deferred on both legs.** *Why:* DSA measures its own
  stack and would add a large confound to a held-constant comparison.
- **2026-07-31 — Report both a single-throughput number and the scaling curve.** *Why:* the single number
  is the customer-quotable form; the curve is what reveals where each metadata architecture saturates, and
  the saturation *shape* may differ between the two designs even where peak numbers are close.
- **2026-07-31 — OpenSlide only; not a tool comparison.** *Why:* OpenSlide is the literature standard
  (CLAM, UNI, CONCH all use it) and handles both formats (SVS, `.tif`). Adding a second reader would vary
  two things at once.
- **2026-07-31 — Both datasets, reported separately, never averaged.** *Why:* cross-vendor format
  diversity (Aperio SVS vs OME-TIFF) **and** different on-disk directory layouts (nested vs flat), which
  changes the metadata-op count per open. Averaging them would hide the layout effect, which is itself an
  interesting axis for a metadata comparison.
- **2026-07-31 — Concurrency grid {1, 8, 64, 256}, extending past the instance's core count.** *Why:*
  log-spaced bookends of the saturation curve, with the top point deliberately oversubscribed so
  client-side saturation is visible as its own regime and cannot be mistaken for a filesystem limit.
- **2026-07-31 — Single-pass per cell, not padded with loops.** *Why:* matches how a real cataloging job
  runs and keeps the unit of work identical across legs. **Known tradeoff:** sub-second high-concurrency
  cells under-sample the 1 Hz filesystem-side recorders — see the open methodology item above, to be
  resolved before the first cell and applied identically to both legs.
- **2026-07-31 — Output to a separate `cataloging/2.0/…` directory, not co-located with the slides.**
  *Why:* the canonical dataset directory is treated as read-only and immutable so that both legs read
  byte-identical inputs; sidecar output dirs are cleanly removable per cell.

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage 2 roadmap created for the WEKA-vs-Lustre comparison. Methodology (2.0 sweep design, concurrency grid, single-pass, separate output dir, 2.1 deferral) retained with rationale restated. Added: per-leg framing, the metadata-architecture contrast (MDT-with-provisioned-IOPS vs distributed) and its link to **D7**, the **cross-leg comparability caveat** on filesystem-reported ops/s, per-filesystem recording adapters, the directory-layout axis, and the sub-second-cell open item. Removed all inherited results and outcome expectations. All numbers `[PENDING]`. |

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, decision log **D1–D15**
- `Stage-1-Ingest.md` — the synthetic ceilings (1.0b/1.0d) Stage 2's "% of ceiling" divides by, block-size matched; and the per-timestamp client-summing aggregator pattern this stage's aggregator reuses
- `README.md` — operational runbook and both canaries
- `../SCRIPT-TRACKER.md` — per-script reference and deferred cloud-session TODOs
- `INDEX.md` — append-only run history (auto-generated)
