# Stage 3 — Tissue detection (the 20× coord generator), measured identically on both filesystems

> **Every substage runs twice — once on WEKA (Leg A), once on FSx for Lustre (Leg B)** — with
> everything else held constant. The delta is the result, and a single leg is half an unfinished
> comparison.
>
> **Stage 3 is also the 20× coord generator.** 3.0 is the single place the 20× contract is implemented;
> its output coordinate lists gate all of Stages 4/5/6/7 **in both legs**.

For project-wide conventions and recording philosophy see `../CLAUDE.md`; framing and the fairness contract
`../PROJECT-THESIS.md`; stage map and the decision register `STAGES.md`; runbook `RUNBOOK.md`.

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
**Whether either filesystem becomes visible here is measured, not assumed** — the recording is nearly
free, and storage materially busier than the algorithm implies would be a finding to chase, not noise to
dismiss.

---

## ⚠️ Scope caveat — read before presenting Stage 3 numbers

**Both legs measure POSIX tissue detection via CLAM. Neither measures object-store access** — CLAM's
`create_patches_fp.py` and the underlying OpenSlide reads expect filesystem paths, and object access is out
of scope for this project on both sides (`../PROJECT-THESIS.md` §9).

**Say "POSIX tissue detection via CLAM" alongside any Stage 3 number**, and name the filesystem and its
provisioned configuration.

---

## ⚠️ Cross-leg comparability caveat — CPU is not directly comparable across legs

Stage 3 quotes a CPU curve off its concurrency sweep, which is what makes **D15**'s core accounting
load-bearing here: a CPU reading computed over *total* cores is invalid across legs.

**The WEKA client reserves CPU cores for its DPDK data path; the Lustre client does not** (it works through
kernel threads). So the number of cores actually available to the application differs between legs, on the
same instance. Raw "CPU %busy" is therefore **not** a valid cross-leg comparison, and neither is
throughput-per-core computed against total cores.

**How this stage handles it (per D15):**
- Record **cores reserved by the filesystem client**, **cores available to the application**, and **total
  cores** for every cell, on both legs.
- Compute-saturation readings are computed over **application-available cores** on each leg.
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

3.0 generates coords in 20× space, per dataset. Rationale and sources are **D1–D3**; per-script detail is
in `SCRIPT-TRACKER.md`.

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
  handled by the uniform 1064-slide cohort (**D5**).

**Both legs consume the same coord definition.** The coords are regenerated per leg (they are written to the
filesystem under test, and generating them is itself the measured workload), and **a coord-equivalence check
between legs is a data-integrity gate** — see the completeness note in 3.0 below.

---

## Recording approach (Stage 3-specific)

Standard `record-run.sh`. The measurement set every cell records, the cost inputs, the operational source
table and its per-filesystem inversion are in `RUNBOOK.md` (**D12**, `../PROJECT-THESIS.md` §7) and are not
restated here. Stage 3 changes that table in one place:

- **`sar -u` over application-available cores → Primary.** The CPU curve across the concurrency sweep is
  what this stage is measuring — where it bends, and whether it saturates inside the grid at all, is the
  result — so the CPU reading is a number that gets quoted rather than context. The excluded core set is a
  **per-filesystem parameter** (**D15**), not a constant, and the reserved-core reading stays diagnostic on
  the WEKA leg — DPDK cores busy-poll independently of the application's compute, so reading them as "the
  application's CPU" would be wrong in exactly the direction that matters here.

**One comparability rule governs how Stage 3's numbers are read.** CLAM's per-slide elapsed time and
tile-coord counts come from the application itself, so they are comparable across legs by construction.
Filesystem-reported operation counters are **not** — the two filesystems count operations under their own
semantics — so treat them as **within-leg only** until counter semantics are verified equivalent and that
verification is recorded (`Stage-2-Cataloging.md` carries the caveat in full).

### Cross-source canary — Stage 3 specifics

