# Naming & variables — every blank in this project, in one place

**Purpose.** Every path, name, and identifier that varies between environments is enumerated here, with a
recommended value. Nothing is hardcoded in the scripts; they read these from the environment. This doc plus
its companion **`env.example.sh`** are the single source of truth — every other doc and script *references*
these names rather than inventing its own.

**Why this exists.** Before this doc, the same value appeared as `<user>`, `<bucket>`, `<repo>`, `<SLUG>`,
`$FS_MOUNT`, and half a dozen hardcoded literals scattered across 8 docs and 60 scripts. That is the class of
inconsistency that produces a 2am mistake — and in this project one specific mistake (a wrong mount) makes
one leg silently measure the other filesystem while the number still looks correct.

---

## How to use

```bash
cd ~/wsi-cloud
cp cloud-setup/env.example.sh cloud-setup/env.sh   # env.sh is gitignored — it holds real values
$EDITOR cloud-setup/env.sh                          # fill in the DECIDE-NOW values
source cloud-setup/env.sh                           # do this in every shell, or add to ~/.bashrc
./cloud-setup/env.sh --check                        # validates: nothing unset, paths exist, S3 reachable
```

Every script sources nothing implicitly — it reads the environment and **fails loudly if a required variable
is unset.** An unset variable must never silently default, because the defaults are what would be wrong.

---

## Table 1 — DECIDE NOW (choices; set these before provisioning)

| Variable | Recommended | Why this value / what it affects |
|---|---|---|
| `PROJECT_USER` | **`ubuntu`** | The AMI's default user on Ubuntu images — no `adduser` step, no permission surprises. **Do NOT use `root`:** it breaks `/dev/shm` permissions and conda ownership, and it changes the memory slug (see Table 3). |
| `PROJECT_HOME` | **`/home/ubuntu`** | Follows from `PROJECT_USER`. |
| `REPO_DIR` | **`$PROJECT_HOME/wsi-cloud`** | Matches the GitHub repo (`wsi-cloud`). Distinct from the earlier project's `wsi`, so the derived slug (`-home-ubuntu-wsi-cloud`) cannot collide with it — **the directory name is load-bearing for exactly this reason.** |
| `GITHUB_REPO` | **`liadhweka/wsi-cloud`** | SSH remote: `git@github.com:$GITHUB_REPO.git`. |
| `AWS_REGION` | **`us-west-2`** *(subject to g6e capacity)* | Tiebreaker only: the CAMELYON open-data bucket lives there, so that pull is same-region. **Capacity and your standard region outrank this.** Everything — instance, both filesystems, the bucket — must share it. |
| `AWS_AZ` | *(pick one in-region and keep it)* | Cross-AZ traffic adds latency and cost and would contaminate the comparison. |
| `INSTANCE_TYPE` | **`g6e.24xlarge`** *(subject to change)* | 96 vCPU, 768 GiB, 4× L40S, 200 Gbps, EFA-capable. Alternatives: `g6e.48xlarge` (upgrade), `g6e.12xlarge` (floor). See `runs/STAGES.md` **D10**. |
| `S3_BUCKET` | **`weka-wsi-bench-<unique-suffix>`** | ⚠ **S3 bucket names are globally unique across all AWS accounts** — a generic name will likely be taken, so add a suffix. Avoid `-s3` in the name (redundant). |
| `WEKA_MOUNT` | **`/mnt/weka`** | Leg A mount. |
| `LUSTRE_MOUNT` | **`/mnt/lustre`** | Leg B mount. |
| `WEKA_FS_NAME` | **`wsibench`** | The WEKA filesystem name. Kept distinct from the mount path deliberately — they need not match, and assuming they do has caused confusion before. |
| `SCRATCH_DIR` | **`/data/local-nvme`** | Instance-store scratch. **Ephemeral** — dies with the instance, including between legs. |
| `CONDA_ROOT` | **`$SCRATCH_DIR/miniforge`** | Off the OS disk. |
| `CONDA_ENV_MAIN` | **`wsi-cucim-2604`** | Keep this name — `cloud-setup/env-specs/` files are named after it; renaming means editing the specs. |
| `CONDA_ENV_ALT` | **`wsi-cucim`** | Second env, same reasoning. |
| `CLAM_DIR` | **`$PROJECT_HOME/wsi-tools/CLAM`** | The tissue detector used by Stage 3. Cloned during setup; the commit is recorded per run. |
| `CUFILE_CONFIG_DIR` | **`$PROJECT_HOME/cufile-config`** | Where the generated cuFile config lives. |
| `CUFILE_ENV_PATH_JSON` | **`$CUFILE_CONFIG_DIR/cufile.json`** | Generated **per instance** from the template — holds this instance's own addresses (deferred item `D-10`). |
| `HF_HOME` | *(default `~/.cache/huggingface`)* | Model weight cache. |

> **`LIBCUFILE_PRELOAD` is deliberately NOT set globally.** It is located on the instance and applied
> **per cell — on kvikIO cells only**, because cuCIM segfaults when a newer libcufile is preloaded over its
> bundled one. Exporting it globally would break every cuCIM cell in a mixed sweep.

## Table 2 — RECORD WHEN PROVISIONED (outputs; you don't choose these, you capture them)

These go into the **environment contract** (`runs/STAGES.md` **D6**) and are what let Leg B prove it matched
Leg A. **Capture them as you provision** — several are hard to reconstruct later.

