# Filesystem map — where everything lives

> The single-page answer to "where is X?" — the repo, both filesystem mounts, the S3 durable store, local
> scratch, datasets, stage outputs, tools, and memory.
> **Paths under the mounts, S3, and local scratch are the layout the scripts expect.** Confirm and correct
> them against the real environment during setup, and update this file whenever a load-bearing path changes.

For *what* each stage is see `STAGES.md`; for what each script does `SCRIPT-TRACKER.md`; for how to run and
record a cell `RUNBOOK.md`; for every name and its recommended value `NAMING-AND-VARIABLES.md`; for **what we
measure and why** `../PROJECT-THESIS.md`; for the rules `../CLAUDE.md`.

---

## The mount convention — the load-bearing convention in this project

| | |
|---|---|
| **WEKA** | `/mnt/weka` |
| **Lustre (FSx)** | `/mnt/lustre` |
| **What scripts use** | **`$FS_MOUNT`**, resolved from `$LEG` (`weka` \| `lustre`) in `env.sh` |

**Scripts never hardcode a mount path.** The filesystem is a *dimension, not a fork in the code*
(`../PROJECT-THESIS.md` §8, **D11**) — so every path in this document that a benchmark touches is written
relative to `$FS_MOUNT`. A hardcoded `/mnt/weka` is a bug: it silently makes a Lustre cell measure WEKA, and
the number still looks correct.

Both legs use the **identical directory layout beneath their mount**, so the only difference between a WEKA
run and a Lustre run is which mount `$FS_MOUNT` points at.

---

## Repo layout (in git)

```
<repo>/                        # $REPO_DIR — recommended value in NAMING-AND-VARIABLES.md
├── PROJECT-THESIS.md          # SOURCE OF TRUTH: the question, the held-constant contract, both
│                              #   asymmetries, measurement, recording, sequencing, scope, framing
├── CLAUDE.md                  # how we work: the rules, docs cadence, durability, memory hygiene
├── README.md                  # repo entry point
├── env.example.sh             # → env.sh (gitignored — real values); carries a --check validator
├── backup.sh                  # the single durability entry point: memories → mirror, then S3
├── .gitignore                 # excludes datasets, heavy raw telemetry, secrets, caches
├── .claude/settings.json      # permission rules (committed; settings.local.json is per-machine)
│
├── claude-memory-mirror/      # git-tracked copy of the Claude memories (disaster recovery)
│   ├── MEMORY.md              #   the index
│   └── *.md                   #   one file per memory
│
├── docs/                      # what we decided
│   ├── STAGES.md              #   stage map, per-leg plan, cross-stage decision register
│   ├── RUNBOOK.md             #   how to run and record a cell; both canaries; recovery
│   ├── RESULTS.md             #   findings and their story
│   ├── SCRIPT-TRACKER.md      #   per-script reference for scripts/, plus the deferred-work table
│   ├── FILESYSTEM-MAP.md      #   THIS FILE
│   ├── NAMING-AND-VARIABLES.md#   every path/name/variable, with its recommended value
│   ├── Stage-{1..7}-*.md      #   per-stage roadmaps (the audit trail)
│   └── cloud-setup/           #   human-facing procedure, one file per lifecycle event
│       ├── SPINUP-CHECKLIST.md#     the reasoning behind the provisioning choices
│       └── TEARDOWN-AND-REBUILD.md# THE ONE CHECKLIST: teardown · rebuild · leg switch
│
├── prompts/                   # handoff-skeleton.md — THE HANDOFF TEMPLATE: sessions hand off inline
│                              #   from it (same instance, the normal mode); rebuilds may hand off via a
│                              #   durable TEMP/ file (optional — memory + repo are the designed continuity)
│
├── TEMP/                       # HUMAN-TRANSFER CHANNEL between machines via git (tmux blocks copy-paste):
│                              #   proposed terraform for the laptop, carried snippets. Transient; never
│                              #   authoritative; no script reads it (rules in its README.md)
│
├── scripts/                   # what we run with — the script library, the cuFile config template
│   │                          #   and GDS-TUNING-CHECKLIST.md, plus:
│   ├── manifests/             #   dataset manifests
│   └── env-specs/             #   conda env specs for rebuilding the Python stack
│
└── runs/                      # what we got — ONE tree, filesystem as a dimension
    ├── INDEX.md               #   one line per run — AUTO-GENERATED, never hand-edit
    ├── env-contract-leg-<leg>.json  # the environment contract; Leg B verifies Leg A's
    ├── .leg-state/            #   per-leg resume markers — tracked in git deliberately, because
    │                          #   they are what stops a rebuilt leg redoing completed steps
    ├── sweep-logs/            #   tee'd driver output (gitignored)
    └── <UTC>-<fs>-s<stage>-<name>/   # one dir per run
```