The general rules and the per-filesystem consistency relation are in `RUNBOOK.md`. Stage 3 adds two things:

- **At Stage 3's small byte rates the operation-count curve is the load-bearing check**, because
  per-second byte values are too small to ratio reliably at 1 Hz. A byte-based canary tripping on a short
  cell is the sampling limit documented in `Stage-2-Cataloging.md`, not a consistency failure — record that
  judgement rather than silently widening the band.
- **An app-level accounting check:** CLAM's own per-slide elapsed times, summed over the slides the cell
  processed and divided by the cell's concurrency, must account for the recorded window. It is the one
  check that the `n` chunks really ran in parallel and that the recorded window covers the work — a
  serialised launch or a mis-built chunk set yields a complete, plausible cell whose concurrency label is
  wrong, and nothing on the filesystem side would show it.

---

## Substage roadmap

⏳ planned · 🟡 running · ✅ complete.

### 3.0 — CLAM tissue detection sweep (the 20× coord generator)

| | |
|---|---|
| **Status** | ✅ Leg A (weka, 6/6 cells OK; 4 canary judgements = the documented small-byte-rate sampling limit, report-only) · ⏳ Leg B |
| **Leg A results (`s3.0-tissue-summary-<leg>.csv`)** | BRCA: n=1 2571 s (0.44 slides/s) → n=8 320 s (3.53, 8.0×) → n=64 105 s (10.77, 3.1× more — app-core CPU 82% sustained at n=64). CAM16: 383 → 50 → 19 s (1.04 → 7.98 → 21.0 slides/s; CPU 87% at n=64). Filesystem-side ops sustained up to **18.1k ops/s** (BRCA n=64) — the op-count curve is the quotable filesystem-side signal here, exactly as this stage's canary note predicts; per-second byte volumes are too small for the active-window read mean at the short high-n windows (reads ~0 there — a sampling artifact, recorded, not a measurement of zero I/O). **Completeness = the integrity anchor: 1131/1133 BRCA (the two documented zero-tissue DX2 slides, masks still written 1133/1133) and 399/399 CAM16, identical across all n** — captured as the `coords-3.0` fingerprint for the Leg-B gate. *Caveats:* compute-leaning as designed — CPU over application-available cores approaches saturation at n=64 while storage stays lightly loaded; cells are single-shot (Stage 3 has no designated D18 headline cell). |
| **Tool** | CLAM `create_patches_fp.py` (`github.com/mahmoodlab/CLAM`, commit recorded at run time). Deps: openslide-python, libopenslide, opencv-python, h5py, numpy, pandas, matplotlib, tqdm — versions captured by `record-run.sh` |
| **Source → Target** | `$FS_MOUNT/data/tcga-brca/` and `$FS_MOUNT/data/camelyon16/images/` → `$FS_MOUNT/tissue-detection/3.0/<dataset>/n<N>/{patches/<slide-id>.h5, masks/<slide-id>.jpg}` |
| **Methodology** | **2-D sweep:** datasets ∈ {TCGA-BRCA full, CAMELYON16 (`.tif` under `images/`)} × concurrency ∈ {1, 8, 64} = **6 cells per leg**. CLAM has no concurrency flag, so concurrency is external: the slide manifest is round-robin split into N symlink-dir chunks and N parallel `create_patches_fp.py --source chunk<i> --save_dir <cell-dir> --seg --patch <PATCH_ARGS>` instances run, all writing to one per-cell save dir (collision-free because round-robin guarantees no two chunks share a slide). **Per-dataset 20× `PATCH_ARGS`** as specified above. `--stitch` deliberately omitted — its visualization output is not consumed downstream, and skipping it keeps the cell's cost concentrated on segmentation. **Single-pass per cell.** |
| **Why this exists** | Two purposes at once. (1) It is **the 20× coord generator** — the single implementation point of the contract that governs Stages 4–7, so it must run before them in each leg. (2) It is the compute-leaning counterpart to Stage 2's metadata stress, measuring what each filesystem is asked for by a workload whose I/O is bounded by design. |
| **Why identical on both** | Same CLAM commit, same per-dataset args, same chunking scheme, same concurrency grid, same datasets. Only `$FS_MOUNT` differs. |
| **Concurrency grid rationale** | {1, 8, 64} — a log-spaced 3-point grid is sufficient to resolve a compute-leaning saturation curve. The top point is chosen relative to the instance's core count so that saturation is reached without thrashing; per **D15** the *effective* parallelism differs between legs because the WEKA client reserves cores, and both the nominal `n` and the available-core count are recorded per cell. |
| **20× effect on this stage** | The tile *count* per slide changes with magnification, but the dominant segmentation cost is Otsu + morphology **on the thumbnail**, which is magnification-independent — so 20× changes what Stage 3 *emits*, not primarily what it costs. The reduced tile count propagates downstream as smaller inputs for Stages 4–7. Runtime is recorded, not estimated. |
| **Sweep driver** | `../scripts/sweep-stage3-tissue-detection.sh` |
| **Aggregation step** | Roll the cells up into the summary CSV, with the compute-saturation reading taken over application-available cores (**D15**) — `../scripts/aggregate-stage3-tissue-detection.py`; its interface is in `SCRIPT-TRACKER.md`. **Grouping the roll-up on the `fs` field is deferred work** (`RUNBOOK.md`), so until it lands the cross-filesystem view is assembled by hand from the two legs' CSVs |
| **Aggregated output** | `s3.0-tissue-summary-<leg>.csv` |
| **Recorded per cell** | Compute-saturation curve over application-available cores (sustained + peak across n ∈ {1, 8, 64}, both datasets), throughput (slides/sec), filesystem-side read bytes and operation counts, 20× tiles per slide, output completeness — plus the full measurement set and the cost inputs (`RUNBOOK.md`) |
| **Cross-source check** | Byte-ratio checks are noisy at Stage 3's small per-second volumes; the operation-count curve is the load-bearing check. If a byte-based canary trips on a short cell, treat it as the sub-second sampling limit documented in `Stage-2-Cataloging.md`, not as a consistency failure — and record that judgement rather than silently widening the band |
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
| `record-run.sh` | live | `../scripts/record-run.sh` | every substage |
| `aggregate-stage3-tissue-detection.py` | live | `../scripts/aggregate-stage3-tissue-detection.py` | 3.0 |
| `weka stats realtime` | record at run time | system | WEKA leg recording |
| `lctl`, `lfs` | record at run time | Lustre client | Lustre leg recording |

