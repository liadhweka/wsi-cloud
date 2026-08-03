#!/usr/bin/env bash
# Stage 6.A sweep driver — foundation-model feature extraction.
#
# Three tiers per `runs/Stage-6-Feature-Extraction.md`:
#   Tier 1 (scaling): N_GPUs sweep × models × backends on 50-slide cross-stage subset
#       - 4 N_GPUs × 2 models × kvikio = 8 cells
#       - 1 N_GPUs (=4) × 2 models × cucim_batched_cpu (comparator) = 2 cells
#       - Total: 10 cells (UNI2-h adds 5 more if license resolved)
#   Tier 2 (production-scale): full TCGA-BRCA at peak N=4, both backends, all models
#       - 2 models × N=4 × kvikio (via chunked raw-TIFF) = 2 cells
#       - 2 models × N=4 × cucim_batched_cpu (canonical SVS) = 2 cells
#       - Total: 4 cells (UNI2-h adds 2 more if license resolved)
#       - kvikio cells require chunked raw-TIFF conversion — invokes
#         `run-stage6a-tier2-chunked.sh` (pending)
#   Tier 3 (cross-dataset): CAMELYON16 50-slide subset at peak N=4 × kvikio
#       - 2 models × N=4 × kvikio × CAM16 = 2 cells (UNI2-h adds 1)
#
# Per-cell LD_PRELOAD scoping (per cucim_libcufile_preload_abi_clash memory):
#   - kvikio cells: set LD_PRELOAD=libcufile-1.17
#   - cucim cells: leave LD_PRELOAD unset (libcufile-1.17 ABI-clashes with cuCIM 26.04)
#
# NUMA-aware GPU assignment (mirrors Stage 4.C / 5):
#   N=1 → GPU 2 (NUMA-0, IB-adjacent)
#   N=2 → GPU 2,3 (both NUMA-0)
#   N=4 → GPU 2,3,6,7 (NUMA-0 + NUMA-2)
#   N=8 → all 8 GPUs (full NUMA spread)
#
# Usage:
#   ./sweep-stage6a-extract.sh smoke              # single-cell validation
#   ./sweep-stage6a-extract.sh tier1              # 15 cells (Virchow2 + GigaPath + UNI2-h scaling)
#   ./sweep-stage6a-extract.sh tier1_uni2h        # 5 cells (UNI2-h only)
#   ./sweep-stage6a-extract.sh tier1_n248         # 12 cells: N=2/4/8 + cuCIM N=4 × 3 models (resume target)
#   ./sweep-stage6a-extract.sh tier2              # 6 cells (full BRCA at N=4)
#   ./sweep-stage6a-extract.sh tier3              # 3 cells (CAM16 cross-dataset)
#   ./sweep-stage6a-extract.sh all                # tier1 + tier3 (skips tier2)
set -uo pipefail

REPO=/home/liadhermelin/wsi/rerun_new_TRUERESULTS
CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604
PY="$CONDA_ENV/bin/python"
EXTRACTOR="$REPO/runs/lib/extract-features-foundation-stage6.py"
RECORD="$REPO/runs/lib/record-run.sh"

LIBCUFILE_117=/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0
CUFILE_JSON=/home/liadhermelin/wsi-debug/p1-gdsio/cufile-full-rdma.json

# Sanity
[ -f "$LIBCUFILE_117" ] || { echo "missing libcufile 1.17 at $LIBCUFILE_117" >&2; exit 1; }
[ -f "$CUFILE_JSON" ]   || { echo "missing corrected cufile.json at $CUFILE_JSON" >&2; exit 1; }
[ -f "$EXTRACTOR" ]     || { echo "missing extractor at $EXTRACTOR" >&2; exit 1; }
[ -x "$RECORD" ]        || { echo "missing or non-exec record-run.sh at $RECORD" >&2; exit 1; }

# Dataset paths (matches FILESYSTEM-MAP)
BRCA_RAWTIFF_50=/mnt/liad/data/tcga-brca-rawtiff
BRCA_SVS=/mnt/liad/data/tcga-brca
BRCA_COORDS=/mnt/liad/tissue-detection/3.0/tcga-brca/n64/patches
BRCA_50_MANIFEST=$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv
BRCA_FULL_MANIFEST=$REPO/runs/manifests/tcga-brca-full40x-stage4a-format.tsv

