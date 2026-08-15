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
| **D-5** | **Per-filesystem consistency relation** | The canary logic in the aggregators | Must be derived from the actual EC scheme (WEKA) and the actual stripe layout (Lustre) — neither exists yet |
| **D-6** | **cuFile path accounting as a recorded source** | `record-run.sh` + the kvikIO readers. **`aggregate-stage4c-kvikio.py` is the concrete consumer:** its `gds_engaged` column is hardcoded `"unknown"` and stays that way until this source exists — so closing D-6 has a defined finish line, namely that column carrying a recorded value | Needs the real cuFile/nvidia-fs stats format. Every kvikIO cell must record GPU-direct-vs-bounced bytes or it is incomplete (**D8**) |
| **D-7** | **During-run sync, watchdog, canary-abort** | `record-run.sh` | **Partly done:** `sync-to-s3.sh` exists and `run-leg.sh` syncs after every step. Still needed: per-**cell** sync inside `record-run.sh`, the per-cell watchdog timeout, and making the canary abort the chain |
| **D-8** | **GPU/NUMA map + DDP ranges** | `run-multiproc-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6a-extract.sh`, `sweep-stage7-clinical.sh` | The GPU↔NUMA↔NIC map must be re-derived on the real instance; GPU-count sweeps follow its GPU count |
| **D-9** | **Core-accounting values** | `env.sh`, per leg | The exclusion **mechanism** is in place — `record-run.sh` records `cores_reserved` from `FS_CLIENT_RESERVED_CORES` and every CPU aggregator reads it per run, refusing null. What remains is the per-leg **value**: measure the reserved-core list on each real client (**D15**) and set the variable (`none` on a leg that reserves none) |
| **D-10** | **cuFile config + env VALUES** | ~20 files reference conda/cuFile/CUDA paths. They now genuinely read documented variables (`$CONDA_ENVS_DIR`, `$LIBCUFILE_PRELOAD`, `$CUFILE_ENV_PATH_JSON`) and refuse if unset — audit items `A-4`/`A-5`; before that they were literals from another machine. What remains is the **values** | Leg A's values are set by the bootstrap (`LIBCUFILE_PRELOAD` located and exported; a compat-mode `cufile.json` generated per instance). Remaining: rewrite `../scripts/GDS-TUNING-CHECKLIST.md` (bannered) incl. a Lustre-over-EFA branch, and Leg B's cufile config |
| **D-11** | **Lustre tuning** | Stripe layout + client tunables | Needs FSx (Leg B). **Part of "Lustre at maximum" (D7)** — skipping it would understate Lustre and break the fairness basis |
| **D-15** | **Make step 4.D actually recorded** | `convert-stage4c-rawtiff.sh` | It is `run-leg.sh` step 4.D and its own header calls it a recorded cell, but it **never invokes `record-run.sh`** — no run dir, no telemetry, no `INDEX.md` row, no S3 sync for the 20× conversion the roadmap treats as a measured workload. It also does not fail loud when zero slides resolve from the manifest. Wrapping it changes what a substage produces, so it needs the owner's nod |
| **D-16** | **Lustre client-side EFA configuration** | `../prompts/prompt-lustre-cluster-cloud.md` | The documented Leg-B flow enables EFA on the instance and the file system and installs the generic EC2 EFA software, but nothing yet runs AWS's FSx-Lustre EFA client setup — so the client would mount over TCP, forfeiting GDS **and** the per-server-cap escape while still producing numbers. That breaks the "Lustre at maximum" basis (**D7**) invisibly. Needs the current AWS FSx-Lustre client docs, plus a gate that `lnetctl net show` lists an `efa` net |
| **D-17** | **Leg-B kernel-vs-contract policy** | `../prompts/prompt-lustre-cluster-cloud.md` | The documented Lustre client install can pull a newer kernel, and `kernel` is a `MUST_MATCH` contract field — so the Leg-B procedure can invalidate the comparison the contract exists to protect; any OS upgrade can too. Decide: pin the kernel and install a client build matching the running kernel (per AWS's install docs for this OS), or re-baseline both legs |
| **D-19** | **Substage 1.8 has no implementation and no marker** | `Stage-1-Ingest.md` | The FSx-native S3 import is the only substage with neither a driver row, a "no implementation" note, nor a deferred id. It is a Lustre-leg capability cell excluded from the head-to-head, so omitting it breaks no cross-leg comparison and would go unnoticed. Build it in Leg B or record a decision not to |
| **D-21** | **A contract-verified marker `run-leg.sh` refuses without** | `env-contract.py`, `run-leg.sh` | The rebuild runs `env-contract.py verify` as "the gate", then starts the leg **without checking the gate ever ran or passed.** Phase 1 (safe): `verify` writes `runs/.leg-state/$LEG/contract-verified` on PASS and unlinks it on FAIL; `run-leg.sh` warns loudly when it is absent or older than the contract. Phase 2 — promoting that to a refusal — **needs explicit ratification**, since it can abort a leg |
| **D-23** | **`sync-to-s3.sh --self-test`** | `../scripts/sync-to-s3.sh` | Its header carries a seven-step manual first-run procedure, including the one that matters: prove a file under a MIRROR path disappears when deleted locally and a file under an ARCHIVE path does **not**. Mechanise it under a namespaced `_selftest/` prefix, print (don't run) the cleanup command, and make removing the file's `UNVERIFIED` banner conditional on it passing. Needs the real bucket |
| **D-24** | **Cross-leg artifact fingerprints** | new `capture`/`compare` in `../scripts/`, defined in `STAGES.md` | `RUNBOOK.md` declares four cross-leg integrity gates — same slides producing coords and same per-slide tile counts; same raw-TIFF byte counts and tile-grid dimensions; same feature file count, per-slide tile count and tensor shapes — each "fail-loud and invalidates downstream comparison", and **nothing computes or compares them.** A declared gate that no code implements is worse than no gate: it reads as covered. Propose the per-artifact-class fingerprint definitions for ratification now; build after Stage 3.0 has real output |
| **D-25** | **Stage 6.C's 4-GPU partition** | `orchestrate-concurrent-stage6c.sh` | 6.C pins MIL to GPU 0 "to stay out of the extract workload's GPUs" while extract requests 4 — an isolation that is arithmetically impossible on a 4-GPU instance. Decide the partition (extract on 3 + MIL on 1, or accept sharing and delete the isolation claim); either way the retention denominators change, so it is a methodology call, not a tuning one |
| **D-26** | **The dangling `Q<n>` decision-citation scheme** | 29 citations across 12 scripts | Scripts cite locked decisions as `Q1`–`Q13`; **zero `Q<n>` identifiers survive anywhere in `docs/`**. Every one of those citations is unresolvable. Either reintroduce stable ids into the per-stage registers or rewrite the citations to name the decision — a convention call either way |
| **D-27** | **`--compat-mode` knob for the Stage-5 trainer and Stage-6 extractor** | `train-resnet50-stage5.py:480`, `extract-features-foundation-stage6.py:636`, their drivers | Both hardcode `compat_mode="off"` citing a **previous environment's** "Stage 4.C winner", with no CLI knob — so **`STAGES.md`'s mode-controlled paired cell for 5.A/6.A cannot be run at all**, and a leg where GDS is unachievable has no way to request compat. The reader classes already validate `off\|on\|auto`; adding the flag needs no target value. Only the per-leg *value* is a cloud input |
| **D-28** | **Stage 7.2 reads full-cohort raw-TIFF that no step produces** | `sweep-stage7-clinical.sh:227-232`, `convert-stage4c-rawtiff.sh` | 7.2 is configured against the 1073-slide cohort through the kvikIO/raw-TIFF backend, but 4.D converts only the subset and 6.A Tier 2's chunks are transient. Either 4.D retains the full cohort (order ~7 TB — a capacity input, **D7**/**D4**) or 7.2 runs on the subset. Record the choice in the Stage-4 and Stage-7 roadmaps |
| **D-30** | **`record-run.sh`'s OK/INCOMPLETE verdict enforces none of RUNBOOK's per-cell requirements** | `record-run.sh:394-422` | A cell missing cost inputs, cache state, core accounting or cuFile path proof is still stamped `OK`. Decide what blocks versus warns — same shape as **D-21** phase 2, and it should be decided with it |
| **D-31** | **The environment contract omits the 20 workload-shape variables** | `env-contract.py:48-72` | `docs/NAMING-AND-VARIABLES.md` Table 5 declares them identical-across-legs, but the contract records none. **Do not simply append them to `MUST_MATCH`:** `verify()` pushes a null-vs-null pair into `unrecorded` and returns FAILED, so the normal case (both legs on defaults) would fail. Needs a tri-state or a defaults-aware comparison |
| **D-32** | **`dataset_manifest_sha` hashes the manifest, not the dataset bytes** | `env-contract.py:174-175` | The held-constant field "the datasets and their byte contents" is therefore asserted, never verified. Full rehashing costs hours of leg wallclock, so the cheaper options (file count + total bytes + newest mtime; or a sampled hash) are a methodology call |
| **D-33** | **Stage 7's `## 7.1` headline grid is structurally always empty** | `aggregate-stage7-clinical.py` | The grid filters on `cell_name.startswith('7.1')`, but `RUN_NAME_RE` strips the stage segment, so a `record-run.sh`-named dir `…-s7.1-baseline-…` yields `cell_name='baseline-…'` and never matches. 7.2 only appears because its driver pre-computes a `-s7-7.2-…` dir, leaving the sub-tier inside the name. Either match on the recorded `stage` field or stop stripping the segment — but the two naming shapes must be reconciled first, which is why this is not a one-line fix |

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
**Caveats.** Honours `RECORD_RUN_DIR`. Marks `INCOMPLETE` if the command returns non-zero **or** any stream
in **this leg's required list** has fewer than two lines (per-`$FS`, D-4). The WEKA-leg set: `weka stats
realtime` 1 Hz poll (all processes; client rows filtered at parse time), `nvidia-smi`, `sar`, kernel netdev
counters (Diagnostic here except 1.7), RDMA/EFA device counters (header-only where absent, not required on
this leg), and a **verbatim 1 Hz `/proc/driver/nvidia-fs/stats` capture** (the kernel half of cuFile path
accounting). Snapshots also capture nvidia-fs params and the cell's cuFile config. `metadata.json` carries
`fs_transport` from `FS_TRANSPORT`. **Refuses `--fs lustre`** until the Lustre recorder adapter is built on
Leg B (D-4).
**⏳ DEFER:** the Lustre recorder half (D-4); cuFile path accounting's reader half + the kvikIO-cell
requirement wiring (D-6); during-run S3 sync, per-cell watchdog, canary-abort (D-7).

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
success (Rule 11).
**⏳ `UNVERIFIED AGAINST A REAL BUCKET`** — written before the environment existed. Its header carries a
**7-step FIRST-RUN PROCEDURE**; run it before trusting the script and then remove the banner. **Step 6 is the
one that matters:** create a throwaway file under an *archive* path, sync, delete it locally, sync again, and
confirm it does **not** disappear from S3. Also tracked as open item `D-7`.

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
**What.** Drives one whole leg's sweeps in dependency order: **31 steps** (22 sweeps + the 9 interleaved
stability-canary invocations `C0`–`C8`, **D18**), `--dry-run`, `--list`, `--from`,
`--only`. Each step carries its driver **and that driver's target** where the driver dispatches on `$1`
(4.C `tier1`, 5 `all`, 6.A `tier1`, 6.A.3 `tier3`, 6.B.3 `all`, 6.B.2 `all`, 6.C `all`, 7 `all`) — the runner
word-splits the command, and `--from`/`--only` are validated against the step-id list so a typo cannot
silently skip the whole leg.
**Why.** A leg is many hours of sweeps that must run in a fixed order because each stage produces inputs the
next consumes. Driving that by hand overnight invites a missed step or a silently-continued failure.
**It orchestrates SWEEPS, not cells** — per-cell recording and failure isolation stay with `record-run.sh`.
**The five guards, each with its reason:** (1) **abort the chain on any step failure** — later steps consume
earlier outputs, so continuing would build cells on missing inputs; (2) **checkpoint + resume** via per-step
done-markers, so a crash re-runs only what is missing; (3) **S3 sync after every step**, because both mounts
and local scratch are ephemeral; (4) **tee everything** — on an overnight run the log is the only forensic
record; (5) **refuse a leg on the wrong transport** — WEKA must be on DPDK and Lustre on EFA (**D16**), read
from `FS_TRANSPORT`, recorded from client evidence — the bootstrap writes it on the WEKA leg, the cluster
prompt verifies it (and records it on Leg B). Unset refuses too, because an
unrecorded transport cannot be shown to be the right one. Overridable only by a written reason in
`runs/.leg-state/$LEG/transport-waiver`, which is then echoed into the log. *Why here:* this is the unattended
entry point, and the fallback transports (UDP / TCP) mount cleanly and report plausible numbers, so an
instruction followed hours earlier is not evidence.
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
verification, open-items memory).

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
handoff must exist before this runs. The commit it makes is the human-initiated teardown commit, not an
autonomous one. First real teardown must also run `sync-to-s3.sh`'s FIRST-RUN procedure (open-items
memory).

---

## Stage 1 — Ingest

### `sweep-stage1-{seqw,seqr,randw,randr}.sh` — synthetic ceiling sweeps
**What.** Four `fio` drivers: sequential write, sequential read, random write IOPS, random read IOPS. Block
size × concurrency grids; sequential grids at iodepth=1, IOPS grids at iodepth=8.
**Why.** These anchor the whole project: **every downstream "% of ceiling" divides by one of these cells at
the matching block size.** Throughput is strongly block-size-dependent, so a single ceiling number would make
mid-block workloads look artificially high or low. They are also the cleanest apples-to-apples cells in the
project, since `fio` is filesystem-agnostic.
**I/O.** Host RAM ↔ `$FS_MOUNT/benchmarks/fio-scratch/` → per-cell run dirs.
**Caveats.** `--unlink=1` cleans per cell. Read sweeps need a layout phase before the timed window.
**⏳ DEFER:** nothing driver-side — mount, repo root and filesystem labelling are all done. The remaining
work for these cells is in the aggregator: per-filesystem sources (D-4) and the consistency relation (D-5).

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
**What.** Dataset × concurrency grid, single pass per cell.
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
cache differently, so the crossover must be characterised per filesystem rather than assumed shared.

### `convert-rawtiff-20x.py` + `convert-stage4c-rawtiff.sh` — the 20× raw-TIFF writer
**What.** Writes a single-level, 256-tiled, uncompressed TIFF whose **level-0 is the 20× image**, so cuFile
reads level-0 byte ranges directly as tiles and coords map to a tile index by integer division. Per-dataset
read path; **fail-loud mpp guard** rejecting off-magnification slides.
**Why.** The standard converter has no magnification/level flag and always emits the source's 40× level-0.
Keeping a 40× artifact and reading pyramid level-1 would be ~4× larger, ~4× slower to produce, and — the
decisive point — **not the artifact a 20× GPU-direct customer stores** (**D4**). Matching the readers'
resize interpolation means both backends see the same pixels.
**Caveats.** **Idempotent skip on existing non-empty output** — so a stale artifact from another magnification
or converter version is **silently reused**. Delete before regenerating. The output is a large capacity cost
on both filesystems (order ~7 TB at full cohort) and thus a sizing input to **D7**.

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
difference.

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
| `tcga-brca-full40x-stage4a-format.tsv` | **The 1073-slide uniform-magnification cohort** (**D5**) | 6.A Tier 2, 6.B.3, 7.2/7.3/7.5, 6.D |
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
