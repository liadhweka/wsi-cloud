#!/usr/bin/env bash
# Stage 6.A sweep driver — foundation-model feature extraction.
#
# Three tiers per `docs/Stage-6-Feature-Extraction.md`. All three foundation models
# are first-class; UNI2-h cells carry the PENDING-APPROVAL tag (see run_cell), which
# is a publication filter, not a scope reduction:
#   Tier 1 (scaling): 50-slide cross-stage subset
#       - 3 models × N ∈ {1, 2, 4} × kvikio = 9 cells
#       - 3 models × N=4 × cucim_batched_cpu (data-path comparator) = 3 cells
#       - Total: 12 cells
#   Tier 2 (production-scale): full TCGA-BRCA cohort at N=4
#       - 3 models × N=4 × cucim_batched_cpu (canonical SVS) = 3 cells
#       - 1 multi-model kvikio cell — all 3 models share one chunked raw-TIFF
#         conversion, via `run-stage6a-tier2-chunked-multimodel.sh` = 1 cell
#       - Total: 4 cells
#   Tier 3 (cross-dataset): CAMELYON16 50-slide subset at N=4 × kvikio
#       - 3 models × N=4 × kvikio × CAM16 = 3 cells
#
# Per-cell LD_PRELOAD scoping — the standing rule for every sweep that mixes the two
# backends (docs/Stage-6-Feature-Extraction.md, "Per-cell LD_PRELOAD scoping"):
#   - kvikio cells: set LD_PRELOAD to the SYSTEM libcufile ($LIBCUFILE_PRELOAD)
#   - cucim cells: leave LD_PRELOAD unset (cuCIM links its own bundled copy and
#     segfaults on its first read under the ABI clash, even for CPU reads — a
#     failure that reads as a multiprocessing bug rather than a preload one)
#
# GPU assignment: N ∈ {1, 2, 4} on a 4-GPU instance (STAGES.md D10), matching Stage 5.
# ⏳ D-8: the index lists in gpu_csv_for_n() are plain 0-based placeholders — replace
# them with the NUMA/NIC-aware ordering once the topology map is derived on the real
# instance. The range is right; the pinning order is not yet.
#
# Usage:
#   ./sweep-stage6a-extract.sh smoke              # single-cell validation
#   ./sweep-stage6a-extract.sh tier1              # 12 cells (Virchow2 + GigaPath + UNI2-h scaling)
#   ./sweep-stage6a-extract.sh tier1_uni2h        # 4 cells (UNI2-h only)
#   ./sweep-stage6a-extract.sh tier1_n24          # 9 cells: N=2/4 + cuCIM N=4 × 3 models (resume target)
#   ./sweep-stage6a-extract.sh tier2              # 4 cells (full BRCA at N=4)
#   ./sweep-stage6a-extract.sh tier3              # 3 cells (CAM16 cross-dataset)
#   ./sweep-stage6a-extract.sh all                # tier1 + tier3 (skips tier2)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
EXTRACTOR="$REPO/scripts/extract-features-foundation-stage6.py"
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

# Sanity
[ -f "$CUFILE_JSON" ]   || { echo "missing corrected cufile.json at $CUFILE_JSON" >&2; exit 1; }
[ -f "$EXTRACTOR" ]     || { echo "missing extractor at $EXTRACTOR" >&2; exit 1; }

# cuFile mode for the kvikIO cells — same contract as sweep-stage5-training.sh:
# 'off' (GDS) is the grid's default; the mode-controlled paired cell
# (docs/STAGES.md, Stage-6 roadmap 6.A Tier 1) is requested by exporting this
# for that one invocation. Passed to the extractor as --compat-mode and set
# through kvikio.defaults — one channel, so the mode a cell ran in is never
# ambiguous. Validated here because the note is built before the extractor runs.
CUFILE_COMPAT_MODE="${CUFILE_COMPAT_MODE:-off}"
case "$CUFILE_COMPAT_MODE" in
  off|on|auto) ;;
  *) echo "CUFILE_COMPAT_MODE must be off|on|auto, got '$CUFILE_COMPAT_MODE'" >&2; exit 2 ;;
esac
[ -x "$RECORD" ]        || { echo "missing or non-exec record-run.sh at $RECORD" >&2; exit 1; }
FAILED_CELLS=0