CAM_RAWTIFF_50=/mnt/liad/data/camelyon16-rawtiff
CAM_COORDS=/mnt/liad/tissue-detection/3.0/camelyon16/n64/patches
CAM_50_MANIFEST=$REPO/runs/manifests/camelyon16-stage4a-subset.tsv

# Standard env (overridden per cell for LD_PRELOAD)
export CONDA_PREFIX="$CONDA_ENV"
export CUFILE_ENV_PATH_JSON="$CUFILE_JSON"
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-^lo,docker}"

# Map N_GPUs → NUMA-aware GPU CSV
gpu_csv_for_n() {
  case "$1" in
    1) echo "2" ;;
    2) echo "2,3" ;;
    4) echo "2,3,6,7" ;;
    8) echo "0,1,2,3,4,5,6,7" ;;
    *) echo "ERR:bad-n=$1" >&2; return 2 ;;
  esac
}

# Dataset config → (rawtiff_dir, svs_dir, coords_dir, manifest)
dataset_config() {
  case "$1" in
    brca50)
      echo "$BRCA_RAWTIFF_50|$BRCA_SVS|$BRCA_COORDS|$BRCA_50_MANIFEST"
      ;;
    cam16)
      echo "$CAM_RAWTIFF_50|<no-svs-dir>|$CAM_COORDS|$CAM_50_MANIFEST"
      ;;
    brca_full)
      # Note: kvikio backend for full BRCA requires chunked raw-TIFF — handled
      # by a separate orchestrator. The svs path works directly with cucim.
      echo "$BRCA_RAWTIFF_50|$BRCA_SVS|$BRCA_COORDS|$BRCA_FULL_MANIFEST"
      ;;
    *)
      echo "ERR:bad-dataset=$1" >&2; return 2
      ;;
  esac
}

# Run a single 6.A cell.
#   args: model (virchow2|gigapath|uni2-h), backend (kvikio|cucim_batched_cpu),
#         n_gpus, gpu_csv, dataset_tag (brca50|cam16|brca_full)
run_cell() {
  local model="$1"; shift
  local backend="$1"; shift
  local n_gpus="$1"; shift
  local gpu_csv="$1"; shift
  local dataset_tag="$1"; shift

  # Dataset paths
  local cfg
  cfg=$(dataset_config "$dataset_tag") || return 2
  IFS='|' read -r rawtiff svs coords manifest <<< "$cfg"

  # Backend-specific LD_PRELOAD
  local preload=""
  if [ "$backend" = "kvikio" ]; then
    preload="$LIBCUFILE_117"
  fi

  # Cell + run-dir naming
  local cell_name="extract-${model}-${backend//_batched_cpu/}-${dataset_tag}-N${n_gpus}"
  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s6.A-${cell_name}"

  # Per-slide .pt output dir.
  local features_out="/mnt/liad/features/6.A/${model}/${dataset_tag}"
  mkdir -p "$features_out"

  # Cleanup .pt before each cell. The extractor's skip-on-existing logic (a real
  # feature for incremental restart of long runs, e.g. Tier 2 chunked recovery)
  # makes every non-first benchmark-sweep cell do zero work because the prior
  # cell already wrote .pt files. Tier 1 + Tier 3 are throughput-measurement
  # sweeps; their features are NOT the deliverable (Tier 2 full-BRCA features
  # are). Wiping between cells gives each cell a cold start. Found 2026-05-20.
  local n_pt_before
  n_pt_before=$(find "$features_out" -maxdepth 1 -name '*.pt' 2>/dev/null | wc -l)
  if [ "$n_pt_before" -gt 0 ]; then
    echo "[cleanup] wiping $n_pt_before pre-existing .pt files in $features_out"
    find "$features_out" -maxdepth 1 -name '*.pt' -print -delete | wc -l >/dev/null
  fi

  # Prepend PENDING-APPROVAL tag for UNI2-h cells (per 2026-05-19 conditional-use plan:
  # HF access granted, Mahmood Lab publication permission pending; results tagged
  # in run-dir metadata so they're easy to filter from any external materials).
  local approval_tag=""
  if [ "$model" = "uni2-h" ]; then
    approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  fi
  local note="${approval_tag}Stage 6.A cell: model=${model} backend=${backend} N_gpus=${n_gpus} dataset=${dataset_tag} gpus=${gpu_csv} batch=256. WHY: locked Q1-Q9 (Stage-6-Feature-Extraction.md decision log). Foundation-model frozen-eval extraction via mp.spawn DDP; per-rank modulo slide partitioning. AMP autocast FP16 + channels_last + cudnn.benchmark. CLS-token pooling (storage-benchmark universal choice). Per-cell LD_PRELOAD scoping: kvikio cells set libcufile-1.17, cuCIM cells unset (per cucim_libcufile_preload_abi_clash memory)."

  local extractor_args=(
    --backend "$backend"
    --world-size "$n_gpus"
    --model "$model"
    --coords-dir "$coords"
    --manifest "$manifest"
    --output-dir "$features_out"
    --batch-size 256
    --extraction-steps-csv "$run_dir/extraction-steps.csv"
    --per-slide-csv "$run_dir/per-slide.csv"
    --summary-json "$run_dir/extraction-summary.json"
  )
  if [ "$backend" = "kvikio" ]; then
    extractor_args+=( --rawtiff-dir "$rawtiff" --n-buffer 256 --num-threads 16 )
  else
    extractor_args+=( --svs-dir "$svs" )
  fi

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name"
  echo "  N_gpus=$n_gpus gpus=$gpu_csv backend=$backend model=$model dataset=$dataset_tag"
  echo "  LD_PRELOAD=${preload:-<unset>}"
  echo "  features → $features_out"
  echo "  extractor: $PY $EXTRACTOR ${extractor_args[*]}"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$preload" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "$note" \
    -- "$PY" "$EXTRACTOR" "${extractor_args[@]}"

  local rc=$?
  echo "[$cell_name] record-run.sh exited rc=$rc"
  return "$rc"
}

