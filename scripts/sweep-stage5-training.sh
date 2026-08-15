#!/usr/bin/env bash
# Stage 5 sweep driver — PyTorch DDP ResNet-50 training fed by the filesystem
# under test. Runs identically on both legs; the mount comes from $FS_MOUNT.
#
# 6 cells — both blocks are FULL sweeps over the GPU-count range, per
# Stage-5-Training.md ("5.B is a full sweep, not a single comparator cell"):
#   5.A.{1,2,4}  kvikIO/cuFile + raw-TIFF + DDP    — the GPU-direct data path
#   5.B.{1,2,4}  cuCIM CPU batched + DDP           — the production-current path
#
# GPU-count range is N ∈ {1, 2, 4}, matching the 4-GPU instance (STAGES.md D10).
# ⏳ D-8: the GPU indices below are plain 0-based. The NUMA-aware GPU↔NIC ordering
# must be re-derived on the real instance and substituted here — the *range* is
# right, the *pinning order* is not yet.
#
# Each cell: 5 min ramp + 20 min steady = ~30 min wallclock per cell.
#
# Required env (set below): CONDA_PREFIX, CUFILE_ENV_PATH_JSON, OMP_NUM_THREADS=8,
# MKL_NUM_THREADS=8, NCCL_DEBUG=WARN, and LD_PRELOAD of the system libcufile on
# kvikIO cells ONLY (ABI clash segfaults cuCIM) — versions re-derived per instance.
#
# Usage:
#   ./sweep-stage5-training.sh smoke      # single-GPU short cell (validate trainer end-to-end, ~3-5 min)
#   ./sweep-stage5-training.sh all        # run all 6 cells sequentially
#   ./sweep-stage5-training.sh 5.A.1      # run a specific cell only
#   CUFILE_COMPAT_MODE=on ./sweep-stage5-training.sh 5.A.4   # mode-controlled paired cell
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
TRAINER="$REPO/scripts/train-resnet50-stage5.py"
RECORD="$REPO/scripts/record-run.sh"

# The SYSTEM libcufile, matched to the installed kernel nvidia-fs module. Read from
# the environment (docs/NAMING-AND-VARIABLES.md Table 1) — never hardcoded:
# the conda env bundles an older copy, the right path is instance-specific, and a
# path pointing nowhere makes LD_PRELOAD a silent no-op, so the kvikIO cells would
# quietly run on the WRONG libcufile and still report numbers. ⏳ D-10: locate it on
# the real instance and export LIBCUFILE_PRELOAD before running any kvikIO sweep.
: "${LIBCUFILE_PRELOAD:?LIBCUFILE_PRELOAD is unset -- locate the system libcufile matched to the loaded nvidia-fs module and export it (see docs/NAMING-AND-VARIABLES.md Table 1)}"
LIBCUFILE_SYSTEM="$LIBCUFILE_PRELOAD"
[ -f "$LIBCUFILE_SYSTEM" ] || { echo "LIBCUFILE_PRELOAD points at a nonexistent file: $LIBCUFILE_SYSTEM" >&2; exit 1; }
CUFILE_JSON=${CUFILE_ENV_PATH_JSON}

# Sanity checks
[ -f "$CUFILE_JSON" ]   || { echo "missing corrected cufile.json at $CUFILE_JSON" >&2; exit 1; }
[ -f "$TRAINER" ]       || { echo "missing trainer at $TRAINER" >&2; exit 1; }
[ -x "$RECORD" ]        || { echo "missing or non-exec record-run.sh at $RECORD" >&2; exit 1; }
[ -x "$PY" ]            || { echo "missing python at $PY" >&2; exit 1; }

# cuFile mode for the kvikIO cells. 'off' (GDS) is what the 5.A grid runs in, so the
# default leaves every existing cell unchanged; the mode-controlled paired cell
# (docs/STAGES.md, Stage-5-Training.md § 5.A) is requested by exporting this for that
# one invocation. THIS repo's variable, deliberately not kvikIO's own env var — the
# value is passed to the trainer as --compat-mode and set through kvikio.defaults, and
# a second channel setting the same knob would make the mode a cell ran in ambiguous.
# Validated here rather than only in the trainer's argparse: run_cell builds the cell's
# --note before the trainer starts, so an unrecognised value would otherwise reach
# record-run.sh as a note naming a mode that nothing ever ran in.
CUFILE_COMPAT_MODE="${CUFILE_COMPAT_MODE:-off}"
case "$CUFILE_COMPAT_MODE" in
  off|on|auto) ;;
  *) echo "CUFILE_COMPAT_MODE must be off|on|auto, got '$CUFILE_COMPAT_MODE'" >&2; exit 2 ;;
