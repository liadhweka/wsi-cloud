# Project stage map + plan hub — WEKA vs Lustre on AWS

> **Status: BUILD PHASE — no benchmark has run.** The repo is being stood up pre-provisioning: docs
> written, scripts being adapted, environment not yet created. **Every number in this tree is
> `[PENDING]`.** Headline results fill in per substage as cells land.
>
> **No document here may contain a predicted outcome, an expected magnitude, or a pre-assigned
> "headline" stage.** Results precede story — see **D9**.

This file is the authoritative map between **`--stage` flag values** and **what each stage means**, plus
the per-leg plan and the **cross-stage methodology decision log**. Per-stage detail lives in the roadmap
docs (`Stage-<N>-*.md`); per-script reference in `../SCRIPT-TRACKER.md`; paths in `../FILESYSTEM-MAP.md`;
the framing and fairness contract in `../PROJECT-THESIS.md`; the project rules in `../CLAUDE.md`.

---

## The comparison structure

**Every stage is measured identically on both filesystems. The WEKA-vs-Lustre delta is the result.**

There is no "WEKA stage" and no "Lustre stage" — there is one stage, run twice, once per filesystem, with
everything else held constant. Concretely that means:

- Each cell carries a `--fs {weka|lustre}` dimension recorded in the run-dir name and in
  `metadata.json`, so the aggregators pivot on filesystem and emit head-to-head CSVs directly (**D11**).
- The same script, the same commit, the same datasets, the same knob values run on both sides. A cell that
  cannot run identically on both sides is either (a) redesigned until it can, or (b) explicitly labelled a
  **single-filesystem capability cell** and excluded from the head-to-head (see **D8** for the one
  deliberate exception, and Stage 1 for the FSx-native-S3-import case).
- **Leg A (WEKA) runs first, then Leg B (FSx for Lustre)**, because the two are provisioned separately and
  the instance is rebuilt between them. Cross-leg comparability is enforced by the **environment
  contract** (**D6**), not by trust.

**A note that governs how every bandwidth number here is read:** throughput is expected to be capped by
the client instance's line rate, not by either filesystem (both are sized above it — **D7**). A tie on a
pure bandwidth cell therefore says something about the instance, **not** about either filesystem, and must
never be written up as a finding about either. The axes that carry information are metadata, IOPS,
small-file behaviour, concurrency, and latency.

---

## The GPU-direct measurement matrix

GPUDirect Storage is **retained and asymmetric by design** (**D8**). Per applicable stage (4.C, 5.A,
6.A, and the Stage 7 inference backends), **three cells per filesystem** — because cuFile's compat mode
exists on both sides, which is what makes the asymmetry analysable rather than confounding:

| | POSIX (native reads) | cuFile **compat** | cuFile **GDS** |
|---|---|---|---|
| **WEKA** | ✅ measured | ✅ measured | ✅ *if achievable — determined empirically* |
| **Lustre** | ✅ measured | ✅ measured | ✅ measured (over EFA) |

That grid separates three readings that a single "Lustre-GDS vs WEKA-GDS" number would conflate:

1. **Lustre-compat vs WEKA-compat** → the **pure filesystem comparison** at an identical code path,
   identical artifact, identical API — no transport difference. The cleanest apples-to-apples number in the
   GPU-direct block.
2. **Lustre-GDS vs Lustre-compat** → the **pure GDS effect**, isolated inside one filesystem.
3. **Lustre-GDS vs WEKA-best** → the **deployment-reality question**: what a customer actually gets on
   each, given what each can do on AWS.

The plain-POSIX cell is additionally needed because cuFile-compat stacks a bounce buffer and the cuFile
layer on top of POSIX and may be **slower than a filesystem's own native path** — without it we would
understate whichever side falls back. POSIX is each filesystem's best-foot-forward number; compat is the
like-for-like one. Full design rationale in `Stage-4-Patching.md` § GPU-direct experimental design.

