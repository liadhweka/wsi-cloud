# Naming & variables — every blank in this project, in one place

**Purpose.** Every path, name, and identifier that varies between environments is enumerated here, with a
recommended value. Nothing is hardcoded in the scripts; they read these from the environment. This doc plus
its companion **`../env.example.sh`** are the single source of truth — every other doc and script
*references* these names rather than inventing its own.

**Why this exists.** Every environment-varying value has **exactly one name**, defined here, and no synonym
anywhere else. A value that appears as `<user>` in one doc, `<repo>` in another, and a hardcoded literal in a
script is the class of inconsistency that produces a 2am mistake — and in this project one specific mistake,
**a wrong mount**, makes one leg silently measure the other filesystem while the number still looks correct.

---

## How to use

```bash
cd <repo>
cp env.example.sh env.sh   # env.sh is gitignored — it holds real values
$EDITOR env.sh             # fill in the DECIDE-NOW values
source env.sh              # do this in every shell, or add to ~/.bashrc
./env.sh --check           # validates: nothing unset, paths exist, S3 reachable
```

Every script sources nothing implicitly — it reads the environment and **fails loudly if a required variable
is unset.** An unset variable must never silently default, because the defaults are what would be wrong.

---

## Table 1 — DECIDE NOW (choices; set these before provisioning)

| Variable | Recommended | Why this value / what it affects |
|---|---|---|
| `PROJECT_USER` | **`ec2-user`** | The AMI's default user on Amazon Linux 2023 images — no `adduser` step, no permission surprises. **Do NOT use `root`:** it breaks `/dev/shm` permissions and conda ownership, and it changes the memory slug (see Table 3). |
| `PROJECT_HOME` | **`/home/ec2-user`** | Follows from `PROJECT_USER`. |
| `REPO_DIR` | **`$PROJECT_HOME/wsi-cloud`** | Matches the GitHub repo (`wsi-cloud`). Distinct from the earlier project's `wsi`, so the derived slug (`-home-ec2-user-wsi-cloud`) cannot collide with it — **the directory name is load-bearing for exactly this reason.** |
| `GITHUB_REPO` | **`liadhweka/wsi-cloud`** | SSH remote: `git@github.com:$GITHUB_REPO.git`. |
| `AWS_REGION` | **`ap-northeast-2`** | Chosen for g6e capacity, which outranks every tiebreaker (the CAMELYON open-data bucket's home region lost to it). Everything — instance, both filesystems, the bucket — must share it. |
| `AWS_AZ` | *(per leg: the AZ its filesystem lives in)* | **Within a leg**, client and filesystem must share the AZ — cross-AZ traffic adds latency and cost and would contaminate that leg's numbers. **Across legs** the AZ may differ (`aws_az` is MAY_DIFFER — the concurrent-legs reclassification, `STAGES.md` **D6**); per-leg ambient variance is what **D18**'s canary bands measure. |
| `INSTANCE_TYPE` | **`g6e.24xlarge`** | The L40S GPU family, ≥200 Gbps client networking, and EFA-capable from the start because Leg B needs EFA. **Identical in both legs** — it is the single largest held-constant variable. If **D10**'s pre-committed revisit trigger fires, the move is up to `g6e.48xlarge`, **before Leg B**. Specs, why, and the trigger: `STAGES.md` **D10**. |
| `S3_BUCKET` | **`liad-wsi-cloud`** | ⚠ **S3 bucket names are globally unique across all AWS accounts**, which is why the name carries an owner prefix rather than a generic one. |
| `WEKA_MOUNT` | **`/mnt/weka`** | Leg A mount. |
| `LUSTRE_MOUNT` | **`/mnt/lustre`** | Leg B mount. |
| `WEKA_FS_NAME` | **`default`** | The WEKA filesystem name — created by the terraform-aws-weka module under its default name. Kept distinct from the mount path deliberately — they need not match, and assuming they do has caused confusion before. |
| `SCRATCH_DIR` | **`/data/local-nvme`** | Instance-store scratch. **Ephemeral** — dies with the instance, including between legs. |
| `CONDA_ROOT` | **`$SCRATCH_DIR/miniforge`** | The miniforge **install** root. Off the OS disk. |
| `CONDA_ENVS_DIR` | **`$SCRATCH_DIR/conda-envs`** | Where the **environments** live — deliberately *not* under `CONDA_ROOT`, so the interpreter path is stable if miniforge is reinstalled. Every sweep driver builds its interpreter as `$CONDA_ENVS_DIR/$CONDA_ENV_MAIN/bin/python`. |
| `CONDA_ENV_MAIN` | **`wsi-cucim-2604`** | Keep this name — `../scripts/env-specs/` files are named after it; renaming means editing the specs. |
| `CONDA_ENV_ALT` | **`wsi-cucim`** | Second env, same reasoning. Used by the two cuCIM-CPU drivers (Stage 4.A, 4.B). |
| `CLAM_DIR` | **`$PROJECT_HOME/wsi-tools/CLAM`** | The tissue detector used by Stage 3. Cloned during setup; the commit is recorded per run. |
| `CUFILE_CONFIG_DIR` | **`$PROJECT_HOME/cufile-config`** | Where the generated cuFile config lives. |
| `CUFILE_ENV_PATH_JSON` | **`$CUFILE_CONFIG_DIR/cufile.json`** | Generated **per instance, per leg** by the bootstrap — a compat-mode config on BOTH legs, which per **D8**'s expected-symmetric outcome is also the end state (no true GDS at this client class; a per-cell path split contradicting that would reopen `D-10`'s GDS-side wiring). |
| `LIBCUFILE_PRELOAD` | *(set by the bootstrap)* | The **path** of the system `libcufile` matched to the loaded `nvidia-fs` module. Every kvikIO sweep driver reads it and **refuses to start without it.** The bootstrap locates and exports it from the installed CUDA stack at build time. |

