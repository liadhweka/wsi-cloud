# Project stage map + plan hub — WEKA vs Lustre on AWS

This file is the authoritative map between **`--stage` flag values** and **what each stage means**, plus the
per-leg plan and the **cross-stage decision register**.

Per-stage detail lives in the roadmap docs (`Stage-<N>-*.md`); per-script reference in `SCRIPT-TRACKER.md`;
how to run and record a cell in `RUNBOOK.md`; paths in `FILESYSTEM-MAP.md`; findings in `RESULTS.md`; **what
we measure and why in `../PROJECT-THESIS.md`**, which wins over anything here; the project rules in
`../CLAUDE.md`.

---

## The comparison structure

**Every stage is measured identically on both filesystems. The WEKA-vs-Lustre delta is the result.**

There is no "WEKA stage" and no "Lustre stage" — there is one stage, run twice, once per filesystem, with
everything else held constant (`../PROJECT-THESIS.md` §3). Concretely:

- Each cell carries a `--fs {weka|lustre}` dimension recorded in the run-dir name and in `metadata.json`, so
  the aggregators pivot on filesystem and emit head-to-head CSVs directly (**D11**).
- The same script, the same commit, the same datasets, the same knob values run on both sides. A cell that
  cannot run identically on both sides is either (a) redesigned until it can, or (b) explicitly labelled a
  **single-filesystem capability cell** and excluded from the head-to-head (see **D8** for the one deliberate
  exception, and Stage 1 for the FSx-native-S3-import case).
- **Leg A (WEKA) runs first, then Leg B (FSx for Lustre)**, because the two are provisioned separately and the
  instance is rebuilt between them. Cross-leg comparability is enforced by the **environment contract**
  (**D6**), not by trust.

**Every cell reports the full measurement set, and no metric is designated primary** (`../PROJECT-THESIS.md`
§4). Which axis turns out to be decisive is a result, not a design input — so a cell that recorded only the
axis someone expected to matter cannot be repaired later. `RUNBOOK.md` defines the set and the per-cell cost
inputs.

---

## The GPU-direct measurement matrix

GPUDirect Storage is **retained and asymmetric by design** (**D8**). **The full grid is characterised once, at
4.C** — **both cuFile modes on both filesystems** — because cuFile's compat mode exists on both sides, which
is what makes the asymmetry analysable rather than confounding. **4.B supplies the plain-POSIX row** against
which both cuFile modes are read:

| | POSIX (native reads) | cuFile **compat** | cuFile **GDS** |
|---|---|---|---|
| **WEKA** | measured | measured | measured *if achievable — determined empirically* |
| **Lustre** | measured | measured | measured (over EFA) |

That grid separates three readings that a single "Lustre-GDS vs WEKA-GDS" number would conflate:

1. **Lustre-compat vs WEKA-compat** → the **pure filesystem comparison** at an identical code path, identical
   artifact, identical API — no transport difference.
2. **Lustre-GDS vs Lustre-compat** → the **pure GDS effect**, isolated inside one filesystem.
3. **Lustre-GDS vs WEKA-best** → the **deployment-reality question**: what a customer actually gets on each,
   given what each can do on AWS.

The plain-POSIX cell is additionally needed because cuFile-compat stacks a bounce buffer and the cuFile layer
on top of POSIX and may be **slower than a filesystem's own native path** — without it we would understate
whichever side falls back. POSIX is each filesystem's best-foot-forward number; compat is the like-for-like
one. Full design rationale in `Stage-4-Patching.md` § GPU-direct experimental design.

**A single Phase-0 cell settles the WEKA-GDS question empirically before the matrix is committed**
(`../PROJECT-THESIS.md` §5.2). The matrix is built so either answer is usable and nothing is wasted — that is
why it is designed this way rather than around an assumed answer.

**The later GPU-direct stages deliberately do not repeat the full grid**, because 4.C already characterises
the GDS-vs-compat delta at the read level across the whole grid, and repeating it at every rank count would
multiply cells for information already in hand.

- **5.A and 6.A** run **each filesystem in its best available cuFile mode, plus one mode-controlled paired
  cell** at a single concurrency, on any leg where both modes are available. The paired cell preserves the
  link back to 4.C, so a cross-leg difference at training or extraction scale can be checked against the
  read-level mode difference rather than guessed at. **Whether a leg has that cell at all follows from that
  leg's answer to the D8 question**, so their cell counts are given as a composition, not a fixed total.