**Prove the path, per cell.** Every kvikIO cell records cuFile's own accounting of GPU-direct vs bounced
bytes (`CUFILE_STATS`, `/proc/driver/nvidia-fs/stats`) as a first-class source. **A configuration flag is
not proof of behaviour** — `allow_compat_mode` being set does not tell you which path a read actually
took. A cell that quietly fell back, or quietly didn't, silently poisons the comparison.

If WEKA turns out to support true GDS on some AWS path, the matrix fills in as a 2×3 and nothing is
wasted — that is why it is designed this way rather than around a predicted answer.

---

## The 20× coord-space contract

The magnification contract is filesystem-independent and identical in both legs. Full implementation
detail in `../SCRIPT-TRACKER.md`; the rationale is **D1–D5**.

- **CAMELYON16** (`.tif`, native 20× level): `--patch_level 1 --patch_size 256`.
- **TCGA-BRCA** (`.svs`, 40× base, no native 20× level): `--patch_level 0 --patch_size 512
  --step_size 512`; readers read 512 px @ 40× and **resize to 256 px @ 20×** (exactly what CLAM's
  `custom_downsample` and Trident's `--mag 20` do internally).
- Coords step by a **level-0 footprint of 512 px for both** datasets → the coord→raw-TIFF-tile divisor is
  512 (not the raw tile width 256). Tiles are a **uniform 256 px @ 20×** across all three foundation
  models (Virchow2's native 224 is reached by the model's own resize).
- **Full-BRCA cohort = 1073 slides** (`manifests/tcga-brca-full40x-stage4a-format.tsv`) — the uniform
  40×-base set, with a fail-loud mpp guard in `convert-rawtiff-20x.py` that refuses any stray off-mag
  slide (**D5**).

---

## Per-filesystem recording adapters

The recording *philosophy* is identical across legs; the *sources* are not. **Never quote a
throughput/latency/IOPS number from a source that is bypassed or irrelevant for the path in use** — cite
the path-appropriate primary or mark it diagnostic-only. Canonical rule text in `../CLAUDE.md`; the
operational table and both canaries live in `README.md`.

| | Primaries | Diagnostic-only |
|---|---|---|
| **WEKA** (DPDK over ENA) | `weka stats realtime`; app-level; the wire counters for the DPDK path | kernel net counters (`sar -n DEV`); `iostat` (block layer bypassed → ~zero for the mount); `sar -u` (DPDK cores spin-poll → look busy regardless) |
| **Lustre** (FSx) | client `/proc/fs/lustre` + `lctl get_param`; CloudWatch per-OST/MDT metrics; app-level; **the client's network counters, which ARE the data path here** (kernel LNet over TCP, or the EFA provider's counters when EFA-mounted) | whichever of the above does not match the LND actually in use — **determine it, don't assume** |

**Derive the consistency relation per filesystem; never port one across (D12).** WEKA's erasure coding
implies a specific wire-vs-app write amplification (which is why the EC scheme is captured at
provisioning). Lustre stripes across OSTs with no default erasure coding, so its relation follows from the
actual stripe layout and must be derived from it. Run the canary after every sweep; disagreement means
bugged infra, and it is fixed before continuing.

**Two canaries per sweep, both mechanical:** an **exclusivity/health check before** (no competing load,
provisioning matches the contract) and the **cross-source consistency check after**. On an unattended
overnight chain these must *abort the chain themselves* rather than wait to be noticed.

---

## The per-leg plan (dependency order)

Leg B repeats this identically. Ordering is driven purely by **what gates what** — no step is ordered by
an expectation about its result.

**Phase 0 — environment verification + baseline (gated on provisioning).** Confirm the mount is healthy
and the provisioned configuration matches what the fairness contract specifies (**D7**); confirm exclusive
access; capture the synthetic read/write baseline **per block size**, because throughput is
block-size-dependent and a single number misleads. Record as the leg's reference baseline and re-confirm
before each major run. **Every downstream "% of ceiling" divides by the Stage-1.0 cell at the *matching*
block size** — never a mismatched-block ceiling, which would make a mid-block workload look artificially
high or low.

