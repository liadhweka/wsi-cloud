# Stage 3 — Tissue detection (the 20× coord generator), measured identically on both filesystems

> **STATUS — read first.** Nothing has run. Every number below is **`[PENDING]`** and every
> interpretation section is **`[STORY PENDING RESULTS]`**.
>
> **Every substage runs twice — once on WEKA (Leg A), once on FSx for Lustre (Leg B)** — with
> everything else held constant. The delta is the result.
>
> **Stage 3 is also the 20× coord generator.** 3.0 is the single place the 20× contract is implemented;
> its output coordinate lists gate all of Stages 4/5/6/7 **in both legs**.

For project-wide conventions and recording philosophy see `../CLAUDE.md`; framing and the fairness contract
`../PROJECT-THESIS.md`; stage map and decision log **D1–D16** `STAGES.md`; runbook `README.md`.

---

## What Stage 3 measures

The "find the tissue" workload. WSI pipelines cannot afford to process every tile of every slide — most
slide surface area is empty glass (typically 50–70%, sometimes 90%+ for needle biopsies). Step one of any
analysis is foreground segmentation: identify which tile coordinates contain tissue and store that as a
coordinate list for downstream stages to consume.

The standard approach, which we follow:
1. Read the lowest-resolution pyramid level (the thumbnail — a few hundred pixels per side).
2. Apply Otsu thresholding in HSV/LAB space, or a saturation threshold.
3. Morphological cleanup (open/close, to remove pen marks, air bubbles, dust).
4. Save a binary tissue mask plus the list of (x, y) tile coordinates containing tissue, as an HDF5 sidecar.

**The I/O profile per slide is small by construction, and the compute is not.** Per slide: read the header
and tile-offset tables (a few MB), read the lowest-level thumbnail (~0.5–2 MB), run Otsu plus morphology on
that thumbnail, write a small HDF5 (~10–100 KB). That is a property of the *algorithm*, not a prediction
about either filesystem: the segmentation cost is per-slide-thumbnail and does not scale with the number of
output tiles.

**What that makes Stage 3 useful for.** It is the counterpart to Stage 2's metadata stress — a workload
whose demand on storage is bounded by design while its demand on CPU scales with slide count. Together the
two stages bracket the pipeline's load profile: one leans on the metadata path, one leans on compute.
**Whether either filesystem becomes visible in Stage 3, and whether they differ, is `[STORY PENDING
RESULTS]`** — the recording is nearly free, so we measure rather than assume, and a result showing storage
materially busier than the algorithm implies would be a finding to chase, not noise to dismiss.

---

## ⚠️ Scope caveat — read before presenting Stage 3 numbers

**Both legs measure POSIX tissue detection via CLAM. Neither measures object-store access** — CLAM's
`create_patches_fp.py` and the underlying OpenSlide reads expect filesystem paths, and object access is out
of scope for this project on both sides (`../PROJECT-THESIS.md` § scope).

**Say "POSIX tissue detection via CLAM" alongside any Stage 3 number**, and name the filesystem and its
provisioned configuration.

---

## ⚠️ Cross-leg comparability caveat — CPU is not directly comparable across legs

Stage 3 is the first stage whose headline is a **CPU saturation curve**, which makes **D15** immediately
load-bearing here:

**The WEKA client reserves CPU cores for its DPDK data path; the Lustre client does not** (it works through
kernel threads). So the number of cores actually available to the application differs between legs, on the
same instance. Raw "CPU %busy" is therefore **not** a valid cross-leg comparison, and neither is
throughput-per-core computed against total cores.

**How this stage handles it (per D15):**
- Record **cores reserved by the filesystem client**, **cores available to the application**, and **total
  cores** for every cell, on both legs.
- The compute-saturation headline is computed over **application-available cores** on each leg.
- On the WEKA leg, the DPDK cores are excluded from the saturation interpretation, because they busy-poll
  independently of the application's compute. On the Lustre leg there is no equivalent set to exclude —
  **so the exclusion list is a per-filesystem adapter parameter, not a constant.**