# Dataset paths (matches FILESYSTEM-MAP)
BRCA_RAWTIFF_50=${FS_MOUNT}/data/tcga-brca-rawtiff
BRCA_SVS=${FS_MOUNT}/data/tcga-brca
BRCA_COORDS=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches
BRCA_50_MANIFEST=$REPO/scripts/manifests/tcga-brca-stage4a-subset.tsv
BRCA_FULL_MANIFEST=$REPO/scripts/manifests/tcga-brca-full40x-stage4a-format.tsv

CAM_RAWTIFF_50=${FS_MOUNT}/data/camelyon16-rawtiff
CAM_COORDS=${FS_MOUNT}/tissue-detection/3.0/camelyon16/n64/patches
CAM_50_MANIFEST=$REPO/scripts/manifests/camelyon16-stage4a-subset.tsv

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
    1) echo "0" ;;
    2) echo "0,1" ;;
    4) echo "0,1,2,3" ;;
    *) echo "ERR:bad-n=$1 (valid: 1, 2, 4 on a 4-GPU instance)" >&2; return 2 ;;
  esac
}

# Refuse a GPU list that cannot be what the cell claims.
#
# gpu_csv_for_n is always called inside `$(...)`, which discards its `return 2` and
# captures only stdout — an unmapped N therefore yields the EMPTY STRING, not an
# abort. An empty CUDA_VISIBLE_DEVICES hides every device (it is one deleted
# character away from unset, which exposes ALL of them), so the cell dies inside
# mp.spawn and the caller's `|| echo "(cell failed; continuing)"` reduces that to a
# log line while run_cell has already wiped the previous cell's features. A list
# that merely disagrees with --world-size is worse: CUDA_VISIBLE_DEVICES silently
# DROPS indices that do not exist rather than erroring, so the cell runs on fewer
# GPUs than its name and its n_gpus column claim, and reports a plausible tiles/sec.
# Mirrors the guard in run-multiproc-kvikio.sh and orchestrate-concurrent-stage6c.sh.
assert_gpu_csv() {
  local gpu_csv="$1"; local n_gpus="$2"; local ctx="$3"
  if [ -z "$gpu_csv" ] || [ "${gpu_csv#ERR:}" != "$gpu_csv" ]; then
    echo "FATAL[$ctx]: no GPU list for N=$n_gpus (gpu_csv_for_n rejected it: ${gpu_csv:-<empty>})." >&2
    echo "        Valid N on this instance is 1, 2 or 4 (STAGES.md D10)." >&2
    return 2
  fi
  local -a arr
  IFS=',' read -ra arr <<< "$gpu_csv"
  if [ "${#arr[@]}" -ne "$n_gpus" ]; then
    echo "FATAL[$ctx]: gpu_csv='$gpu_csv' lists ${#arr[@]} GPU(s) but N=$n_gpus." >&2
    echo "        The device list and --world-size must agree." >&2
    return 2
  fi
  local n_present
  n_present="$(nvidia-smi -L 2>/dev/null | wc -l)"
  if [ "${n_present:-0}" -eq 0 ]; then
    echo "FATAL[$ctx]: no GPUs visible (nvidia-smi -L returned nothing)." >&2
    return 2
  fi
  local g
  for g in "${arr[@]}"; do
    if ! [[ "$g" =~ ^[0-9]+$ ]] || [ "$g" -ge "$n_present" ]; then
      echo "FATAL[$ctx]: gpu_csv='$gpu_csv' names GPU index '$g', but this instance has" >&2
      echo "        $n_present GPU(s) (valid indices 0..$((n_present - 1)))." >&2
      echo "        Re-derive the GPU list for THIS instance (deferred item D-8)." >&2
      return 2
    fi
  done
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

  assert_gpu_csv "$gpu_csv" "$n_gpus" "$model/$backend/$dataset_tag" || return 2

  # kvikIO + brca_full is a refused pairing, not a supported one. dataset_config
  # pairs the full-cohort manifest with the 50-slide raw-TIFF dir, because the
  # cohort's raw-TIFF does not exist at rest — it is generated chunk by chunk. A
  # kvikIO cell here would find ~4% of its slides, log "skip (rawtiff missing)"
  # for the rest, exit 0, and record a plausible tiles/sec under a cell name, a
  # note and an n_gpus column that all say full-cohort. Nothing downstream can
  # tell the difference, so the pairing is refused rather than documented.
  if [ "$backend" = "kvikio" ] && [ "$dataset_tag" = "brca_full" ]; then
    echo "FATAL: backend=kvikio with dataset=brca_full is not a valid run_cell combination." >&2
    echo "       The full-cohort kvikIO path is run_tier2_kvikio_chunked_multimodel" >&2
    echo "       (targets: tier2, tier2_kvikio_only), which converts chunk by chunk." >&2
    return 2
  fi

  # Dataset paths
  local cfg
  cfg=$(dataset_config "$dataset_tag") || return 2
  IFS='|' read -r rawtiff svs coords manifest <<< "$cfg"

  # Backend-specific LD_PRELOAD + cuFile mode. The mode is recorded as REQUESTED
  # (the per-cell cuFile path accounting settles which path actually ran, D8);
  # on a cuCIM cell it is <n/a>, never a value the cell did not use.
  local preload=""
  local compat_mode=""
  if [ "$backend" = "kvikio" ]; then
    preload="$LIBCUFILE_SYSTEM"
    compat_mode="$CUFILE_COMPAT_MODE"
  fi

  # Cell + run-dir naming. A non-default cuFile mode joins the NAME, not only
  # the note — the aggregators group configs by name, and the mode-controlled
  # paired cell must never collapse into its best-mode twin.
  local cell_name="extract-${model}-${backend//_batched_cpu/}-${dataset_tag}-N${n_gpus}"
  if [ "$backend" = "kvikio" ] && [ "$compat_mode" != "off" ]; then
    cell_name="${cell_name}-compat${compat_mode}"
  fi
  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.A-${cell_name}"

  # Per-slide .pt output dir.
  local features_out="${FS_MOUNT}/features/6.A/${model}/${dataset_tag}"
  mkdir -p "$features_out"

  # Cleanup .pt before each cell. The extractor's skip-on-existing logic (a real
  # feature for incremental restart of long runs, e.g. Tier 2 chunked recovery)
  # makes every non-first benchmark-sweep cell do zero work because the prior
  # cell already wrote .pt files. Tier 1 + Tier 3 are throughput-measurement
  # sweeps; their features are NOT the deliverable (Tier 2 full-BRCA features
  # are). Wiping between cells gives each cell a cold start.
  local n_pt_before
  n_pt_before=$(find "$features_out" -maxdepth 1 -name '*.pt' 2>/dev/null | wc -l)
  if [ "$n_pt_before" -gt 0 ]; then
    echo "[cleanup] wiping $n_pt_before pre-existing .pt files in $features_out"
    find "$features_out" -maxdepth 1 -name '*.pt' -print -delete | wc -l >/dev/null
  fi

  # Prepend PENDING-APPROVAL tag for UNI2-h cells — internal use is unrestricted;
  # the tag in run-dir metadata is what gets filtered before anything is
  # externalised (Mahmood Lab written approval pending; see Stage 6 roadmap).
  local approval_tag=""
  if [ "$model" = "uni2-h" ]; then
    approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  fi
  local note="${approval_tag}Stage 6.A cell: model=${model} backend=${backend} N_gpus=${n_gpus} dataset=${dataset_tag} gpus=${gpu_csv} batch=256 cufile_compat_mode=${compat_mode:-<n/a>} (REQUESTED, not proven — the per-cell cuFile path accounting settles which path ran). WHY: docs/Stage-6-Feature-Extraction.md 6.A Tier 1 + that stage's decision register. Foundation-model frozen-eval extraction via mp.spawn DDP; per-rank modulo slide partitioning. AMP autocast FP16 + channels_last + cudnn.benchmark. CLS-token pooling (storage-benchmark universal choice). Per-cell LD_PRELOAD scoping: kvikio cells preload the system libcufile, cuCIM cells leave it unset — cuCIM links its own bundled libcufile and segfaults on its first read under the ABI clash."

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
    extractor_args+=( --rawtiff-dir "$rawtiff" --n-buffer 256 --num-threads 16 --compat-mode "$compat_mode" )
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
  (( rc != 0 )) && FAILED_CELLS=$(( FAILED_CELLS + 1 ))
  return "$rc"
}