> **`LIBCUFILE_PRELOAD` holds a path; `LD_PRELOAD` is what must never be global.** Exporting the *path* is
> required — the drivers read it. What the drivers then do is set **`LD_PRELOAD` per cell, on kvikIO cells
> only**, because cuCIM segfaults when a newer libcufile is preloaded over its bundled one. Exporting
> `LD_PRELOAD` globally would break every cuCIM cell in a mixed sweep.
>
> **Why the drivers refuse rather than defaulting:** a libcufile path from another machine makes
> `LD_PRELOAD` a silent no-op, so the kvikIO cells would run against the conda env's bundled copy and still
> report plausible numbers — the worst failure mode this project has.

## Table 2 — RECORD WHEN PROVISIONED (outputs; you don't choose these, you capture them)

These go into the **environment contract** (`STAGES.md` **D6**) and are what let Leg B prove it matched
Leg A. **Capture them as you provision** — several are hard to reconstruct later.

| Variable | Where it comes from | Why it's needed |
|---|---|---|
| `AMI_ID` | Instance launch | Leg B rebuilds from this exact AMI. Pin it. |
| `INSTANCE_ID` | Instance launch | Provenance. |
| `CLIENT_HOSTNAME` | `hostname` on the instance | Provenance. The aggregators select client telemetry by **role** (`Mode=="client"`), never by hostname — hostnames are rebuild-unstable, and this cluster runs exactly one client container by design. |
| `WEKA_BACKEND_TYPE` · `WEKA_BACKEND_COUNT` | Your WEKA provisioning | Sizing evidence for the fairness basis (**D7**). |
| `WEKA_BACKEND_AMI` | `describe-instances` at spin-up | **Recorded, never pinned:** backends are `MAY_DIFFER` and absent on Leg B, but the leg's provenance must say what they ran (STAGES.md **D20**). |
| `WEKA_CAPACITY_TB` | WEKA provisioning | Same. |
| `WEKA_EC_SCHEME` | WEKA provisioning | **Required** to derive the WEKA cross-source consistency relation (**D12**) — the canary cannot run without it. |
| `WEKA_BACKEND_RAM_TOTAL` | Sum of backend instance RAM | WEKA's half of the cache the Stage 6.B corpus must exceed. The corpus is sized against **both** filesystems' caches so one identical definition serves both legs (**D13**) — see the open-items memory, the 6.B corpus-sizing item. |
| `WEKA_CLIENT_CORES` · `WEKA_CLIENT_NICS` | `weka` client config | Client provisioning, and the reserved-core count for **D15** core accounting. |
| `FS_CLIENT_RESERVED_CORES` | The client's own report, per leg | The reserved-core **ID list** (e.g. `24-31`) — `record-run.sh` expands it into every run's `cores_reserved`, and every CPU aggregator reads that per run, **refusing a run recorded without it** (**D15**). Set `none` on a leg whose client reserves no cores: unset means *unknown*, and an unknown exclusion set is refused, never assumed. |
| `RECORD_CACHE_STATE` | **Sweep drivers, per cell — never `env.sh`** | The cell's declared cache regime, recorded into `metadata.json` as `cache_state` (null + warned when unset). Declared is not achieved: the achieved state is what worker output and the pre-cell canary establish (**D13**). |
| `RECORD_TIMEOUT_S` | **Sweep drivers — never `env.sh`** | The D-7 per-cell watchdog: `record-run.sh` group-TERM/KILLs the wrapped command past this many seconds (fire recorded in `raw/watchdog.log`; rc flows to the verdict). Drivers set it from their cells' own runtimes; unset falls back to 86400 — deliberately only a hung-forever backstop, because a watchdog that kills a valid hours-scale cell destroys real money. |
| `FSX_TIER` · `FSX_CAPACITY_TIB` · `FSX_METADATA_IOPS` | FSx provisioning (Leg B) | The "Lustre at maximum" evidence (**D7**), and FSX's cache size follows from tier × capacity. |
| `STAGE1_SEQ_CORPUS_GIB` | Derived from the fetched server-side cache figures at provisioning — ≥ ~2× the **larger** of the two filesystems' server caches | The 1.0b scan corpus. Sizes are parameters, never driver literals (**D13**); one identical definition serves both legs. `prep-stage1-read-corpora.sh` stages it; both read sweeps refuse without its marker and cross-check the staged size against this value. |
| `STAGE1_RANDR_REGION_GIB` · `STAGE1_RANDR_REGIONS` | Same derivation event | The 1.0d **one-touch region pool**: 21 grid cells plus reserve regions for the **D18** knee/peak repeats (a repeat must read fresh blocks or it measures its first run's cache). Region count must exceed 21 or the randr driver refuses. |
| `FSX_EFA_ENABLED` | FSx provisioning | Required to escape the per-client-per-server cap (GDS is out of reach on this client class regardless — `STAGES.md` **D8**). |
| `LUSTRE_STRIPE_LAYOUT` | `lfs getstripe` after mount | **Required** to derive the Lustre consistency relation (**D12**). |
| `DRIVER_VERSION` · `CUDA_VERSION` · `NVIDIA_FS_VERSION` · `LIBCUFILE_VERSION` · `KERNEL_VERSION` | The instance | Held-constant contract; the cuFile stack must be version-matched. |
| `SCRIPT_COMMIT` | `git rev-parse HEAD` | Both legs must run the same code. **Collected by `env-contract.py` itself — never an `env.sh` field.** The contract is written at the *end* of a leg, so a hand-typed copy goes stale the moment the tree advances, and only the typed one would be wrong. |
| `FS_TRANSPORT` | `dpdk` (WEKA) / `efa` (Lustre) | The transport actually in use, from the client's own report — never from the mount options passed. **`run-leg.sh` refuses to start a leg when it is unset or shows the fallback** (`udp`/`tcp`) without a written waiver (**D16**): the fallbacks mount cleanly and report plausible numbers for a configuration we decided not to measure. |
| `INSTANCE_USD_PER_HR` · `FS_USD_PER_HR` | Vendor pricing pages, **fetched the day you set them** | The two infra cost inputs (`../PROJECT-THESIS.md` §4). Recorded per cell by `record-run.sh`; null + warned when unset, never guessed. |
| `SOFTWARE_USD_PER_HR` | WEKA leg: the **public AWS Marketplace rate** (citable; a negotiated price is not), **metered on usable capacity** (confirmed with WEKA Sales — basis, value and the data-validity note for earlier cells: `STAGES.md` **D20**). Lustre leg: **`0`** — the FSx service rate is software-inclusive, and the recorded basis states it | The all-in cost's third input (**D7**). Both infra-only and all-in are computed per cell; presentation is a writing-time choice. |
| `PRICE_CHECKED_UTC` | The date you fetched the prices | An undated price cannot be audited and a stale one silently rewrites the conclusion — treat undated as missing. |
| `FS_PER_CLIENT_CEILING_GBPS` · `FS_PER_CLIENT_CEILING_BASIS` · `CEILING_CHECKED_UTC` | Per leg, **fetched dated like a price**: the vendor-**documented per-client** throughput cap where one is documented (FSx — the same AWS performance page **D7** cites), the instance's own line rate otherwise (WEKA documents no per-client cap, so the physical NIC is the honest ceiling; basis says which) | Recorded into the environment contract, so every result can show **measured vs documented ceiling** per leg — a single client cannot drive an aggregate maximum, and this turns that objection into a table (**D7**). |

## Table 3 — DERIVED (computed; never set by hand)

| Variable | How it's derived | Note |
|---|---|---|
| `MEMORY_SLUG` | `REPO_DIR` with `/` → `-` | For the chosen names: `-home-ec2-user-wsi-cloud`. **Discover it, don't type it** — the memory restore and backup steps derive it (`FILESYSTEM-MAP.md`), so a path change needs no edits. **`env.sh`'s copy is display-only:** `restore-memories.sh` and `backup.sh` each derive their own from the repo's *real* location and never read it, so `--check` prints it as `info` rather than validating it — an `ok` on a value nothing reads would claim it is in force when it is not. Don't wire anything to it. |
| `LEG` | set per leg in `env.sh`; `run-leg.sh --leg` exports it | `weka` \| `lustre`. Feeds `FS_MOUNT`, the run-dir name segment, the `metadata.json` field, and the S3 prefix. **`record-run.sh` derives `--fs` from it** when the flag is not passed, so the sweep drivers stay argument-free — see the `--fs` note below. |
| `FS_MOUNT` | `WEKA_MOUNT` or `LUSTRE_MOUNT`, from `LEG` | **The single most important variable in the project.** Every script resolves the mount through it. A hardcoded mount makes one leg measure the other with no failure signal. |

> **How a cell gets its filesystem label — `--fs` and `$LEG`.** `record-run.sh` takes
> `--fs {weka|lustre}`, and **when the flag is absent it falls back to `$LEG`.** That is why the sweep
> drivers take no arguments (`run-leg.sh` states the same): they inherit `LEG` from the sourced `env.sh`, or
> from `run-leg.sh --leg`, which exports it. **With neither the flag nor `LEG` set, the wrapper refuses** —
> the fallback is explicit configuration, not a default. `record-run.sh` additionally cross-checks the label
> against `FS_MOUNT` and refuses on disagreement, and `run-leg.sh` makes the same check at leg level, where
> `--leg` (human-supplied) and `FS_MOUNT` (environment-supplied) are genuinely independent.
>
> The label matters beyond bookkeeping: the run-dir name **must** contain the `-<leg>-` segment, because
> `sync-to-s3.sh` and `teardown-preflight.sh` both glob `runs/*-$LEG-s*/`. A run dir without it is never
> backed up to S3 **and the teardown gate does not notice.**

---

## Table 4 — Doc placeholder → variable

So a reader of any doc knows which variable a `<placeholder>` refers to.

| In the docs | Variable | | In the docs | Variable |
|---|---|---|---|---|
| `<user>` | `PROJECT_USER` | | `<fs>`, `<leg>` | `LEG` |
| `<repo>` | `REPO_DIR` | | `<bucket>` | `S3_BUCKET` |
| `<account>` | (GitHub account in `GITHUB_REPO`) | | `<slug>`, `<SLUG>` | `MEMORY_SLUG` |
| `<stage>` | `--stage` value (see `STAGES.md`) | | `<UTC>`, `<UTC-timestamp>` | generated by `record-run.sh` |
| `<run-dir>`, `<run-name>` | generated by `record-run.sh` | | `<workload>`, `<config>` | free-text run-name segments |
| `<ds>`, `<dataset>` | `tcga-brca` \| `camelyon16` | | `<model>` | `virchow2` \| `gigapath` \| `uni2-h` |
| `<slide-id>`, `<slide_id>` | per-slide identifier from the manifest | | `<backend>` | `openslide` \| `cucim` \| `kvikio` |
| `<cache>` | `cold` \| `warm` | | `<format>` | heatmap output format |
| `<cell>`, `<cell-dir>` | per-cell output dir | | `<rev>`, `<reason>` | forensic-rename suffixes |

*(`<br>` is HTML inside a table cell, not a placeholder — it will show up in any grep for `<…>`.)*

---

## Table 5 — WORKLOAD SHAPE (the Stage 6.C, 6.D and Stage 7 knobs; defaulted inside the driver)

The three multi-workload orchestrators — `../scripts/orchestrate-concurrent-stage6c.sh`,
`../scripts/pipeline-end-to-end-stage6d.sh` and
`../scripts/orchestrate-clinical-deployment-stage7.sh` — read these from the environment and fall back to an
in-script default. **They are workload shape, so they are part of what was measured:** both legs must run the
same values, or the comparison varies two things at once — which is exactly what the held-constant contract
(`../PROJECT-THESIS.md` §3) exists to prevent. Nothing fails when one is unset — that is the risk, and the
reason they are enumerated here instead of being left to the scripts. The one deliberate exception is
`MIL_NUM_WORKERS`, which **must** fail when unset (see its row): its correct value is a per-project
measurement, so a silent default is exactly the wrong-config hazard the others merely risk.

**Leave them unset unless a cell needs otherwise.** Unset means the driver default, which is identical on both
legs by construction. A value exported into the shell applies to **every** cell of that leg, so it must be
exported identically on the other — that is the one way these become a cross-leg difference nobody chose.

**Who sets what.** Stage 7's sweep driver sets the `INFER_*` values per cell in the child environment (its
single-process cells pass them as CLI arguments and read none of these), so the defaults below apply to any
`INFER_*` a cell does not name. **Stage 6.C's sweep driver overrides nothing** — every 6.C cell runs exactly
the defaults below. The `INGEST_*`, `VIEWER_*` and `HEATMAP_VIEWER_*` values apply only to cells that name
those workloads in `--workloads`.

