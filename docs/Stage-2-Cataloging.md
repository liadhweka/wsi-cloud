# Stage 2 — Cataloging & metadata extraction, measured identically on both filesystems

> **Every substage runs twice — once on WEKA (Leg A), once on FSx for Lustre (Leg B)** — with
> everything else held constant. The delta is the result; a single leg is half an unfinished
> comparison.
>
> Stage 2 is **magnification-independent** (header/metadata only — no tiling, no pixel reads beyond
> the slide header), so the 20× contract (**D1–D5**) does not change a single Stage 2 cell.

For project-wide conventions and recording philosophy see `../CLAUDE.md`; for framing and the fairness
contract `../PROJECT-THESIS.md`; for the stage map and the decision register `STAGES.md`; for how to run
a cell and recover from failures `RUNBOOK.md`.

**Stage 2 reports no ceiling-relative figure, and no Stage-1 cell has to land before it.** `STAGES.md`
sequences 2.0 as self-contained — it needs only the datasets on the filesystem. *Why no denominator
exists:* Stage 1's synthetic ceilings (**1.0a–d**) are all **data-path** cells — sequential bytes (1.0a/b)
and random-read/write IOPS (1.0c/d). The project has **no synthetic metadata ceiling**, and 2.0's
discriminating quantity is an operation rate over per-file `open()`s, so dividing it by 1.0d's random-read
IOPS would put a metadata-operation numerator over a data-path denominator — precisely the mismatch the
project's block-size-matched "% of ceiling" rule exists to prevent.

**Scaling is normalised inside the stage instead:** against **2.0's own lowest-concurrency cell**, reported
as strong-scaling efficiency and the location of the saturation knee. That needs no external anchor, and it
is what a reader actually wants from this stage — how far each metadata architecture scales, and where it
stops. Absolute slides/sec and operation rates are reported alongside it, cross-leg per the comparability
caveat below.

**Noted, not adopted:** a synthetic metadata ceiling could be added as a Stage-1 cell, and there is a real
argument for it — a maxed FSx has **user-provisioned** metadata IOPS (**D7**), so a synthetic ceiling is the
only way to show whether 2.0 reached what was provisioned. **Not in scope**, and carried as an open question
rather than dropped (tracked in the open-items memory): it needs new tooling, and that tooling would have to
be validated on both filesystems before either leg could quote it.

---

## What Stage 2 measures

The **metadata-stress** workload — the stage that puts the two filesystems' metadata architectures on
identical work.

Real WSI pipelines need per-slide metadata — dimensions per pyramid level, MPP (microns per pixel),
magnification, scanner properties, ICC colour profile, vendor tags — for every slide in a dataset. This
feeds indexing, QC, pipeline routing, and PACS/LIMS integration. The I/O is **tiny per slide** (header
plus tile-offset tables, typically the first few MB plus a small footer) and **repeated across thousands
of files**, so the work the filesystem sees is dominated by per-file operations rather than by bytes
moved.

The customer pain point: legacy NAS metadata servers bottleneck on per-file `open()`, plateauing at modest
concurrency regardless of how many parallel readers you add, because a single metadata server is the
constraint. Both filesystems under test claim to remove that constraint, and they do it **differently**:

- **Lustre** concentrates metadata on dedicated **MDTs**, with metadata IOPS provisioned independently of
  capacity.
- **WEKA** distributes metadata across all backend containers, with no separate metadata tier to provision.

**The fairness basis (D7) is directly at stake here.** Lustre is provisioned with **user-provisioned high
metadata IOPS** rather than the capacity-derived default, precisely so that this comparison runs against
Lustre's best configuration. That provisioned configuration is recorded per cell.

---

## ⚠️ Scope caveat — read before presenting Stage 2 numbers