# ---------- Tiers ----------

tier1_scaling() {
  echo "=== Stage 6.A Tier 1: scaling sweep on 50-slide subset (3 models) ==="
  # All three foundation models are first-class. UNI2-h cells are tagged
  # PENDING-APPROVAL in metadata (see run_cell) and stay internal-only until
  # Mahmood Lab written approval lands.
  for model in virchow2 gigapath uni2-h; do
    for n in 1 2 4; do
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
  for n in 1 2 4; do
    run_cell uni2-h kvikio "$n" "$(gpu_csv_for_n "$n")" brca50 || echo "  (cell failed; continuing)"
  done
  run_cell uni2-h cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca50 || echo "  (cell failed; continuing)"
}


tier1_cucim_scaling_fill() {
  # Completes the cuCIM scaling curve for the foundation models at the 50-slide
  # BRCA subset, so 6.A has a full cuCIM curve to set against the kvikIO one rather
  # than a single comparator point. Runs the low-N cells that the main Tier 1
  # target does not already cover.
  # 6 cells: 3 models × N ∈ {1, 2}.
  echo "=== Stage 6.A Tier 1: cuCIM scaling fill-in (N=1, N=2 × 3 models) ==="
  for n in 1 2; do
    for model in virchow2 gigapath uni2-h; do
      run_cell "$model" cucim_batched_cpu "$n" "$(gpu_csv_for_n "$n")" brca50 \
        || echo "  (cell $model cucim N=$n failed; continuing)"
    done
  done
}