# ---------- Tiers ----------

tier1_scaling() {
  echo "=== Stage 6.A Tier 1: scaling sweep on 50-slide subset (3 models) ==="
  # All three foundation models are first-class as of 2026-05-19. UNI2-h cells
  # are tagged PENDING-APPROVAL in metadata (see run_cell); HF access granted,
  # Mahmood Lab written approval awaited before external publication.
  for model in virchow2 gigapath uni2-h; do
    for n in 1 2 4 8; do
      local gpus
      gpus=$(gpu_csv_for_n "$n")
      run_cell "$model" kvikio "$n" "$gpus" brca50 || echo "  (cell failed; continuing)"
    done
    # cuCIM CPU batched comparator at N=4 only
    run_cell "$model" cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca50 || echo "  (cell failed; continuing)"
  done
}

tier1_uni2h() {
  # Kept as a convenience target for running only the UNI2-h cells (e.g., if you
  # want to re-extract UNI2-h features after a re-run of Virchow2/GigaPath).
  echo "=== Stage 6.A Tier 1: UNI2-h cells only ==="
  for n in 1 2 4 8; do
    run_cell uni2-h kvikio "$n" "$(gpu_csv_for_n "$n")" brca50 || echo "  (cell failed; continuing)"
  done
  run_cell uni2-h cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca50 || echo "  (cell failed; continuing)"
}

tier1_cucim_n4_rerun() {
  # Focused re-run for the 2 cuCIM-N=4 cells that failed pre-2026-05-20 cuCIM
  # concat-ndim fix (Virchow2 + GigaPath; UNI2-h cuCIM cell already ran clean
  # post-fix in the tier1_n248 sweep).
  echo "=== Stage 6.A Tier 1: cuCIM N=4 re-run (Virchow2 + GigaPath) ==="
  for model in virchow2 gigapath; do
    run_cell "$model" cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca50 || echo "  (cell failed; continuing)"
  done
}

