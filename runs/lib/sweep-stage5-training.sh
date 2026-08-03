#!/usr/bin/env bash
# Stage 5 sweep driver — PyTorch DDP ResNet-50 training fed by WekaFS storage.
#
# 5 cells per locked Stage-5-Training.md decisions (2026-05-16):
#   5.A.1  kvikIO+GDS+raw-TIFF + DDP N=1 (GPU 2, NUMA-0)
#   5.A.2  kvikIO+GDS+raw-TIFF + DDP N=2 (GPU 2,3, both NUMA-0)
#   5.A.4  kvikIO+GDS+raw-TIFF + DDP N=4 (GPU 2,3,6,7, NUMA-0 + NUMA-2)
#   5.A.8  kvikIO+GDS+raw-TIFF + DDP N=8 (all 8 GPUs, full NUMA spread)
#   5.B.4  cuCIM CPU batched   + DDP N=4 (GPU 2,3,6,7) -- the production-current comparator
#
# Each cell: 5 min ramp + 20 min steady = ~30 min wallclock per cell.
# Total sweep: ~3-4 hr wallclock.
#
# Required env (set below): LD_PRELOAD libcufile 1.17, CUFILE_ENV_PATH_JSON
# corrected, CONDA_PREFIX, OMP_NUM_THREADS=8, MKL_NUM_THREADS=8, NCCL_DEBUG=WARN.
#
# Usage:
#   ./sweep-stage5-training.sh smoke      # single-GPU short cell (validate trainer end-to-end, ~3-5 min)
#   ./sweep-stage5-training.sh all        # run all 5 cells sequentially (~3-4 hr)
#   ./sweep-stage5-training.sh 5.A.1      # run a specific cell only
set -uo pipefail

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604
PY="$CONDA_ENV/bin/python"
TRAINER="$REPO/runs/lib/train-resnet50-stage5.py"
RECORD="$REPO/runs/lib/record-run.sh"

LIBCUFILE_117=/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0
CUFILE_JSON=${CUFILE_ENV_PATH_JSON}

# Sanity checks
[ -f "$LIBCUFILE_117" ] || { echo "missing libcufile 1.17 at $LIBCUFILE_117" >&2; exit 1; }
[ -f "$CUFILE_JSON" ]   || { echo "missing corrected cufile.json at $CUFILE_JSON" >&2; exit 1; }
[ -f "$TRAINER" ]       || { echo "missing trainer at $TRAINER" >&2; exit 1; }
[ -x "$RECORD" ]        || { echo "missing or non-exec record-run.sh at $RECORD" >&2; exit 1; }
[ -x "$PY" ]            || { echo "missing python at $PY" >&2; exit 1; }

BRCA_RAWTIFF=${FS_MOUNT}/data/tcga-brca-rawtiff
BRCA_SVS=${FS_MOUNT}/data/tcga-brca
BRCA_MANIFEST=$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv
BRCA_COORDS=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches

export CONDA_PREFIX="$CONDA_ENV"
export CUFILE_ENV_PATH_JSON="$CUFILE_JSON"
# NOTE: LD_PRELOAD is set PER-CELL in run_cell() — only kvikIO cells need
# libcufile-1.17. For cuCIM CPU batched cells, preloading libcufile-1.17 against
# cuCIM 26.04 (built with bundled libcufile 1.14.1) causes an ABI-mismatch
# segfault inside slide.read_region() — the first 5.B sweep cell hit this and
# was diagnosed 2026-05-19. cuCIM CPU decode doesn't use GDS at all, so the
# preload is unnecessary for that backend.
# Avoid PyTorch thread oversubscription on the 256-core box. Stage-5-Training.md Q6.
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
# NCCL: WARN for normal runs; if scaling drops unexpectedly, bump to INFO.
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
# Avoid noisy NCCL warnings when only one node is in use (single-host DDP).
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-^lo,docker}"

# The trainer launches itself via torch.multiprocessing.spawn — NO torchrun.
# WHY: torchrun's c10d rendezvous (both dynamic and --standalone) tries to bind
# a TCP store to socket.gethostname()=a100 → /etc/hosts → a100.cluster.local
# → 192.168.6.102. That IP is NOT bound to any interface on this host (the IB
# data path uses 10.0.4.102 / 10.0.5.102), so the TCP store fails with
# "No route to host". Verified 2026-05-17 on Stage 5 pre-flight smoke. Bypass:
# trainer takes --world-size and spawns workers itself with MASTER_ADDR=127.0.0.1.

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

  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s${substage}-${cell_name}"

  local note="Stage ${substage} cell: backend=${backend} N_gpus=${n_gpus} gpus=${gpu_csv} batch_per_rank=256 effective_batch=$((256 * n_gpus)) ramp=${ramp}s steady=${runtime}s. WHY this cell: locked Q1-Q6 (Stage-5-Training.md decision log 2026-05-16). ResNet-50 (storage-stressed; small fast model = more demand on storage). DDP via torchrun --nproc_per_node=${n_gpus}. NUMA-aware GPU assignment per project_a100_state.md (GPU 2,3 NUMA-0 IB-adjacent; GPU 6,7 NUMA-2). LD_PRELOAD=libcufile-1.17, CUFILE_ENV_PATH_JSON=corrected. Per-training-step CSV at training-steps.csv is PRIMARY headline source; nvidia-smi promoted to PRIMARY (was diagnostic pre-Stage-4). Trainer: $TRAINER."

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
    trainer_args+=( --rawtiff-dir "$BRCA_RAWTIFF" --n-buffer 256 --num-threads 16 )
  elif [ "$backend" = "cucim_batched_cpu" ]; then
    trainer_args+=( --svs-dir "$BRCA_SVS" )
  fi

  # LD_PRELOAD libcufile-1.17 ONLY for kvikIO backend (needed for GDS path).
  # cuCIM CPU batched backend segfaults with the preload due to ABI mismatch
  # vs its bundled libcufile 1.14.1 — see comment near top of this script.
  local preload=""
  if [ "$backend" = "kvikio" ]; then
    preload="$LIBCUFILE_117"
  fi

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name (N_gpus=$n_gpus gpus=$gpu_csv backend=$backend mp.spawn LD_PRELOAD=${preload:-<unset>})"
  echo "  trainer cmd: $PY $TRAINER ${trainer_args[*]}"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$preload" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage "$substage" \
    --note "$note" \
    -- "$PY" "$TRAINER" "${trainer_args[@]}"

  local rc=$?
  echo "[$cell_name] record-run.sh exited rc=$rc"
  return "$rc"
}