### Stage 6.C — `orchestrate-concurrent-stage6c.sh`

| Variable | Driver default | What it affects |
|---|---|---|
| `EXTRACT_MODEL` | **`virchow2`** | The foundation model the concurrent extract workload runs, and — through the embedding dimension the driver picks from it — the MIL workload's input width. `uni2-h` also flips the sweep driver's `[PENDING-APPROVAL-DO-NOT-EXTERNALIZE]` cell tag. |
| `EXTRACT_DATASET_TAG` | **`brca50`** | Names the feature output dir, `$FS_MOUNT/features/6.A/$EXTRACT_MODEL/<tag>-6c-concurrent`. It selects **where features are written, not which slides are read** — the extract manifest is fixed in-script. |
| `EXTRACT_GPUS` | **`1,2,3`** | `CUDA_VISIBLE_DEVICES` for the extract workload. **The partition is ratified (2026-08-21): extract on GPUs 1–3, MIL pinned to GPU 0** — true isolation, so GPU contention stays out of a filesystem-QoS cell; the Tier-1 solo baselines run at this exact config, so every retention denominator matches its numerator. 6.D deliberately differs (`PIPELINE_GPUS` keeps all four — sequential phases, must match 6.A Tier 2's N). The driver refuses any index the instance does not have — `CUDA_VISIBLE_DEVICES` *drops* an unknown index silently, so the workload would run at reduced width while the cell claimed full width. **A guard cannot catch a wrong order**: the NUMA/NIC-aware order within {1,2,3} is still to be derived from `nvidia-smi topo -m` (deferred item `D-8`). |
| `EXTRACT_N_GPUS` | **`3`** | DDP world size for the extract workload. Must equal the number of indices in `EXTRACT_GPUS`; a mismatch changes the concurrency the cell actually ran at. |
| `MIL_NUM_WORKERS` | **no default — required for any cell naming the `mil` workload** | The MIL workload's DataLoader concurrency: **the measured 6.B.3 saturation knee**, read from Leg A's 6.B.3 results at 6.C entry and then held **identical on both legs** (it is workload shape). Deliberately not defaulted: a carried-over knee from another environment would run every 6.C retention figure at a wrong config with no failure signal, so the orchestrator refuses a `mil` cell without it. |
| `MIL_FEATURES_TAG` | **`brca_full`** | Which 6.A feature dir the MIL workload trains from (`$FS_MOUNT/features/6.A/$EXTRACT_MODEL/<tag>`). **Silent-fallback caveat:** with fewer than 10 `.pt` files there the workload falls back to the `brca50` dir, and skips itself entirely if that is also short — so a wrong tag *changes the workload* rather than failing the cell. |
| `INGEST_N` | **`4`** | fpsync concurrency for the ingest workload — the "scanner pace" baseline, fixed rather than swept so ingest is a constant background load. |
| `INGEST_SRC` | **`$SCRATCH_DIR/fpsync-source/tcga-brca`** | Ingest source. On local NVMe deliberately, so the read side of the copy is not the filesystem under test. A missing dir fails the ingest workload only — the rest of the cell continues. |
| `INGEST_DST` | **`$FS_MOUNT/runs-stage6c-ingest-target`** | Ingest target, on the filesystem under test. |
| `VIEWER_N` | **`4`** | fio `numjobs` for the viewer workload (bs=4K random reads, `iodepth=1` — the Stage 1.6 pathologist-viewing pattern). |
| `VIEWER_SCRATCH` | **`$FS_MOUNT/benchmarks/fio-scratch-6c-viewer`** | Where that fio scratch is created and read. |

### Stage 6.D — `pipeline-end-to-end-stage6d.sh`

| Variable | Driver default | What it affects |
|---|---|---|
| `PIPELINE_GPUS` | **`0,1,2,3`** | `CUDA_VISIBLE_DEVICES` for the pipeline's extraction phase (Phase 3). Same standing caveat as `EXTRACT_GPUS`: the **set** is valid on the 4-GPU instance, the NUMA/NIC-aware **order** is not yet derived (`D-8`), and the driver's guard catches a wrong set but never a wrong order. Kept identical in shape to `EXTRACT_GPUS` so the two sibling orchestrators cannot drift apart. **Including GPU 0 is correct here, unlike 6.C:** 6.D's phases run *sequentially*, so Phase 3's extraction and Phase 4's MIL (pinned to GPU 0) never overlap in time. Don't "fix" this by copying 6.C's off-GPU-0 workaround — it would shrink the extraction phase below the width 6.A composes with. |
| `PIPELINE_N_GPUS` | **`4`** | World size for the extraction phase; must equal the number of indices in `PIPELINE_GPUS`. **This width is not free to choose:** 6.D's entire output is per-phase wallclock, composed against the Stage 6.A Tier 2 extraction cell — so it must equal **6.A Tier 2's N**, or the end-to-end number cannot be composed with 6.A's at all. |

### Stage 7 — `orchestrate-clinical-deployment-stage7.sh`

| Variable | Driver default | What it affects |
|---|---|---|
| `INFER_MODEL` | **`virchow2`** | The foundation model each inference process runs. `uni2-h` also flips the sweep driver's `[PENDING-APPROVAL-DO-NOT-EXTERNALIZE]` cell tag. |
| `INFER_BACKEND` | **`kvikio`** | The tile-read path, and with it the per-process `LD_PRELOAD`: `kvikio` preloads the system libcufile, anything else leaves it unset — because cuCIM segfaults under a preloaded newer libcufile. |
| `INFER_CACHE_POLICY` | **`warm`** | The cache state the cell runs at. Cold-versus-warm is an **enforced axis** (`../PROJECT-THESIS.md` §6), so this shapes the result rather than the convenience of the run. |
| `INFER_HEATMAP_FORMAT` | **`tiff5x`** | Heatmap output format — the write side of the cell, and the thing sub-tier 7.3 varies. |
| `INFER_MANIFEST` | **`$REPO_DIR/scripts/manifests/tcga-brca-stage4a-subset.tsv`** | Which slides the inference workload walks. Processes partition it by `--process-id`, so its **length interacts with N**: a manifest shorter than N leaves processes idle and makes the high-N cells asymmetric. |
| `INFER_COORDS_DIR` | **`$FS_MOUNT/tissue-detection/3.0/tcga-brca/n64/patches`** | The Stage 3 tissue-detection coordinates read per slide. |
| `INFER_RAWTIFF_DIR` | **`$FS_MOUNT/data/tcga-brca-rawtiff`** | Raw-TIFF tile source — the input to the GPU-direct read path. |
| `INFER_SVS_DIR` | **`$FS_MOUNT/data/tcga-brca`** | Canonical SVS source. |
| `INGEST_N` | **`4`** | fpsync concurrency for the ingest workload — same fixed scanner-pace background load as 6.C. |
| `INGEST_SRC` | **`$SCRATCH_DIR/fpsync-source/tcga-brca`** | Ingest source, on local NVMe so the read side is not the filesystem under test. |
| `INGEST_DST` | **`$FS_MOUNT/runs-stage7-ingest-target`** | Ingest target, on the filesystem under test. **Stage-specific** — not the 6.C target. |
| `VIEWER_N` | **`4`** | fio `numjobs` for the SVS viewer workload (bs=4K random reads on 4 GB files). |
| `VIEWER_SCRATCH` | **`$FS_MOUNT/benchmarks/fio-scratch-7-viewer`** | Where that fio scratch is created and read. **Stage-specific** — not the 6.C scratch. |
| `HEATMAP_VIEWER_N` | **`4`** | fio `numjobs` for the heatmap-viewer workload (bs=4K random reads on 1 GB files) — the "pathologist opens the heatmap that just landed" load. |
| `HEATMAP_VIEWER_DIR` | **`$FS_MOUNT/heatmaps/7.5/viewer-scratch`** | Where that scratch lives — deliberately **not** the dir the inference workload writes heatmaps into, so "viewer reads heatmaps" is isolated from "inference writes heatmaps" while both still share the filesystem. |

> **`INGEST_N` is two different variables.** Stage 1.6 (`../scripts/sweep-stage1-mixed.sh`) assigns its own
> `INGEST_N=4` internally and **ignores the environment** — fixed across that sweep's cells on purpose, so the
> only thing varying is the read side. Exporting `INGEST_N` changes 6.C and 7, never 1.6.

---

## Values that must be identical across legs

`INSTANCE_TYPE`, `AWS_REGION`, `AWS_AZ`, `AMI_ID`, `KERNEL_VERSION`, `DRIVER_VERSION`, `CUDA_VERSION`,
`NVIDIA_FS_VERSION`, `LIBCUFILE_VERSION`, `SCRIPT_COMMIT`, dataset bytes, the magnification contract, the
model set, the recording harness's metric definitions (`../PROJECT-THESIS.md` §3) — **and every workload-shape
value in Table 5**, which is workload code by another name.

**Everything else is expected to differ** — everything filesystem-specific is the variable under test. The
environment contract records both sets, split into fields that **must match** and fields **expected to
differ**, so the distinction is auditable rather than asserted; **a mismatch is fail-loud, not a footnote.**
An unrecorded field counts as failed — a null cannot be shown to have matched.

## What must NOT go in `env.sh`

No AWS access keys, no Hugging Face tokens, no passwords. Credentials come from the **instance profile** and
`hf auth login`. `env.sh` is gitignored, but treat it as if it were public anyway.