| Variable | Where it comes from | Why it's needed |
|---|---|---|
| `AMI_ID` | Instance launch | Leg B rebuilds from this exact AMI. Pin it. |
| `INSTANCE_ID` | Instance launch | Provenance. |
| `CLIENT_HOSTNAME` | `hostname` on the instance | **Load-bearing:** the aggregators filter telemetry to the client's own rows by hostname. Currently hardcoded to a previous host in 19 files (deferred item `D-4`). |
| `WEKA_BACKEND_TYPE` · `WEKA_BACKEND_COUNT` | Your WEKA provisioning | Sizing evidence for the fairness basis (**D7**). |
| `WEKA_CAPACITY_TB` | WEKA provisioning | Same. |
| `WEKA_EC_SCHEME` | WEKA provisioning | **Required** to derive the WEKA cross-source consistency relation (**D12**) — the canary cannot run without it. |
| `WEKA_BACKEND_RAM_TOTAL` | Sum of backend instance RAM | Determines how large the Stage 6.B corpus must be to read genuinely cold (tracker item 5b). |
| `WEKA_CLIENT_CORES` · `WEKA_CLIENT_NICS` | `weka` client config | Client provisioning, and the reserved-core count for **D15** core accounting. |
| `FSX_TIER` · `FSX_CAPACITY_TIB` · `FSX_METADATA_IOPS` | FSx provisioning (Leg B) | The "Lustre at maximum" evidence (**D7**), and FSX's cache size follows from tier × capacity. |
| `FSX_EFA_ENABLED` | FSx provisioning | Required for GDS and to escape the per-client-per-server cap. |
| `LUSTRE_STRIPE_LAYOUT` | `lfs getstripe` after mount | **Required** to derive the Lustre consistency relation (**D12**). |
| `DRIVER_VERSION` · `CUDA_VERSION` · `NVIDIA_FS_VERSION` · `LIBCUFILE_VERSION` · `KERNEL_VERSION` | The instance | Held-constant contract; the cuFile stack must be version-matched. |
| `SCRIPT_COMMIT` | `git rev-parse HEAD` | Both legs must run the same code. |

## Table 3 — DERIVED (computed; never set by hand)

| Variable | How it's derived | Note |
|---|---|---|
| `MEMORY_SLUG` | `REPO_DIR` with `/` → `-` | For the chosen names: `-home-ubuntu-wsi-cloud`. **Discover it, don't type it** — `NEW-CLOUD-SETUP.md` § B8 and `backup.sh` both derive it, so a path change needs no edits. |
| `FS_MOUNT` | `WEKA_MOUNT` or `LUSTRE_MOUNT`, from `--fs` | **The single most important variable in the project.** Every script resolves the mount through it. A hardcoded mount makes one leg measure the other with no failure signal. |
| `LEG` | `weka` \| `lustre` | Run-dir name segment, `metadata.json` field, S3 prefix. |
| `LIBCUFILE_PRELOAD` | Located on the instance | The system `libcufile` matched to the kernel module. **Scoped per cell** — set on kvikIO cells only. |
| `CUFILE_ENV_PATH_JSON` | Generated per instance | Holds this instance's own addresses. |

---

## Table 4 — Doc placeholder → variable

So a reader of any doc knows which variable a `<placeholder>` refers to.

| In the docs | Variable | | In the docs | Variable |
|---|---|---|---|---|
| `<user>` | `PROJECT_USER` | | `<fs>`, `<leg>` | `LEG` |
| `<repo>` | `REPO_DIR` | | `<bucket>` | `S3_BUCKET` |
| `<account>` | (GitHub account in `GITHUB_REPO`) | | `<slug>`, `<SLUG>` | `MEMORY_SLUG` |
| `<stage>` | `--stage` value (see `runs/STAGES.md`) | | `<UTC>`, `<UTC-timestamp>` | generated by `record-run.sh` |
| `<run-dir>`, `<run-name>` | generated by `record-run.sh` | | `<workload>`, `<config>` | free-text run-name segments |
| `<ds>`, `<dataset>` | `tcga-brca` \| `camelyon16` | | `<model>` | `virchow2` \| `gigapath` \| `uni2-h` |
| `<slide-id>`, `<slide_id>` | per-slide identifier from the manifest | | `<backend>` | `openslide` \| `cucim` \| `kvikio` |
| `<cache>` | `cold` \| `warm` | | `<format>` | heatmap output format |
| `<cell>`, `<cell-dir>` | per-cell output dir | | `<rev>`, `<reason>` | forensic-rename suffixes |

*(`<br>` in the grep output is HTML in tables, not a placeholder.)*

---

## Values that must be identical across legs

`INSTANCE_TYPE`, `AWS_REGION`, `AWS_AZ`, `AMI_ID`, `KERNEL_VERSION`, `DRIVER_VERSION`, `CUDA_VERSION`,
`SCRIPT_COMMIT`, dataset bytes, the magnification contract, the model set, the recording harness.

**Everything else is expected to differ** — that's the point of the comparison. The environment contract
records both sets so the distinction is auditable rather than asserted.

## What must NOT go in `env.sh`

No AWS access keys, no Hugging Face tokens, no passwords. Credentials come from the **instance profile** and
`hf auth login`. `env.sh` is gitignored, but treat it as if it were public anyway.