Then, in dependency order:

| # | Run | Why it sits here (what it gates / needs) |
|---|---|---|
| 1 | **1.0a/b/c/d** synthetic ceilings (fio: seqw / seqr / randw IOPS / randr IOPS) | Anchors every downstream "% of ceiling" denominator; needs nothing |
| 2 | **1.7** S3 → filesystem hydration | Puts the datasets on the filesystem; gates everything below. Also a legitimate large-write ingest measurement in its own right |
| 3 | **3.0** tissue detection | Generates the 20× coords; gates 4 / 5 / 6 / 7 |
| 4 | **4.D** 20× raw-TIFF conversion | Produces the artifact the kvikIO cells read; gates 4.C / 5.A / 6.A-kvikio / 7.x-kvikio. Itself a large sequential write + read workload |
| 5 | **4.C** kvikIO from raw-TIFF · **4.B** on-the-fly reads · **4.A** pre-extract | 4.C/4.B need coords (+ raw-TIFF for 4.C); 4.A writes HDF5 that nothing else here consumes |
| 6 | **5.A / 5.B** DDP training scaling | Need coords + raw-TIFF (5.A) |
| 7 | **6.A** foundation-model extraction, Tier 1 → 3 → 2 | Needs coords + raw-TIFF; Tier 2 is the long pole; produces the features 6.B.3 and 7.3 consume |
| 8 | **6.B.3** MIL on real features → **6.B.1/2** synthetic corpus + file-IO stress | 6.B.3 needs 6.A features; 6.B.1/2 are self-contained |
| 9 | **6.C** concurrent multi-workload / QoS | Wants the other workloads characterised first so the concurrent mix is meaningful |
| 10 | **2.0** cataloging / metadata sweep | Self-contained; needs only the datasets on the filesystem |
| 11 | **Stage 7** (7.1–7.6) | 7.3 needs 6.A features; the rest need coords + raw-TIFF |
| 12 | **1.5 / 1.6** bulk local→fs copy + mixed concurrent ingest+read | Self-contained; placed late because they perturb the filesystem |
| 13 | **1.8** *(Lustre leg only)* FSx-native S3 import | Single-filesystem capability cell — excluded from the head-to-head; see Stage 1 |

**Wallclock is not estimated here.** Estimates from a different environment would be fiction, and an
estimate is a prediction. Each roadmap records actual durations as cells land, and the running total is
maintained in `INDEX.md`.

---

## Stage map (`--stage` values)

## Stage 0 — infra validation
Smoke / recording-infra runs only. No real benchmark data. Used to prove `record-run.sh`, the per-FS
adapters, the S3 sync, and both canaries work on a newly provisioned environment **before** any measured
cell.

## Stage 1 — Ingest
Substages: **1.0a/b/c/d** synthetic ceilings (fio: seqw / seqr / randw IOPS / randr IOPS — anchor first);
**1.4** local-NVMe scratch provisioning; **1.5** bulk local→filesystem copy (`fpsync`); **1.6** mixed
concurrent ingest + read; **1.7** S3 → filesystem hydration (the head-to-head ingest cell — identical
method on both sides); **1.8** FSx-native S3 import (**Lustre leg only**, capability cell, not
head-to-head).

> **Changed vs a conventional on-prem plan, and why:** the WAN download from GDC / the CAMELYON open-data
> bucket happens **once, before either leg**, into our own S3 bucket. It is not a filesystem measurement
> and is not a comparison cell. What *is* measured is **S3 → filesystem hydration (1.7)**, which must use
> the **same method on both filesystems** — otherwise the ingest numbers compare two different mechanisms
> rather than two filesystems. FSx's native S3 data-repository import is a genuine Lustre advantage but
> has no WEKA counterpart, so it is measured separately as **1.8** and clearly labelled.