- **Stage 7's kvikIO backends** run in **best available mode only, with no paired cell.** Stage 7 measures
  per-slide latency and its behaviour under concurrency; the mode delta is a read-path property already
  measured at 4.C, and adding a mode axis here would multiply the latency grid without answering a question
  Stage 7 asks.

Recorded here as a scoping choice so it is visible as a decision rather than an oversight.

**Prove the path, per cell.** Every kvikIO cell records cuFile's own accounting of GPU-direct vs bounced bytes
(`CUFILE_STATS`, `/proc/driver/nvidia-fs/stats`) as a first-class source. **A configuration flag is not proof
of behaviour** — `allow_compat_mode` being set does not tell you which path a read actually took. A cell that
quietly fell back, or quietly didn't, silently poisons the comparison.

---

## The 20× coord-space contract

The magnification contract is filesystem-independent and identical in both legs. Full implementation detail in
`SCRIPT-TRACKER.md`; the rationale is **D1–D5**.

- **CAMELYON16** (`.tif`, native 20× level): `--patch_level 1 --patch_size 256`.
- **TCGA-BRCA** (`.svs`, 40× base, no native 20× level): `--patch_level 0 --patch_size 512 --step_size 512`;
  readers read 512 px @ 40× and **resize to 256 px @ 20×** (exactly what CLAM's `custom_downsample` and
  Trident's `--mag 20` do internally).
- Coords step by a **level-0 footprint of 512 px for both** datasets → the coord→raw-TIFF-tile divisor is 512
  (not the raw tile width 256). Tiles are a **uniform 256 px @ 20×** across all three foundation models
  (Virchow2's native 224 is reached by the model's own resize).
- **Full-BRCA cohort = 1073 slides** (`../scripts/manifests/tcga-brca-full40x-stage4a-format.tsv`) — the uniform 40×-base
  set, with a fail-loud mpp guard in `convert-rawtiff-20x.py` that refuses any stray off-mag slide (**D5**).

---

## Recording

The recording *philosophy* is identical across legs; the *sources* are not, because **the per-filesystem
primaries invert** — the client's kernel network counters are diagnostic on the WEKA leg and the data path on
the Lustre leg. The rule and the per-filesystem table are in **`../PROJECT-THESIS.md` §7**; the operational
source list, both canaries, and the full per-cell measurement set are in **`RUNBOOK.md`**. Neither is restated
here, because two copies of a rule drift and the stale one is invisible.

**Derive the consistency relation per filesystem; never port one across** (**D12**). WEKA's erasure coding
implies a specific wire-vs-app write amplification, which is why the EC scheme is captured at provisioning.
Lustre stripes across OSTs with no default erasure coding, so its relation follows from the actual stripe
layout and must be derived from it.

**Two canaries per sweep, both mechanical:** an exclusivity/health check **before**, and the cross-source
consistency check **after**. On an unattended overnight chain these must *abort the chain themselves* rather
than wait to be noticed.

---

## The per-leg plan (dependency order)

Leg B repeats this identically. Ordering is driven purely by **what gates what** — no step is ordered by an
expectation about its result.

**Phase 0 — environment verification + baseline (gated on provisioning).** Confirm the transport is the
intended one from the client's own report (**D16**) and that the mount is healthy; confirm the provisioned
configuration matches what the fairness basis specifies (**D7**); confirm exclusive access; settle the
WEKA-GDS question with the single empirical cell (**D8**); capture the synthetic read/write baseline **per
block size**, because throughput is block-size-dependent and a single number misleads. Record as the leg's
reference baseline and re-confirm before each major run. **Every downstream "% of ceiling" divides by the
Stage-1.0 cell at the *matching* block size** — never a mismatched-block ceiling, which would make a mid-block
workload look artificially high or low.

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

**Wallclock is not estimated here.** Estimates from a different environment would be fiction, and an estimate
is a prediction. Each roadmap records actual durations as cells land, and the running total is maintained in
`../runs/INDEX.md`.

**Cost to complete is rolled up per leg from the same wallclock.** Each cell records its wallclock and both
price inputs (`RUNBOOK.md`); the leg figure is
`(instance $/hr + filesystem $/hr) × leg wallclock`, and it is the figure that turns the provisioning
asymmetry (**D7**) from a caveat into arithmetic (`../PROJECT-THESIS.md` §4). Prices are **fetched from the
vendor's current pricing and stamped with the date checked**, never recalled — a stale price silently rewrites
the conclusion. The leg figure is **infrastructure-only, excluding storage-software licensing**, and carries
that label wherever it is quoted (`RUNBOOK.md`).

---

## Stage map (`--stage` values)

## Stage 0 — infra validation
Smoke / recording-infra runs only. No real benchmark data. Used to prove `record-run.sh`, the per-FS adapters,
the S3 sync, and both canaries work on a newly provisioned environment **before** any measured cell.

## Stage 1 — Ingest
Substages: **1.0a/b/c/d** synthetic ceilings (fio: seqw / seqr / randw IOPS / randr IOPS — anchor first);
**1.4** local-NVMe scratch smoke-proof (the RAID itself is built by the instance bootstrap); **1.5** bulk local→filesystem copy (`fpsync`); **1.6** mixed
concurrent ingest + read; **1.7** S3 → filesystem hydration (the head-to-head ingest cell — identical method
on both sides); **1.8** FSx-native S3 import (**Lustre leg only**, capability cell, not head-to-head).

> **Why the WAN download is not a cell:** the pull from GDC / the CAMELYON open-data bucket happens **once,
> before either leg**, into our own S3 bucket. It measures a WAN link and an external service, not a
> filesystem. What *is* measured is **S3 → filesystem hydration (1.7)**, which must use the **same method on
> both filesystems** — otherwise the ingest numbers compare two mechanisms rather than two filesystems. FSx's
> native S3 data-repository import has no WEKA counterpart, so it is measured separately as **1.8** and
> clearly labelled.

## Stage 2 — Cataloging & metadata extraction
**2.0** OpenSlide property sweep (metadata-stress; magnification-independent). **2.1** DSA/MongoDB
integration — deferred.

## Stage 3 — Tissue detection (the 20× coord generator)
**3.0** CLAM tissue detection sweep — generates the 20× coords per the per-dataset args above, and gates all
of 4/5/6/7. **3.1** deferred.

## Stage 4 — Patching / tile extraction
- **4.A** pre-extract tiles to per-slide HDF5 (50-slide subset).
- **4.B** on-the-fly reads (OpenSlide CPU + cuCIM CPU batched). cuCIM `read_region(device='cuda')` is ruled
  out as a **library** defect, filesystem-independent — do not re-investigate, and never report it as a
  storage finding for either side (detail in `Stage-4-Patching.md`).
- **4.C** kvikIO + cuFile reads from the 20× raw-TIFF — the GPU-direct cell, run on both filesystems per the
  matrix above.
- **4.D** 20× raw-TIFF conversion (`convert-rawtiff-20x.py`) — an input-generation step that is itself a
  measured large-sequential write workload.

## Stage 5 — Training data pipeline
**5.A** kvikIO + cuFile + raw-TIFF → ResNet-50 DDP scaling sweep; **5.B** cuCIM CPU batched → ResNet-50 DDP
scaling sweep. DDP N-range follows the instance's GPU count (**D10**).

## Stage 6 — Feature extraction & MIL
- **6.A** foundation-model extraction (Virchow2 / GigaPath / UNI2-h `[PENDING-APPROVAL]`); Tier 1 (50-slide
  scaling) → Tier 3 (CAMELYON16 cross-dataset) → Tier 2 (full-BRCA 1073-slide cohort).
- **6.B** small-file / metadata stress: **B.3** canonical-CLAM `bs=1` MIL on real features → **B.1**
  synthetic-corpus generation → **B.2** file-IO stress.
- **6.C** concurrent multi-workload (QoS + endurance).
- **6.D** end-to-end pipeline timing — constructive bookend, **not** a measured cell.

## Stage 7 — Clinical Inference Deployment
**7.1** per-slide latency baselines (cold + warm × backends × models) · **7.2** latency under concurrent load ·
**7.3** heatmap write characterisation (consumes 6.A features) · **7.4a/b** streaming loop + read-after-write
consistency · **7.5a/b** mixed workload + endurance · **7.6** CAMELYON16 cross-dataset.

---

## Cross-stage decision register

One entry per **live** cross-stage or project-wide methodology decision, with **what, why, and the sources**.
The WHY and the official source are as load-bearing as the choice: in a competitive comparison every choice is
a place a skeptical reader looks for bias. Decisions scoped to one stage live in that stage's roadmap.

The ids are stable anchors cited from across the repo, not a sequence. When a decision changes, its entry is
**overwritten**; a superseded decision plus an explanation of why it was wrong helps nobody.

**D1 — Magnification: 20× "by the book."** 20× / ~0.5 mpp is the dominant published standard for the
foundation models we run, and **no model requires 40×**. *Sources (official model cards / papers):* UNI
"trained at 20× resolution" [HF `MahmoodLab/UNI`]; Prov-GigaPath "normalizes to 0.5 µm/px … tiles at 20×"
[Nature `s41586-024-07441-w`; HF `prov-gigapath/prov-gigapath`]; Virchow2 "0.5 mpp (20×)" [HF
`paige-ai/Virchow2`]; Mahmood Lab **Trident** canonical recipe `--mag 20`. → directly comparable to the
literature and to what customers run. *Why it matters to a storage comparison:* magnification sets tile count
per slide and therefore the I/O pattern both filesystems see; a non-standard magnification would make every
number harder to relate to a customer's real workload.

**D2 — Coord generation: CLAM with per-dataset args; do NOT switch to Trident.** CAMELYON16 `--patch_level 1
--patch_size 256`; TCGA-BRCA `--patch_level 0 --patch_size 512 --step_size 512` + reader resize → 256. *How:*
stock CLAM, no source patch (BRCA's 512→256 resize **is** CLAM's `custom_downsample`). *Why + sources:* CLAM
and Trident do the **identical** thing for a slide lacking a native 20× level — read the nearest native level,
resize to target. CLAM `wsi_core/WholeSlideImage.py` (`custom_downsample==2` → read 512@L0 → `.resize(256)`);
Trident `trident/wsi_objects/WSI.py` `get_best_level_and_custom_downsample()` + `WSIPatcher` resize. **The tile
content and the storage I/O pattern a benchmark measures are identical either way**, and CLAM avoids Trident's
coord-attr format shim rippling through every reader.

**D3 — Uniform 256 px @ 20× tiles across all three models.** Literature patch sizes, all @20×: UNI/UNI2-h 256,
Prov-GigaPath 256, Virchow2 224, CONCH 256, TITAN 512 [HF model cards; Trident per-encoder recipes]. *Why
uniform 256:* matches UNI2-h and GigaPath exactly; **Virchow2's native 224 is reached by the model's own resize
from the 256 tile** (standard practice); keeps coord generation **single-pass and shared across the three
models**, which preserves the Tier-2 shared-conversion optimisation; and the 256-vs-224 *storage* difference is
negligible. Holding tile size constant also keeps the cross-filesystem comparison clean — only the mount
varies.

**D4 — Raw-TIFF: produce a TRUE 20× artifact, not level-1 of a 40× raw-TIFF.** `convert-rawtiff-20x.py`
(tifffile single-level, 256 px-tiled, uncompressed 20× writer) rather than `cucim convert`. *Why + sources:*
`cucim convert` exposes no `--mag`/`--level` and always emits the SVS 40× level-0 (verified against the
installed version's `cli.py`; re-verify against the version actually installed). A 40× artifact read at pyramid
level-1 is ~4× larger, ~4× slower to produce, and **not what a 20× GPU-direct customer actually stores.**
*Storage-comparison consequence:* the raw-TIFF footprint is a provisioning input on **both** filesystems and,
on FSx, capacity is simultaneously a performance knob — so this decision feeds **D7**.

**D5 — Full-BRCA cohort: uniform 1073-slide 40×-base set.**
`../scripts/manifests/tcga-brca-full40x-stage4a-format.tsv`, plus a fail-loud mpp guard
(`0.4 ≤ eff_mpp ≤ 0.65`). *Why + sources — a ground-truth mpp scan of the BRCA set:* the
`openslide.objective-power` tag is **unreliable** (slides labelled 20× that are mpp≈0.25, i.e. true 40×), so we
key on **mpp, not the tag**. **None** of the set has a native 20× pyramid level. The per-dataset 20× read
mis-tiles a true-20× slide to **10×** (reads 512 px @ 20× → resize 256 = a 10× FOV) and halves its coord
density — so excluding the off-mag minority preserves the footprint-512 contract and removes a magnification
confound, while leaving a cohort far larger than a storage benchmark needs. The guard refuses any stray off-mag
slide as defence in depth.

*The three counts, and why they differ* — they are cited across the roadmaps and must not be conflated:
**1133** slides downloaded from GDC → **1131** with non-empty CLAM coords (the two zero-tissue DX2 slides
documented in `Stage-3-Tissue-Detection.md` produce none) → **1073** kept by the mpp filter (51 true-20× and 7
unknown-mpp excluded). The manifest header records the same derivation, and it is authoritative.

**D6 — Two sequential legs, with a machine-enforced environment contract.** Leg A = WEKA, Leg B = FSx for
Lustre, then the synthesis. *Why sequential:* the two are provisioned separately and the instance is rebuilt
between them; running them concurrently would mean two clients or a shared client, either of which breaks the
held-constant contract. *Why the contract:* legs separated in time can drift (AMI, driver, dataset bytes,
script commit), and drift is indistinguishable from a filesystem difference after the fact. So Leg A writes a
machine-readable contract that **Leg B verifies before its first cell**, split into fields that must match and
fields expected to differ, and a mismatch is fail-loud. Full rule text in `../PROJECT-THESIS.md` §3.

**D7 — Fairness basis: Lustre at MAXIMUM capability, WEKA at a realistic production config, cost reported
alongside.** *Why:* beating a competitor's **best** configuration is worth far more than beating one we sized
ourselves, and it forecloses the objection that whoever picked the tier picked the winner. The asymmetry is
stated in every result headline — a reader's first question is "what was the other side running?", so the
answer must already be on the page, and **cost-to-complete is what keeps it honest** (`../PROJECT-THESIS.md`
§4). **Maximum is defined per axis:** tier `PERSISTENT-1000` (the top SSD throughput-per-TiB tier); capacity
**≥25 TiB**, chosen because at that tier's MB/s-per-TiB it is where provisioned disk throughput exceeds the
client's line rate; **user-provisioned high metadata IOPS** (Persistent-2 provisions these independently of
capacity); EFA-enabled file system + EFA-mounted client.

**Both sides must be sized above what the client can drive** — **WEKA's backend count and capacity are
floored by the same rule**, because a filesystem provisioned below the client's capability measures its own
sizing rather than its architecture, and any delta that follows is a sizing artifact. This is a provisioning
requirement, not a prediction about results. The provisioned configuration of **both** sides is recorded into
the environment contract, so the fairness basis is verifiable after the fact rather than asserted.
*Sources:* [FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html),
[SSD storage performance characteristics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html)
— fetch both at provisioning time; tier names, per-TiB figures and limits change.
*Licensing is priced in — as a second recorded figure, not a replacement.* Every cell records
`software_usd_per_hr` alongside the other price inputs, and **both** cost figures — infra-only and all-in —
are computed per cell on **both** legs; which one leads the writeup is a writing-time choice made with all the
data present. The input is deliberately asymmetric and the recorded basis says so: FSx's service rate is
software-inclusive (`0` there), while WEKA's is the **public AWS Marketplace rate** — citable where a
negotiated price is not — dated like every price. An all-in figure with the asymmetry stated beats an
infra-only figure with the licence silently excluded: the latter is the most attackable number in the
deliverable.

**D8 — GPU-direct retained, and asymmetric by design.** kvikIO/cuFile is **not** dropped to force symmetry.
*Why:* Lustre-over-EFA supports GDS while WEKA-over-ENA may fall back to compat mode, and **that is precisely
the choice a customer faces on AWS** — so it is the measurement, not a confound. kvikIO/cuFile runs on both
sides, meaning the same application code and the same raw-TIFF artifact execute on both. Both sides
additionally get a plain-POSIX cell, because compat mode stacks a bounce buffer on top of POSIX and would
otherwise understate whichever side falls back. **The GDS-on-WEKA question is resolved empirically, not from
documentation** — WEKA's own materials claim GDS support on AWS while the transport analysis (ENA is not
RDMA-capable) suggests fallback; a single Phase-0 cell using `gdscheck -p` plus a recorded canary settles it,
and the matrix is built so either answer is usable. **Prove the path per cell** via cuFile's
GPU-direct-vs-bounced byte accounting; a config flag is not proof. *Sources:*
[FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html) (EFA-enabled
file systems support GDS; per-client caps by interface),
[WEKA networking](https://docs.weka.io/weka-system-overview/networking-in-wekaio).

**D10 — Compute instance `g6e.24xlarge`, with a pre-committed revisit trigger.** 96 vCPU, 768 GiB, 4× L40S,
200 Gbps across 2 network cards, 2× 1900 GB NVMe, EFA-capable. *Why this one:* L40S is the required GPU
family, and ≥200 Gbps is needed for a credible bandwidth axis (a 100 Gbps client would cap the client side at
roughly half). *Why it must be identical in both legs:* it is the single largest held-constant variable, and it
must be EFA-capable from the start because Leg B needs EFA even though Leg A does not. **Pre-committed revisit
trigger:** if Leg A's synthetic ceiling pins at line rate across block sizes **and** the `num_workers` sweep
saturates on CPU cores rather than storage, the instance is measuring itself rather than the filesystem — move
up (`g6e.48xlarge`, 8× L40S / 400 Gbps) **before Leg B**. Recorded in advance so the call is not made later
under sunk cost. *Consequences:* DDP N-range ∈ {1, 2, 4}; `num_workers` headroom; a GPU/NUMA pinning map
re-derived on the real instance. *Source:*
[EC2 accelerated-computing instance specs](https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html) —
fetch it; instance specs change.

**D11 — One `runs/` tree, with the filesystem as an explicit dimension.** `--fs {weka|lustre}` becomes a
run-dir name segment **and** a `metadata.json` field; aggregators pivot on it. *Why not one tree per
filesystem:* the deliverable **is** the cross-filesystem delta, and separate trees would force every comparison
to be assembled by hand; cross-leg drift is made **visible** by the **D6** contract instead of structurally
prevented (`../PROJECT-THESIS.md` §8). **The run-dir segment is load-bearing beyond bookkeeping:** both the
S3 sync and the teardown gate select run dirs by it, so a run dir missing it is never backed up **and the
teardown gate does not notice** — a silent loss of the only copy. The exact pattern they glob is recorded once,
in `NAMING-AND-VARIABLES.md`.

**D12 — Per-filesystem recording adapters, and a per-filesystem consistency relation.** The recording
philosophy is constant; the primary sources are not (`../PROJECT-THESIS.md` §7). *Why:* WEKA's DPDK client
bypasses the kernel network and block layers, so kernel counters mislead there — while on a Lustre client those
same counters **are** the data path. Using one filesystem's source table for the other produces confidently
wrong numbers. **The cross-source relation must be re-derived per filesystem, never ported:** WEKA's erasure
coding sets a specific wire-vs-app write amplification (hence capturing the EC scheme at provisioning), whereas
Lustre stripes across OSTs with no default erasure coding, so its relation follows from the actual stripe
layout. Both canaries run per sweep and **abort the chain mechanically** on failure, because the normal mode is
unattended overnight execution.

**D13 — Cold-vs-warm is a hard, enforced axis with cache state recorded per cell.** *Why:* both sides carry
substantial cache — the client's own RAM plus each filesystem's server-side cache — and the two are not equal
and not under common control. Any warm cell therefore risks measuring cache rather than storage, and the risk
is *asymmetric*, so a corpus genuinely cold on one side may be partly warm on the other and produce a
cache-size artifact that looks like a filesystem difference. Making cold-vs-warm explicit protects the result
in both directions: it prevents a cache-served number being read as storage performance, and a cold number
being read as steady-state.

**How the axis is satisfied, in order of preference.** An explicit cold/warm dimension is not the only way, and
often not the best one: `O_DIRECT` already removes the client page cache, and a managed service exposes no
interface for clearing its server-side cache — so unless that turns out to be wrong, a nominal "cold" arm on
many cells would differ from its warm twin only by an uncontrolled variable, doubling the wallclock to
separate nothing. **What is actually achievable per filesystem is determined before the first measured cell,
not assumed here.**

1. **Cold by construction — preferred wherever a working set can be sized.** Make the read working set exceed
   **the larger of the two server-side caches**, and there is nothing left for cache to serve. **Size it
   against both filesystems' caches:** FSx's follows from its documented file-server cache per TiB at the
   provisioned tier and capacity, WEKA's from the backends' aggregate RAM; **fetch the FSx figure at
   provisioning rather than recalling it.** Where one corpus definition must serve both legs, this is the only
   option that preserves the held-constant contract (§6).
2. **A cold reference cell.** One cell at a single point in the grid, run cold, as *evidence* that (1) worked
   or that an exemption holds. Costs a fraction of a full axis and converts an assertion into a measurement.
3. **An explicit cold/warm dimension.** Right where the axis is genuinely informative and the sweep is cheap —
   a metadata sweep whose whole stage runs in minutes, for instance.
4. **A recorded exemption.** Permitted only with a stated technical ground — e.g. a mixed steady-state cell
   that is warm by construction because production is warm — and only alongside (2), so the exemption is
   evidenced rather than asserted.

**Three mechanics that decide whether any of this works:**

- **Data written immediately before it is read is server-cache-resident.** A read cell whose files are created
  in a layout phase seconds earlier is measuring the write cache. Stage its data ahead of the timed window and
  do not unlink and recreate between cells.
- **Client-side clearing must drop dentries and inodes, not just the page cache.** For a metadata workload the
  attribute and dentry caches are the relevant ones: a warm dentry cache can serve `open()` entirely
  client-side, which makes the cell measure the client's VFS rather than either filesystem's metadata path —
  and it does so *identically on both legs*, compressing the very difference the cell exists to find.
- **Never let warmth track the swept variable.** A grid run in ascending concurrency warms monotonically with
  concurrency, so the two effects cannot be separated afterwards. Randomise or reverse cell order.

**Cache state is recorded as achieved per cell either way**, with the residual uncertainty stated — the
server-side component is only partly under our control on a managed service. *Source:*
[SSD storage performance characteristics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html).

**D14 — S3 is the durable store; git and S3 have non-overlapping authority.** Instance-local NVMe and both
filesystem mounts are **ephemeral** — they die with the instance and the cluster, and the instance is
deliberately rebuilt between legs. **git is authoritative for all small text**; **S3 for the heavy write-once
data git cannot hold.** Because the two do not overlap, **S3 versioning is unnecessary** — an object is
written once and never edited, so there is no prior version for versioning to retain and nothing it would
protect that the write-once discipline does not. Full rule text,
including the two deliberately different sync semantics, in `../CLAUDE.md` → Durability.

**D15 — The two clients consume CPU differently, so CPU-derived metrics need a per-filesystem core
accounting.** The **WEKA client reserves dedicated cores for its DPDK data path; the Lustre client does not**
(it works through kernel threads). On one identical instance, the number of cores actually available to the
application therefore **differs between legs** — which makes raw "CPU %busy", and any throughput-per-core
figure computed against total cores, invalid as a cross-leg comparison. *Why this matters beyond bookkeeping:*
it is a real architectural cost difference, and both ways of ignoring it are wrong — hiding the reservation
flatters Lustre's available parallelism, while excluding the reserved cores from WEKA's cost flatters WEKA's
per-core efficiency. **How every stage handles it:** record **cores reserved by the filesystem client**,
**cores available to the application**, and **total cores** per cell on both legs; compute compute-saturation
readings over **application-available** cores; treat the reserved-core exclusion list as a **per-filesystem
adapter parameter, not a constant**; and report the reservation itself as part of that filesystem's cost rather
than netting it out silently. Most load-bearing in the compute-leaning stages (3, and the CPU backends in 4.B /
5.B / 6.A), and it also shifts *effective* parallelism at a given nominal concurrency, so both nominal `n` and
available-core count are recorded per cell.

**D16 — Each filesystem is measured on its intended transport, and a fallback aborts rather than proceeds.**
**WEKA over DPDK. Lustre over EFA.** Both stacks have a working lower-performance fallback that engages
*without erroring* — WEKA's client can run UDP-only (`num_cores=0 -o net=udp`), and an FSx Lustre client that
has the generic EC2 EFA software but not the FSx-specific client configuration mounts over **TCP**. *Why this
is a recorded decision rather than an implementation detail:* each fallback produces a complete, plausible set
of numbers for a configuration this project has explicitly promised not to measure — UDP would understate
WEKA, and TCP forfeits both GPUDirect Storage and the escape from Lustre's per-client-per-file-server bandwidth
cap, breaking the "Lustre at maximum" fairness basis (**D7**) invisibly. So the intended transport is **not** a
tuning preference to be optimised toward; it is a **precondition of the measurement**.

**Enforcement.** The transport in use is evidenced from the client's own report, never inferred from the
mount options passed — the instance bootstrap records the WEKA leg's DPDK-vs-UDP evidence at boot, and the
Lustre cluster prompt requires `lnetctl net show` to list an `efa` net, not only `tcp`. The
evidence is written into `FS_TRANSPORT`, and **`run-leg.sh` refuses to start a leg when it is unset or shows
the fallback** without a written waiver. **If the intended transport cannot be brought up, the instruction is
STOP AND REPORT IMMEDIATELY — at the setup step, before mounting, and before any cell runs, including a
throwaway one.** Explicitly *not* "measure it and flag it in the writeup": the fallback works, so by the time
the flag is read the wallclock and the money are spent and the results tree's provenance has to be argued
about. Deliberately measuring a fallback transport requires a **written human waiver with the reason
recorded**, and would force a re-baseline and a restatement of the fairness basis. DPDK on a VM depends on
SR-IOV exposing a Virtual Function of the physical device — an instance/driver capability, not a choice — so
the realistic resolutions are to fix the configuration or change the instance. Record the transport per leg in
the environment contract either way.

**Distinct from the GPU-direct axis, and not to be conflated:** WEKA falling back to **cuFile compat mode** is
part of asymmetry 2 and is a **measured axis** — both cuFile modes run on both filesystems (**D8**). A
transport fallback is a stop; a cuFile compat-mode result is data. *Sources:* `docs.weka.io` on `num_cores` /
`net=` mount options and the UDP-mode limitations (a UDP client "cannot be configured in high availability
mode"); AWS FSx for Lustre client documentation for the EFA client configuration.

**D18 — Run-to-run variance is measured, and deltas must clear the noise band.** *Why:* every cell is
single-shot by default and the two legs run days apart on rebuilt hardware in a shared cloud — without a
measured noise band, any cross-leg delta is arguable as jitter, and that argument lands on the weakest point
of an otherwise fully-instrumented comparison. Three mechanisms, **identical on both legs** because the policy
itself is a held-constant input: **(1)** a fixed **stability-canary pair** (`sweep-stability-canary.sh`: 8 GiB
O_DIRECT fio read cell + create/stat/unlink metadata cell, ~3 min the pair) interleaved by `run-leg.sh` at
nine points across the leg — a start/end bracket plus interior points between the major sweeps — whose spread
is the leg's empirical noise band; a cross-leg delta is **quoted only where it clears both legs' bands**.
**(2)** **N=3 for headline cells**: the per-leg knee and pinned-peak cells (discovered by each Tier-1, so the
repeats run right after the peak cell completes — `REP=2` / `REP=3` re-invocations; `record-run.sh` suffixes
the run name and records the `rep` field) plus the designated short headline cells; aggregation reports
**median with spread** where a config has multiple reps. **(3)** Long cells (hours-scale, internally
averaging) get a **split-window check** — first-half versus second-half agreement from the already-recorded
timeline — instead of repeats. Estimated cost ≈ 4–6 h per leg (~4–6%); the canary alone is ~1.5–2 h.
*Procedure:* `RUNBOOK.md` "Run-to-run variance". Band computation and rep-grouping live in the shared
aggregation helper (**tracker D-4**).

---

## Naming convention

Run directories: `<UTC-timestamp>-<fs>-s<stage>-<workload>-<config>` — e.g.
`2026-…-weka-s4.C-kvikio-brca-N4-compat`. The `--fs` and `--stage` values passed to `record-run.sh` become the
`<fs>` and `s<stage>` segments automatically and are both recorded in `metadata.json`, so the aggregators pivot
on filesystem without parsing directory names. `record-run.sh` derives the runs root from its own location on
disk, so run dirs and `INDEX.md` land in this repo's `runs/` tree.