## Datasets used in Stage 3

| Dataset | Source | Scope | License | Used in |
|---|---|---|---|---|
| TCGA-BRCA Diagnostic SVS | hydrated per leg (Stage 1.7) | full cohort | Open access | 3.0 |
| CAMELYON16 (`images/` only) | hydrated per leg (Stage 1.7) | the scanned WSIs, excluding masks/annotations | CC0 | 3.0 |

Byte-verified held-constant inputs, identical in both legs (**D6**).

## Decision register (Stage 3-scoped)

- **Tool: CLAM `create_patches_fp.py`.** *Why:* literature standard; its HDF5 coord output is directly
  consumable by Stages 4–6 with no conversion; reproducible with stock CLAM by anyone checking our numbers.
- **Per-dataset 20× args** (CAMELYON16 `--patch_level 1 --patch_size 256`; TCGA-BRCA `--patch_level 0
  --patch_size 512 --step_size 512`). *Why:* matches the published foundation-model protocol and keeps the
  level-0 coord step at 512 px for both datasets, so the coord→tile divisor is uniform. Full rationale and
  sources in **D1–D3**.
- **Magnification keyed on mpp, not the `objective-power` tag.** *Why:* the tag is demonstrably unreliable
  on BRCA, and a mis-keyed slide silently mis-tiles to 10× and halves its coord density — a correctness bug
  that would propagate into every downstream stage on both legs.