tier1_cucim_scaling_fill() {
  # Added 2026-05-24 — Stage 6.A Tier 1 cuCIM scaling fill-in (task #15).
  # Original Tier 1 had cuCIM at N=4 only (Stage-5-inherited pattern). Tier 2
  # (2026-05-23) revealed that the kvikIO/cuCIM ratio narrows with N and even
  # reverses at production scale. Stage 5 fill-in (5.B.{1,2,8} added 2026-05-24)
  # confirmed the trend for ResNet-50. This target completes the cuCIM scaling
  # curve for foundation models at the 50-slide BRCA subset.
  # 9 cells: 3 models × N ∈ {1, 2, 8}. ~3-4 hr.
  echo "=== Stage 6.A Tier 1: cuCIM scaling fill-in (N=1, N=2, N=8 × 3 models) ==="
  for n in 1 2 8; do
    for model in virchow2 gigapath uni2-h; do
      run_cell "$model" cucim_batched_cpu "$n" "$(gpu_csv_for_n "$n")" brca50 \
        || echo "  (cell $model cucim N=$n failed; continuing)"
    done
  done
}

tier1_scaling_n248() {
  # Re-run target for resuming Tier 1 after a partial completion: re-runs the
  # N=2/4/8 cells + cuCIM N=4 comparator only (skips N=1). Used 2026-05-20 to
  # finish Tier 1 after the skip-on-existing bug invalidated the N=2/4/8/cuCIM
  # cells of the original sweep — the N=1 cells (which ran on cold dirs) had
  # valid measurements. Each cell still wipes the output dir at start via
  # run_cell's cleanup, so the existing N=1 features get wiped and the cells
  # measure their own throughput cleanly.
  echo "=== Stage 6.A Tier 1: resumed sweep (skip N=1, run N=2/4/8 + cuCIM N=4 × 3 models) ==="
  for model in virchow2 gigapath uni2-h; do
    for n in 2 4 8; do
      run_cell "$model" kvikio "$n" "$(gpu_csv_for_n "$n")" brca50 || echo "  (cell failed; continuing)"
    done
    run_cell "$model" cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca50 || echo "  (cell failed; continuing)"
  done
}

tier3_cross_dataset() {
  echo "=== Stage 6.A Tier 3: CAM16 cross-dataset at N=4 (3 models) ==="
  for model in virchow2 gigapath uni2-h; do
    run_cell "$model" kvikio 4 "$(gpu_csv_for_n 4)" cam16 || echo "  (cell failed; continuing)"
  done
}

run_tier2_kvikio_chunked() {
  # Tier 2 kvikIO cell — runs under run-stage6a-tier2-chunked.sh orchestrator.
  # Single record-run wraps the whole multi-chunk operation.
  local model="$1"
  local n_gpus="${2:-4}"
  local gpu_csv="${3:-2,3,6,7}"
  local chunk_size="${4:-200}"

  local cell_name="extract-${model}-kvikio-brca_full-N${n_gpus}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s6.A-${cell_name}"
  local features_out="/mnt/liad/features/6.A/${model}/brca_full"
  local orchestrator="$REPO/runs/lib/run-stage6a-tier2-chunked.sh"

  [ -x "$orchestrator" ] || { echo "missing orchestrator $orchestrator" >&2; return 1; }
  mkdir -p "$features_out"

  # Cleanup .pt before Tier 2 kvikIO cell. The chunked orchestrator iterates
  # multiple chunk-invocations of the extractor; the extractor's skip-on-existing
  # is correct WITHIN the chunked run (so chunk N+1 doesn't redo chunk N's
  # slides). But BEFORE the chunked run, any .pt left over from a prior cuCIM
  # Tier 2 cell for the same model must be wiped so kvikIO actually does work.
  # See cleanup rationale in run_cell. Found 2026-05-20.
  local n_pt_before
  n_pt_before=$(find "$features_out" -maxdepth 1 -name '*.pt' 2>/dev/null | wc -l)
  if [ "$n_pt_before" -gt 0 ]; then
    echo "[cleanup] wiping $n_pt_before pre-existing .pt files in $features_out (pre-chunked-orchestrator)"
    find "$features_out" -maxdepth 1 -name '*.pt' -delete
  fi

  local approval_tag=""
  [ "$model" = "uni2-h" ] && approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  local note="${approval_tag}Stage 6.A Tier 2 cell: model=${model} backend=kvikio N=${n_gpus} dataset=brca_full (1131 slides chunked into ~6 batches of ${chunk_size} slides each). Each chunk: SVS→raw-TIFF conversion → extraction → raw-TIFF cleanup. Per-chunk timing in per-chunk-summary.csv. Outer record-run captures continuous WEKA time-series across all chunks. Per cucim_libcufile_preload_abi_clash memory: kvikio cells set LD_PRELOAD=libcufile-1.17."

  echo ""
  echo "=========================================="
  echo "[$now_utc] Tier 2 kvikIO cell (chunked): $cell_name"
  echo "  model=$model N=$n_gpus gpus=$gpu_csv chunk_size=$chunk_size"
  echo "  outer record-run wraps the chunked orchestrator"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$LIBCUFILE_117" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "$note" \
    -- "$orchestrator" \
       --model "$model" --n-gpus "$n_gpus" --gpu-csv "$gpu_csv" \
       --output-dir "$features_out" \
       --extraction-steps-csv "$run_dir/extraction-steps.csv" \
       --per-slide-csv "$run_dir/per-slide.csv" \
       --summary-json "$run_dir/extraction-summary.json" \
       --per-chunk-summary "$run_dir/per-chunk-summary.csv" \
       --chunk-size "$chunk_size"
}