- The reservation itself is reported as part of WEKA's cost, not hidden. Ignoring it would flatter WEKA on
  per-core efficiency; ignoring the fact that it exists would flatter Lustre on available parallelism.
  Reporting both numbers is the only honest option.

---

## Strategy framing

**CLAM's tissue detector is the literature standard** — the reference implementation whose HDF5 output the
UNI / CONCH / GigaPath / Virchow / TITAN foundation-model pipelines consume. Using it means:

1. Stage 3 output is **directly consumable by Stage 4** and onward to Stage 6 with no format conversion.
2. The methodology is comparable to published research benchmarks — anyone can reproduce it with stock CLAM.
3. CLAM's per-slide multiprocessing model provides the natural concurrency knob to sweep.

**Single-pass per cell** — the full dataset processed once per cell, no looping. Same rationale as Stage 2:
it matches how the job is really run and keeps the unit of work identical across legs. The sub-second-cell
recording limitation documented in `Stage-2-Cataloging.md` may apply at the top concurrency point;
whichever resolution is chosen there is applied identically here and on both legs.

**3.0 is the only Stage 3 substage.** There is no deferred sibling — CLAM tissue detection *is* the standard
approach, so there is no alternative tool worth a comparison cell.

---

## The 20× coord-space contract as implemented here

3.0 generates coords in 20× space, per dataset. Rationale and sources are **D1–D3**; implementation detail
is in `../SCRIPT-TRACKER.md`, grounded in `lib/sweep-stage3-tissue-detection.sh`.

- **CAMELYON16** (`.tif`, native 20× pyramid level): `--patch_level 1 --patch_size 256 --step_size 256` —
  read the native 20× level directly at 256 px, no resize.
- **TCGA-BRCA** (`.svs`, 40× base, no native 20× level): `--patch_level 0 --patch_size 512 --step_size 512`
  — coords step by a **level-0 footprint of 512 px**; downstream readers read 512 px @ 40× and **resize to
  256 px @ 20×** (exactly what CLAM's `custom_downsample` and Trident's `--mag 20` do internally).
- **For both datasets the level-0 coord step is 512 px** → the coord→raw-TIFF-tile divisor is 512, not the
  256 px tile width. Tiles are a **uniform 256 px @ 20×** across all three foundation models.
- **Magnification is keyed on mpp, not the `objective-power` tag.** A ground-truth scan established that the
  BRCA `openslide.objective-power` tag is unreliable — slides labelled 20× that are actually mpp≈0.25 (true
  40×). *Why it matters:* a true-20×-base slide read with the 40× args mis-tiles to **10×** (reads 512 px @
  20× → resize 256 = a 10× field of view) and halves its coord density. The 50-slide subsets used by Stage 4
  are 100% 40×-base by true mpp, so the BRCA args are correct for every subset slide; the full-BRCA set is
  handled by the uniform 1073-slide cohort (**D5**).

**Both legs consume the same coord definition.** The coords are regenerated per leg (they are written to the
filesystem under test, and generating them is itself the measured workload), and **a coord-equivalence check
between legs is a data-integrity gate** — see the completeness note in 3.0 below.

---

## Recording approach (Stage 3-specific)

Standard `record-run.sh`, with **per-filesystem source adapters** (**D12**).

**Stage-3 promotion:** per-core CPU is promoted to a **primary** source here, because the saturation curve
is the headline. Interpret it per **D15** and the comparability caveat above — the set of cores excluded
from the interpretation is a per-filesystem parameter.

### Primary sources

| Source | What it captures | Role |
|---|---|---|
| **App-level** (CLAM per-slide elapsed time + tile-coord count) | Per-slide detection time, total wallclock, slides/sec, tiles per slide | **The cross-leg headline** — identical work on identical files |
| **`sar -u` over application-available cores** | Compute saturation curve as concurrency rises | **Primary for Stage 3.** Core set is per-filesystem (**D15**); reserved client cores excluded on the WEKA leg |
| **Filesystem-side read bytes** (WEKA `Read`; Lustre `/proc/fs/lustre` OSC read) | Client-side bytes/sec | Small by construction; recorded to establish what the workload actually asks of storage |
| **Filesystem-side operation counters** (WEKA `Ops/s`; Lustre MDC RPC counts) | The open + read pattern | The load-bearing **within-leg** cross-source check, since byte rates are too small to be reliable at 1 Hz. **Not a cross-leg metric** — see `Stage-2-Cataloging.md` comparability caveat |
| **Filesystem-side write bytes** | HDF5 output volume | Small (~10–100 KB/slide); confirms the write side is not a factor |
| **Wire counters for the path in use** | WEKA: DPDK-path counters. Lustre: client network counters (**primary on that leg**) | Cross-source consistency |

