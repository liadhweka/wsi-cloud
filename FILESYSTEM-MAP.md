# Filesystem map — where everything lives

> The single-page answer to "where is X?" — the repo, both filesystem mounts, the S3 durable store, local
> scratch, datasets, stage outputs, tools, and memory.
> **Status: build phase.** The repo exists; **the cloud environment does not yet.** Paths under the mounts,
> S3, and local scratch are the *intended* layout the scripts expect — confirm and correct them against the
> real environment during setup, then update this file.

For *what* each stage is see `runs/STAGES.md`; for what each script does `SCRIPT-TRACKER.md`; for how to run
a cell `runs/README.md`; for the rules `CLAUDE.md`.

---

## The mount convention — the load-bearing convention in this project

| | |
|---|---|
| **WEKA** | `/mnt/weka` |
| **Lustre (FSx)** | `/mnt/lustre` |
| **What scripts use** | **`$FS_MOUNT`**, resolved from `$LEG` (`weka` \| `lustre`) in `env.sh` |

**Scripts never hardcode a mount path.** The filesystem is a *dimension* (**D11**), so every path in this
document that a benchmark touches is written relative to `$FS_MOUNT`. A hardcoded `/mnt/weka` in a script is
a bug — it silently makes a Lustre cell measure WEKA.

Both legs use the **identical directory layout beneath their mount**, so the only difference between a
WEKA run and a Lustre run is which mount `$FS_MOUNT` points at.

---

## Repo layout (in git)

```
~/wsi-cloud/
├── CLAUDE.md                  # project rules: 11 Rules, recording philosophy, durability,
│                              #   docs cadence, framing, memory hygiene
├── PROJECT-THESIS.md          # the question, held-constant contract, both asymmetries, scope
├── PRESENTING.md              # per-stage presentation script (methodology until results land)
├── SCRIPT-TRACKER.md          # per-script reference for runs/lib/
├── FILESYSTEM-MAP.md          # THIS FILE
├── README.md                  # repo entry point
├── backup.sh                  # memories → mirror, then S3 sync (delegates to runs/lib/sync-to-s3.sh)
├── .gitignore                 # excludes datasets, heavy raw telemetry, secrets, caches
├── .claude/settings.json      # permission rules (committed)
│
├── claude-memory-mirror/      # git-tracked copy of the Claude memories (disaster recovery)
│   ├── MEMORY.md              #   the index
│   └── *.md                   #   one file per memory
│
├── cloud-setup/               # provisioning + handoff artifacts
│   ├── NEW-CLOUD-SETUP.md     #   the human-facing walkthrough: empty AWS account → running benchmark
│   ├── SPINUP-CHECKLIST.md    #   what to tell the person provisioning the environment
│   ├── TEARDOWN-AND-REBUILD.md#   the do-every-time checklist for both halves
│   ├── NAMING-AND-VARIABLES.md#   every path/name/variable, with its recommended value
│   ├── env.example.sh         #   → env.sh (gitignored); has a --check validator
│   ├── prompt-env-prep-cloud.md  #   Claude prompt 1: system stack + local scratch
│   ├── handoff-cloud.md       #   Claude prompt 2: build + run the leg
│   ├── AUDIT-PROMPT.md        #   the pre-deployment repo audit brief
│   ├── AUDIT-REPORT.md        #   its findings: what was fixed, what is raised, the verdict
│   └── env-specs/             #   conda env specs for rebuilding the Python stack
│
└── runs/                      # benchmark records — ONE tree, filesystem as a dimension
    ├── README.md              #   operational runbook + both canaries
    ├── STAGES.md              #   stage map, per-leg plan, decision log D1–D15
    ├── INDEX.md               #   one line per run — AUTO-GENERATED, never hand-edit
    ├── Stage-{1..7}-*.md      #   per-stage roadmaps (the audit trail)
    ├── lib/                   #   the script library (+ GDS-TUNING-CHECKLIST.md, cuFile template)
    ├── manifests/             #   dataset manifests
    ├── sweep-logs/            #   tee'd driver output (gitignored)
    └── <UTC>-<fs>-s<stage>-<name>/   # one dir per run
```

**One `runs/` tree, not one per filesystem** (**D11**) — the deliverable *is* the cross-filesystem delta, so
separate trees would force every comparison to be assembled by hand. Cross-leg drift is caught by the
environment contract instead.

---

## S3 — the durable store (the only thing that survives a teardown besides git)

Instance-local NVMe and **both filesystem mounts are ephemeral.** They die with the instance and the
cluster, and the instance is rebuilt between legs. Claude's conversation context does not survive either.

**Authority split, non-overlapping** (**D14**):
- **git** is authoritative for all small text — docs, `results.json`, `metadata.json`, `0_README.md`,
  configs, the memory mirror.
- **S3** is authoritative for the heavy write-once data git cannot hold — raw telemetry and datasets.