run_tier2_kvikio_chunked_multimodel() {
  # Tier 2 kvikIO MULTI-MODEL cell — runs all 3 models in one cell via the
  # cross-model-conversion-sharing orchestrator. Per chunk: convert once →
  # extract per model from the shared raw-TIFF → cleanup. Saves ~55 hr vs the
  # per-model single-model orchestrator (smoke 2026-05-21 showed convert is
  # ~15× extract per chunk).
  local models_csv="$1"
  local n_gpus="${2:-4}"
  local gpu_csv="${3:-2,3,6,7}"
  local chunk_size="${4:-200}"

  local cell_name="extract-multimodel-kvikio-brca_full-N${n_gpus}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s6.A-${cell_name}"
  local orchestrator="$REPO/runs/lib/run-stage6a-tier2-chunked-multimodel.sh"

  [ -x "$orchestrator" ] || { echo "missing multimodel orchestrator $orchestrator" >&2; return 1; }

  # Cleanup per-model brca_full output dirs before starting. The chunked
  # multi-model orchestrator does NOT wipe per-model output dirs itself, and
  # the extractor's skip-on-existing logic would short-circuit every kvikIO
  # cell after the prior cuCIM Tier 2 cells wrote their .pt files. Mirrors
  # the cleanup pattern in run_cell + run_tier2_kvikio_chunked.
  IFS=',' read -ra MODELS_ARR <<< "$models_csv"
  for model in "${MODELS_ARR[@]}"; do
    local mdir="/mnt/liad/features/6.A/${model}/brca_full"
    mkdir -p "$mdir"
    local n_pt_before
    n_pt_before=$(find "$mdir" -maxdepth 1 -name '*.pt' 2>/dev/null | wc -l)
    if [ "$n_pt_before" -gt 0 ]; then
      echo "[cleanup] wiping $n_pt_before pre-existing .pt files in $mdir (pre-multimodel-orchestrator)"
      find "$mdir" -maxdepth 1 -name '*.pt' -delete
    fi
  done

  # PENDING-APPROVAL tag fires if uni2-h is in the model list (always true under
  # the conditional-use plan — UNI2-h is in tier2_production's default model set).
  local approval_tag=""
  if [[ ",$models_csv," == *",uni2-h,"* ]]; then
    approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  fi
  local note="${approval_tag}Stage 6.A Tier 2 MULTI-MODEL chunked cell: models=$models_csv backend=kvikio N=${n_gpus} dataset=brca_full (1131 slides chunked into ~6 batches of ${chunk_size} slides each). Cross-model conversion sharing: each chunk SVS→raw-TIFF converts ONCE, then extracts for each model in turn, then cleans up. Saves ~55 hr vs per-model orchestrator (smoke 2026-05-21 found convert is ~15× extract per chunk). Per cucim_libcufile_preload_abi_clash memory: kvikio cells set LD_PRELOAD=libcufile-1.17."

  echo ""
  echo "=========================================="
  echo "[$now_utc] Tier 2 kvikIO MULTI-MODEL cell: $cell_name"
  echo "  models=$models_csv N=$n_gpus gpus=$gpu_csv chunk_size=$chunk_size"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$LIBCUFILE_117" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "$note" \
    -- "$orchestrator" \
       --models "$models_csv" --n-gpus "$n_gpus" --gpu-csv "$gpu_csv" \
       --output-dir-base "/mnt/liad/features/6.A" \
       --run-dir "$run_dir" \
       --chunk-size "$chunk_size"
}