**Both legs measure POSIX cataloging via OpenSlide. Neither measures object-store cataloging** (S3 /
boto3 / s3fs). OpenSlide expects a filesystem path; against object storage you would need an `s3fs-fuse`
POSIX shim (adds latency to every metadata op), a pre-staged local cache (measures cache hit rate), or a
custom byte-range plugin. **Object access is out of scope for this project on both sides**
(`../PROJECT-THESIS.md` §9).

The methodology is deliberately **symmetric and backend-agnostic** — same datasets, same OpenSlide
version, same concurrency grid, same cold/warm arms, same per-slide unit of work, only `$FS_MOUNT`
differs. That symmetry is what makes the WEKA-vs-Lustre delta meaningful, and it would also let a third
backend be added later without redesigning the cell.

**When presenting, say "POSIX cataloging via OpenSlide" alongside the number**, and name which filesystem
and which provisioned configuration produced it.

---

## ⚠️ Cross-leg comparability caveat — which metrics are valid across filesystems

This is load-bearing for Stage 2 specifically, because much of its filesystem-side evidence is an
*operation count*.

- **App-level metrics ARE cross-leg comparable.** Slides/sec, total wallclock, per-slide latency
  distribution — these come from the extractor's own timing of identical work on identical files, so they
  are comparable across legs by construction.
- **Filesystem-reported `ops/s` is NOT automatically cross-leg comparable.** WEKA and Lustre count and
  report "operations" using **their own counter semantics** — what each counts as one op, and at which
  layer, is not guaranteed equivalent. The number of *syscalls* OpenSlide issues per slide is identical on
  both sides, but the number each filesystem *reports* need not be.
  → **Treat filesystem-reported ops/s as a within-leg diagnostic** (a scaling curve, a saturation knee, a
  sanity check that the workload is metadata-dominated), **never as a cross-leg figure**, unless counter
  semantics are explicitly verified equivalent and that verification is recorded. If they cannot be
  reconciled, say so and compare at app level.