```
s3://<bucket>/                          # private, same region as everything else
├── datasets/
│   ├── tcga-brca/                      # downloaded once from GDC, reused by BOTH legs
│   └── camelyon16/                     # mirror of the open-data pull
├── runs/<leg>/<run-dir>/raw/           # heavy telemetry — synced during and after each run
└── env-contracts/                      # uploaded by sync-to-s3.sh --mode full
    ├── env-contract-leg-weka.json      # written at end of Leg A (name set by env-contract.py)
    └── env-contract-leg-lustre.json    # Leg B verifies against Leg A's before its first cell
```

**Two sync semantics, deliberately different:** mirror-with-delete for docs and memories (git backs them
independently, so an exact reflection is safe); **add-and-update, never delete** for telemetry and datasets
— we will want to reclaim local disk by cleaning old raw telemetry, and a delete-sync would then destroy the
only remaining copy.

---

## Datasets and stage outputs (NOT in git — on the filesystem under test)

Everything below is **created per leg** on `$FS_MOUNT`, using the identical layout on both.

| What | Path | Notes |
|---|---|---|
| TCGA-BRCA (canonical SVS) | `$FS_MOUNT/data/tcga-brca/` | 40× base; hydrated from S3 by **1.7**, byte-verified. The BRCA source for all stages |
| CAMELYON16 (canonical) | `$FS_MOUNT/data/camelyon16/` | `.tif` under `images/` (native 20×), plus annotations and masks |
| **20× tile coords** | `$FS_MOUNT/tissue-detection/3.0/<ds>/n<N>/patches/` | Per-slide coord HDF5 + mask JPEG. Produced by **3.0**; gates Stages 4–7 |
| **20× raw-TIFF** | `$FS_MOUNT/data/<ds>-rawtiff/` | Single-level uncompressed TIFF whose level-0 **is** the 20× image; kvikIO reads byte ranges directly. Produced by **4.D**. Large (order ~7 TB at full cohort) — a sizing input to **D7** |
| Stage 4.A pre-extracted tiles | `$FS_MOUNT/patches/4.A/<ds>/n<N>/<slide-id>.h5` | Per-slide tile HDF5 (subset); consumed by nothing downstream |
| Stage 2 property sidecars | `$FS_MOUNT/cataloging/2.0/<ds>/n<N>/<slide-id>.json` | Reproducible; cleaned per cell |
| Stage 6.A features | `$FS_MOUNT/features/6.A/<model>/<dataset>/<slide-id>.pt` | model ∈ {virchow2, gigapath, uni2-h}; dataset ∈ {brca50, brca_full, cam16}. Consumed by 6.B.3 and 7.3 |
| Stage 6.B synthetic corpora | `$FS_MOUNT/features-6.B-synthetic/…` | Deliberately sized **past cache** — see the cold-cache problem in the Stage 6 roadmap |
| Stage 7 heatmaps | `$FS_MOUNT/heatmaps/7.x/<cell>/<slide-id>.{tiff,png}` | Render output; cleanable after presentation |
| fio scratch (ephemeral) | `$FS_MOUNT/benchmarks/fio-scratch/` | Cleaned per cell |
| Stage 7 ingest target (transient) | `$FS_MOUNT/runs-stage7-ingest-target/` | 7.5 mixed workload |

> **Regeneration hygiene.** The raw-TIFF converter and the 6.A extractor both **skip existing non-empty
> output without failing loud.** A leftover artifact from a different magnification, converter version, or
> aborted chunked run is therefore **silently reused**. Delete stale output before regenerating, and verify
> chunk cleanup between Tier-2 runs.

---

## Local scratch (ephemeral — nothing that matters lives here)

`/data/local-nvme/` — the instance's local NVMe, RAID-0 + XFS, mounted `noatime,nofail`.

| Subdir | Contents |
|---|---|
| `conda-envs/` | The Python environments (kept off the OS disk) |
| `fpsync-source/` | Locally-staged corpus — the fast source for the 1.5 bulk-copy sweep |
| `staging/` | Download landing zone before pushing to S3 |
| `runs/` | Overflow for in-flight telemetry before its S3 sync |

**It dies with the instance**, including between legs. Provisioned by **1.4** on every instance build, with a
smoke `fio` recorded to prove it out-runs the filesystem write ceiling (or 1.5 measures the source, not the
filesystem).

---

## The GPU-direct / cuFile environment

The kvikIO path needs three things right, and **all three are environment-specific — re-derive them, never
copy values from another machine:**