# Predefined cells. All use BRCA-only per locked Q5; ramp=300 runtime=1200 per roadmap.
cell_5A1()   { run_cell 5.A "train-resnet50-kvikio-brca-N1" 1 "2"         kvikio            300 1200; }
cell_5A2()   { run_cell 5.A "train-resnet50-kvikio-brca-N2" 2 "2,3"       kvikio            300 1200; }
cell_5A4()   { run_cell 5.A "train-resnet50-kvikio-brca-N4" 4 "2,3,6,7"   kvikio            300 1200; }
cell_5A8()   { run_cell 5.A "train-resnet50-kvikio-brca-N8" 8 "0,1,2,3,4,5,6,7" kvikio      300 1200; }
cell_5B4()   { run_cell 5.B "train-resnet50-cucim-brca-N4" 4 "2,3,6,7"    cucim_batched_cpu 300 1200; }

# Added 2026-05-24 — Stage 5 cuCIM scaling fill-in (task #14).
# Original P3-compressed scope (locked 2026-05-16, Q2) had only one cuCIM cell
# at N=4 as a comparator. Tier 2 (Stage 6.A) finding 2026-05-23 revealed the
# kvikIO/cuCIM ratio reverses at production scale + N=8. The cuCIM scaling
# curve at the Stage 5 50-slide subset is now more interesting — does the
# crossover hint at Stage 5 scale too, or is it specific to full-BRCA scale?
# These 3 cells extend Stage 5.B into a {1, 2, 4, 8} sweep symmetric with 5.A.
cell_5B1()   { run_cell 5.B "train-resnet50-cucim-brca-N1" 1 "2"               cucim_batched_cpu 300 1200; }
cell_5B2()   { run_cell 5.B "train-resnet50-cucim-brca-N2" 2 "2,3"             cucim_batched_cpu 300 1200; }
cell_5B8()   { run_cell 5.B "train-resnet50-cucim-brca-N8" 8 "0,1,2,3,4,5,6,7" cucim_batched_cpu 300 1200; }

# Pre-flight smoke: single-GPU, 30s ramp + 60s steady, kvikIO backend.
# Validates the trainer end-to-end before committing to 3-4 hr of execution.
smoke()       { run_cell 5.A "smoke-train-resnet50-kvikio-N1" 1 "2"       kvikio             30   60; }

cucim_scaling_fill() {
  # Stage 5 cuCIM scaling fill-in. Runs 5.B.{1,2,8}. ~1.25 hr total.
  echo "=== Stage 5 cuCIM scaling fill-in (5.B.1, 5.B.2, 5.B.8) ==="
  cell_5B1 || echo "cell 5.B.1 failed (continuing)"
  cell_5B2 || echo "cell 5.B.2 failed (continuing)"
  cell_5B8 || echo "cell 5.B.8 failed (continuing)"
  echo "=== Stage 5 cuCIM scaling fill-in done. Re-aggregate with: $REPO/runs/lib/aggregate-stage5-training.py ==="
}

all() {
  echo "=== Stage 5 sweep — running all 5 cells (~3-4 hr) ==="
  cell_5A1 || echo "cell 5.A.1 failed (continuing)"
  cell_5A2 || echo "cell 5.A.2 failed (continuing)"
  cell_5A4 || echo "cell 5.A.4 failed (continuing)"
  cell_5A8 || echo "cell 5.A.8 failed (continuing)"
  cell_5B4 || echo "cell 5.B.4 failed (continuing)"
  echo "=== Stage 5 sweep done. Aggregate with: $REPO/runs/lib/aggregate-stage5-training.py ==="
}

case "${1:-}" in
  smoke)             smoke ;;
  5.A.1|5A1)         cell_5A1 ;;
  5.A.2|5A2)         cell_5A2 ;;
  5.A.4|5A4)         cell_5A4 ;;
  5.A.8|5A8)         cell_5A8 ;;
  5.B.1|5B1)         cell_5B1 ;;
  5.B.2|5B2)         cell_5B2 ;;
  5.B.4|5B4)         cell_5B4 ;;
  5.B.8|5B8)         cell_5B8 ;;
  cucim_scaling_fill) cucim_scaling_fill ;;
  all)               all ;;
  *) echo "usage: $0 {smoke|all|cucim_scaling_fill|5.A.{1,2,4,8}|5.B.{1,2,4,8}}" >&2; exit 2 ;;
esac