### Diagnostic-only sources

| Source | Note |
|---|---|
| `sar -u` over filesystem-reserved cores — **WEKA leg only** | DPDK cores busy-poll independently of application compute. Recorded, but never read as "the application's CPU" — and per **D15** their count is reported as part of WEKA's cost |
| `sar -d` per block device | Network filesystems; expect ~zero for the mount. Confirms we are not hitting local disk |
| Client network counters — **WEKA leg only** | Control plane only on that leg (DPDK bypass). **Primary on the Lustre leg** |
| `nvidia-smi` | CLAM tissue detection is CPU-only; captured for completeness, expected idle |

### Cross-source canary

Per **D12**, derived per filesystem. Within each leg: wire counters track the filesystem-side byte counter
at that filesystem's expected ratio; the application-available-core saturation curve flattens at the
concurrency knee; and CLAM's reported per-slide time reconciles with `slide_count × per-slide cost ÷
concurrency` as a basic accounting check. **At Stage 3's small byte rates the operation-count curve is the
load-bearing check**, since per-second byte values are too small to ratio reliably at 1 Hz.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete. All substages are ⏳ on both legs.

### 3.0 — CLAM tissue detection sweep (the 20× coord generator)

| | |
|---|---|
| **Status** | ⏳ both legs — runs early in each leg (gates 4/5/6/7) |
| **Tool** | CLAM `create_patches_fp.py` (`github.com/mahmoodlab/CLAM`, commit recorded at run time). Deps: openslide-python, libopenslide, opencv-python, h5py, numpy, pandas, matplotlib, tqdm — versions captured by `record-run.sh` |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca/` and `$FS_MOUNT/data/camelyon16/images/` → `$FS_MOUNT/tissue-detection/3.0/<dataset>/n<N>/{patches/<slide-id>.h5, masks/<slide-id>.jpg}` |
| **Methodology** | **2-D sweep:** datasets ∈ {TCGA-BRCA full, CAMELYON16 (`.tif` under `images/`)} × concurrency ∈ {1, 8, 64} = **6 cells per leg**. CLAM has no concurrency flag, so concurrency is external: the slide manifest is round-robin split into N symlink-dir chunks and N parallel `create_patches_fp.py --source chunk<i> --save_dir <cell-dir> --seg --patch <PATCH_ARGS>` instances run, all writing to one per-cell save dir (collision-free because round-robin guarantees no two chunks share a slide). **Per-dataset 20× `PATCH_ARGS`** as specified above. `--stitch` deliberately omitted — its visualization output is not consumed downstream, and skipping it keeps the cell's cost concentrated on segmentation. **Single-pass per cell.** |
| **Why this exists** | Two purposes at once. (1) It is **the 20× coord generator** — the single implementation point of the contract that governs Stages 4–7, so it must run before them in each leg. (2) It is the compute-leaning counterpart to Stage 2's metadata stress, measuring what each filesystem is asked for by a workload whose I/O is bounded by design. |
| **Why identical on both** | Same CLAM commit, same per-dataset args, same chunking scheme, same concurrency grid, same datasets. Only `$FS_MOUNT` differs. |
| **Concurrency grid rationale** | {1, 8, 64} — a log-spaced 3-point grid is sufficient to resolve a compute-leaning saturation curve. The top point is chosen relative to the instance's core count so that saturation is reached without thrashing; per **D15** the *effective* parallelism differs between legs because the WEKA client reserves cores, and both the nominal `n` and the available-core count are recorded per cell. |
| **20× effect on this stage** | The tile *count* per slide changes with magnification, but the dominant segmentation cost is Otsu + morphology **on the thumbnail**, which is magnification-independent — so 20× changes what Stage 3 *emits*, not primarily what it costs. The reduced tile count propagates downstream as smaller inputs for Stages 4–7. Actual runtime `[PENDING]` — recorded, not estimated. |
| **Sweep driver** | `lib/sweep-stage3-tissue-detection.sh` |
| **Aggregator** | `lib/aggregate-stage3-tissue-detection.py` — application-available-core CPU headline (reserved-core exclusion list as a per-filesystem parameter, **D15**) plus per-timestamp client-summed filesystem counters; pivoted by `--fs` |
| **Aggregated output** | `s3.0-tissue-summary.csv` (PENDING) |
| **Headline results** | `[PENDING]` — to fill in per cell: compute-saturation curve over application-available cores (sustained + peak across n ∈ {1, 8, 64}, both datasets), throughput (slides/sec), filesystem-side read bytes and operation counts, 20× tiles per slide, output completeness |
| **Cross-source validation** | `[PENDING]` — expect noisy byte-ratio checks at Stage 3's small per-second volumes; the operation-count curve is the load-bearing check. If a byte-based canary trips on a short cell, treat it as the sub-second sampling limit documented in `Stage-2-Cataloging.md`, not as a consistency failure — and record that judgement rather than silently widening the band |
| **Head-to-head** | `[STORY PENDING RESULTS]` |
| **Expected-completeness note — the zero-tissue DX2 slides** | Two BRCA slides — **`TCGA-A7-A0CD-01Z-00-DX2`** and **`TCGA-A7-A6VX-01Z-00-DX2`** — are known to yield no tissue contours under CLAM's default segmentation parameters (`sthresh=8`). Both are DX2 (secondary diagnostic) slides, typically sparser than DX1 primaries. They open cleanly via OpenSlide; CLAM reports zero contours to process and writes no `.h5` because there are no coordinates. **This is real CLAM behaviour given the slides and the default parameters — not a benchmark failure, and independent of both storage and magnification.** Production CLAM workflows tune segmentation per slide; we accept the resulting completeness rate and record it. |
| **Coord-equivalence gate between legs (data integrity)** | Because the completeness rate and per-slide tile counts are **storage-independent**, they double as a **data-integrity check across legs**: for a given dataset and concurrency, the set of slides producing coords and the tile count per slide should be **identical on WEKA and on Lustre**. A divergence means the two legs did not process the same inputs — different bytes, a truncated hydration, or a different CLAM commit — and is a **fail-loud condition that invalidates downstream comparison**, not a curiosity. Run this check before consuming 3.0 output in Stage 4 of the second leg. |

