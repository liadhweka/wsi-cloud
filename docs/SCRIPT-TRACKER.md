# Script tracker — per-script reference for `../scripts/`

> **Configuration comes from the environment, never from hardcoded literals.** Every variable is enumerated
> in **`NAMING-AND-VARIABLES.md`** with its recommended value, and set via **`../env.example.sh`** → `env.sh`
> (which has a `--check` mode that validates before anything runs). **Read that doc before editing any
> script** — it is the single source of truth for names, and the reason `$FS_MOUNT` exists.
>
> The remaining per-filesystem adapter and environment-value work is listed under **Deferred work** below.
> Retargeting itself is complete.

For *what* each stage is see `STAGES.md`; for how to run a cell `RUNBOOK.md`; for where things live
`FILESYSTEM-MAP.md`; for the rules `../CLAUDE.md`.

---

## How to read this doc

Every entry gives **what it does**, **why it exists** (the methodology rationale, not just the mechanics),
its **inputs → outputs**, and any **caveats** — the non-obvious behaviour that costs debugging time if
forgotten. Scripts are grouped by stage, after the cross-stage infrastructure they all depend on.

**Deferred work is marked `⏳ DEFER`** and is also tracked in the `cloud-session-open-items` memory, so it
cannot be lost by living only here.

---

## ⚠️ Deferred work — what must change before anything runs

None of this could be done meaningfully before the environment exists. All of it is a **hard prerequisite**
for a valid cell.

### ⏳ Deferred — genuinely needs the real environment