tier2_production() {
  echo "=== Stage 6.A Tier 2: full BRCA at N=4 (3 models) ==="
  # cuCIM cells: canonical SVS, no chunking, no conversion sharing applicable
  # (cuCIM reads SVS directly). Per-model cells, sequential.
  for model in virchow2 gigapath uni2-h; do
    run_cell "$model" cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca_full || echo "  (cell failed; continuing)"
  done
  # kvikIO cells: ONE multi-model cell with cross-model conversion sharing.
  run_tier2_kvikio_chunked_multimodel "virchow2,gigapath,uni2-h" 4 "2,3,6,7" 200 \
    || echo "  (Tier 2 multi-model kvikio cell failed; continuing)"
}

tier2_kvikio_only() {
  echo "=== Stage 6.A Tier 2: kvikIO multi-model only (skip cuCIM cells) ==="
  run_tier2_kvikio_chunked_multimodel "virchow2,gigapath,uni2-h" 4 "2,3,6,7" 200 \
    || echo "  (Tier 2 multi-model kvikio cell failed; continuing)"
}

tier2_production_n8() {
  # Stage 6.A Tier 2 at N=8 — the post-Tier-1-data revision of the Q2 decision.
  # Tier 1 showed foundation-model extraction scales at 81-82% efficiency at
  # N=8 (vs Stage 5 ResNet-50's 69% that originally motivated "peak N=4").
  # N=8 gives a stronger customer story (all 8 GPUs at production scale) AND
  # roughly halves per-cell wallclock vs N=4 (extract phase dominated).
  # Per feedback_methodology_revisability (2026-05-21).
  echo "=== Stage 6.A Tier 2 at N=8: full BRCA across 3 models, both backends ==="
  for model in virchow2 gigapath uni2-h; do
    run_cell "$model" cucim_batched_cpu 8 "$(gpu_csv_for_n 8)" brca_full \
      || echo "  (cell failed; continuing)"
  done
  run_tier2_kvikio_chunked_multimodel "virchow2,gigapath,uni2-h" 8 "0,1,2,3,4,5,6,7" 200 \
    || echo "  (Tier 2 multi-model kvikio cell failed; continuing)"
}

tier2_resume_post_virchow2_cucim() {
  # Resume target for Stage 6.A Tier 2 after Virchow2 cuCIM has completed
  # (1131 .pt files in /mnt/liad/features/6.A/virchow2/brca_full/ retained).
  # Skips Virchow2 cuCIM; runs GigaPath + UNI2-h cuCIM then kvikIO multi-model.
  # Used 2026-05-21 after the first Tier 2 sweep hit a record-run.sh timestamp
  # race condition that broke GigaPath cuCIM; killed sweep to apply
  # RECORD_RUN_DIR fix; resumed via this target.
  echo "=== Stage 6.A Tier 2 RESUME: gigapath + uni2-h cuCIM, then kvikIO multi-model ==="
  for model in gigapath uni2-h; do
    run_cell "$model" cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca_full \
      || echo "  (cell $model cucim failed; continuing)"
  done
  run_tier2_kvikio_chunked_multimodel "virchow2,gigapath,uni2-h" 4 "2,3,6,7" 200 \
    || echo "  (Tier 2 multi-model kvikio cell failed; continuing)"
}