---

## Tool inventory used in Stage 3

| Tool | Version | Source | Used in |
|---|---|---|---|
| `CLAM` (`create_patches_fp.py`) | commit recorded at run time | `git clone github.com/mahmoodlab/CLAM` | 3.0 |
| `openslide-python` | record at run time | pip / conda | 3.0 (via CLAM) |
| `libopenslide` | record at run time | system package | 3.0 (transitively) |
| `opencv-python`, `h5py`, `numpy`, `pandas` | record at run time | conda env | 3.0 (via CLAM) |
| `record-run.sh` | live | `lib/record-run.sh` | every substage |
| `aggregate-stage3-tissue-detection.py` | live | `lib/aggregate-stage3-tissue-detection.py` | 3.0 |
| `weka stats realtime` | record at run time | system | WEKA leg recording |
| `lctl`, `lfs` | record at run time | Lustre client | Lustre leg recording |

## Datasets used in Stage 3

| Dataset | Source | Scope | License | Used in |
|---|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | hydrated per leg (Stage 1.7) | full cohort | Open access | 3.0 |
| CAMELYON16 (`images/` only) | hydrated per leg (Stage 1.7) | the scanned WSIs, excluding masks/annotations | CC0 | 3.0 |

Byte-verified held-constant inputs, identical in both legs (**D6**).

## Decision log (Stage 3-scoped)