## Stage 2 — Cataloging & metadata extraction
**2.0** OpenSlide property sweep (metadata-stress; magnification-independent). **2.1** DSA/MongoDB
integration — deferred.

## Stage 3 — Tissue detection (the 20× coord generator)
**3.0** CLAM tissue detection sweep — generates the 20× coords per the per-dataset args above, and gates
all of 4/5/6/7. **3.1** deferred.

## Stage 4 — Patching / tile extraction
- **4.A** pre-extract tiles to per-slide HDF5 (50-slide subset).
- **4.B** on-the-fly reads (OpenSlide CPU + cuCIM CPU batched). cuCIM `read_region(device='cuda')` is
  ruled out as a **library** defect, filesystem-independent — do not re-investigate, and never report it
  as a storage finding for either side (`cucim-read-region-device-cuda-non-viable…` memory).
- **4.C** kvikIO + cuFile reads from the 20× raw-TIFF — the GPU-direct cell, run on both filesystems per
  the matrix above.
- **4.D** 20× raw-TIFF conversion (`convert-rawtiff-20x.py`) — an input-generation step that is itself a
  measured large-sequential write workload.

## Stage 5 — Training data pipeline
**5.A** kvikIO + cuFile + raw-TIFF → ResNet-50 DDP scaling sweep; **5.B** cuCIM CPU batched → ResNet-50
DDP scaling sweep. DDP N-range follows the instance's GPU count (**D10**).

## Stage 6 — Feature extraction & MIL
- **6.A** foundation-model extraction (Virchow2 / GigaPath / UNI2-h `[PENDING-APPROVAL]`); Tier 1
  (50-slide scaling) → Tier 3 (CAMELYON16 cross-dataset) → Tier 2 (full-BRCA 1073-slide cohort).
- **6.B** small-file / metadata stress: **B.3** canonical-CLAM `bs=1` MIL on real features
  (`canonical-clam-mil-bs1` memory) → **B.1** synthetic-corpus generation → **B.2** file-IO stress.
- **6.C** concurrent multi-workload (QoS + endurance).
- **6.D** end-to-end pipeline timing — constructive bookend, **not** a measured cell.

## Stage 7 — Clinical Inference Deployment
**7.1** per-slide latency baselines (cold + warm × backends × models) · **7.2** latency under concurrent
load · **7.3** heatmap write characterisation (consumes 6.A features) · **7.4a/b** streaming loop +
read-after-write consistency · **7.5a/b** mixed workload + endurance · **7.6** CAMELYON16 cross-dataset.

---

## Methodology decision log

Every cross-stage / project-wide methodology fork, with **what / when / why / sources**. This is the
canonical record; per-stage roadmaps carry local decisions and point here. Per `../CLAUDE.md`, the WHY and
the official source are as load-bearing as the choice. Decisions scoped to one stage live in that stage's
roadmap. **Any decision touching an assumed environment value must also update the reference index in the
`weka-vs-lustre-cloud-open-decisions` memory.**

**D1 — Magnification: 20× "by the book." (2026-07-31)** 20× / ~0.5 mpp is the dominant published standard
for the foundation models we run, and **no model requires 40×**. *Sources (official model cards /
papers):* UNI "trained at 20× resolution" [HF `MahmoodLab/UNI`]; Prov-GigaPath "normalizes to 0.5 µm/px …
tiles at 20×" [Nature `s41586-024-07441-w`; HF `prov-gigapath/prov-gigapath`]; Virchow2 "0.5 mpp (20×)"
[HF `paige-ai/Virchow2`]; Mahmood Lab **Trident** canonical recipe `--mag 20`. → directly comparable to
the literature and to what customers run. *Why it matters to a storage comparison:* magnification sets
tile count per slide and therefore the I/O pattern both filesystems see; picking a non-standard
magnification would make every number harder to relate to a customer's real workload.