- **Both datasets, reported separately.** *Why:* vendor-format diversity (Aperio SVS vs OME-TIFF) at modest
  extra runtime; and their differing directory layouts affect metadata-op counts, which should not be
  averaged away.
- **Concurrency grid {1, 8, 64}.** *Why:* a 3-point log-spaced grid resolves a compute-leaning saturation
  curve; a fourth higher point would mostly measure thrashing. Per **D15**, effective parallelism differs
  across legs because the WEKA client reserves cores, so both nominal `n` and available cores are recorded.
- **`--stitch` omitted.** *Why:* the stitched visualization is not consumed by any downstream stage, and
  including it would add per-cell cost unrelated to what the stage measures.
- **Per-core CPU is a primary source here, computed over application-available cores.** *Why:* the CPU
  curve across the concurrency sweep is what this stage measures, so the reading is quoted rather than used
  as context — and quoting it honestly requires excluding cores that busy-poll independently of
  application compute.
  **The exclusion set is a per-filesystem parameter (D15), not a constant** — this is the clearest case in
  the project where a recording detail cannot be shared between legs.
- **Single-pass per cell.** *Why:* matches how the job is really run and keeps the unit of work identical
  across legs. Sub-second-cell sampling limits are handled by the resolution chosen in
  `Stage-2-Cataloging.md`, applied identically to both legs.
- **Output to a separate `tissue-detection/3.0/…` directory.** *Why:* the canonical dataset directory stays
  read-only so both legs read byte-identical inputs; per-cell output dirs are cleanly removable.
- **CLAM's dependency home is the MAIN pinned env (`wsi-cucim-2604`), whose pip layer carries matplotlib +
  its leaf deps (installed `--no-deps`, so no pinned package moved; pip-freeze spec regenerated so every
  rebuild and Leg B inherit it through the bootstrap).** *Why the main env:* it already carried every other
  CLAM dep (openslide, cv2, h5py, numpy, pandas), and a second env would put a held-constant input in two
  places. The driver builds its interpreter per the NAMING convention
  (`$CONDA_ENVS_DIR/$CONDA_ENV_MAIN/bin/python3`) — bare `python3` resolved to whatever led PATH and was
  wrong on every build.
- **3.0 cells declare `RECORD_CACHE_STATE=na-compute-leaning-unmanaged`** (the D21 verdict rule requires
  every measured cell to declare). *Why `na-*`:* this stage defines no cache axis — its I/O is bounded by
  design (headers + thumbnails) and its measured quantities are compute-side and completeness, so a cache
  regime is deliberately not an axis here; `na-*` maps to NOT_APPLICABLE in the D13 reconciler rather than
  claiming a cold or warm state nothing establishes.
- **Coord equivalence between legs is a fail-loud data-integrity gate.** *Why:* completeness and per-slide
  tile counts are storage-independent, so any cross-leg divergence proves the legs did not process
  identical inputs — which would invalidate every downstream comparison. Cheap to check, and it catches a
  class of error (partial hydration, wrong commit) that is otherwise invisible until the numbers look
  strange.

## Cross-references

- `../CLAUDE.md` — project rules: recording philosophy, per-filesystem adapters, framing
- `../PROJECT-THESIS.md` — the question, held-constant contract, both asymmetries, scope
- `STAGES.md` — stage map, per-leg plan, cross-stage decision register (esp. **D1–D3** magnification,
  **D15** CPU)
- `Stage-2-Cataloging.md` — the cross-leg ops-counter comparability caveat and the sub-second-cell open item, both of which apply here
- `SCRIPT-TRACKER.md` — per-script reference including the 20× contract implementation
- `RUNBOOK.md` — the per-cell measurement set, the source table, both canaries
- `../runs/INDEX.md` — append-only run history (auto-generated)