| # | Work | Scope | Why it can't be done yet |
|---|---|---|---|
| **D-4** | **Per-filesystem recording adapters — WEKA-leg recorder half DONE; remaining: the shared aggregation helper, and the Lustre half on Leg B** | the aggregators' filesystem-side parsers (helper); `record-run.sh` + `parse-results.py` (Lustre half) | **Done on the Leg-A instance against live streams:** `record-run.sh` now carries a per-`$FS` recorder set and required-stream list, the INCOMPLETE rule evaluates against the leg's own list, and a Stage-0 cell records `OK` with the WEKA primaries live (verified: client-summed WEKA-side vs fio app-level agree within ~5%). `parse-results.py` emits `weka_stats_client` — the pattern-#1 client-filtered per-timestamp-summed series — beside the whole-stream context aggregates. The wrapper **refuses `--fs lustre`** until the Lustre recorder set is written against the live `/proc/fs/lustre` + `lctl get_param` (`osc.*.stats` / `llite.*.stats`) streams on the provisioned Leg-B cluster — never a recalled format. **Still deferred:** the **shared per-leg schema helper** (one module the aggregators import) replacing the per-file filesystem-side parsers; B-1's `_reserved_cores` folds into it; it owns **metric-key naming** (normalize the `non_dpdk_*` / `agg_cpu_busy_ex_dpdk_*` keys to leg-neutral names while no sweep exists), groups rep-indexed runs (**D18**) reporting **median + spread**, computes the stability-canary noise band per leg, and **reconciles declared vs achieved cache state per cell** (**D13**) — a declaration without its achieved evidence is marked and never quoted as its declared regime; the Lustre-side evidence source gets named during the Leg-B build. Capture note: flag-less `sar -o` verified on this instance's sysstat — all converted categories populated on the Stage-0 smoke |
| **D-5** | **Per-filesystem consistency relation — WEKA derivation + evaluator BUILT; remaining: band calibration on the post-switch cluster, and the Lustre half on Leg B** | `wsi_agg_helper.py` (`check <run-dir>`) | The WEKA relation is derived and written down (helper docstring + Stage-1 register): clients place EC stripes on backends directly, so write wire/app = (D+P)/D from `WEKA_EC_SCHEME` and read = 1.0 — anchored by the 2026-08-15 Stage-0 probes (5+2: write 1.455 = 1.40 × ~1.04 protocol; read 1.034). **Bands are loaded from `runs/.leg-state/$LEG/canary-bands.json` — absent, the canary exits non-zero as UNCALIBRATED rather than inventing a tolerance. The WEKA leg is CALIBRATED (2026-08-16, `calibrate-canary-bands.sh`, 12 cells on the 6xlarge cluster): anchors reproduce (write 1.456, read 1.042); 4K derived separately (read 1.424, write 1.372 → smallbs_widening 1.366); `check` PASSES end-to-end.** Remaining: chain wiring (D-7 canary-abort — until then run `check` after every sweep by hand); mixed-cell widening needs mixed calibration cells before 1.6; the Lustre relation derives from the actual stripe layout on Leg B (the helper refuses until then) |
| **D-6** | **cuFile path accounting — 4.C recorded source + consumer BUILT; remaining: the Stage-5/6 worker wiring, the recorded Phase-0 verification cell, and the INCOMPLETE-requirement wiring** | `wsi_cufile_accounting.py` (new shared module); `read-tiles-kvikio.py` + `aggregate-stage4c-kvikio.py` (done); `train-resnet50-stage5.py` + `extract-features-foundation-stage6.py` (pending); `record-run.sh` (pending, with **D-30**) | **Done:** the shared module snapshots `/proc/driver/nvidia-fs/stats` (live ver-4.0 format), emits the per-cell `path_accounting` split — `gds_bytes` / `bounced_or_posix_bytes` / `gds_engaged ∈ {gds, partial, none, no-reads, unknown-accounting-off}` — plus both kvikio compat fields, because path accounting has **three layers** (kvikio's own compat can serve reads via POSIX without entering cuFile at all — verified live 2026-08-15). `aggregate-stage4c-kvikio.py`'s `gds_engaged` now carries the recorded value (per-process consensus on mp cells; disagreement reports as `mixed(...)`); an accounting-off state reports as unknown, never zero. **The Phase-0 determination ran on the 6xlarge cluster (2026-08-16, `probe-gds-phase0.sh`): no true GDS on WEKA-over-ENA — cuFile = compat/bounce; strict-GDS open refused; outcome + consequences in `Stage-4-Patching.md`.** The INCOMPLETE wiring is DONE (D-30/register D21: `RECORD_KVIKIO_CELL=1` without a recorded split → INCOMPLETE). **The Stage-5 trainer AND Stage-6 extractor wiring are DONE** (same pattern in both: the kvikIO reader accumulates per-rank aligned cuFile bytes, all-reduced; rank 0 holds one cell-global `PathAccounting` window — nvidia-fs deltas are device-global, so it covers all ranks — and emits `path_accounting` into `training-summary.json` / `extraction-summary.json`, which the D-30 wrapper check finds; drivers set `RECORD_KVIKIO_CELL=1` on kvikIO cells only). Smoke-verified live on the Stage-5 cell 2026-08-18. **Remaining:** the nvidia-fs block parser in `parse-results.py`; the pre-cuFile-cell canary requirement (with D-7 — on this leg the known-good signature is bounce-accounting non-zero) |
| **D-7** | **During-run sync, watchdog, canary-abort** | `record-run.sh` | **Partly done:** `sync-to-s3.sh` exists and `run-leg.sh` syncs after every step. Still needed: per-**cell** sync inside `record-run.sh`, the per-cell watchdog timeout, and making the canary abort the chain |
| **D-8** | **GPU/NUMA map + DDP ranges** | `run-multiproc-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6a-extract.sh`, `sweep-stage7-clinical.sh` | The GPU↔NUMA↔NIC map must be re-derived on the real instance; GPU-count sweeps follow its GPU count |
| **D-9** | **Core-accounting values** | `env.sh`, per leg | The exclusion **mechanism** is in place — `record-run.sh` records `cores_reserved` from `FS_CLIENT_RESERVED_CORES` and every CPU aggregator reads it per run, refusing null. What remains is the per-leg **value**: measure the reserved-core list on each real client (**D15**) and set the variable (`none` on a leg that reserves none) |
| **D-10** | **cuFile config + env VALUES** | ~20 files reference conda/cuFile/CUDA paths. They now genuinely read documented variables (`$CONDA_ENVS_DIR`, `$LIBCUFILE_PRELOAD`, `$CUFILE_ENV_PATH_JSON`) and refuse if unset — audit items `A-4`/`A-5`; before that they were literals from another machine. What remains is the **values** | Leg A's values are set by the bootstrap (`LIBCUFILE_PRELOAD` located and exported; a compat-mode `cufile.json` generated per instance). Remaining: rewrite `../scripts/GDS-TUNING-CHECKLIST.md` (bannered) incl. a Lustre-over-EFA branch, and Leg B's cufile config |
| **D-11** | **Lustre tuning** | Stripe layout + client tunables | Needs FSx (Leg B). **Part of "Lustre at maximum" (D7)** — skipping it would understate Lustre and break the fairness basis. AWS's documented client tunings for >64 GiB-RAM and >64-vCPU clients (ldlm LRU, ptlrpcd/ksocklnd module params, max_rpcs_in_flight, statahead) apply to this instance class — take them from the live FSx performance-tips page at Leg-B setup, never from a recalled copy |
| **D-16** | **Lustre client-side EFA configuration** | `../prompts/prompt-lustre-cluster-cloud.md` | The documented Leg-B flow enables EFA on the instance and the file system and installs the generic EC2 EFA software, but nothing yet runs AWS's FSx-Lustre EFA client setup — so the client would mount over TCP, forfeiting GDS **and** the per-server-cap escape while still producing numbers. That breaks the "Lustre at maximum" basis (**D7**) invisibly. Needs the current AWS FSx-Lustre client docs, plus a gate that `lnetctl net show` lists an `efa` net |
| **D-17** | **Leg-B kernel-vs-contract policy — and the same "latest is not a pin" hazard in the NVIDIA stack** | `../prompts/prompt-lustre-cluster-cloud.md`, `bootstrap-instance.sh` | The documented Lustre client install can pull a newer kernel, and `kernel` is a `MUST_MATCH` contract field — so the Leg-B procedure can invalidate the comparison the contract exists to protect; any OS upgrade can too. Decide: pin the kernel and install a client build matching the running kernel (per AWS's install docs for this OS), or re-baseline both legs. **Same class, one layer down:** the client AMI is now pinned in terraform (`client_instance_ami_id`, 2026-08-15), but the bootstrap installs the NVIDIA driver via unpinned `dnf install nvidia-driver`, so `DRIVER_VERSION`/`NVIDIA_FS_VERSION` can drift between legs independently of the AMI. Before Leg B's rebuild: pin the driver package to Leg A's recorded versions (dnf versionlock or explicit package versions from the contract), or accept the contract verify as the tripwire and re-baseline deliberately if it fires |
| **D-19** | **Substage 1.8 has no implementation and no marker** | `Stage-1-Ingest.md` | The FSx-native S3 import is the only substage with neither a driver row, a "no implementation" note, nor a deferred id. It is a Lustre-leg capability cell excluded from the head-to-head, so omitting it breaks no cross-leg comparison and would go unnoticed. Build it in Leg B or record a decision not to |
| **D-24** | **Cross-leg artifact fingerprints — three of four classes BUILT + CAPTURED (`dataset-bytes`, `coords-3.0`, `rawtiff-4d`); remaining: `features-6a`, once 6.A first produces output** | `fingerprint.py` `capture`/`compare`; definitions in `STAGES.md` **D19** + the `RUNBOOK.md` gates table | The four per-class definitions are decided (dataset bytes: hashed path/size/md5 list; coords: per-slide count + array-contents hash; raw-TIFF: byte count + tile grid; features: counts + shapes + dtype, never values) and fingerprints land in `runs/.leg-state/<leg>/fingerprints/` (git-tracked). Each class is built against its first real artifact, never imagined output — `features-6a` refuses until 6.A's features exist; build it right after, before 6.B.3/7.3 consume them |
| **D-25** | **Stage 6.C's 4-GPU partition** | `orchestrate-concurrent-stage6c.sh` | 6.C pins MIL to GPU 0 "to stay out of the extract workload's GPUs" while extract requests 4 — an isolation that is arithmetically impossible on a 4-GPU instance. Decide the partition (extract on 3 + MIL on 1, or accept sharing and delete the isolation claim); either way the retention denominators change, so it is a methodology call, not a tuning one |
| **D-26** | **The dangling `Q<n>` decision-citation scheme** | 29 citations across 12 scripts | Scripts cite locked decisions as `Q1`–`Q13`; **zero `Q<n>` identifiers survive anywhere in `docs/`**. Every one of those citations is unresolvable. Either reintroduce stable ids into the per-stage registers or rewrite the citations to name the decision — a convention call either way |
| **D-30** | **Verdict semantics DECIDED + wrapper half DONE (ratified 2026-08-16; register D21): cache_state undeclared on a stage≥1 cell → INCOMPLETE; `RECORD_KVIKIO_CELL=1` without a recorded `path_accounting` split → INCOMPLETE; missing cost inputs → warn only (re-derivable arithmetic); contract-verified marker absent at leg start → refuse (was D-21). Remaining: the driver declarations** | stage 3–7 sweep drivers | The wrapper now refuses undeclared cells, so **every stage 3–7 driver must set `RECORD_CACHE_STATE` per cell (and `RECORD_KVIKIO_CELL=1` on kvikIO cells) before its stage runs, or the chain aborts on a mislabelled-as-INCOMPLETE cell**. Done: stage-3, 4.A, 4.D, **4.C** (`cold` — client-cold at read/window entry with the reader's `client_page_cache_discarded` as the reconciler evidence; `warm` on a `--warm-cache` cell), **5** (`warm` — steady-state by construction, note-worded for the reconciler). Remaining, at each stage's gate: **6.A Tier 2's chunked orchestrators** (their regime — reads of just-converted, server-cache-resident chunks — is a methodology call to surface at the Tier-2/CHUNK_SIZE gate; Tier 1/3 cells are done: kvikio `cold` per-slide-discard, cucim `warm` steady-state), `sweep-stage6b-{mil,stress}.sh`, `sweep-stage6c.sh`, `sweep-stage7-clinical.sh`. Regimes follow each roadmap's cache-discipline row; surface any stage whose roadmap defines none |
| **D-31** | **The environment contract omits the 20 workload-shape variables** | `env-contract.py:48-72` | `docs/NAMING-AND-VARIABLES.md` Table 5 declares them identical-across-legs, but the contract records none. **Do not simply append them to `MUST_MATCH`:** `verify()` pushes a null-vs-null pair into `unrecorded` and returns FAILED, so the normal case (both legs on defaults) would fail. Needs a tri-state or a defaults-aware comparison |
| **D-32** | **`dataset_manifest_sha` hashes the manifest, not the dataset bytes** | `env-contract.py:174-175` | The held-constant field "the datasets and their byte contents" is therefore asserted, never verified. Full rehashing costs hours of leg wallclock, so the cheaper options (file count + total bytes + newest mtime; or a sampled hash) are a methodology call |
| **D-33** | **Stage 7's `## 7.1` headline grid is structurally always empty** | `aggregate-stage7-clinical.py` | The grid filters on `cell_name.startswith('7.1')`, but `RUN_NAME_RE` strips the stage segment, so a `record-run.sh`-named dir `…-s7.1-baseline-…` yields `cell_name='baseline-…'` and never matches. 7.2 only appears because its driver pre-computes a `-s7-7.2-…` dir, leaving the sub-tier inside the name. Either match on the recorded `stage` field or stop stripping the segment — but the two naming shapes must be reconciled first, which is why this is not a one-line fix |
| **D-35** | **Local raw telemetry fills the 48 GB root volume mid-leg — relocate-after-verified-sync belongs in the chain** | `run-leg.sh` (per-step sync), terraform (next rebuild) | The 2026-08-16 ENOSPC abort: `runs/*/raw` accumulates locally (~16 GB by mid-1.0b) although S3 already held every byte via the per-step verified sync, and the HF model cache (13 GB) also lived on the root volume. Interim (this leg): the session chain relocates each finished step's raw payloads to `/data/local-nvme/runs-raw-overflow/` with symlinks back — nothing deleted, S3 authoritative, parsers still resolve. **New mechanism (2026-08-19): `record-run.sh` honours `RECORD_RAW_ON_SCRATCH=1` — raw/ is created on the overflow and symlinked from birth**, for cells whose telemetry exceeds root headroom (the Tier-2 multimodel cell writes ~30 GB over ~25 h; the 6.A brca_full cells set it too). Same layout the post-sync relocation produces; sync follows symlinks. Durable remainder: fold relocate-after-verified-sync into `run-leg.sh`'s per-step sync for ordinary cells, and size the root volume ≥100 GB at the next rebuild (terraform, human) |
| **D-36** | **The 1.0 sweep drivers are attempt-all but NOT resume-skip — RUNBOOK's "re-running the driver re-does only what is needed" does not hold for them** | `sweep-stage1-{seqw,seqr,randw,randr}.sh` | A mid-sweep abort (the ENOSPC hit cells 35–36 of 1.0b) forces either a full ~5 h re-run or a manual surgical re-run of the missing cells plus a hand-written step marker (done 2026-08-16 for 1.0b, cells re-run exactly as the driver would have — same names/notes/offsets). Add skip-if-completed-OK per cell (keyed on an existing OK run dir for the same cell name) before Leg B, where the same recovery premise will be relied on |
| **D-37** | **`sync-to-s3.sh --mode full` duration grows linearly with run-dir count** (one `aws s3 sync` invocation per run dir → S3 LIST round-trips even with nothing to upload; ~5 min at ~190 dirs, plausibly 15+ min at leg scale) | `sync-to-s3.sh` | Not a correctness issue — the per-dir verify is honest work — but it sits inside `backup.sh` on the commit path and inside `teardown-prep.sh`. Batch the per-dir syncs (one sync over `runs/` with include patterns) or skip dirs whose raw was already relocated + verified, keeping the archive semantics and the post-sync count verification intact |
| **D-38** | **Ten aggregators lack the FAILED-dir exclusion** — a forensic `-FAILED-<reason>` suffix does not escape their prefix globs, so a renamed dir with a parsed `results.json` re-enters the summary as a zero/garbage row (bit 4.C on 2026-08-18; fixed there, and `aggregate-stage6a-extract.py`/`aggregate-stage1-hydrate.py` already exclude) | `aggregate-stage{1-mixed,1-fpsync,2-properties,3-tissue-detection,4a-patches,4b-tilesread,6b,6c-concurrent,7-clinical}.py`, `aggregate-sweep.py` | Past summaries are gate-verified CLEAN (earlier FAILED dirs had no parseable results, and `aggregate-sweep.py`'s name regex rejects the suffix), so no recorded data is polluted — apply the exclusion when each is next touched, or in one pass before Leg B, same policy as the abort-on-failure retrofit |
| **D-34** | **Short-cell recorder poll rate — DECIDED (ratified 2026-08-16, Stage-2 register): raise the filesystem-side poll rate for short cells (~10 Hz), identically on both legs; build it** | `record-run.sh` (recorder set) | Sub-second high-concurrency Stage 2/3 cells yield 1–3 samples at 1 Hz, so any sustained mean is ill-defined and both legs lose filesystem-side evidence exactly where the metadata architectures differ most. Implement before the first Stage 2/3 cell; verify the higher rate does not itself perturb the measurement (the recorded `_sample_interval_s` block is the evidence) |

> **Nothing was deleted.** An earlier plan assumed GPUDirect Storage would be dropped, which would have
> removed the kvikIO / raw-TIFF / cuFile scripts. **GDS is retained and asymmetric by design** (**D8**), so
> the entire library carries forward — including `read-tiles-kvikio.py`, `run-multiproc-kvikio.sh`,
> `sweep-stage4c-kvikio.sh`, `aggregate-stage4c-kvikio.py`, `convert-rawtiff-20x.py`,
> `convert-stage4c-rawtiff.sh`, `fe-core-kvikio.sh`, `GDS-TUNING-CHECKLIST.md`, and
> `cufile-full-rdma.template.json`.

---

## Cross-cutting patterns (learned the hard way — preserve these)

These recur across scripts and each one exists because its absence caused a real failure. The safety
property they share: an unset or inconsistent input **aborts loudly** instead of defaulting — the project's
worst failure mode, *silently measures the wrong filesystem while the number still looks correct*, is
converted into *refuses to run*.

1. **Per-timestamp client summing, not a pre-aggregated mean.** An aggregator that reads a pre-aggregated
   filesystem-side metric can under-report by ~100×, because that metric averages across **all** rows in the
   stats stream including many idle server-side rows. **Correct pattern:** re-read the raw stats CSV, filter
   to the client's own rows, sum across the client's processes **per timestamp**, then aggregate the
   per-second sums. Filter by a stable identity — **role** (`Mode=="client"`; this cluster runs exactly one
   client container by design) — never a hostname or a numeric process/node id, both reassigned on rebuild or
   reinstall. ⏳ **The pattern generalises to both legs; the source schema does not** (D-4).
2. **`setsid` + process-group kill, never `pkill -f`.** A `-f` pattern matches the wrapper shell and the
   recording wrapper too (their argv contain the pattern string), so the signal kills the whole chain —
   producing duplicate `INDEX.md` entries and a spurious `INCOMPLETE` on a cell whose data is fine.
3. **Per-cell `LD_PRELOAD` scoping.** Set the system libcufile only on kvikIO cells. cuCIM links libcufile
   internally even for CPU reads and segfaults on an ABI mismatch. Nearly every sweep here is mixed.
4. **Pre-computed run dir via `RECORD_RUN_DIR`.** When a driver needs the run-dir path *before* invoking the
   wrapper (to pass output paths into the wrapped command), it exports `RECORD_RUN_DIR` and the wrapper uses
   it instead of generating its own timestamp — eliminating a caller/wrapper timestamp race.
5. **Cleanup-before-cell where a script skips existing output.** Three places reuse output *without failing
   loud*: the raw-TIFF converter, the 6.A extractor, and Tier-2 chunked conversion. Without a wipe, every
   cell after the first short-circuits and reports a plausible-looking meaningless number.
6. **Generous collective timeouts for ragged workloads.** Datasets with wide per-slide tile-count
   distributions make the slowest rank dominate; a short default collective timeout kills an otherwise valid
   multi-rank cell.
7. **Parser idioms that bite.** Lowercase CSV headers; `;`-delimited `sar` output; unit suffixes inside
   numeric telemetry fields; **cumulative wire counters requiring diff/dt**. All handled in the existing
   aggregators — don't regress them. **The dt is read from the samples' own timestamps, never assumed from
   the nominal sample rate** — see `parse-results.py` for why a rate divided by an assumed interval is a
   silent, systematic overstatement.
8. **Idle-robust active-window mean.** Throughput aggregates use a trimmed active-window mean rather than a
   whole-window mean, because a storage-idle setup or model-load phase inside the recording window otherwise
   dilutes the number badly. Keep the naive full-window value alongside so both remain visible.

---

## Cross-stage infrastructure

### `record-run.sh` — the recording wrapper
**What.** Wraps any benchmark command: pre-run snapshot → start all recorders → run the command with
stdout/stderr tee'd → stop recorders cleanly → post-run snapshot → parse raw CSVs into `results.json` →
append one line to `INDEX.md`. Derives the runs root from its own location on disk, so the tree it writes
into is determined by where the script physically lives.
**Why.** "If it isn't recorded, it didn't happen." One wrapper means every cell in the project is recorded
identically, and per-cell failure is isolated — a bad cell goes `INCOMPLETE` without taking down the sweep.
**I/O.** `--stage`, `--run-name`, `--note`, then `--` and the command → a fully populated run dir.
`metadata.json` carries core accounting (`cores_total`/`cores_reserved`/`cores_available`, expanded from
`FS_CLIENT_RESERVED_CORES`) and the declared `cache_state` (from `RECORD_CACHE_STATE`, set per cell by the
sweep drivers) — each recorded null + warned when unset, never guessed; CPU aggregators refuse a null
`cores_reserved` (**D15**/**D13**).
**Caveats.** Honours `RECORD_RUN_DIR`. Marks `INCOMPLETE` if the command returns non-zero, **or** any stream
in **this leg's required list** has fewer than two lines (per-`$FS`, D-4), **or** — the ratified D-30
verdict semantics (register D21) — a **stage ≥ 1 cell has no `RECORD_CACHE_STATE` declared** (write cells
declare `na-write-cell`; deliberate non-axes declare `na-*`; stage 0 is exempt — infra proofs measure the
recorder, not storage), **or** a cell declared `RECORD_KVIKIO_CELL=1` has **no recorded `path_accounting`
split** in the run dir (a config flag is not proof of path, D8). **Missing cost inputs stay warn-only** —
cost is re-derivable arithmetic from wallclock + a dated price; a missing regime or path proof is not. The WEKA-leg set: `weka stats
realtime` 1 Hz poll (all processes; client rows filtered at parse time), `nvidia-smi`, `sar`, kernel netdev
counters (Diagnostic here except 1.7), RDMA/EFA device counters (header-only where absent, not required on
this leg), and a **verbatim 1 Hz `/proc/driver/nvidia-fs/stats` capture** (the kernel half of cuFile path
accounting). Snapshots also capture nvidia-fs params and the cell's cuFile config. `metadata.json` carries
`fs_transport` from `FS_TRANSPORT`. **Refuses `--fs lustre`** until the Lustre recorder adapter is built on
Leg B (D-4).
**⏳ DEFER:** the Lustre recorder half (D-4); cuFile path accounting's reader half + the kvikIO-cell
requirement wiring (D-6); during-run S3 sync, per-cell watchdog, canary-abort (D-7).

### `wsi_agg_helper.py` — the shared per-leg aggregation helper (D-4 remainder, D-5, D-13, D-18)
**What.** One importable module (stdlib-only, same directory as the aggregators) holding the per-leg logic:
the **consistency relation** (WEKA: (D+P)/D writes, 1.0 reads, from `WEKA_EC_SCHEME`; Lustre: refuses until
built on Leg B), the **canary evaluator** (`check <run-dir>` — verdict per direction with every widening
named; bands from `runs/.leg-state/$LEG/canary-bands.json`, and **UNCALIBRATED exits non-zero** rather than
inventing a tolerance), the pattern-#1 **client series**, **D18 rep grouping** (median + spread;
`single_shot` flagged) and the **stability noise band**, **D13 cache reconciliation** (`cache <run-dir>` —
declared vs achieved; verdicts CONSISTENT / DECLARED_WITHOUT_EVIDENCE / CONTRADICTED / NOT_APPLICABLE /
UNDECLARED, and anything not CONSISTENT is marked, never quoted as its declared regime), and the
**leg-neutral metric-key map** (`non_dpdk_*` → `app_cores_*`).
**Why one module.** Per-leg logic in fourteen aggregators drifts fourteen ways; the stale copy is invisible.
**Caveats.** `selftest` runs without any environment. Evidence sources for cache reconciliation: the run
dir's `cache-evidence.txt` (rc must be 0), the workers' `client_page_cache_discarded` (false CONTRADICTS a
cold declaration), and the drivers' recorded construction wording. **`calibrate <run-dir>...`** computes and
writes the leg's bands from the calibration cells (`calibrate-canary-bands.sh` drives them): lo/hi from the
observed normalized-ratio spread ±5% per direction (≥3 large-bs cells per direction or it refuses),
`smallbs_widening` from the bs4k cells. **⏳ DEFER:** migrating the aggregators'
filesystem-side parsers onto it (with the Lustre schemas, Leg B); the
Lustre-side cache-evidence source gets named during the Leg-B build.

### `calibrate-canary-bands.sh` — the D-5 band calibration driver ⭐ NEW
**What.** Runs the calibration cells on the provisioned cluster — 3× probe-shaped large-block pairs
(seqw/seqr bs=4M jobs=16 iodepth=8, the shape of the 2026-08-15 anchor probes) plus 3× small-block pairs
(randw/randr bs=4K, because the Stage-1 register requires the small-bs band **derived at the block size
under test**, never inherited) — then computes and writes `runs/.leg-state/$LEG/canary-bands.json` via
`wsi_agg_helper.py calibrate`.
**Why.** The post-cell consistency canary refuses (UNCALIBRATED) without a bands file, by design; the bands
must come from repeats on the cluster that will run the leg, because the wire/app ratio carries the protocol
share of this cluster's transport and EC scheme.
**I/O.** Needs `FS_MOUNT`, `LEG`, `WEKA_EC_SCHEME` → 12 recorded Stage-0 run dirs (diagnostic, never quote)
+ the bands JSON. Fixtures at `$FS_MOUNT/benchmarks/fio-canary-calib/` (160 GiB, retained — cheap
re-calibration).
**Caveats.** The read cells deliberately read the just-written files — backend-RAM-resident, drives out of
the picture; the RATIO is the measurement, so `RECORD_CACHE_STATE=na-calibration-server-resident`. Refuses
to write bands from a partial set (any failed cell → exit non-zero). `calibrate` deliberately does **not**
write `mixed_widening` — that needs mixed calibration cells (open-items memory B.3); a guessed widening can
mask a real inconsistency. Re-run on any cluster change; the bands file is leg-scoped.

### `probe-gds-phase0.sh` + `probe-gds-phase0.py` — the recorded D8 Phase-0 determination ⭐ NEW
**What.** Three recorded Stage-0 cells that settle the WEKA-GDS question empirically before the GPU-direct
matrix is committed: **A** kvikio compat OFF + `allow_compat_mode=true` (standing config — cuFile engaged,
bounce permitted); **B** kvikio compat OFF + `allow_compat_mode=false` (strict — true GDS works or the
cuFile layer refuses, and **either answer is the determination**); **C** kvikio compat ON (kvikio's own
POSIX path, never enters cuFile — nvidia-fs must stay zero, proving the three-layer distinction).
`gdscheck -p` output is captured in each cell's `cmd.log`.
**Why.** D8: the vendor's materials and the transport analysis disagree, so the answer must be evidence —
the recorded `path_accounting` split, never a configuration flag.
**Caveats.** The mode is forced via `KVIKIO_COMPAT_MODE` in the env **before the interpreter starts**, and
the probe **refuses on a resolved-vs-requested mismatch** — a determination cell whose mode silently
differed determines nothing. A cuFile refusal in cell B is recorded evidence and exits 0; the probe exits
non-zero only when it cannot determine (mode mismatch, accounting off). Test file: 1 GiB urandom at
`$FS_MOUNT/benchmarks/gds-phase0/` (zeros risk a compression/sparse fast path). Reads are
backend-RAM-resident by construction — the PATH is the question, not the rate. Cells declare
`RECORD_KVIKIO_CELL=1`, so the D-30 wrapper check enforces the recorded split.

### `fingerprint.py` — cross-leg artifact fingerprints: capture + compare (was `D-24`) ⭐ NEW
**What.** `capture <class>` computes a storage-independent fingerprint into
`runs/.leg-state/<leg>/fingerprints/<class>.json` (git-tracked, so Leg B compares against Leg A's committed
capture); `compare <a> <b>` diffs two captures and **exits non-zero on any mismatch** — the fail-loud gate
of the RUNBOOK's integrity table. Classes per register **D19**: `dataset-bytes` (sorted relpath/size/md5
list → one SHA-256; md5s re-emitted from the hydration verifier's own basis, never re-hashed — hours of
re-hashing to restate a recorded verification), `coords-3.0` (per-slide count + SHA-256 of the raw coords
*array contents*, dtype recorded — the array, not the HDF5 container), `rawtiff-4d` (per slide: output
byte count + tile-grid dims, plus the image/tile dims the grid derives from — a tile-size drift is a
converter-version change worth failing on; slides enumerated from the D5 cohort + CAM16 subset manifests,
missing artifact → refusal). `features-6a` refuses until its artifact first exists — a format designed
against imagined output gets rewritten (D-24).
**Caveats.** Run with the MAIN env's interpreter (h5py). Refuses on any missing dataset file rather than
fingerprinting a partial corpus. `leg`/`basis` fields are excluded from compare (expected to differ /
descriptive).

### `rerun-cell.sh` — the D18 repeat runner ⭐ NEW
**What.** `rerun-cell.sh <run-dir> <rep>` re-invokes a recorded cell's exact command as `REP=<rep>` with the
original name, stage, note (annotated) and cache declaration — all from the run dir's `metadata.json`, never
a human retype — so `record-run.sh` suffixes `-rep<N>` and aggregation groups reps to median + spread.
**Why.** Knee/pinned-peak cells are per-leg discoveries, so the repeats cannot be pre-wired into
`run-leg.sh`; hand-retyping a cell's command is the transcription risk the recorded command exists to remove.
**Caveats.** **Refuses 1.0d cells**: a one-touch repeat must claim a fresh reserve region via the randr
driver's ledger or it measures its first run's cache — that repeat path goes through the driver's own
mechanics, not this generic runner. **Rewrites recorded output paths into the repeat's own run dir**
(pre-computed via `RECORD_RUN_DIR`): a recorded command can carry paths INTO the original run dir (4.C's
`--summary-json`/`--latency-csv`), and re-running it verbatim overwrites the original cell's outputs —
bit the 4.C reps 2026-08-18 (originals' summaries restored from their cmd.logs, which print the summary
verbatim; two random cells' per-tile CSVs hold rep3 content, noted in their `notes.md`). The four 4.B
rep dirs predate this fix and carry no `reader-summary.json` of their own — recover from each rep's
cmd.log when the D-4 helper's rep grouping lands.

### `verify-substage-closeout.sh` — the mechanical substage-closeout gate ⭐ NEW
**What.** For one substage (or `--all-completed`): every cell OK in INDEX · aggregate CSV present **and
newer than the newest cell** · the roadmap's `**Leg <X> results` row present inside that substage's section
· consistency canary on every cell (NO_DATA fatal; judgements counted) · raw verifiably in S3
(size-checked dry-run). Exit 0 = closed; anything else names what's missing. **Gates every next-phase
launch** (RUNBOOK § Substage closeout; CLAUDE.md carries the rule).
**Why.** The closeout lived as non-negotiable prose in three documents and was still skipped once (Stage 3,
2026-08-17) — the project's own lesson applied to itself: a trigger must be mechanical.
**Caveats.** The substage table inside the script is the registry — **extend it in the same edit that adds a
new substage** (unknown → refusal, not skip). The roadmap check keys on the `**Leg <X> results` row-prefix
convention. Rep cells are audited (INDEX/canary/S3) but excluded from grid CSVs until the D-4 helper's rep
grouping lands — `aggregate-sweep.py`'s name regex skips `-repN` dirs, so the grids stay single-shot.

### `aggregate-stage1-hydrate.py` — the 1.7 aggregate the closeout gate found missing ⭐ NEW
**What.** Rolls the hydration cells into `s1.7-hydrate-summary.csv`: per cell mcr, wallclock, fs-side write
(active-window + naive means), corpus-GiB/s-over-wallclock, INDEX verdict. Self-locates; no args.
**Why.** The roadmap promised the aggregate; no script produced it — the same class of miss as the Stage-3
results block, found by the closeout gate's first full audit.

### `parse-results.py` — raw CSVs → `results.json`
**What.** Reads a run dir's `raw/` time series and writes aggregate statistics.
**Why.** Independent of the wrapper, so a parser fix or a new derived metric never requires re-running the
benchmark — which matters when a cell costs hours.
**Cumulative counters become rates by dividing by the dt read from each sample pair's own `timestamp`** —
never by the nominal sample rate. *Why the division is load-bearing:* the recorders sleep 1 s **plus** loop
overhead, and under load a sample slips further; treating the raw delta as a per-second rate then overstates
every wire-counter rate by exactly the slip. Those rates feed the cross-source consistency canary, where the
error inflates the wire side of the ratio and can either mask a real inconsistency or manufacture a false
one. A pair whose dt is missing, unparseable or non-positive is **dropped, not guessed**.
**Output schema.** Each delta-aggregated group carries a **`_sample_interval_s`** block (count / mean / min /
max), so the sampling actually achieved is visible rather than assumed to be 1 Hz — the same slip that
corrupts a rate also tells a reader how much to trust the series. Recorder stamps are second-resolution, so a
sub-second slip is quantised away; that residual is an open item, not silently absorbed.
**Caveats.** Overwrites `results.json` in place; raw data untouched. Implements the active-window mean.
Emits **`weka_stats_client`** — the pattern-#1 series: `Mode=="client"` rows only, summed across the
client's processes per timestamp (latencies and CPU% averaged, since a latency does not sum) — the quotable
filesystem-side number; the whole-stream `weka_stats` aggregates stay alongside as context, and divergence
between the two is itself a check that the filter matched. `nvidia-fs-stats.log` is presence-only until its
parser is written against the enabled-under-load format (D-6).
**⏳ DEFER:** the Lustre source schemas (D-4, Leg B); the nvidia-fs block parser (D-6).

### `aggregate-sweep.py` — generic sweep aggregator
**What.** Rolls N run dirs into a summary CSV, including block-size × concurrency grids.
**Why.** The `fio` sweeps share one shape, so one generic aggregator serves all of them.
**Caveats.** The only aggregator taking an **explicit glob**; the per-stage ones self-locate via `__file__`.
`warmref` cells (the 1.0b/d D13 evidence cells) are excluded from the grid — keyed on (bs, jobs) they would
collide with the grid cell they exist to contrast with — and printed as a separate reference block.
**⏳ DEFER:** the `--fs` pivot. `metadata.json` carries the `fs` field already; teaching the aggregators to
group on it is part of the per-filesystem adapter work (D-4).

### `build-tcga-manifest.py` — dataset manifest builder
**What.** Queries the GDC API and emits a download manifest TSV.
**Why.** Makes the dataset selection reproducible and auditable rather than an undocumented download.
**Caveats.** Used once during pre-leg staging into S3, not per leg.

### `sync-to-s3.sh` — the durability layer ⭐ NEW
**What.** Pushes everything teardown-critical to S3. Three modes: `--mode full` (called by `backup.sh`),
`--mode run --run-dir <path>` (one run's raw telemetry), `--mode datasets --src <path>`. Plus `--dry-run`.
**Why.** Instance-local scratch and **both filesystem mounts are ephemeral** — they die with the instance and
the cluster, and the instance is rebuilt between legs. Without this, a teardown destroys every run's raw time
series. git covers all the small text; S3 covers the heavy write-once data git cannot hold.
**Why two sync semantics — the whole point of the script.** **MIRROR** (`--delete`) for docs and the memory
mirror, where local is genuinely authoritative and git backs it independently, so an exact reflection is
safe. **ARCHIVE** (never `--delete`) for telemetry and datasets, because we will want to reclaim local disk
by pruning old telemetry and a delete-sync would then **destroy the only remaining copy**.
**Why NOT `--no-overwrite` for the archive group,** even though it sounds safer: telemetry CSVs **grow**
while a run is in flight, and that flag only transfers files absent at the destination — so the first sync
would upload a partial CSV and no later sync would ever fix it. Default comparison (size differs *or* source
newer) is what handles growing files. Documented in the script header so it isn't "improved" back.
**I/O.** Config entirely from the environment (`S3_BUCKET`, `LEG`, `AWS_REGION`) — nothing hardcoded.
**Caveats.** Fails early and loudly on missing credentials or an unreachable bucket, so a sweep does not
discover at 4am that hours of telemetry had nowhere to land. **Every guard path exits non-zero**, which is
what lets a sweep chain abort on a failed sync. Verifies object count after syncing rather than assuming
success (Rule 11). **Verified against the real bucket 2026-08-15**, including `--self-test` (was `D-23`):
the mechanised semantics proof under `s3://$S3_BUCKET/_selftest/` — mirror probe must disappear on a local
delete, archive probe must survive it — with a named non-zero exit per failed assertion and the leftover
cleanup command **printed, never run** (removing anything from S3 stays a manual act, per the semantics it
proves). **Re-run `--self-test` before every teardown.**

### `env-contract.py` — cross-leg comparability enforcement ⭐ NEW (`D-12`)
**What.** `write` collects every environment fact into JSON at the end of a leg; `verify` compares the current
environment against a reference contract before the next leg's first cell; `show` prints one readably; **`env`
emits it back as `env.sh`-shaped `export` lines** for the rebuild.
**Why `env` exists.** `env.sh` is gitignored, so it is **lost on every rebuild**; the bootstrap regenerates it
and merges the previous leg's held-constant fields by consuming this emit programmatically. A hand
transcription step here would put a typo in front of the one artifact whose whole purpose is proving the two
legs matched. **Held-constant fields are emitted live; leg-specific fields are emitted COMMENTED** — on a
cross-leg rebuild those describe the *other* filesystem, and this leg's setup writes the new ones (the
bootstrap on WEKA; the cluster prompt on Lustre).
Fields absent from the contract are emitted as a commented placeholder saying so, never invented.
*Caveat:* **paste the output over the placeholders, do not `>>` append.* `env.sh`'s `--check` block sits at the
bottom of the file and runs before anything appended after it, so appended values source correctly and are
still reported `MISSING`.
**Why.** The two legs run at **different times on a rebuilt instance**. Anything that drifts — AMI, driver,
dataset bytes, script commit — is **indistinguishable from a filesystem difference** once the numbers exist.
This makes comparability a mechanical check rather than a judgement call.
**The load-bearing design decision:** fields are split into **`MUST_MATCH`** (instance type, region/AZ, AMI,
kernel, driver/CUDA/cuFile versions, GPU/CPU/memory, script commit, dataset manifest hash, env name, Python)
and **`MAY_DIFFER`** (everything filesystem-specific — mount, backend config, EC scheme, FSx tier, stripe
layout, client cores/NICs). *Why it matters:* a verifier that ignored the distinction would either fail on
everything or catch nothing, since the filesystem fields are **supposed** to differ — they are the variable
under test.
**Caveats.** Facts are collected automatically where possible and read from the environment otherwise;
anything unavailable is recorded as **null, never guessed**. `verify` treats a null on a held-constant field
as **unverifiable → FAILED**, because *an unrecorded fact cannot be shown to have matched*. `write` also exits
non-zero when held-constant fields are missing, so an incomplete contract cannot pass unnoticed.
**`python_version` is collected from `$CONDA_ENVS_DIR/$CONDA_ENV_MAIN/bin/python`, never from the
interpreter running the tool** — the latter recorded the launcher (miniforge base at a teardown, system
python at boot), so the identical environment "failed" verify under a different launcher.
**`script_commit` compares by ancestry, not equality:** the teardown writes the contract before its own
final commit+push, so HEAD is legitimately ahead on every rebuild; the recorded commit must be an
**ancestor** of HEAD (reported as *advanced, ancestor-ok* with the auditable diff range), and divergence
stays a VIOLATION. **`verify` writes `runs/.leg-state/$LEG/contract-verified` on PASS** (with the contract's
sha256) and unlinks it on FAIL — the marker `run-leg.sh` refuses without (D-21, ratified). The contract also
carries the per-leg **recovery fields** (prices + dates, ceiling, `FS_CLIENT_RESERVED_CORES`, backend AMI)
and the held-constant **`STAGE1_*` corpus definition**, because the 2026-08 rebuild lost every value that
lived only in the gitignored env.sh. `env --for-leg <leg>` matching the contract's leg emits the
leg-specific fields **live** (same-leg rebuild); without it they emit commented (cross-leg, correct).
**`env.sh` is reconciled against instance metadata, not trusted.** `instance_type`, `aws_region`, `aws_az`,
`ami_id` and `instance_id` are fetched from **both** `env.sh` and IMDS; **metadata wins** and any disagreement
is recorded in `source_conflicts`. *Why metadata wins:* `env.sh` is a generated
file that can still drift or be hand-edited between rebuilds, and a wrong value there would flow into Leg A's
contract, be emitted into Leg B's `env.sh` from that same contract, and then be compared against itself by
`verify` — matching, and hiding exactly the drift the contract exists to catch. `write` warns on a conflict; `teardown-preflight.sh` NO-GOes on one, because `env.sh` is
what the next instance is rebuilt from. A contract predating the check reports *unverified*, not *agrees*.
**Third field list, `RECOVERY_ONLY` (`s3_bucket`).** Comparing it proves nothing — you must already know the
bucket to have fetched the contract — but without it the recovery artifact could not rebuild the file it is the
recovery source for. It is invisible to `verify` and to `write`'s completeness check, which both iterate the
other two lists.

### `run-leg.sh` — unattended leg orchestrator ⭐ NEW (`D-14`)
**What.** Drives one whole leg's sweeps in dependency order: **32 steps** (22 sweeps + the `1.0r-prep`
corpus-staging step + the 9 interleaved stability-canary invocations `C0`–`C8`, **D18**), `--dry-run`,
`--list`, `--from`, `--only`. Each step carries its driver **and that driver's target** where the driver dispatches on `$1`
(4.C `tier1`, 5 `all`, 6.A `tier1`, 6.A.3 `tier3`, 6.B.3 `all`, 6.B.2 `all`, 6.C `all`, 7 `all`) — the runner
word-splits the command, and `--from`/`--only` are validated against the step-id list so a typo cannot
silently skip the whole leg.
**Why.** A leg is many hours of sweeps that must run in a fixed order because each stage produces inputs the
next consumes. Driving that by hand overnight invites a missed step or a silently-continued failure.
**It orchestrates SWEEPS, not cells** — per-cell recording and failure isolation stay with `record-run.sh`.
**The six guards, each with its reason:** (1) **abort the chain on any step failure** — later steps consume
earlier outputs, so continuing would build cells on missing inputs; (2) **checkpoint + resume** via per-step
done-markers, so a crash re-runs only what is missing; (3) **S3 sync after every step**, because both mounts
and local scratch are ephemeral; (4) **tee everything** — on an overnight run the log is the only forensic
record; (5) **refuse a leg on the wrong transport** — WEKA must be on DPDK and Lustre on EFA (**D16**), read
from `FS_TRANSPORT`, recorded from client evidence — the bootstrap writes it on the WEKA leg, the cluster
prompt verifies it (and records it on Leg B). Unset refuses too, because an
unrecorded transport cannot be shown to be the right one. Overridable only by a written reason in
`runs/.leg-state/$LEG/transport-waiver`, which is then echoed into the log. *Why here:* this is the unattended
entry point, and the fallback transports (UDP / TCP) mount cleanly and report plausible numbers, so an
instruction followed hours earlier is not evidence; (6) **refuse a leg whose environment contract was never
verified** (ratified, was D-21): when `runs/env-contract-leg-$LEG.json` exists, the `contract-verified`
marker written by `env-contract.py verify` must exist and its recorded sha256 must match the current
contract file — "the procedure says verify ran" is an instruction, and this converts it into a checkable
fact. `--dry-run` is exempt (it executes nothing).
**Caveats.** Refuses to start without `FS_MOUNT`/`S3_BUCKET`, and **refuses if `--leg` disagrees with
`FS_MOUNT`**. A step whose driver does not exist yet is reported **MISSING and aborts** rather than being
skipped — *a leg with a hole in it looks complete in `INDEX.md`*, which is the failure this prevents. One
step is currently MISSING by design: 6.B.1 (needs the corpus-size decision, the open-items memory).

### `prove-recording.sh` — the scripted Stage-0 recording proof (was `D-20`)
**What.** Runs one real ~15 s fio cell through `record-run.sh` and asserts, each with a named non-zero
exit: the cell recorded and `INDEX.md` says OK; the leg's core streams carry data; `results.json` has a
**non-zero client-summed filesystem-side rate** (a present-but-zero series means the client filter matched
nothing); every `raw/` file is verifiably in S3 after a run-mode sync; and the generic aggregator emits the
cell's row (the proof cell is named `-bs1m-jobs4` so `aggregate-sweep.py` can parse it).
**Why.** The rebuild checklist's five eyeball checks are where one gets skipped; this runs on every rebuild
before wallclock is spent.
**Caveats.** Three assertions print **loud SKIPs until their subjects exist**: the mechanical pre-cell
canary (`D-7`), the post-cell consistency canary (`D-5`), and the fs-pivoted aggregation column (`D-4`
helper). **Extend this script when each lands** — a proof that silently proves less than the checklist
promises is the failure it exists to prevent. Its run dir is a real Stage-0 run dir; never delete it.

### `verify-conda-env.sh` — fail-loud environment verification (was `D-22`)
**What.** Real imports per env (main: torch/cupy/cucim/kvikio/openslide/tifffile/h5py/timm/transformers;
alt: torch/cucim/openslide/tifffile/h5py/numpy), CUDA availability and visible-GPU count vs `nvidia-smi`,
and — when a reference environment contract exists — `python_version` against it. Non-zero on any drift.
**Why.** The bootstrap's smoke is import-only and warn-only; this is the verification it lacks. On a
first Leg-A build the contract cross-check reports itself skipped rather than silently passing.
**Caveats.** Verification only — environment creation stays in the bootstrap.

### `teardown-preflight.sh` — prove nothing is lost, before tearing down ⭐ NEW
**What.** Checks nine things and prints **GO / NO-GO**: nothing in flight · live memories mirrored · **the
next-session handoff prompt written and dated today** · git clean **and pushed** · environment contract complete
**and in S3** · **`env.sh` agreeing with instance metadata** · **every local run dir's raw telemetry present in
S3** · nothing else stranded on ephemeral storage · rebuild inputs (AMI, type, region/AZ) recorded.
**Why it VERIFIES rather than tears down.** Terminating the instance and deleting filesystems is irreversible,
so it stays a human action. The part worth automating is not the destruction — it is **proving** nothing is
lost, because that is the part a person does badly: it is easy to assume a sync worked, and impossible to
eyeball whether some run dir exists only on a disk about to disappear. A script that destroyed *and* had a bug
in its own verification would be the worst possible tool.
**The check that matters** is the per-run S3 comparison: `raw/` is gitignored, so S3 is its only home, and a
silently-failed sync is invisible until you look for data that no longer exists. `--quick` skips exactly that
check, so **never use it before a real teardown**.
**Caveats.** Exits non-zero on NO-GO, deliberately — never wire it into an automated teardown that ignores the
exit code. Companion checklist: `cloud-setup/TEARDOWN-AND-REBUILD.md`.

### `restore-memories.sh` — mirror → live memory dir ⭐ NEW
**What.** Copies `claude-memory-mirror/` into `~/.claude/projects/<slug>/memory/` and **verifies** the result.
`--check` verifies without changing anything. Bootstrap rather than benchmark, but it lives in `../scripts/`
with everything else that is executed rather than read.
**Why it is a script and not four lines in the checklist.** It runs on **every** instance build — at least
twice, once per leg — and its failure mode is **silent**: `rsync` into the wrong directory succeeds, and a
fresh Claude session then starts with no memories and **no error**, proceeding to redo settled decisions. On an
ephemeral instance the mirror is the only continuity that exists. The manual version also asked the operator to
eyeball "expect ~20 files", which is exactly the check people skip.
**So it: derives the slug from the repo path** rather than trusting a typed one; **refuses** on a missing or
empty mirror or a mirror with no `MEMORY.md` (better than producing an empty memory dir); and **diffs** the
result afterwards.
**Caveats.** **Direction matters — restore *before* ever running `backup.sh`**, which mirrors the other way and
would otherwise overwrite the mirror from an empty live dir (it refuses in that case; correct ordering makes
the refusal moot). *Extra* files in the live dir are reported but **not** a failure — that is the live dir
being ahead after a session wrote new memories; *missing* or *differing* files are fatal.

### `bootstrap-instance.sh` — the automated client build ⭐ NEW

**What.** The Terraform `clients_custom_data_post_mount` payload: builds the whole client on first boot —
dnf packages, the pinned NVIDIA/CUDA-12.9 stack (chosen so `nvidia-fs` and the system `libcufile` are
version-matched), **the nvidia-fs I/O counters enabled and persisted via modprobe.d** (default-off, and an
off state records a present-but-all-zero GPU-direct byte split that corrupts the **D8** determination),
local-NVMe RAID0+XFS scratch, WEKA login via Secrets Manager and mount verification,
`env.sh` generated from instance evidence (IMDS plus the client's own transport report → `FS_TRANSPORT`),
`LIBCUFILE_PRELOAD` located and exported, the compat-mode `cufile.json`, both conda envs from
`env-specs/` with smoke tests, HF token + model prefetch from SSM, memory restore, and the S3 dataset
hydration guard.

**Why.** A rebuild is `terraform apply` plus `claude /login` and nothing else — every manual step in a
rebuild is a place the two legs can silently diverge, and the environment contract can only verify what a
build records mechanically.

**Caveats.** The env smoke tests are **import-only and warn-only** (`WSI-WARN`; the boot continues) —
fail-loud verification is `D-22`. The re-hydration guard keys on
`runs/.leg-state/$LEG/hydration-complete`, which only the `D-13` hydrate driver will write. Boot progress
lands in the instance log; the SSM deploy-key step must report the fixed key installed (next-rebuild
verification, open-items memory). **The rebuild's env.sh merge runs the contract emit FIRST
(`env --for-leg weka`, so same-leg fields arrive live) and applies this instance's freshly-derived cluster
evidence AFTER it** — a mid-leg rebuild can deliberately change the cluster, so live facts must beat the
torn-down cluster's recorded ones, while contract-only values (prices, corpus sizes, reserved cores) still
recover. `weka status` reports capacity in **TiB**; the bootstrap converts to TB before writing
`WEKA_CAPACITY_TB` (the 2026-08 rebuild wrote the TiB number under the TB name — a ~10% silent unit error).

### `prefetch-datasets-to-s3.sh` — one-time dataset staging ⭐ NEW

**What.** Stages TCGA-BRCA (per-file fetch from the GDC data API over HTTPS, manifest-driven,
**md5-verified per file**, failed files removed and retried) and CAMELYON16 (open-data bucket copy) into
`s3://$S3_BUCKET/datasets/`. Resumable; skips objects already present.

**Why.** The WAN pull happens **once, before either leg** — it measures a WAN link, not a filesystem — and
S3 is then the per-leg hydration source (1.7), so both legs read byte-identical datasets (**D6**).

**Caveats.** Consumes the gdc-manifest-format TSVs from `build-tcga-manifest.py`. Not a measured cell.
Requires local staging space under `$SCRATCH_DIR`. **The per-mode completion marker
(`datasets/.prefetch-complete-<mode>`) is written only on a zero-failure pass** — per-file failures land in
`$STAGE/.prefetch-failures-<mode>` and any entry there blocks the marker and exits non-zero, because the
marker short-circuits every future run and would otherwise hide a gap until 1.7's byte-verify, mid-leg.
The pilot and full modes share the same S3 keys, so a full pass skips (never duplicates) pilot objects.

### `teardown-prep.sh` — the pre-destroy orchestrator ⭐ NEW

**What.** Runs the teardown sequence mechanically: `backup.sh` (memories → mirror → S3 sync), boot-log
archive, `git commit` + `git push` (fail-loud — an unpushed repo dies with the instance), then hands off to
`teardown-preflight.sh` as the GO/NO-GO gate and echoes its verdict.

**Why.** The teardown checklist's order is load-bearing and a human runs it under time pressure; scripting
the preparation makes the steps unskippable, while the **destruction itself stays human** — this script
never terminates anything.

**Caveats.** Gated on the preflight, which demands the next-session handoff written and dated — so the
handoff must exist before this runs. Claude runs the whole prep including the commit + push (the
autonomous-git convention, ratified 2026-08-15); it also runs `sync-to-s3.sh --self-test` before relying on
the sync. Only the destruction stays human.

---

## Stage 1 — Ingest

### `sweep-stage1-{seqw,seqr,randw,randr}.sh` — synthetic ceiling sweeps
**What.** Four `fio` drivers: sequential write, sequential read, random write IOPS, random read IOPS.
Sequential grids at iodepth=1, IOPS grids at iodepth=8.
**Why.** These anchor the whole project: **every downstream "% of ceiling" divides by one of these cells at
the matching block size.** Throughput is strongly block-size-dependent, so a single ceiling number would make
mid-block workloads look artificially high or low. They are also the cleanest apples-to-apples cells in the
project, since `fio` is filesystem-agnostic.
**The write sweeps (1.0a seqw, 1.0c randw)** write to `$FS_MOUNT/benchmarks/fio-scratch/`, `--unlink=1`
cleans per cell — a write cell has no cold/warm regime to protect.
**The read sweeps (1.0b seqr, 1.0d randr) are cold by construction (D13; ratified 2026-08-15)** and read the
corpora staged by `prep-stage1-read-corpora.sh` — they **refuse without its marker** and cross-check the
staged sizes against the `STAGE1_*` env parameters. 1.0b: shared scan corpus (≥ ~2× the larger server
cache; cyclic-scan LRU self-eviction), single pass per cell, per-cell offset rotation. 1.0d: per-cell
disjoint **one-touch regions** (each block ≤ once per sweep — no cache-behavior assumptions; the
corpus-exceeds-cache rule fails for random access, where LRU serves ≈ cache/corpus and the legs' unequal
caches make hit rates asymmetric); **D18 repeats claim fresh reserve regions** via
`runs/.leg-state/$LEG/randr-region-claims`. Both run fixed de-ordered sequences, carry a **warm reference
cell** (route-2 evidence, inverted because the default regime is cold), declare `RECORD_CACHE_STATE` per
cell, and exit non-zero if any cell failed.
**⏳ DEFER:** aggregator-side per-filesystem sources (D-4) and the consistency relation (D-5).

### `prep-stage1-read-corpora.sh` — stage + evict the 1.0b/1.0d read corpora
**What.** One recorded prep cell (a real sustained-write + sustained-read workload, not a comparison cell),
three phases: write the 1.0b scan corpus, write the 1.0d one-touch region pool, then an **eviction pass**
(full sequential read of the scan corpus) so the staging writes' server-RAM tail is flushed before any cell
runs. Verifies every file at full size, then writes `runs/.leg-state/$LEG/stage1-read-corpus-staged`
carrying the staged sizes — the marker both read sweeps gate on.
**Why.** Data written immediately before it is read is server-cache-resident whatever the client does; the
corpora must pre-exist the sweeps, and the staging warmth itself must be gone.
**I/O.** Env parameters `STAGE1_SEQ_CORPUS_GIB` / `STAGE1_RANDR_REGION_GIB` / `STAGE1_RANDR_REGIONS` →
`$FS_MOUNT/benchmarks/stage1-read-corpus/`. Refuses without corpus+10% free space.
**Caveats.** Idempotent via the marker (re-run exits 0); to restage after a cluster rebuild, remove the
marker — the corpora themselves are **retained** deliberately (capacity inputs, SPINUP-CHECKLIST item 12).
`run-leg.sh` runs it as step `1.0r-prep`, between 1.0a and 1.0b.

### `sweep-stage1-hydrate.sh` — Stage 1.7 S3 → filesystem hydration (was `D-13`)
**What.** The head-to-head ingest sweep: `max_concurrent_requests ∈ {4, 16, 64, 256}` = 4 cells, each a
**full `aws s3 sync` of both dataset prefixes** with the target wiped before it (same-region transfer is
free; the write workload is the measurement). The **final cell's data is kept and byte-verified** — TCGA
per-file md5 + count + size against the manifest; CAMELYON16 count + per-file size (its manifest carries
multipart ETags, not md5s; the staging copy was checksummed by S3 end-to-end — basis recorded in the
verification report at `runs/.leg-state/$LEG/hydration-verification.txt`). Only a clean verify writes
`runs/.leg-state/$LEG/hydration-complete`, the marker `run-leg.sh` and the bootstrap's re-hydration guard
key on.
**Why the last pass is the kept corpus.** Wipe-before-cell (never after) means the grid needs no extra
hydration pass, and a failed verify blocks the marker so a partial corpus cannot poison downstream stages.
**I/O.** `s3://$S3_BUCKET/datasets/{tcga-brca,camelyon16}/` → `$FS_MOUNT/data/{tcga-brca,camelyon16}/`.
**Caveats.** Refuses without the S3 `.prefetch-complete-full` marker (hydrating a partial corpus would fail
the verify only after every pass has run) and without corpus-size + 10% free space. Sets
`RECORD_CACHE_STATE=na-write-cell` — a write cell has no cold/warm regime. `max_concurrent_requests` is a
config-file setting, so each cell runs under a generated per-cell `AWS_CONFIG_FILE` with the region passed
explicitly. Identical grid verbatim on both legs; FSx's native import is 1.8, a separate capability cell.

### `chain-stage1-bcd.sh` — sweep chainer
**What.** Runs several Stage-1 sweeps back to back unattended.
**Why.** The precedent for leg-level chaining (D-14) — cells are already isolated, so chaining is safe.

### `fe-core-fio.sh` · `fe-core-kvikio.sh` — shared cell helpers
**What.** Single-cell helpers for a `fio` cell and a kvikIO cell, used for baselines and quick checks.
**Why.** Phase 0 needs the ceiling captured **per block size** without standing up a whole sweep.
**⏳ DEFER:** `fe-core-kvikio.sh` needs cuFile path accounting (D-6) and the GPU pinning order (D-8).
**⚠ Neither is the Phase-0 ceiling capture** — each runs ONE fixed configuration, while every downstream
"% of ceiling" divides by the **block-size-matched** Stage 1.0a–d cell. Use the Stage 1.0 sweeps for that.

### `sweep-stage1-fpsync.sh` + `aggregate-stage1-fpsync.py` — bulk local→filesystem copy
**What.** Sweeps parallel-copy concurrency over the real corpus from local NVMe.
**Why.** The clean write-path benchmark on **real WSI files with real metadata operations**, closest to the
scanner-to-storage path labs actually run. Comparison against the synthetic ceiling shows how much of the
write path is reachable with real files rather than one scratch stream.
**Caveats.** Needs a local source faster than the filesystem's write ceiling, or the source is the bottleneck
and the cell measures the wrong thing. The aggregator implements pattern **#1**.

### `sweep-stage1-mixed.sh` + `aggregate-stage1-mixed.py` — mixed ingest + read
**What.** Fixed-rate ingest running concurrently with a swept random-read `fio` grid; captures **both** sides.
**Why.** The operationally realistic state — a scanner feeding while clinicians read. Answers two questions
at once: can readers work at acceptable latency during ingest, and does reader load throttle ingest?
**Caveats.** Uses pattern **#2** (`setsid` + process-group kill). **Mixed cells need wider canary bands than
single-direction cells**, and the bands must be re-derived per filesystem — the wire carries payload plus
acknowledgements in both directions, and at small block sizes the non-payload share is material.
Runs a fixed, de-ordered cell sequence whose **first entry is the cold reference cell** at (4K, jobs=1) —
`vm.drop_caches=3` with the acknowledgment written into the run dir; the aggregator renders a dedicated
cold-vs-warm-twin block as the D13 exemption evidence. Attempts every cell; exits non-zero if any failed.
**⏳ DEFER:** the fixed ingest rate is set as a **fraction of each leg's own write ceiling**, not an absolute
— so it is parameterised from that leg's 1.5 curve.

---

## Stage 2 — Cataloging

### `extract-slide-properties.py` — per-slide metadata extractor
**What.** Opens each slide via OpenSlide, dumps properties plus derived fields as a JSON sidecar, times it.
**Why.** OpenSlide is the literature standard and handles both formats, so the measurement is comparable to
published work. Concurrency via a persistent worker pool.
**Caveats.** Writes to a **separate** output directory — the canonical dataset dir stays read-only so both
legs read byte-identical inputs.

### `sweep-stage2-properties.sh` + `aggregate-stage2-properties.py`
**What.** Dataset × concurrency × **cache-arm** grid (16 cells per leg), single pass per cell, in a fixed
de-ordered sequence. Cold cells: `vm.drop_caches=3` with the acknowledgment recorded into the run dir (a
failed drop aborts the sweep); warm cells: an unrecorded n=64 warmup pass immediately before, so warm is a
construction, not an inheritance. The aggregator parses the arm from the run name and keys the grid
`(dataset, arm, concurrency)`. Attempts every cell; exits non-zero if any failed.
**Why.** Single-pass matches how a real cataloging job runs and keeps the unit of work identical across legs.
**Caveats.** **High-concurrency cells finish in under a second**, so 1 Hz recorders capture 1–3 samples and
any sustained mean is ill-defined — a sampling limit, not a recording failure. The app-level rate is
unaffected. ⏳ **Resolve the sampling approach before the first cell and apply it identically to both legs.**
**⏳ DEFER:** ops-counter comparability across legs is unresolved — until counter semantics are verified
equivalent, **the app-level rate is the only cross-leg-comparable source** here and the filesystem-reported
ops/s is within-leg only.

---

## Stage 3 — Tissue detection

### `sweep-stage3-tissue-detection.sh` + `aggregate-stage3-tissue-detection.py`
**What.** Drives the CLAM tissue detector across datasets × concurrency, producing the 20× coordinate lists
that gate Stages 4–7. Concurrency is external: the manifest is round-robin split into chunks and N detector
instances run in parallel into one output dir.
**Why.** Round-robin splitting guarantees no two chunks share a slide, so parallel instances cannot collide.
Per-dataset tiling arguments implement the 20× contract (**D2**). `--stitch` is omitted because its
visualisation output is not consumed downstream.
**Caveats.** CPU saturation is computed over **application-available** cores, and **the excluded core set
is a per-filesystem parameter** (**D15**) — WEKA reserves cores, Lustre does not. Two slides are expected to
yield no tissue under default parameters: real tool behaviour, storage- and magnification-independent, and
therefore a **cross-leg integrity check**.
**⏳ DEFER:** core accounting (D-9) — the reserved-core exclusion set must be measured on the real client
before this stage's CPU-saturation curve means anything.

---

## Stage 4 — Patching

### `extract-tiles-to-hdf5.py` + `sweep-stage4a-patches.sh` + `aggregate-stage4a-patches.py`
**What.** Reads each slide's coords, extracts and JPEG-encodes each tile, appends to a per-slide HDF5.
**Why.** The pre-extract strategy baseline. HDF5 with variable-length JPEG bytes is CLAM-style, directly
compatible with Stages 5–6, and far smaller than raw uint8.
**Caveats.** Concurrency is swept **outer-descending** so cheap cells validate the methodology before the
long-pole serial cell. Subset-limited (50 slides/dataset, fixed seed) because a serial full-cohort cell is
infeasible and 4.A's output feeds nothing downstream.

### `read-tiles-onthefly.py` + `sweep-stage4b-tilesread.sh` + `aggregate-stage4b-tilesread.py`
**What.** Random-tile reads from slides via either OpenSlide per-tile or cuCIM batched CPU, selected by flag.
Time-based cells; per-worker LRU slide-handle cache; p99 per-tile latency.
**Why.** The on-the-fly strategy — the pattern modern pipelines actually run, and the one that stresses
storage the way training does. Two backends because both exist in production.
**Slide paths are resolved through an index built once, before the clock starts** — in **both** the OpenSlide
and cuCIM workers. *Why it cannot be lazy:* resolution sits on the cache-miss branch of the timed loop, which
fires on roughly one iteration in eight (`P_NEW_SLIDE`), and resolving by walking the corpus put a full
directory scan plus per-directory existence probes **inside the measurement window** — a metadata workload,
on the axis where the two filesystems differ most, contaminating the cell that exists to isolate the
tile-read path. The index preserves the original probe order (flat `.tif`, flat `.svs`, subdir `.svs`, subdir
`.tif`), so which file wins for a given slide id is unchanged.
**Caveats.** cuCIM's GPU `read_region` is **ruled out** — a library defect (buffer allocation spanning the
whole offset range, unbundled decoder, pre-GA upstream), therefore **filesystem-independent and not a
comparison axis**; never report it as a storage finding for either side. **Cache discipline is load-bearing
here** (**D13**): at high worker counts the coord pool can become cache-resident, and the two filesystems
cache differently, so the crossover must be characterised per filesystem rather than assumed shared. The
driver runs every tier's cells in a fixed de-ordered sequence, with Tier-1 **cold reference cells**
(`-coldref`, drop acknowledgment recorded per cell) at the high-N crossover points, placed after their warm
twins; the aggregator keeps coldref rows distinct. Attempts every cell; exits non-zero if any failed.

### `convert-rawtiff-20x.py` + `convert-stage4c-rawtiff.sh` — the 20× raw-TIFF writer
**What.** Writes a single-level, 256-tiled, uncompressed TIFF whose **level-0 is the 20× image**, so cuFile
reads level-0 byte ranges directly as tiles and coords map to a tile index by integer division. Per-dataset
read path; **fail-loud mpp guard** rejecting off-magnification slides.
**Why.** The standard converter has no magnification/level flag and always emits the source's 40× level-0.
Keeping a 40× artifact and reading pyramid level-1 would be ~4× larger, ~4× slower to produce, and — the
decisive point — **not the artifact a 20× GPU-direct customer stores** (**D4**). Matching the readers'
resize interpolation means both backends see the same pixels.
**Recording (was D-15, owner's nod 2026-08-17).** The driver runs **one `record-run.sh` cell per dataset**
(`s4.D-rawtiff-{brca,cam16}-par<N>`, cache `na-mixed-rw-unmanaged`) via a `--inner` self-reinvocation, so
the recorded command is explicit in `cmd.txt`; each cell's verdict counts **only its own invocation's**
conversion rows (`conversion-log.tsv` in the run dir; the global append-only TSV gets them folded in once,
by one writer, after the pool drains — no cross-worker tail race). The outer path **fails loud when any
manifest id resolves to no source** (an unresolved id silently shrinks the cohort), and a failed dataset
cell aborts before the next dataset (downstream consumes the artifact).
**Caveats.** **Idempotent skip on existing non-empty output** — so a stale artifact from another magnification
or converter version is **silently reused**. Delete before regenerating. The output is a large capacity cost
on both filesystems (order ~7 TB) and thus a sizing input to **D7**. **Scope (ratified 2026-08-15, was
D-28): full BRCA cohort (1064, retained at rest — 7.2's disjoint-chunk N=64 cell needs it) + the CAM16
50-slide subset.** Manifests are parsed comment-aware (the full-cohort manifest carries commented excluded
IDs at its tail; a fixed line offset would ingest them), and the driver refuses without ~8 TB free headroom
(ENOSPC mid-cohort wastes hours).

### `read-tiles-kvikio.py` + `run-multiproc-kvikio.sh` + `sweep-stage4c-kvikio.sh` + `aggregate-stage4c-kvikio.py`
**What.** cuFile reads of tile byte ranges straight into GPU buffers, in two modes: a faithful sequential
full-level read, and random-tile reads drawn from the **same coord pools as 4.B** for apples-to-apples
comparison. Tiered sweep over pipelining depth, task size, thread count, pre-registration, and multi-process
scaling.
**Why.** The GPU-direct path, and the only Stage 4 path where the two filesystems' transports genuinely
differ. Sharing 4.B's coord pools is what makes the strategies directly comparable.
**Per-tile latency is stamped inside the drain**, once each future has actually returned, so it spans
**submit → observed completion** and therefore includes queueing behind earlier futures in the same batch.
For a pipelined reader that is the honest customer-facing quantity — but **it is not the isolated service
time of one read and must never be quoted as one.** A single clock read taken before the drain would subtract
the submit time from a stamp taken before any I/O had been waited on, excluding the I/O wait entirely and
leaving a latency figure that measured submit overhead alone.
**The aggregator reports the requested cuFile mode and the achieved path as separate columns.**
`cufile_mode_requested` is read off the run-dir name and says only what the cell was **asked** to do;
**`gds_engaged` is `"unknown"`** until cuFile's own GPU-direct-versus-bounced byte accounting is wired in
(D-6). *Why it is not derived from the mode:* doing so restates the request as though it were evidence —
precisely the "a configuration flag is not proof of behaviour" failure **D8** forbids — and a cell that
silently fell back to compat, or silently did not, would look identical in the CSV either way. An absent
answer is visible; a fabricated one is not.
**Caveats.** Reads must be block-aligned. **Every cell runs in both cuFile modes on both filesystems** so the
filesystem effect and the transport effect are separable (**D8**). **`LD_PRELOAD` scoped per cell** (pattern
#3). The aggregator implements all four parser idioms (pattern #7), including diff/dt on cumulative counters.
**⏳ DEFER:** path accounting is mandatory per cell (D-6); NUMA-aware GPU assignment (D-8); cuFile config
(D-10).

### `cufile-full-rdma.template.json` · `GDS-TUNING-CHECKLIST.md`
**What.** A parameterised cuFile configuration template, and a doc-grounded verify → measure → tune procedure.
**Why.** On a GDS-capable transport the cuFile config lists the client's own network addresses and transport
options; the WEKA leg runs a bootstrap-generated compat-mode config with no address list. The template plus
checklist keep the GDS-side procedure reproducible instead of folkloric.
**⏳ DEFER:** every value is environment-specific (D-10); the checklist needs a Lustre-over-EFA section.

---

## Stage 5 — Training

### `train-resnet50-stage5.py` + `sweep-stage5-training.sh` + `aggregate-stage5-training.py`
**What.** Real DDP training with an in-process reader (kvikIO or cuCIM CPU batched by flag), emitting a
**per-step CSV** with the dataload / forward / backward / optimiser split.
**Why.** Stage 4 measures what storage delivers; this measures whether a training loop **consumes** it at
scale. The per-step phase split is what makes a scaling falloff *attributable* rather than narrated.
**Caveats — three trainer-correctness requirements, all load-bearing for the storage measurement:**
`cudnn.benchmark`, `channels_last`, and **CUDA-event phase timing rather than per-phase host syncs**. Without
them compute runs several times slower than optimal, which **understates the demand placed on storage** and
flatters both filesystems. Self-launches ranks via `mp.spawn` with an explicit loopback master rather than a
launcher whose rendezvous binds to a resolved hostname that may not be on a local interface; `spawn` not
`fork`, because forked CUDA workers inherit a broken context. One rank = one in-process reader on the kvikIO
path (its internal pipelining already provides the parallelism). The cuCIM reader configuration is **re-tuned
per filesystem, never copied** — the optimum reflects a decode-vs-storage-latency interaction, so imposing
one side's optimum on the other is a fairness bug that reads as a filesystem difference.
The **mode-controlled paired cell** (`STAGES.md`) is requested by exporting `CUFILE_COMPAT_MODE=on` for one
invocation; a non-default mode joins the **cell name** (`-compat<mode>`), because the aggregators group
configs by name and the pair must never collapse into its best-mode twin.
**⏳ DEFER:** NUMA-aware GPU pinning order (D-8); cuFile env values (D-10). The GPU-count *range* is set:
N ∈ {1, 2, 4} on both blocks, matching the 4-GPU instance.

---

## Stage 6 — Feature extraction, MIL, concurrency, end-to-end

### `extract-features-foundation-stage6.py` + `sweep-stage6a-extract.sh` + `aggregate-stage6a-extract.py`
**What.** DDP wrapper loading three foundation models in frozen eval mode, fed by either data path, writing
per-slide feature tensors. Emits a per-extraction-step CSV.
**Why.** The 2024-onward production workload. Three models because production labs use them interchangeably
and they span a useful range of compute weight, which shifts the storage-to-compute balance.
**It refuses to save any slide whose embedding buffer was not completely filled.** The buffer is
`torch.empty`, so a row the batch loop never reached still holds whatever was previously in that GPU memory;
saving it writes **uninitialised memory to disk as a feature vector**, under a header claiming `n_tiles` real
rows. Such a file loads cleanly, has the right shape and dtype, and trains without error — nothing
downstream can detect it, which is why this is a refusal rather than a warning.
**Output schema.** The summary carries **`n_slides_incomplete_refused`**, and the process **exits non-zero**
whenever it is above zero, so no driver can mark the step done on a feature set that is missing slides.
**Caveats.** **Cleanup-before-cell is mandatory** (pattern #5) — the extractor skips existing output, so
without a wipe every cell after the first short-circuits and reports a plausible-looking meaningless number.
Ranks take **disjoint** partitions (the model is frozen, so DDP is throughput-only). The largest model may
need a reduced batch size — if so, apply it **identically on both legs** or it becomes a fake filesystem
difference. cuFile mode plumbing matches Stage 5: `CUFILE_COMPAT_MODE` (validated `off|on|auto`, default
`off`) → `--compat-mode` on kvikIO cells only, recorded as REQUESTED in the note, and a non-default mode
joins the cell name; both Tier-2 chunked orchestrators carry the same knob for the per-leg best-available
mode.

### `run-stage6a-tier2-chunked.sh` · `run-stage6a-tier2-chunked-multimodel.sh` — production-scale orchestrators
**What.** Convert a chunk of slides to raw-TIFF → extract → delete the chunk → advance. The multi-model
variant converts **once per chunk** and extracts for all models before deleting.
**Why.** Full-cohort raw-TIFF does not fit at once, and conversion is a large share of per-chunk wallclock —
so sharing it across models is structural, not a micro-optimisation.
**Caveats.** An aborted run **leaves chunks that get silently reused**. Verify cleanup between runs.

### `generate-synthetic-features-stage6b.py`
**What.** Writes a synthetic feature-file corpus at a specified file count, size, and dtype.
**Why.** The differentiating I/O pattern is small-file reads plus metadata operations, for which embedding
*content* is irrelevant — synthetic gives controlled scale, size distribution, and bit-width, none of which
the real corpus provides.
**Caveats — the most consequential sizing decision in the project.** The corpus must exceed **the client page
cache plus the larger of the two filesystems' server-side caches**, or a cell that is cold on one leg is
partly warm on the other and the difference looks like a filesystem property. ⏳ **Size it before Leg A
generates anything, using both filesystems' cache sizes, and use one identical definition on both legs.**

### `read-feature-files-stage6b.py` + `sweep-stage6b-stress.sh`
**What.** Reads feature files under a specified access pattern, optionally deserialising (production
behaviour), timing each load; multi-process, host-only.
**Why.** The metadata / small-file substage — structurally **not** bandwidth-bound, so it stays
discriminating even under a client-capped ceiling. Three access patterns because metadata-path behaviour is
pattern-sensitive and reporting only the friendliest or harshest would misrepresent both filesystems.
**The client page cache is dropped once, in a throwaway child of the parent, before the worker pool exists.**
A drop issued from inside a pool worker races every other worker: they are already reading by then, so the
cache is warm when it fires and the eviction lands in the middle of their measurement — the worst of both,
since the cell is then neither cold nor undisturbed. The child exists to keep the parent CUDA-free: the
discard helper lives in cucim, whose import pulls in the CUDA stack.
**Output schema.** The summary carries **`client_page_cache_discarded`** — the state **achieved**, not
requested (**D13**). `null` = not attempted; `false` = attempted and failed, which makes the cell **warm**
and it must be labelled warm rather than called cold with a caveat. Client page cache only — it says nothing
about the filesystem's server-side cache, the other half of the cold-state question.
**Caveats.** Caches cleared before each cell **to the extent achievable, and recorded as achieved** (**D13**).

### `train-mil-stage6b.py` + `sweep-stage6b-mil.sh` + `aggregate-stage6b.py`
**What.** Attention-MIL training over real extracted features at **`batch_size=1` with `collate_MIL`**;
`num_workers` is the swept axis.
**Why.** Verified against upstream CLAM: one slide per forward step, 2-D bag input, never a padded batch —
which **OOMs**, because padding inflates to the largest bag in the batch and WSI bag-size distributions are
wide. **Storage concurrency comes from `num_workers`, not `batch_size`.**
**Caveats.** The real feature corpus fits comfortably in instance RAM, so this workload is largely
**memory-served on both filesystems** after its first pass — what it measures is **MIL throughput, not
storage bandwidth**, and the cold storage number belongs to the synthetic corpus. Say so rather than letting
a reader infer a storage result.

### `orchestrate-concurrent-stage6c.sh` + `sweep-stage6c.sh` + `aggregate-stage6c-concurrent.py`
**What.** Launches up to four concurrent workloads, each emitting its own telemetry CSV, plus an
`orchestration.log` of start / ramp-end / steady-end for window alignment.
**Why.** Concurrent heterogeneous load on one namespace is where storage architectures diverge, and no
single-workload measurement surfaces it. Pair and triple tiers exist so an all-four result is
**diagnosable** rather than a single number with no cause.
**Caveats.** Uses pattern **#2**. Retention is computed against **same-filesystem** solo baselines re-measured
at the exact concurrent config. The ingest workload is **data-bounded** — it exhausts its source and exits, so
report it as "active throughout" with the active-window rate, not a retention percentage. Interference between
the training and viewer workloads may be a **host** effect present on both legs; per **D15**, host-CPU
accounting differs between legs, so check the core accounting before attributing it to the filesystem.

### `pipeline-end-to-end-stage6d.sh` + `aggregate-stage6d.py`
**What.** Sequential end-to-end orchestration, and the aggregator that composes the bookend from measured
per-phase numbers.
**Why.** The phases are strictly sequential with no shared-resource interaction, so measured per-phase
wallclocks compose **exactly** — running it live would repeat the long-pole stage for hours and add no
insight. Retained as the productisation template.
**Caveats.** **Every component must come from the same leg's run dirs.** The aggregators glob run dirs, so
mixing legs is easy to do by accident and would produce a number describing neither filesystem.

---

## Stage 7 — Clinical inference deployment

### `inference-per-slide-stage7.py`
**What.** Chains tissue detection → feature extraction → MIL → heatmap write for one slide, emitting a
per-phase latency row. Reuses the Stage 6 readers and MIL module.
**Why.** Deployment decisions are made on seconds-per-slide, not aggregate throughput — a different metric
from every earlier stage. The MIL aggregator runs **untrained in eval mode** because forward cost is identical
regardless of training state and we are measuring latency, not accuracy.
**Caveats.** Per-cell `LD_PRELOAD` scoping; exposes a start barrier for the orchestrator. Heatmap content is
**real attention weights** — zero marginal cost since the forward already runs, and it produces the artifact a
production system actually writes.

### `orchestrate-clinical-deployment-stage7.sh` + `sweep-stage7-clinical.sh` + `aggregate-stage7-clinical.py`
**What.** Runs N concurrent inference jobs and/or the four-way clinical mixed workload; per-cell driver;
aggregator over all sub-tiers.
**Why.** Concurrent jobs consume **disjoint** slide chunks, mirroring production (each clinician runs their
own slide) and preventing both idle processes and duplicated work from distorting the percentiles.
**Caveats.** Per-process batch size declines as concurrency rises to bound GPU memory — **the schedule is
instance-specific and must be re-derived**. Per-slide wallclock remains the metric regardless, since that is
what an SLA is written against. High-concurrency cells deliberately oversubscribe the GPUs and therefore
measure storage and queueing, not GPU throughput.

### `read-after-write-stage7.py`
**What.** A writer process emitting a tiled TIFF with **synthetic content**, and a reader polling that path
for visibility and then reading the first chunk.
**Why.** Read-after-write visibility is a **consistency** property, not a bandwidth one, and the two
filesystems have different metadata architectures — so there is no reason to assume they behave the same.
**Why the content is synthetic and not a real inference output.** Visibility depends on the file's size, its
tile structure and the fsync-then-rename ordering — not on what the pixels contain. Running the per-slide
inference chain to produce real heatmap pixels would add tens of seconds of orthogonal latency to every
iteration and dilute the quantity being measured. It is the one Stage-7 writer that is not a real forward,
and that exception is what this paragraph exists to justify.
**Caveats — a correctness requirement, not a style choice.** The writer must **write to a temporary name,
fsync, then rename.** Without it the file exists at zero length the moment it is opened, the reader's
existence check fires at creation, and the result is a plausible-looking number that measures nothing.
**Artifact size is requested, never assumed.** `--bytes-per-write` sizes the pixel grid through an assumed
deflate ratio that this content does not obey — the pattern is a small base tiled up by `np.repeat` and
compresses far harder — so the **achieved** size is `stat()`'d and both are recorded
(`bytes_per_write_target`, `bytes_written_mean_achieved`, `bytes_written_target_ratio`), with a **loud
warning** when they diverge past 2×. It matters because visibility latency depends on the artifact's real
size and tile geometry: an artifact an order of magnitude smaller than a production heatmap answers the
question for a file nobody writes. Per the Stage 7 decision the artifact is sized and tiled from a
**measured 7.3 output on the same leg** — pass that size in, and let the target-vs-achieved check confirm it.
**Output schema.** `visibility_latency_resolution_floor_ms` = the poll interval. The reader can only observe
the file on a poll boundary, so **any latency at or under it is quantisation, not measurement** — recorded so
nobody reads a sub-interval p50 as a real number. Recording the floor is unambiguous; **tightening the
interval is a tuning judgment against CPU cost and stays open.**
**Single-client scope:** writer and reader are processes on one instance; cross-client consistency would need
a second instance.

### `streaming-loop-stage7.sh`
**What.** Synthetic-scanner cadence driving the full arrival → inference → heatmap → viewer loop with
per-slide event timestamps.
**Why.** The end-to-end workflow bookend, and it captures cross-slide queueing if inference falls behind the
emitter — which a per-slide latency number alone would hide.

---

## Manifests (`../scripts/manifests/`)

| File | What | Used by |
|---|---|---|
| `tcga-brca-full40x-stage4a-format.tsv` | **The 1064-slide uniform-magnification cohort** (**D5**) | 6.A Tier 2, 6.B.3, 7.2/7.3/7.5, 6.D |
| `tcga-brca-stage4a-subset.tsv` · `camelyon16-stage4a-subset.tsv` | 50-slide subsets, fixed seed — the cross-stage anchor | 4.A, 4.C, 5, 6.A Tier 1/3, 7.1/7.6 |
| `tcga-brca-full.tsv` · `camelyon16-full.tsv` | Full download manifests | One-time staging into S3 |
| `tcga-brca-full-stage4a-format.tsv` | Full cohort before the magnification-uniformity exclusion | Retained for traceability — **not** the cohort of record |
| `tcga-brca-pilot.tsv` | Small pilot set | Smoke tests |

**These are filesystem-agnostic and carry over unchanged** — they are part of what makes the datasets a
held-constant input across legs (**D6**).

---

### `sweep-stability-canary.sh` — the run-to-run noise band (`D18`)
**What.** Two fixed, short cells (~3 min the pair): an 8 GiB O_DIRECT fio read cell (60 s sequential + 60 s
random) and a create/stat/unlink 2000-file metadata cell, each wrapped in `record-run.sh` under
`--stage stability`.
**Why.** The spread of a deliberately fixed config across the leg is the leg's empirical noise band — the
thing a cross-leg delta must clear before it is a finding (**D18**). It measures *path stability*, not
absolute capability: O_DIRECT keeps the client cache out, and the server side is consistently warm on purpose.
**I/O.** No arguments; needs `FS_MOUNT`. Fixtures live at `${FS_MOUNT}/benchmarks/stability-canary/` (the io
file is laid out by fio on first run and reused). → two run dirs per invocation.
**Caveats.** Invoked by `run-leg.sh` steps `C0`–`C8` (unique ids, so resume semantics hold). Band computation
and rep-grouping are aggregation-side — **D-4**'s shared helper.

---

### `push-safe.sh` — the two-committer push convention (`D6`)
**What.** `git pull --rebase --autostash` + `git push`, retried ×5 with backoff.
**Why.** Two autonomous sessions commit concurrently; bare `git push` loses races. Union-merge attributes
(`.gitattributes`) let the append-only artifacts merge themselves; a REAL rebase conflict aborts loudly —
that is an ownership violation to report (`CLAUDE.md`, "Concurrent legs"), never to auto-resolve.
**I/O.** No arguments. → pushed HEAD, or a loud refusal.

---

### `wsi-lustre-phase2.sh` — the baked lustre mount automation (`D6`/`D16`/`D-17`) — **NOT YET BAKED**
**What.** Ships as a loud refusal carrying the baked shape (six stages, every failure a WSI-FATAL that
leaves the filesystem unmounted). Content comes from the first gated walk's validated transcript.
**Why.** The FSx EFA client procedure cannot be safely automated before it has been validated once on the
pinned AMI/kernel — the walk validates, this file inherits. Until baked, invoking it refuses.
**Caveats.** The D16 gate is structural: `lnetctl net show` must evidence `efa` or there is no mount and no
fallback — a TCP waiver is a human decision.

---

## Environment specs (`../scripts/env-specs/`)

Four kinds of file, **not interchangeable** — pick deliberately, because `conda_env_main` and
`python_version` are `MUST_MATCH` contract fields, so the environment is a **held-constant input**: whatever
Leg A ends up with, Leg B must reproduce bit-identically.

| File | What it is | Use it when |
|---|---|---|
| `env-create-history.txt` | **The recipe** — the actual `mamba create`/`install` commands, loose pins that re-solve against the CUDA present | Building the FIRST environment on a new stack (the bootstrap's route) |
| `*.conda-explicit.txt` | Fully pinned package URLs — reproduces the **conda layer** bit-identically (`conda create -p <path> --file <file>`); it **cannot carry the pip layer** | **The Leg-B rebuild** (first half), so Leg B matches Leg A exactly |
| `*.environment.yml` | Solved spec with versions; its `name:` is an absolute **path**, so create with `-p`, not `-n` | A middle route if the explicit file will not solve |
| `*.pip-freeze.txt` | Record of the pip-installed remainder; its **PyPI-form `name==ver` lines are the pip layer's pin** (conda-provided packages appear as `@ file://` and are skipped) | **The Leg-B rebuild (second half)** — the builder `pip install --no-deps`'s those lines on top of the conda layer; also the cross-check |

**After Leg A's environments are final, regenerate these files from what was actually built** — the explicit
file is only a valid Leg-B target once it describes the real environment. If the explicit file will not solve
on the Leg-B instance, that is a **finding to surface** (the two legs cannot share an environment), not
something to work around silently.

---

## Cross-references

`../CLAUDE.md` (rules, recording, durability) · `../PROJECT-THESIS.md` (the question, both asymmetries, and
the framing rule, §10) · `STAGES.md` (the cross-stage decision register) · `RUNBOOK.md` (how to run a cell,
both canaries, silent-skip hazards) · `FILESYSTEM-MAP.md` (paths) · `NAMING-AND-VARIABLES.md` (every name and
its recommended value) · `RESULTS.md` (findings) · the per-stage roadmaps (methodology and per-cell results) ·
`cloud-session-open-items` memory (the running tracker, including every `⏳ DEFER` above).