**D2 — Coord generation: CLAM with per-dataset args; do NOT switch to Trident. (2026-07-31)** CAMELYON16
`--patch_level 1 --patch_size 256`; TCGA-BRCA `--patch_level 0 --patch_size 512 --step_size 512` + reader
resize → 256. *How:* stock CLAM, no source patch (BRCA's 512→256 resize **is** CLAM's `custom_downsample`).
*Why + sources:* CLAM and Trident do the **identical** thing for a slide lacking a native 20× level — read
the nearest native level, resize to target. CLAM `wsi_core/WholeSlideImage.py` (`custom_downsample==2` →
read 512@L0 → `.resize(256)`); Trident `trident/wsi_objects/WSI.py`
`get_best_level_and_custom_downsample()` + `WSIPatcher` resize. **The tile content and the storage I/O
pattern a benchmark measures are identical either way**, and CLAM avoids Trident's coord-attr format shim
rippling through every reader.

**D3 — Uniform 256 px @ 20× tiles across all three models. (2026-07-31)** Literature patch sizes, all
@20×: UNI/UNI2-h 256, Prov-GigaPath 256, Virchow2 224, CONCH 256, TITAN 512 [HF model cards; Trident
per-encoder recipes]. *Why uniform 256:* matches UNI2-h and GigaPath exactly; **Virchow2's native 224 is
reached by the model's own resize from the 256 tile** (standard practice); keeps coord generation
**single-pass and shared across the three models**, which preserves the Tier-2 shared-conversion
optimisation; and the 256-vs-224 *storage* difference is negligible. Holding tile size constant also
keeps the cross-filesystem comparison clean — only the mount varies.

**D4 — Raw-TIFF: produce a TRUE 20× artifact, not level-1 of a 40× raw-TIFF. (2026-07-31)**
`convert-rawtiff-20x.py` (tifffile single-level, 256 px-tiled, uncompressed 20× writer) rather than
`cucim convert`. *Why + sources:* `cucim convert` (26.4.0 `cli.py`) exposes no `--mag`/`--level` and always
emits the SVS 40× level-0 (verified). Keeping a 40× artifact and reading pyramid level-1 was rejected: the
artifact is ~4× larger, conversion is ~4× slower, and it is **not what a 20× GPU-direct customer actually
stores.** *Storage-comparison consequence:* the raw-TIFF footprint is a provisioning input on **both**
filesystems (~7 TB at the full cohort) and, on FSx, capacity is simultaneously a performance knob — so
this decision feeds **D7**.

**D5 — Full-BRCA cohort: uniform 1073-slide 40×-base set. (2026-07-31)**
`tcga-brca-full40x-stage4a-format.tsv` (1073 slides; 51 true-20× + 7 unknown-mpp excluded) plus a
fail-loud mpp guard (`0.4 ≤ eff_mpp ≤ 0.65`). *Why + sources — ground-truth mpp scan of all 1133 BRCA
slides:* the `openslide.objective-power` tag is **unreliable** (slides labelled 20× that are mpp≈0.25,
i.e. true 40×), so we key on **mpp, not the tag**. By true mpp, full BRCA is 1075 × 40× (mpp~0.25) /
51 × true-20× / 7 unknown, and **none** has a native 20× pyramid level. The per-dataset 20× read
mis-tiles a true-20× slide to **10×** (reads 512 px@20× → resize 256 = a 10× FOV) and halves its coord
density — so excluding the ~5% off-mag slides preserves the footprint-512 contract and removes a
magnification confound. 1073 slides is ample for a storage benchmark. The guard refuses any stray
off-mag slide as defence in depth.