esac

BRCA_RAWTIFF=${FS_MOUNT}/data/tcga-brca-rawtiff
BRCA_SVS=${FS_MOUNT}/data/tcga-brca
BRCA_MANIFEST=$REPO/scripts/manifests/tcga-brca-stage4a-subset.tsv
BRCA_COORDS=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches

export CONDA_PREFIX="$CONDA_ENV"
export CUFILE_ENV_PATH_JSON="$CUFILE_JSON"
# NOTE: LD_PRELOAD is set PER-CELL in run_cell() — only kvikIO cells need the
# system libcufile. Preloading it for a cuCIM CPU cell causes an ABI-mismatch
# segfault inside slide.read_region(), because cuCIM links its own bundled
# libcufile internally even for CPU reads. cuCIM CPU decode does not use GDS at
# all, so the preload is unnecessary there. See the
# `docs/RUNBOOK.md` (mixed-backend sweeps): the versions are
# era-specific, the pattern is durable.
# Cap PyTorch's thread pools so N ranks do not oversubscribe the host's cores
# (Stage-5-Training.md Q6). ⏳ D-8: re-derive this against the real vCPU count and
# the per-filesystem application-available core count (D15) — 8 is a placeholder.
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
# NCCL: WARN for normal runs; if scaling drops unexpectedly, bump to INFO.
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
# Avoid noisy NCCL warnings when only one node is in use (single-host DDP).
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-^lo,docker}"

# The trainer launches itself via torch.multiprocessing.spawn — NO torchrun.
# WHY: torchrun's c10d rendezvous (both dynamic and --standalone) binds its TCP
# store to the address that socket.gethostname() resolves to. On a host where that
# name resolves to an address not bound to any local interface, the store fails
# with "No route to host" — a class of failure that depends on the machine's
# /etc/hosts and interface layout, so it must be assumed possible on any new
# instance rather than re-diagnosed. Bypass: the trainer takes --world-size and
# spawns its own workers with an explicit MASTER_ADDR=127.0.0.1.

# Run a single Stage 5 cell.
#   args: stage_substage (e.g. 5.A) cell_name N_gpus gpu_csv backend ramp runtime
run_cell() {
  local substage="$1"; shift
  local cell_name="$1"; shift
  local n_gpus="$1"; shift
  local gpu_csv="$1"; shift
  local backend="$1"; shift
  local ramp="$1"; shift
  local runtime="$1"; shift

  # A non-default cuFile mode becomes part of the cell NAME, not only the note:
  # the mode-controlled paired cell (docs/STAGES.md) would otherwise share its
  # twin's name, and the aggregators group configs by name — the pair would
  # silently collapse into one config.
  if [ "$backend" = "kvikio" ] && [ "$CUFILE_COMPAT_MODE" != "off" ]; then
    cell_name="${cell_name}-compat${CUFILE_COMPAT_MODE}"
  fi

  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s${substage}-${cell_name}"

  # Determined BEFORE the note is built, so the note records the value actually
  # used rather than an empty placeholder. Set only on kvikIO cells: cuCIM links
  # libcufile internally and segfaults on an ABI mismatch (cross-cutting pattern #3).
  # Same for the cuFile mode: cuCIM CPU reads never touch cuFile, so on a 5.B cell it
  # is recorded as <n/a> rather than as a value the cell did not actually use.
  local preload=""
  local compat_mode=""
  if [ "$backend" = "kvikio" ]; then
    preload="$LIBCUFILE_SYSTEM"
    compat_mode="$CUFILE_COMPAT_MODE"
  fi

  local note="Stage ${substage} cell on fs=${LEG}: backend=${backend} N_gpus=${n_gpus} gpus=${gpu_csv} batch_per_rank=256 effective_batch=$((256 * n_gpus)) ramp=${ramp}s steady=${runtime}s cufile_compat_mode=${compat_mode:-<n/a>} (REQUESTED, not proven — the per-cell cuFile path accounting settles which path ran). WHY this cell: see Stage-5-Training.md § 5.A/5.B — ResNet-50 is the storage-stressing choice (small fast model = more demand per unit of compute). DDP self-launched via mp.spawn with an explicit loopback master. GPU set=${gpu_csv} (⏳ D-8: NUMA-aware ordering to be re-derived on this instance). LD_PRELOAD=${preload:-<unset>}, CUFILE_ENV_PATH_JSON=${CUFILE_ENV_PATH_JSON}. Per-training-step CSV at training-steps.csv is the PRIMARY headline source; nvidia-smi is also PRIMARY from Stage 4 onward. Trainer: $TRAINER."

  local trainer_args=(
    --backend "$backend"
    --world-size "$n_gpus"
    --coords-dir "$BRCA_COORDS"
    --manifest "$BRCA_MANIFEST"
    --batch-size 256
    --ramp "$ramp" --runtime "$runtime"
    --training-steps-csv "$run_dir/training-steps.csv"
    --summary-json "$run_dir/training-summary.json"
    --lru-size 64
    --seed 42
  )
  if [ "$backend" = "kvikio" ]; then
    trainer_args+=( --rawtiff-dir "$BRCA_RAWTIFF" --n-buffer 256 --num-threads 16 --compat-mode "$compat_mode" )
  elif [ "$backend" = "cucim_batched_cpu" ]; then
    trainer_args+=( --svs-dir "$BRCA_SVS" )
  fi

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name (N_gpus=$n_gpus gpus=$gpu_csv backend=$backend mp.spawn LD_PRELOAD=${preload:-<unset>})"
  echo "  trainer cmd: $PY $TRAINER ${trainer_args[*]}"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$preload" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage "$substage" \
    --note "$note" \
    -- "$PY" "$TRAINER" "${trainer_args[@]}"

  local rc=$?
  echo "[$cell_name] record-run.sh exited rc=$rc"
  return "$rc"
}