**One `runs/` tree, not one per filesystem** (**D11**) — the deliverable *is* the cross-filesystem delta, so
separate trees would force every comparison to be assembled by hand. Cross-leg drift is caught by the
environment contract instead.

---

## S3 — the durable store (the only thing that survives a teardown besides git)

Instance-local NVMe and **both filesystem mounts are ephemeral.** They die with the instance and the
cluster, and each leg's instance can be rebuilt at any time. Claude's conversation context does not
survive either.

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
├── runs/<leg>/sweep-logs/              # that leg's tee'd driver logs
├── repo/                               # reflection of the memory mirror + the manifests; git stays
│                                       #   authoritative for both
└── env-contracts/                      # one per leg, the leg carried in the filename
```

**Two sync semantics, deliberately different:** mirror-with-delete for the small text git backs
independently, so an exact reflection is safe; **add-and-update, never delete** for telemetry, datasets and
the environment contracts. We will want to reclaim local disk by cleaning old raw telemetry, and a
delete-sync would then destroy the only remaining copy — and a sync run from a checkout that happens not to
hold the other leg's contract would delete the one artifact whose loss makes the whole comparison
unverifiable. `backup.sh` is the single entry point, and the sync is **verified, not assumed.**

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
| Stage 6.B synthetic corpora | `$FS_MOUNT/features-6.B-synthetic/…` | Sized past **both** filesystems' caches so one identical corpus definition serves both legs (**D13**; `Stage-6-Feature-Extraction.md`) |
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
| `runs-raw-overflow/` | **Where completed runs' `raw/` payloads live** — relocated after each step's verified S3 sync, symlinked back from each run dir (`<run>-raw`), because the 48 GB root volume cannot hold a leg's accumulated telemetry (tracker D-35). S3 stays authoritative; the symlinks keep parsers and re-syncs working unchanged |
| `hf-cache/` | The HuggingFace model cache, symlinked from `~/.cache/huggingface` — moved off the root volume for the same reason. A rebuild that recreates `~/.cache/huggingface` must re-point it |

**It dies with the instance**, including between legs. The RAID is built by the instance bootstrap on every
build; **1.4** records the smoke `fio` that proves it out-runs the filesystem write ceiling (or 1.5 measures
the source, not the filesystem).

---

## The GPU-direct / cuFile environment

The kvikIO path needs three things right, and **all three are environment-specific — re-derive them, never
copy values from another machine:**

| Knob | What it is | Why |
|---|---|---|
| conda env | The RAPIDS/cuCIM/PyTorch environment (its own interpreter; `CONDA_PREFIX` exported) | Use the **conda** build, not pip — pip cuCIM wheels have been observed to crash on a libstdc++ ABI mismatch inside `read_region()` |
| `LD_PRELOAD` | The **system** `libcufile`, matched to the installed kernel `nvidia-fs` | The conda env bundles an older copy; the system one matches the kernel module |
| cuFile config (`CUFILE_ENV_PATH_JSON`) | Per-process cuFile JSON | A compat-mode config on both legs — per **D8** neither leg is expected to run true GDS at this client class, so compat is the end state (a contradicting per-cell path split would reopen `D-10`'s GDS wiring) |

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
| conda environments | `/data/local-nvme/conda-envs/` | Rebuilt from `../scripts/env-specs/` on each instance |
| `aws` CLI | system | Dataset staging into S3 (once, pre-leg, via `../scripts/prefetch-datasets-to-s3.sh` — the GDC data API over HTTPS) and 1.7 hydration |
| `fpart` / `fpsync` | system | 1.5 bulk copy, 1.6 mixed, 6.C ingest workload. **One package:** `fpsync` ships inside `fpart` |
| `fio` | system | 1.0 synthetic ceilings, viewer patterns in 1.6 / 6.C / 7.5 |
| Lustre client tools (`lctl`, `lfs`) | system | Lustre-leg recording + stripe layout inspection |
| WEKA client tools | system | WEKA-leg recording |
| GDS tools (`gdscheck`, `gdsio`) | under the CUDA install | Path verification; typically **not** on `$PATH` |
| HuggingFace cache | `~/.cache/huggingface/hub/` | Virchow2 / GigaPath / UNI2-h weights (UNI2-h internal-only) |

---

## Memory (Claude's persistent context — NOT in git; mirrored into it)

Live: `~/.claude/projects/<slug>/memory/`, where `<slug>` is the repo path with `/` → `-`. **Derive it, never
type it** — the command below does, so a change to `REPO_DIR` needs no edit anywhere. `MEMORY.md` indexes the
rest.

```bash
SLUG=$(printf '%s' "$PWD" | sed 's#^/#-#; s#/#-#g')   # derived from the repo path
ls ~/.claude/projects/$SLUG/memory/
```

`backup.sh` mirrors the live directory into `claude-memory-mirror/`; `../scripts/restore-memories.sh` runs it
back the other way, verified, on **every** instance build. **Restore before you ever run `backup.sh` on a
fresh build** — the two move memories in opposite directions, and the wrong order points a mirror-with-delete
at an empty source.

**The two live memories:** `cloud-session-open-items` — the running work list of everything to resolve before
the first measured cell and everything to watch during benchmarking; and `uni2h-conditional-use-status` —
UNI2-h is internal-only, so those rows are filtered out of anything that leaves the building. Everything
else that is durable lives in the docs, not in memory.

---

## Frequently-needed paths

| Looking for… | Path |
|---|---|
| What we measure and why | `../PROJECT-THESIS.md` |
| Project rules | `../CLAUDE.md` |
| Stage map, plan, decision register | `STAGES.md` |
| Run + record a cell, canaries, recovery | `RUNBOOK.md` |
| **Close a completed substage (mandatory gate)** | `../scripts/verify-substage-closeout.sh` — `RUNBOOK.md` § Substage closeout |
| Per-script reference | `SCRIPT-TRACKER.md` |
| Findings | `RESULTS.md` |
| Names, paths and variables | `NAMING-AND-VARIABLES.md` · `../env.example.sh` |
| Script library | `../scripts/` |
| Dataset manifests | `../scripts/manifests/` |
| Run history | `../runs/INDEX.md` (auto-generated) |
| **Start here / what do I do next** | **`cloud-setup/TEARDOWN-AND-REBUILD.md`** — the one checklist |
| Provisioning checklist | `cloud-setup/SPINUP-CHECKLIST.md` |
| Leg-B filesystem setup | Automatic — baked `../scripts/wsi-lustre-phase2.sh`; reasoning/register/fallback: `cloud-setup/LUSTRE-PROVISIONING.md` (Leg A's mount is likewise bootstrap-automatic) |
| Leg close-out / teardown | `../scripts/teardown-prep.sh` per `cloud-setup/TEARDOWN-AND-REBUILD.md`; a durable handoff into `../TEMP/` from `../prompts/handoff-skeleton.md` is optional — the preflight warns, never blocks |
| The two mounts | `/mnt/weka` · `/mnt/lustre` — via `$FS_MOUNT` |
| Datasets (per leg) | `$FS_MOUNT/data/{tcga-brca,camelyon16}/` |
| Coords · raw-TIFF | `$FS_MOUNT/tissue-detection/3.0/…` · `$FS_MOUNT/data/<ds>-rawtiff/` |
| Features | `$FS_MOUNT/features/6.A/…` · `$FS_MOUNT/features-6.B-synthetic/…` |
| Durable telemetry + datasets | `s3://<bucket>/runs/…` · `s3://<bucket>/datasets/…` |
| Environment contracts | `../runs/env-contract-leg-<leg>.json` · `s3://<bucket>/env-contracts/` |
| Local scratch | `/data/local-nvme/` |
| Memory | `~/.claude/projects/<slug>/memory/` (mirrored in `claude-memory-mirror/`) |