**D6 — Competitive framing: two sequential legs, with a machine-enforced environment contract.
(2026-07-31)** Leg A = WEKA, Leg B = FSx for Lustre, then the synthesis. *Why sequential:* the two are
provisioned separately and the instance is rebuilt between them; running them concurrently would mean two
clients or a shared client, either of which breaks the held-constant contract. *Why the contract:* legs
separated in time can drift (AMI, driver, dataset bytes, script commit), and drift is indistinguishable
from a filesystem difference after the fact. So Leg A writes a machine-readable environment contract that
**Leg B verifies before its first cell**, and a mismatch is fail-loud. *Framing consequence:* each leg is
half an unfinished comparison and no single-leg doc may imply finality
(`feedback-each-leg-is-half-an-unfinished-comparison` memory).

**D7 — Fairness basis: Lustre at MAXIMUM capability, WEKA at a realistic production config, cost reported
alongside. (2026-07-31)** *Why:* beating a competitor's **best** configuration is worth far more than
beating one we sized ourselves, and it forecloses the objection that whoever picked the tier picked the
winner. The asymmetry is stated in every result headline — a reader's first question is "what was the
other side running?", so the answer must already be on the page. **"Maximum" is defined per axis, because
one axis is client-capped and the others are not:** tier `PERSISTENT-1000` (1000 MBps/TiB disk,
2600 MBps/TiB network); capacity **≥25 TiB** (at 1000 MBps/TiB this is where FSx *disk* throughput reaches
the client's ~25 GB/s — below it, FSx is the constraint and any delta is a sizing artifact);
**user-provisioned high metadata IOPS** (Persistent-2 provisions these independently of capacity, up to
192,000 — the axis where a maxed Lustre is most formidable); EFA-enabled file system + EFA-mounted client.
**WEKA must also clear ~25 GB/s** so it is not the constraint either — a "realistic" config that starves
the client would produce a sizing artifact, not a finding. *Sources:*
[FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html),
[SSD storage performance characteristics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html).
*Open sub-item (deliberately deferred):* the cost figure needs WEKA licensing priced in or must be
explicitly labelled infrastructure-only — the numbers get fixed later rather than blocking the build.

**D8 — GPU-direct retained, and asymmetric by design. (2026-07-31)** kvikIO/cuFile is **not** dropped to
force symmetry. *Why:* Lustre-over-EFA supports GDS while WEKA-over-ENA is expected to fall back to
compat mode, and **that is precisely the choice a customer faces on AWS** — so it is the measurement, not
a confound. kvikIO/cuFile runs on both sides, meaning the same application code and the same raw-TIFF
artifact execute on both and only the transport differs. Both sides additionally get a plain-POSIX cell,
because compat mode stacks a bounce buffer on top of POSIX and would otherwise understate whichever side
falls back. **The GDS-on-WEKA question is resolved empirically, not from documentation** — WEKA's own
materials claim GDS support on AWS while the transport analysis (ENA is not RDMA-capable) suggests
fallback; we settle it with `gdscheck -p` plus a recorded canary cell, and the matrix is built so either
answer is usable. **Prove the path per cell** via cuFile's GPU-direct-vs-bounced byte accounting; a config
flag is not proof. *Sources:* [FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html)
(EFA-enabled file systems support GDS; per-client caps by interface),
[WEKA networking](https://docs.weka.io/weka-system-overview/networking-in-wekaio).

**D9 — Results precede story. (2026-07-31)** No doc may carry a predicted outcome, an expected magnitude,
a pre-assigned "headline" stage, or outcome-expectation buckets. *Why:* a pre-baked narrative inverts the
logic of benchmarking — it biases which cells get scrutinised and makes a contradicting result feel like a
failure rather than a finding. **Keep the WHY-we-measure-it-this-way** (that is what makes a number
evaluable, and it is separately mandated); **delete the WHAT-it-will-show.** Interpretation sections stay
marked `[STORY PENDING RESULTS]`. **Losses get reported** — provisioning Lustre at maximum raises that
chance, which is the accepted trade because a weakness found here is one a customer does not find later.

**D10 — Compute instance `g6e.24xlarge` *(subject to change)*, with a pre-committed revisit trigger.
(2026-07-31)** 96 vCPU, 768 GiB, 4× L40S (178 GiB), 200 Gbps across 2 network cards, 2× 1900 GB NVMe,
EFA-capable. *Why this one:* L40S is the required GPU family, and ≥200 Gbps is needed for a credible
bandwidth axis (a 100 Gbps client caps at ~12.5 GB/s). *Why it must be identical in both legs:* it is the
single largest held-constant variable, and it must be EFA-capable from the start because Leg B needs EFA
even though Leg A does not. **Pre-committed revisit trigger:** if Leg A's synthetic ceiling pins at line
rate across block sizes **and** the `num_workers` sweep saturates on CPU cores rather than storage, the
instance is measuring itself rather than the filesystem — move up (`g6e.48xlarge`, 8× L40S / 400 Gbps)
before Leg B. Recorded in advance so the call is not made later under sunk cost. *Consequences:* DDP
N-range ∈ {1, 2, 4}; `num_workers` headroom; GPU/NUMA pinning map (re-derived on the real instance).
*Source:* [EC2 accelerated-computing instance specs](https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html).

**D11 — One `runs/` tree, with the filesystem as an explicit dimension. (2026-07-31)** `--fs {weka|lustre}`
becomes a run-dir name segment **and** a `metadata.json` field; aggregators pivot on it. *Why not one tree
per filesystem:* the deliverable **is** the cross-filesystem delta, and separate trees would force every
comparison to be assembled by hand. *Why this is safe:* the contamination risk that per-phase separation
guards against is handled instead by the **D6** environment contract plus a per-leg recorded environment
snapshot — drift becomes **visible** rather than structurally prevented, which is what a comparison needs.

**D12 — Per-filesystem recording adapters, and a per-filesystem consistency relation. (2026-07-31)** The
recording philosophy is constant; the primary sources are not (see the table above). *Why:* WEKA's DPDK
client bypasses the kernel network and block layers, so kernel counters mislead there — while on a Lustre
client those same counters **are** the data path. Using one filesystem's source table for the other would
produce confidently wrong numbers. **The cross-source relation must be re-derived per filesystem, never
ported:** WEKA's erasure coding sets a specific wire-vs-app write amplification (hence capturing the EC
scheme at provisioning), whereas Lustre stripes across OSTs with no default erasure coding, so its
relation follows from the actual stripe layout. Both canaries run per sweep and **abort the chain
mechanically** on failure, because the normal mode is unattended overnight execution.

**D13 — Cold-vs-warm is a hard, enforced axis with cache state recorded per cell. (2026-07-31)** *Why:* a
maxed FSx at PERSISTENT-1000 carries **27.3 GiB of file-server cache RAM per TiB** — ~680 GiB at 25 TiB,
comparable to the instance's own 768 GiB — and WEKA caches too. Any warm cell therefore risks measuring
cache rather than storage, and the risk is *asymmetric* because the two sides cache differently. Making
cold-vs-warm explicit protects the result in both directions: it prevents a cache-served number being read
as storage performance, and prevents a cold number being read as steady-state. *Source:*
[SSD storage performance characteristics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html).

**D14 — S3 is the durable store; git and S3 have non-overlapping authority. (2026-07-31)** Instance-local
NVMe and both filesystem mounts are **ephemeral** — they die with the instance and the cluster, and the
instance is deliberately rebuilt between legs. *Why the split:* **git is authoritative for all small text**
(docs, `results.json`, `metadata.json`, `0_README.md`, configs, the memory mirror) and **S3 is
authoritative for the heavy write-once data git cannot hold** (raw telemetry, datasets). Because they do
not overlap, S3 versioning is unnecessary. **Two sync semantics, deliberately different:**
mirror-with-delete for docs/memories (git backs them independently, so an exact reflection is safe);
**add-and-update, never delete** for telemetry and datasets — we will want to reclaim local disk by
cleaning old raw telemetry, and a `--delete` sync would then destroy the only remaining copy. Syncs run
during long runs, not only at the end, and are **verified rather than assumed**. Full rule text in
`../CLAUDE.md` → Recording → Durability & backup.

**D15 — The two clients consume CPU differently, so CPU-derived metrics need a per-filesystem core
accounting. (2026-07-31)** The **WEKA client reserves dedicated cores for its DPDK data path; the Lustre
client does not** (it works through kernel threads). On one identical instance, the number of cores actually
available to the application therefore **differs between legs** — which makes raw "CPU %busy", and any
throughput-per-core figure computed against total cores, invalid as a cross-leg comparison. *Why this
matters beyond bookkeeping:* it is a real architectural cost difference, and both ways of ignoring it are
wrong — hiding the reservation flatters Lustre's available parallelism, while excluding the reserved cores
from WEKA's cost flatters WEKA's per-core efficiency. **How every stage handles it:** record **cores
reserved by the filesystem client**, **cores available to the application**, and **total cores** per cell on
both legs; compute compute-saturation headlines over **application-available** cores; treat the
reserved-core exclusion list as a **per-filesystem adapter parameter, not a constant** (on the WEKA leg the
DPDK cores busy-poll independently of application work and are excluded from the saturation reading; on the
Lustre leg there is no equivalent set); and report the reservation itself as part of that filesystem's cost
rather than netting it out silently. Most load-bearing in the compute-leaning stages (3, and the CPU
backends in 4.B / 5.B / 6.A), and it also shifts *effective* parallelism at a given nominal concurrency, so
both nominal `n` and available-core count are recorded per cell.

---

## Change log

| When | Change |
|---|---|
| 2026-07-31 | Stage map, per-leg plan, and decision log **D1–D14** created for the WEKA-vs-Lustre AWS project. Status: build phase, nothing measured. |
| 2026-07-31 | **D15 added** during the Stage 2/3 roadmap audit — the WEKA client's dedicated DPDK cores vs the Lustre client's kernel threads make CPU-derived metrics non-comparable across legs without explicit core accounting. Surfaced by Stage 3, whose headline is a CPU saturation curve; applies to every compute-leaning stage. |
| 2026-08-03 | **Pre-deployment audit.** No methodology decision changed; the audit found the *implementation* diverging from decisions already recorded here, and fixed it. Load-bearing corrections: every pre-computed run-dir name now carries the `-<leg>-` segment (without it the S3 sync and the teardown gate both skipped the cell silently — **D11**/**D14**); four drivers now hand their pre-computed run dir to `record-run.sh` instead of writing app-level output to an orphan directory; the conda interpreter and libcufile paths are read from documented variables instead of literals from another machine; and every cell `--note` was stripped of prior-environment figures and pre-assigned conclusions (**D9** — those notes are written into each run's `metadata.json`, so the violation was landing inside the results). Stage 5's and 6.A's GPU-count sweeps were brought to N ∈ {1,2,4} to match the 4-GPU instance (**D10**), and the 8-GPU cells that could not run on it were removed. Full record: `../SCRIPT-TRACKER.md` § "Done during the pre-deployment audit" and `cloud-setup/AUDIT-REPORT.md`. |

---

## Naming convention

Run directories: `<UTC-timestamp>-<fs>-s<stage>-<workload>-<config>` — e.g.
`2026-…-weka-s4.C-kvikio-brca-N4-compat`. The `--fs` and `--stage` values passed to `record-run.sh` become
the `<fs>` and `s<stage>` segments automatically and are both recorded in `metadata.json`, so the
aggregators pivot on filesystem without parsing directory names. `record-run.sh` derives the runs root
from its own location on disk, so run dirs and `INDEX.md` land in this tree.