This does not weaken the stage — the customer-facing question ("how fast can each filesystem catalogue my
dataset?") is answered at app level. It only forbids a specific invalid comparison. The verification is
tracked in the open-items memory (the counter-semantics item).

---

## Strategy framing

Stage 2 is intentionally **compact** — single-pass per cell, no looping.

- **Single-pass per cell.** Each cell processes the full dataset exactly once at a given concurrency, and
  reports "catalogued N slides in X seconds at concurrency C" — one robust number per cell rather than a
  rate derived over loops. *Why:* it matches how a real cataloging job runs (an operator triggers it and
  waits for completion), and it keeps the unit of work identical across legs.
- **Symmetric, backend-agnostic methodology** (see the scope caveat above).
- **2.1 (DSA / MongoDB) is deferred.** *Why:* DSA layers Girder + MongoDB on top of the file metadata the
  filesystem serves, so benchmarking it primarily measures Mongo's index efficiency and Girder's REST
  throughput — not the filesystem. That reasoning is filesystem-independent, so it stays deferred in both
  legs. Revisit only if a DSA-specific customer question arises.

---

## Recording — Stage 2's reading of the source table

The per-cell measurement set, the cost inputs, the operational source table and its per-filesystem split
live in `RUNBOOK.md`, which expresses `../PROJECT-THESIS.md` §7 and **D12** as the commands that produce
each stream. Stage 2 promotes and demotes nothing in that table. It resolves the table's compute
conditional, and it adds one restriction on how a Primary source may be used:

- **Compute matters here, so `sar -u` over application-available cores is quotable.** The concurrency grid
  deliberately runs past the client's core count, so distinguishing a client-CPU knee from a filesystem
  knee is part of what the cell measures — and a source that is only diagnostic may not be quoted for
  that. Read it per **D15**: the WEKA leg reserves cores for its DPDK data path and the Lustre leg does
  not, so the excluded core set differs and raw CPU% is not comparable across legs.
- **Filesystem-reported metadata operation counters are Primary on both legs per the base table, but
  within-leg only** until counter semantics are verified equivalent — see the comparability caveat above.

### Cross-source canary — the Stage 2 addition

The general rules and the per-filesystem consistency relation are in `RUNBOOK.md`. Stage 2 adds one
structural check: **filesystem-reported ops/s ÷ app-level slides/sec — i.e. operations per slide — should
be substantially greater than 1**, because each `openslide.OpenSlide(path)` triggers many internal
metadata operations (open, stat, several reads into header and tile-offset tables) rather than one. That
ratio is a property of *how OpenSlide opens a file*, so within a leg it is a good check that the intended
workload was measured — a large unexplained change means something other than the filesystem changed.

---

## Sub-second cells vs. 1 Hz recorders — DECIDED: raise the poll rate for short cells

**The issue.** At high concurrency, cells complete in well under a second. The 1 Hz filesystem-side
recorders then capture only 1–3 samples, and any sustained-mean metric is ill-defined with that few
samples — filesystem-side throughput/ops fields will read as zero or garbage. **This is a sample-rate
limit, not a recording failure.** The app-level measurement is unaffected, because it derives from
per-slide measurements (1133 BRCA / 399 CAMELYON16 per cell) regardless of cell wallclock.

**Why it matters more here than in a single-filesystem study.** The head-to-head wants filesystem-side
evidence on **both** legs. If both legs lose filesystem-side time-series at high concurrency, the
comparison there rests on app-level alone — acceptable, but it must be a stated choice rather than a
discovery made during analysis.

**The decision (ratified 2026-08-16): raise the recorder poll rate for short cells (~10 Hz), applied
identically on both legs.** *Why this option:* it keeps the single-pass methodology intact and yields
~3–30 samples where 1 Hz yields 1–3. The alternatives were rejected on methodology grounds: padding cells
by looping the dataset changes the unit of work away from "one pass, as an operator would run it," and
**makes cache state vary inside a single cell** — from pass 2 on, the corpus is warm whichever arm the cell
belongs to, so the cell has no one regime it can be labelled with, which **D13** and `RUNBOOK.md`'s pre-cell
canary both forbid (a warm *arm* is a whole cell whose regime is established before it runs; a cell that
warms partway through is an unlabelled average). Accepting app-level-only was the weakest evidence and would
concede the filesystem-side view on exactly the axis where the two metadata architectures differ most.

**Verification requirement:** the higher rate must be shown not to perturb the measurement itself — the
recorded `_sample_interval_s` block and a same-config 1 Hz-vs-10 Hz comparison on a cheap cell are the
evidence. **Implementation is tracker `D-34`** (`record-run.sh`'s recorder set) and must land before the
first Stage 2/3 cell.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All substages are ⏳ on both legs.

### 2.0 — OpenSlide property extraction sweep

| | |
|---|---|
| **Status** | ⏳ both legs |
| **Tool** | `openslide-python` + `libopenslide` (versions recorded at run time; per `openslide.org` and `github.com/openslide/openslide-python`) |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca/` + `$FS_MOUNT/data/camelyon16/images/` → `$FS_MOUNT/cataloging/2.0/<dataset>/n<N>/<slide-id>.json` |
| **Methodology** | **3-D sweep:** datasets ∈ {TCGA-BRCA full (**1133** SVS), CAMELYON16 (**399** `.tif` under `images/` — the actual scanned WSIs; the remaining `.tif` in the dataset are masks and background-tissue overlays, intentionally not catalogued)} × concurrency ∈ {1, 8, 64, 256} × cache arm ∈ {cold, warm} = **16 cells per leg**. Per cell: open each slide via `openslide.OpenSlide(path)`, dump `slide.properties` plus derived fields (`level_count`, `level_dimensions`, `level_downsamples`) as a JSON sidecar, time the operation. Concurrency via `multiprocessing.Pool(processes=N)` with persistent workers. **Single-pass per cell.** Sidecar dirs cleaned per cell. Per-slide latency archived as CSV into each run dir. |
| **Why this exists** | The metadata-stress measurement: how many slides/sec each filesystem's metadata path sustains on real WSI data at concurrency C, and where the saturation knee sits. This is the cell that puts Lustre's dedicated-MDT-with-provisioned-IOPS design against WEKA's distributed-metadata design on identical work. |
| **Why identical on both** | Same datasets (byte-verified), same OpenSlide version, same concurrency grid, **same cold/warm arms and the same client-side clearing steps**, same per-slide work, same output layout. Only `$FS_MOUNT` differs — plus the server-side clearing, which is not equally available on a managed service and is therefore recorded per leg rather than assumed equal. |
| **Concurrency grid rationale** | {1, 8, 64, 256} — log-spaced bookends of the saturation curve. Per-slide work is small, so the cell is latency-limited at low concurrency and the interesting saturation behaviour is at high parallelism. The grid intentionally extends past the instance's core count so that client-side oversubscription is visible as a distinct regime rather than confused with a filesystem limit. |
| **Cache discipline (D13)** | **An explicit cold/warm dimension — D13's route 3, and this is the stage that route was written for.** *Why this stage pays for the full axis where others do not:* cold-by-construction (D13 route 1) is unavailable here, because the read working set is only slide headers and tile-offset tables — the first few MB plus a small footer per slide, as described above — so across 1133 + 399 slides it is trivially resident in both the client's page cache and either filesystem's own, and no corpus definition drawn from these datasets can exceed them. The explicit axis is therefore the only route that separates the metadata path from the caches in front of it, and the whole sweep runs in minutes, so doubling it is cheap. Cold and warm arms over the same datasets × concurrency grid → **16 cells per leg**. **Client-side clearing uses `vm.drop_caches=3`, never `1`** — what each clearing step does and does not clear is tabulated once, in `RUNBOOK.md`. The reason it matters here is the reason this stage needs the axis at all: for a metadata workload the **dentry and attribute caches** are the relevant ones, and a warm dentry cache can serve `open()` entirely client-side — which makes 2.0 measure the client's VFS rather than either filesystem's metadata path, and does so **identically on both legs**, compressing exactly the difference the stage exists to find. **Server-side:** clear whatever each filesystem exposes, and state the residual uncertainty per leg — the server-side component is only partly ours on a managed service, so a cold arm is cold on the client side and best-effort beyond it. **Cell order randomised or reversed, never ascending in concurrency:** run ascending, the corpus warms monotonically with concurrency, and warming and concurrency then cannot be separated afterwards. **The JSON sidecars are output, not the read set:** the dataset directories are read-only and immutable, so nothing a cell reads was written by an earlier cell, and D13's "do not unlink and recreate between cells" does not bear on the per-cell sidecar cleanup. Cache state is **recorded as achieved per cell, never asserted**, in both arms. |
| **Magnification note** | **Magnification-independent** — cataloging reads only the header/metadata, does no tiling and no pixel reads at any magnification. |
| **Sweep driver** | `../scripts/sweep-stage2-properties.sh` |
| **Per-slide extractor** | `../scripts/extract-slide-properties.py` |
| **Aggregator** | `../scripts/aggregate-stage2-properties.py` — rolls the sweep's cells into the summary CSV as the dataset × concurrency × cache-arm grid, and the arm must be a column rather than a name fragment (standing constraint below). Its app-level columns are filesystem-agnostic; its filesystem-side columns read WEKA's telemetry schema, so on the Lustre leg they stay empty and the cross-filesystem view is assembled by hand until the per-filesystem adapter work lands. Interface and that deferral: `SCRIPT-TRACKER.md` (`D-4`) |
| **Aggregated output** | `s2.0-properties-summary-<leg>.csv` |
| **Recorded per cell** | slides catalogued and cell wallclock at that concurrency point; the per-slide latency distribution; the filesystem-side metadata operation rate (within-leg only, per the caveat above); the nominal concurrency and the effective parallelism; the dataset's on-disk layout; the **cache arm** the cell belongs to together with the clearing steps actually applied and what they are known to have cleared — plus the full measurement set, the cache state achieved, and the cost inputs (`RUNBOOK.md`) |
| **Directory-layout observation to record** | The hydrated layouts follow the S3 staging, which is what both legs read: **BRCA is one flat directory of 1133 SVS files** (the prefetch stages per-file GDC API pulls flat — not the per-slide subdirectories a `gdc-client` download would create), and **CAMELYON16's WSIs sit flat under `images/`** (399 files) beside sibling prefixes. Directory shape affects how many metadata operations an `open()` requires and how directory-entry lookup scales with entry count, so **the two datasets are reported separately and never averaged**, and the layout is noted alongside each number. The contrast the layouts actually offer is directory *size* (1133-entry vs 399-entry directories), not nesting depth. Identical on both legs by construction — both hydrate from the same S3 layout. |

> **How the driver implements the axis** (driver and aggregator moved together, deliberately). The 16 cells
> run in a **fixed, de-ordered (n, arm) sequence committed in the script** — identical on both legs, never
> ascending in concurrency. Cold cells run `vm.drop_caches=3` and write the acknowledgment (rc + output)
> into the run dir as `cache-evidence.txt` — the D13 achieved-evidence — and a failed drop **aborts the
> sweep** rather than mislabel a cell. Warm cells are warm **by construction**: an unrecorded n=64 warmup
> pass over the same dataset runs immediately before the cell, so the label never depends on what happened
> to run earlier. Each cell declares its arm via `RECORD_CACHE_STATE`, and the aggregator parses the arm
> from the run name as a first-class grid dimension keyed `(dataset, arm, concurrency)`. Every cell is
> attempted; the driver exits non-zero if any failed, so a chain sees the hole.

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
| `record-run.sh` | live | `../scripts/record-run.sh` | every substage |
| `parse-results.py` | live | `../scripts/parse-results.py` | every substage |
| `aggregate-stage2-properties.py` | live | `../scripts/aggregate-stage2-properties.py` | 2.0 |
| `weka stats realtime` | record at run time | system | WEKA leg recording |
| `lctl`, `lfs` | record at run time | Lustre client | Lustre leg recording |

## Datasets used in Stage 2

| Dataset | Source | Size | License | Used in |
|---|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | staged from S3, hydrated per leg (Stage 1.7) | ~1.05 TiB (1133 slides) | Open access | 2.0 |
| CAMELYON16 | staged from S3, hydrated per leg (Stage 1.7) | ~711 GiB (399 catalogued under `images/`) | CC0 | 2.0 |

Both are byte-verified held-constant inputs, identical in both legs (**D6**).

## Decision register (Stage 2-scoped)

- **Cross-leg comparison is made at app level; filesystem-reported ops/s is a within-leg diagnostic.**
  *Why:* the two filesystems count and report "operations" under their own counter semantics, so absolute
  ops/s is not guaranteed comparable across legs even though the syscalls OpenSlide issues are identical.
  App-level slides/sec measures identical work on identical files and is comparable by construction.
  Cross-leg ops/s may be quoted **only** if counter semantics are explicitly verified equivalent and that
  verification is recorded.
- **Scope: only 2.0; 2.1 (DSA/MongoDB) deferred on both legs.** *Why:* DSA measures its own stack and
  would add a large confound to a held-constant comparison.
- **Report both a single-throughput number and the scaling curve.** *Why:* the single number is the
  customer-quotable form; the curve is what shows where each metadata architecture saturates, and a peak
  figure on its own would hide a difference in the shape of that saturation.
- **No ceiling-relative figure; scaling is normalised against 2.0's own lowest-concurrency cell.** *Why:*
  the project's synthetic ceilings (1.0a–d) are all data-path cells and there is no synthetic metadata
  ceiling, so an operation rate over per-file `open()`s has no matched denominator — dividing it by 1.0d's
  random-read IOPS is exactly the mismatched-denominator error the block-size-matched "% of ceiling" rule
  exists to prevent. Strong-scaling efficiency plus the location of the saturation knee need no external
  anchor and answer what the stage is for; absolute slides/sec and operation rates are reported alongside.
  *Consequence:* 2.0 depends on no Stage-1 cell, which is how `STAGES.md` already sequences it. A synthetic
  metadata ceiling stays a live open question rather than a rejected one — it would be the only way to show
  whether 2.0 reached the metadata IOPS FSx was provisioned with (**D7**) — and is out of scope until new
  tooling exists and is validated on both filesystems.
- **OpenSlide only; not a tool comparison.** *Why:* OpenSlide is the literature standard (CLAM, UNI, CONCH
  all use it) and handles both formats (SVS, `.tif`). Adding a second reader would vary two things at
  once.
- **Both datasets, reported separately, never averaged.** *Why:* cross-vendor format diversity (Aperio SVS
  vs OME-TIFF) **and** different on-disk directory shapes (a 1133-entry flat directory vs a 399-entry
  `images/` directory — both flat at the slide level, per the hydrated layout), which changes the
  metadata-op profile per open. Averaging them would hide the layout effect, which is itself an axis of
  interest for a metadata comparison.
- **Concurrency grid {1, 8, 64, 256}, extending past the instance's core count.** *Why:* log-spaced
  bookends of the saturation curve, with the top point deliberately oversubscribed so client-side
  saturation is visible as its own regime and cannot be mistaken for a filesystem limit.
- **2.0 carries an explicit cold/warm dimension — 16 cells per leg, `vm.drop_caches=3`, cells de-ordered.**
  *Why the full axis here, where most stages take a cheaper route:* the read working set is slide headers
  and tile-offset tables only, so no corpus drawn from these datasets can exceed either side's cache and
  cold-by-construction (**D13** route 1) is simply unavailable; the explicit axis is the only thing that
  separates the metadata path from the caches sitting in front of it, and a stage that runs in minutes makes
  doubling it cheap. *Why `3` and not `1`:* dentries and inodes are the caches a metadata workload lives in,
  and a warm dentry cache serves `open()` client-side — which measures the client's VFS **identically on
  both legs** and compresses the very difference the stage exists to find. *Why cells are randomised or
  reversed:* in ascending concurrency the corpus warms with the swept variable, and warming and concurrency
  are then inseparable. Server-side clearing is best-effort per filesystem with the residual uncertainty
  stated, and cache state is recorded as achieved in both arms.
- **Single-pass per cell, not padded with loops.** *Why:* matches how a real cataloging job runs and keeps
  the unit of work identical across legs. **Known tradeoff:** sub-second high-concurrency cells
  under-sample the 1 Hz filesystem-side recorders — resolved by the short-cell poll-rate decision below.
- **Short cells get a raised filesystem-side recorder poll rate (~10 Hz), identical on both legs;
  implementation is tracker `D-34` and gates the first Stage 2 cell.** *Why:* the full rationale, the
  rejected alternatives (looping pads violate D13; app-level-only concedes the filesystem-side view where
  the metadata architectures differ most), and the perturbation-verification requirement are in the
  "sub-second cells" section above.
- **Output to a separate `cataloging/2.0/…` directory, not co-located with the slides.** *Why:* the
  canonical dataset directory is treated as read-only and immutable so that both legs read byte-identical
  inputs; sidecar output dirs are cleanly removable per cell.

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, cross-stage decision register
- `Stage-1-Ingest.md` — its load-bearing engineering notes carry the **per-timestamp client-summing
  aggregator pattern** this stage's aggregator reuses. **Not a ceiling for Stage 2:** 1.0a–d are data-path
  cells, and no Stage 2 figure divides by one
- `RUNBOOK.md` — per-cell measurement set, cost inputs, source table, both canaries
- `SCRIPT-TRACKER.md` — per-script reference and deferred cloud-session TODOs
- `../runs/INDEX.md` — append-only run history (auto-generated)