tier2_kvikio_multimodel_smoke() {
  # Smoke the multi-model orchestrator with --max-slides 10, chunk-size 5,
  # all 3 models. Validates the per-chunk convert-once + per-model extract +
  # cleanup flow end-to-end before committing to the ~32 hr full sweep.
  echo "=== Stage 6.A Tier 2 MULTI-MODEL smoke: 10 slides × 2 chunks × 3 models ==="
  local cell_name="smoke-multimodel-tier2-kvikio-brca_full-smoke10-N4"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s6.A-${cell_name}"
  local orchestrator="$REPO/runs/lib/run-stage6a-tier2-chunked-multimodel.sh"
  [ -x "$orchestrator" ] || { echo "missing multimodel orchestrator $orchestrator" >&2; return 1; }

  local approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  local note="${approval_tag}Stage 6.A Tier 2 MULTI-MODEL orchestrator SMOKE: 10 slides × 2 chunks × 3 models (virchow2/gigapath/uni2-h). Validates cross-model conversion sharing pipeline before the full Tier 2 sweep."

  CUDA_VISIBLE_DEVICES="2,3,6,7" \
  LD_PRELOAD="$LIBCUFILE_117" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "$note" \
    -- "$orchestrator" \
       --models "virchow2,gigapath,uni2-h" --n-gpus 4 --gpu-csv "2,3,6,7" \
       --output-dir-base "/mnt/liad/features/6.A-smoke" \
       --run-dir "$run_dir" \
       --chunk-size 5 --max-slides 10
}

smoke() {
  echo "=== Stage 6.A smoke: Virchow2 N=1 kvikio brca50 (3 slides only) ==="
  # Quick validation. Calls extractor with --max-slides 3 for fast turnaround.
  local cell_name="smoke-extract-virchow2-kvikio-brca50-N1-3slides"
  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s6.A-${cell_name}"
  local features_out="/mnt/liad/features/6.A/virchow2/brca50-smoke"
  mkdir -p "$features_out"

  CUDA_VISIBLE_DEVICES="2" \
  LD_PRELOAD="$LIBCUFILE_117" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "Stage 6.A smoke cell (3 slides, single GPU) — validates end-to-end extractor before committing to Tier 1 sweep." \
    -- "$PY" "$EXTRACTOR" \
       --backend kvikio --world-size 1 --model virchow2 \
       --rawtiff-dir "$BRCA_RAWTIFF_50" --coords-dir "$BRCA_COORDS" \
       --manifest "$BRCA_50_MANIFEST" --output-dir "$features_out" \
       --batch-size 256 \
       --extraction-steps-csv "$run_dir/extraction-steps.csv" \
       --per-slide-csv "$run_dir/per-slide.csv" \
       --summary-json "$run_dir/extraction-summary.json" \
       --max-slides 3
}

all() {
  echo "=== Stage 6.A: tier1 + tier3 (skipping tier2 until chunked-conversion helper exists) ==="
  tier1_scaling
  tier3_cross_dataset
  echo ""
  echo "=== Stage 6.A sweep done (tier1 + tier3). Aggregate with: $REPO/runs/lib/aggregate-stage6a-extract.py ==="
}

case "${1:-}" in
  smoke)                          smoke ;;
  tier1)                          tier1_scaling ;;
  tier1_uni2h)                    tier1_uni2h ;;
  tier1_n248)                     tier1_scaling_n248 ;;
  tier1_cucim_n4_rerun)           tier1_cucim_n4_rerun ;;
  tier1_cucim_scaling_fill)       tier1_cucim_scaling_fill ;;
  tier2)                          tier2_production ;;
  tier2_n8)                       tier2_production_n8 ;;
  tier2_kvikio_only)              tier2_kvikio_only ;;
  tier2_resume_post_virchow2_cucim) tier2_resume_post_virchow2_cucim ;;
  tier2_kvikio_multimodel_smoke)  tier2_kvikio_multimodel_smoke ;;
  tier3)                          tier3_cross_dataset ;;
  all)                            all ;;
  *)
    echo "usage: $0 {smoke|tier1|tier1_uni2h|tier1_n248|tier1_cucim_n4_rerun|tier2|tier2_kvikio_only|tier2_kvikio_multimodel_smoke|tier3|all}" >&2
    exit 2
    ;;
esac