# Predefined cells. BRCA-only (Stage-5-Training.md § single-dataset scope);
# ramp=300 runtime=1200 per the roadmap. Both blocks sweep N ∈ {1, 2, 4} — the
# instance has 4 GPUs (STAGES.md D10), and the scaling *shape* is the signal.
# ⏳ D-8: the GPU index lists are plain 0-based placeholders; substitute the
# NUMA/NIC-aware ordering once the topology map is derived on the real instance.
cell_5A1()   { run_cell 5.A "train-resnet50-kvikio-brca-N1" 1 "0"       kvikio            300 1200; }
cell_5A2()   { run_cell 5.A "train-resnet50-kvikio-brca-N2" 2 "0,1"     kvikio            300 1200; }
cell_5A4()   { run_cell 5.A "train-resnet50-kvikio-brca-N4" 4 "0,1,2,3" kvikio            300 1200; }
cell_5B1()   { run_cell 5.B "train-resnet50-cucim-brca-N1" 1 "0"        cucim_batched_cpu 300 1200; }
cell_5B2()   { run_cell 5.B "train-resnet50-cucim-brca-N2" 2 "0,1"      cucim_batched_cpu 300 1200; }
cell_5B4()   { run_cell 5.B "train-resnet50-cucim-brca-N4" 4 "0,1,2,3"  cucim_batched_cpu 300 1200; }

# Pre-flight smoke: single-GPU, 30s ramp + 60s steady, kvikIO backend.
# Validates the trainer end-to-end before committing hours of execution.
smoke()       { run_cell 5.A "smoke-train-resnet50-kvikio-N1" 1 "0"     kvikio             30   60; }

all() {
  # A failed cell ABORTS the sweep. It must not be swallowed: run-leg.sh treats a
  # zero exit as "step complete", so continuing past a failure would mark Stage 5
  # done with cells silently missing — a leg with a hole in it that looks complete.
  echo "=== Stage 5 sweep — all 6 cells (5.A.{1,2,4} + 5.B.{1,2,4}) ==="
  cell_5A1 || { echo "cell 5.A.1 FAILED — aborting the Stage 5 sweep" >&2; return 1; }
  cell_5A2 || { echo "cell 5.A.2 FAILED — aborting the Stage 5 sweep" >&2; return 1; }
  cell_5A4 || { echo "cell 5.A.4 FAILED — aborting the Stage 5 sweep" >&2; return 1; }
  cell_5B1 || { echo "cell 5.B.1 FAILED — aborting the Stage 5 sweep" >&2; return 1; }
  cell_5B2 || { echo "cell 5.B.2 FAILED — aborting the Stage 5 sweep" >&2; return 1; }
  cell_5B4 || { echo "cell 5.B.4 FAILED — aborting the Stage 5 sweep" >&2; return 1; }
  echo "=== Stage 5 sweep done. Aggregate with: $REPO/scripts/aggregate-stage5-training.py ==="
}

case "${1:-}" in
  smoke)             smoke ;;
  5.A.1|5A1)         cell_5A1 ;;
  5.A.2|5A2)         cell_5A2 ;;
  5.A.4|5A4)         cell_5A4 ;;
  5.B.1|5B1)         cell_5B1 ;;
  5.B.2|5B2)         cell_5B2 ;;
  5.B.4|5B4)         cell_5B4 ;;
  all)               all ;;
  *) echo "usage: $0 {smoke|all|5.A.{1,2,4}|5.B.{1,2,4}}" >&2; exit 2 ;;
esac