- **2026-07-31 — Tool: CLAM `create_patches_fp.py`.** *Why:* literature standard; its HDF5 coord output is
  directly consumable by Stages 4–6 with no conversion; reproducible with stock CLAM by anyone checking our
  numbers.
- **2026-07-31 — Per-dataset 20× args** (CAMELYON16 `--patch_level 1 --patch_size 256`; TCGA-BRCA
  `--patch_level 0 --patch_size 512 --step_size 512`). *Why:* matches the published foundation-model
  protocol and keeps the level-0 coord step at 512 px for both datasets, so the coord→tile divisor is
  uniform. Full rationale and sources in **D1–D3**.
- **2026-07-31 — Magnification keyed on mpp, not the `objective-power` tag.** *Why:* the tag is
  demonstrably unreliable on BRCA, and a mis-keyed slide silently mis-tiles to 10× and halves its coord
  density — a correctness bug that would propagate into every downstream stage on both legs.
- **2026-07-31 — Both datasets, reported separately.** *Why:* vendor-format diversity (Aperio SVS vs
  OME-TIFF) at modest extra runtime; and their differing directory layouts affect metadata-op counts, which
  should not be averaged away (mirrors the Stage 2 decision).
- **2026-07-31 — Concurrency grid {1, 8, 64}.** *Why:* a 3-point log-spaced grid resolves a compute-leaning
  saturation curve; a fourth higher point would mostly measure thrashing. Per **D15**, effective parallelism
  differs across legs because the WEKA client reserves cores, so both nominal `n` and available cores are
  recorded.
- **2026-07-31 — `--stitch` omitted.** *Why:* the stitched visualization is not consumed by any downstream
  stage, and including it would add per-cell cost unrelated to what the stage measures.
- **2026-07-31 — Per-core CPU promoted to primary, computed over application-available cores.** *Why:* the
  saturation curve is the headline for this stage, and honesty about what is being measured requires
  excluding cores that busy-poll independently of application compute. **The exclusion set is a
  per-filesystem parameter (D15), not a constant** — this is the clearest case in the project where a
  recording detail cannot be shared between legs.
- **2026-07-31 — Single-pass per cell.** *Why:* matches Stage 2, matches how the job is really run, keeps
  the unit of work identical across legs. Sub-second-cell sampling limits are handled by the resolution
  chosen in `Stage-2-Cataloging.md`, applied identically to both legs.
- **2026-07-31 — Output to a separate `tissue-detection/3.0/…` directory.** *Why:* the canonical dataset
  directory stays read-only so both legs read byte-identical inputs; per-cell output dirs are cleanly
  removable.
- **2026-07-31 — Coord equivalence between legs is a fail-loud data-integrity gate.** *Why:* completeness
  and per-slide tile counts are storage-independent, so any cross-leg divergence proves the legs did not
  process identical inputs — which would invalidate every downstream comparison. Cheap to check, and it
  catches a class of error (partial hydration, wrong commit) that is otherwise invisible until the numbers
  look strange.

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage 3 roadmap created for the WEKA-vs-Lustre comparison. Methodology (CLAM tool choice, per-dataset 20× args, mpp-keying, chunked concurrency, `--stitch` omission, single-pass, separate output dir, CPU-promoted-to-primary) retained with rationale restated. Added: per-leg framing, the **D15** CPU-comparability caveat and per-filesystem core-exclusion parameter, the **coord-equivalence data-integrity gate** between legs, and per-filesystem recording adapters. Removed all inherited results, wallclock estimates, and outcome expectations; the compute-vs-storage characterisation is now stated as a property of the algorithm, with visibility of either filesystem left `[STORY PENDING RESULTS]`. |

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, decision log **D1–D16** (esp. **D1–D3** magnification, **D15** CPU)
- `Stage-2-Cataloging.md` — the cross-leg ops-counter comparability caveat and the sub-second-cell open item, both of which apply here
- `../SCRIPT-TRACKER.md` — per-script reference including the 20× contract implementation
- `README.md` — operational runbook and both canaries
- `INDEX.md` — append-only run history (auto-generated)