tier1_scaling_n24() {
  # Re-run target for resuming Tier 1 after a partial completion: re-runs the
  # N=2/4 cells + the cuCIM N=4 comparator only (skips N=1), for the case where
  # the N=1 cells are known-good and the rest must be redone. Each cell still
  # wipes the output dir at start via run_cell's cleanup, so the retained N=1
  # features get wiped and every cell measures its own throughput cold.
  # N tracks gpu_csv_for_n's range (1, 2, 4 — STAGES.md D10), never the tier
  # names of another instance's GPU count.
  echo "=== Stage 6.A Tier 1: resumed sweep (skip N=1, run N=2/4 + cuCIM N=4 × 3 models) ==="
  for model in virchow2 gigapath uni2-h; do
    for n in 2 4; do
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
  local gpu_csv="${3:-$(gpu_csv_for_n 4)}"
  local chunk_size="${4:-200}"

  assert_gpu_csv "$gpu_csv" "$n_gpus" "$model/kvikio/brca_full" || return 2

  local cell_name="extract-${model}-kvikio-brca_full-N${n_gpus}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.A-${cell_name}"
  local features_out="${FS_MOUNT}/features/6.A/${model}/brca_full"
  local orchestrator="$REPO/scripts/run-stage6a-tier2-chunked.sh"

  [ -x "$orchestrator" ] || { echo "missing orchestrator $orchestrator" >&2; return 1; }
  mkdir -p "$features_out"

  # Cleanup .pt before Tier 2 kvikIO cell. The chunked orchestrator iterates
  # multiple chunk-invocations of the extractor; the extractor's skip-on-existing
  # is correct WITHIN the chunked run (so chunk N+1 doesn't redo chunk N's
  # slides). But BEFORE the chunked run, any .pt left over from a prior cuCIM
  # Tier 2 cell for the same model must be wiped so kvikIO actually does work.
  # See cleanup rationale in run_cell.
  local n_pt_before
  n_pt_before=$(find "$features_out" -maxdepth 1 -name '*.pt' 2>/dev/null | wc -l)
  if [ "$n_pt_before" -gt 0 ]; then
    echo "[cleanup] wiping $n_pt_before pre-existing .pt files in $features_out (pre-chunked-orchestrator)"
    find "$features_out" -maxdepth 1 -name '*.pt' -delete
  fi

  local approval_tag=""
  [ "$model" = "uni2-h" ] && approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  local note="${approval_tag}Stage 6.A Tier 2 cell: model=${model} backend=kvikio N=${n_gpus} dataset=brca_full (the 1073-slide uniform-magnification cohort per STAGES.md D5, chunked into batches of ${chunk_size} slides). Each chunk: SVS→raw-TIFF conversion → extraction → raw-TIFF cleanup. Per-chunk timing in per-chunk-summary.csv. Outer record-run captures a continuous filesystem-side time series across all chunks (the source differs per leg — see docs/RUNBOOK.md). Per-cell LD_PRELOAD scoping: kvikIO cells preload the system libcufile (cuCIM cells never do — it links its own bundled copy and segfaults on its first read under the ABI clash)."

  echo ""
  echo "=========================================="
  echo "[$now_utc] Tier 2 kvikIO cell (chunked): $cell_name"
  echo "  model=$model N=$n_gpus gpus=$gpu_csv chunk_size=$chunk_size"
  echo "  outer record-run wraps the chunked orchestrator"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$LIBCUFILE_SYSTEM" \
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
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

run_tier2_kvikio_chunked_multimodel() {
  # Tier 2 kvikIO MULTI-MODEL cell — runs all 3 models in one cell via the
  # cross-model-conversion-sharing orchestrator. Per chunk: convert once →
  # extract per model from the shared raw-TIFF → cleanup. Converting once per chunk
  # instead of once per model is structural rather than a micro-optimisation (convert is
  # ~15× extract per chunk).
  local models_csv="$1"
  local n_gpus="${2:-4}"
  local gpu_csv="${3:-$(gpu_csv_for_n 4)}"
  local chunk_size="${4:-200}"

  assert_gpu_csv "$gpu_csv" "$n_gpus" "multimodel/kvikio/brca_full" || return 2

  local cell_name="extract-multimodel-kvikio-brca_full-N${n_gpus}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.A-${cell_name}"
  local orchestrator="$REPO/scripts/run-stage6a-tier2-chunked-multimodel.sh"

  [ -x "$orchestrator" ] || { echo "missing multimodel orchestrator $orchestrator" >&2; return 1; }

  # Cleanup per-model brca_full output dirs before starting. The chunked
  # multi-model orchestrator does NOT wipe per-model output dirs itself, and
  # the extractor's skip-on-existing logic would short-circuit every kvikIO
  # cell after the prior cuCIM Tier 2 cells wrote their .pt files. Mirrors
  # the cleanup pattern in run_cell + run_tier2_kvikio_chunked.
  IFS=',' read -ra MODELS_ARR <<< "$models_csv"
  for model in "${MODELS_ARR[@]}"; do
    local mdir="${FS_MOUNT}/features/6.A/${model}/brca_full"
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
  local note="${approval_tag}Stage 6.A Tier 2 MULTI-MODEL chunked cell: models=$models_csv backend=kvikio N=${n_gpus} dataset=brca_full (the 1073-slide uniform-magnification cohort per STAGES.md D5, chunked into batches of ${chunk_size} slides). Cross-model conversion sharing: each chunk SVS→raw-TIFF converts ONCE, then extracts for each model in turn, then cleans up. Sharing conversion across models is STRUCTURAL, not a micro-optimisation: full-cohort raw-TIFF does not fit at once and conversion is a large share of per-chunk wallclock. Per-cell LD_PRELOAD scoping: kvikIO cells preload the system libcufile (cuCIM cells never do — it links its own bundled copy and segfaults on its first read under the ABI clash)."

  echo ""
  echo "=========================================="
  echo "[$now_utc] Tier 2 kvikIO MULTI-MODEL cell: $cell_name"
  echo "  models=$models_csv N=$n_gpus gpus=$gpu_csv chunk_size=$chunk_size"
  echo "=========================================="

  CUDA_VISIBLE_DEVICES="$gpu_csv" \
  LD_PRELOAD="$LIBCUFILE_SYSTEM" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "$note" \
    -- "$orchestrator" \
       --models "$models_csv" --n-gpus "$n_gpus" --gpu-csv "$gpu_csv" \
       --output-dir-base "${FS_MOUNT}/features/6.A" \
       --run-dir "$run_dir" \
       --chunk-size "$chunk_size"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

tier2_production() {
  echo "=== Stage 6.A Tier 2: full BRCA at N=4 (3 models) ==="
  # cuCIM cells: canonical SVS, no chunking, no conversion sharing applicable
  # (cuCIM reads SVS directly). Per-model cells, sequential.
  for model in virchow2 gigapath uni2-h; do
    run_cell "$model" cucim_batched_cpu 4 "$(gpu_csv_for_n 4)" brca_full || echo "  (cell failed; continuing)"
  done
  # kvikIO cells: ONE multi-model cell with cross-model conversion sharing.
  run_tier2_kvikio_chunked_multimodel "virchow2,gigapath,uni2-h" 4 "$(gpu_csv_for_n 4)" 200 \
    || echo "  (Tier 2 multi-model kvikio cell failed; continuing)"
}

tier2_kvikio_only() {
  echo "=== Stage 6.A Tier 2: kvikIO multi-model only (skip cuCIM cells) ==="
  run_tier2_kvikio_chunked_multimodel "virchow2,gigapath,uni2-h" 4 "$(gpu_csv_for_n 4)" 200 \
    || echo "  (Tier 2 multi-model kvikio cell failed; continuing)"
}



tier2_kvikio_multimodel_smoke() {
  # Smoke the multi-model orchestrator with --max-slides 10, chunk-size 5,
  # all 3 models. Validates the per-chunk convert-once + per-model extract +
  # cleanup flow end-to-end before committing to the ~32 hr full sweep.
  echo "=== Stage 6.A Tier 2 MULTI-MODEL smoke: 10 slides × 2 chunks × 3 models ==="
  local cell_name="smoke-multimodel-tier2-kvikio-brca_full-smoke10-N4"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.A-${cell_name}"
  local orchestrator="$REPO/scripts/run-stage6a-tier2-chunked-multimodel.sh"
  [ -x "$orchestrator" ] || { echo "missing multimodel orchestrator $orchestrator" >&2; return 1; }

  local approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  local note="${approval_tag}Stage 6.A Tier 2 MULTI-MODEL orchestrator SMOKE: 10 slides × 2 chunks × 3 models (virchow2/gigapath/uni2-h). Validates cross-model conversion sharing pipeline before the full Tier 2 sweep."

  CUDA_VISIBLE_DEVICES="$(gpu_csv_for_n 4)" \
  LD_PRELOAD="$LIBCUFILE_SYSTEM" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.A \
    --note "$note" \
    -- "$orchestrator" \
       --models "virchow2,gigapath,uni2-h" --n-gpus 4 --gpu-csv "$(gpu_csv_for_n 4)" \
       --output-dir-base "${FS_MOUNT}/features/6.A-smoke" \
       --run-dir "$run_dir" \
       --chunk-size 5 --max-slides 10
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

smoke() {
  echo "=== Stage 6.A smoke: Virchow2 N=1 kvikio brca50 (3 slides only) ==="
  # Quick validation. Calls extractor with --max-slides 3 for fast turnaround.
  local cell_name="smoke-extract-virchow2-kvikio-brca50-N1-3slides"
  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.A-${cell_name}"
  local features_out="${FS_MOUNT}/features/6.A/virchow2/brca50-smoke"
  mkdir -p "$features_out"

  CUDA_VISIBLE_DEVICES="2" \
  LD_PRELOAD="$LIBCUFILE_SYSTEM" \
  RECORD_RUN_DIR="$run_dir" \
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
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

all() {
  # Tier 2 is deliberately NOT in `all`: it is the stage's long pole and needs its
  # own capacity check for the transient chunked raw-TIFF before it is committed
  # (docs/Stage-6-Feature-Extraction.md 6.A Tier 2, "Capacity + hygiene"). Run it
  # explicitly via the `tier2` target.
  echo "=== Stage 6.A: tier1 (12 cells) + tier3 (3 cells); tier2 is run explicitly ==="
  tier1_scaling
  tier3_cross_dataset
  echo ""
  echo "=== Stage 6.A sweep done (tier1 + tier3). Aggregate with: $REPO/scripts/aggregate-stage6a-extract.py ==="
}

case "${1:-}" in
  smoke)                          smoke ;;
  tier1)                          tier1_scaling ;;
  tier1_uni2h)                    tier1_uni2h ;;
  tier1_n24)                      tier1_scaling_n24 ;;
  tier1_cucim_scaling_fill)       tier1_cucim_scaling_fill ;;
  tier2)                          tier2_production ;;
  tier2_kvikio_only)              tier2_kvikio_only ;;
  tier2_kvikio_multimodel_smoke)  tier2_kvikio_multimodel_smoke ;;
  tier3)                          tier3_cross_dataset ;;
  all)                            all ;;
  *)
    echo "usage: $0 {smoke|tier1|tier1_uni2h|tier1_n24|tier1_cucim_scaling_fill|tier2|tier2_kvikio_only|tier2_kvikio_multimodel_smoke|tier3|all}" >&2
    exit 2
    ;;
esac

if (( FAILED_CELLS > 0 )); then
  echo "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation)," >&2
  echo "        and this exit tells the chain a hole exists rather than letting the step be marked done." >&2
  exit 1
fi