| Knob | What it is | Why |
|---|---|---|
| conda env | The RAPIDS/cuCIM/PyTorch environment (its own interpreter; `CONDA_PREFIX` exported) | Use the **conda** build, not pip — pip cuCIM wheels have been observed to crash on a libstdc++ ABI mismatch inside `read_region()` |
| `LD_PRELOAD` | The **system** `libcufile`, matched to the installed kernel `nvidia-fs` | The conda env bundles an older copy; the system one matches the kernel module |
| cuFile config (`CUFILE_ENV_PATH_JSON`) | Per-process cuFile JSON | Must list the client's own network addresses and set the transport options the filesystem needs |

> ⚠ **Scope `LD_PRELOAD` per cell.** cuCIM segfaults inside `read_region()` when a newer libcufile is
> preloaded over its bundled one (ABI clash), and it links libcufile internally even for CPU reads. Since
> this project runs kvikIO **and** cuCIM cells on both filesystems, essentially every sweep is mixed. Symptom
> if forgotten: clean init, then a segfault on the first cuCIM read — easily misdiagnosed as a
> multiprocessing bug.

**Reads must be block-aligned** for the GPU-direct path, and **every kvikIO cell records cuFile's own
GPU-direct-vs-bounced byte accounting** — a configuration flag is not proof of which path ran (**D8**).

---

## Tools (NOT in git)

| Tool | Location | Notes |
|---|---|---|
| CLAM | `~/wsi-tools/CLAM/` | Tissue detection (3.0) + tile coords; commit recorded per run |
| conda environments | `/data/local-nvme/conda-envs/` | Rebuilt from `cloud-setup/env-specs/` on each instance |
| `gdc-client`, `aws` CLI | `~/.local/bin/` | Dataset staging into S3 (once, pre-leg) and 1.7 hydration |
| `fpart` / `fpsync` | system | 1.5 bulk copy, 1.6 mixed, 6.C ingest workload. **One package:** `fpsync` ships inside `fpart` |
| `fio` | system | 1.0 synthetic ceilings, viewer patterns in 1.6 / 6.C / 7.5 |
| Lustre client tools (`lctl`, `lfs`) | system | Lustre-leg recording + stripe layout inspection |
| WEKA client tools | system | WEKA-leg recording |
| GDS tools (`gdscheck`, `gdsio`) | under the CUDA install | Path verification; typically **not** on `$PATH` |
| HuggingFace cache | `~/.cache/huggingface/hub/` | Virchow2 / GigaPath / UNI2-h weights (UNI2-h internal-only) |

---

## Memory (Claude's persistent context — NOT in git; mirrored into it)

Live: `~/.claude/projects/<slug>/memory/`, where `<slug>` is the repo path with `/` → `-`
(for the recommended cloud paths: `-home-ubuntu-wsi-cloud`). **Derive it, never type it** — the command
below does. `MEMORY.md` indexes the rest.

`backup.sh` mirrors it into `claude-memory-mirror/` — **derive the slug rather than hardcoding it** (the
script does). To restore on a fresh instance:

```bash
SLUG=$(printf '%s' "$PWD" | sed 's#^/#-#; s#/#-#g')   # derived from the repo path
mkdir -p ~/.claude/projects/$SLUG/memory
rsync -a claude-memory-mirror/ ~/.claude/projects/$SLUG/memory/
```

**Load-bearing memories:** `weka-vs-lustre-cloud-project` (what this is), `cloud-session-open-items` (the
running tracker of everything to resolve, build, or watch), `weka-vs-lustre-cloud-open-decisions` (what is
still assumed, with a reference index), plus the framing, MIL, cuCIM, and UNI2-h memories.

---

## Frequently-needed paths

| Looking for… | Path |
|---|---|
| Project rules | `CLAUDE.md` |
| The question + fairness contract | `PROJECT-THESIS.md` |
| Stage map, plan, decision log | `runs/STAGES.md` |
| Operational runbook + canaries | `runs/README.md` |
| Per-script reference | `SCRIPT-TRACKER.md` |
| Script library | `runs/lib/` |
| Dataset manifests | `runs/manifests/` |
| Run history | `runs/INDEX.md` (auto-generated) |
| Provisioning checklist | `cloud-setup/SPINUP-CHECKLIST.md` |
| The two mounts | `/mnt/weka` · `/mnt/lustre` — via `$FS_MOUNT` |
| Datasets (per leg) | `$FS_MOUNT/data/{tcga-brca,camelyon16}/` |
| Coords · raw-TIFF | `$FS_MOUNT/tissue-detection/3.0/…` · `$FS_MOUNT/data/<ds>-rawtiff/` |
| Features | `$FS_MOUNT/features/6.A/…` · `$FS_MOUNT/features-6.B-synthetic/…` |
| Durable telemetry + datasets | `s3://<bucket>/runs/…` · `s3://<bucket>/datasets/…` |
| Environment contracts | `s3://<bucket>/env-contracts/` |
| Local scratch | `/data/local-nvme/` |
| Memory | `~/.claude/projects/<slug>/memory/` (mirrored in `claude-memory-mirror/`) |
