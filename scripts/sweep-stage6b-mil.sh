#!/usr/bin/env bash
# Stage 6.B.3 MIL classifier training sweep driver — canonical CLAM bs=1.
#
# The non-canonical [B, max_N, D] padded-batch design OOMs at production
# feature sizes; canonical CLAM uses
# batch_size=1 with a custom collate that concatenates along the patch dim;
# the storage-concurrency axis is num_workers (each DataLoader worker
# prefetches one slide via torch.load). Verified against mahmoodlab/CLAM
# utils/utils.py (collate_MIL + get_split_loader bs=1) and models/model_clam.py
# (CLAM_SB.forward([N,D]) single-bag).
#
# 3 cells per `docs/Stage-6-Feature-Extraction.md` 6.B.3:
#   bs=1 × num_workers ∈ {4, 16, 32}
# Single-GPU (MIL aggregator is small; multi-GPU DDP unnecessary).
#
# Uses real 6.A features. Default model: virchow2 (Apache 2.0, available now).
# all_models loops virchow2 → gigapath → uni2-h (with PENDING-APPROVAL tag).
#
# Per cell: 5 min ramp + 15 min steady = ~20 min wallclock × 3 cells = ~1 hr/model.
#
# Usage:
#   ./sweep-stage6b-mil.sh smoke              # single-cell short validation
#   ./sweep-stage6b-mil.sh all                # 3 cells, ~1 hr (single model)
#   ./sweep-stage6b-mil.sh all_models         # 9 cells, ~3 hr (all 3 models)
#   MODEL=virchow2 ./sweep-stage6b-mil.sh all       # explicit model (default)
#   FEATURES_TAG=brca_full ./sweep-stage6b-mil.sh all  # features dataset (default brca_full)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
TRAINER="$REPO/scripts/train-mil-stage6b.py"
RECORD="$REPO/scripts/record-run.sh"

[ -f "$TRAINER" ] || { echo "missing trainer $TRAINER" >&2; exit 1; }
[ -x "$RECORD" ]  || { echo "missing record-run.sh" >&2; exit 1; }
FAILED_CELLS=0

MODEL="${MODEL:-virchow2}"
FEATURES_TAG="${FEATURES_TAG:-brca_full}"
FEATURES_DIR="${FS_MOUNT}/features/6.A/${MODEL}/${FEATURES_TAG}"

case "$MODEL" in
  virchow2)        EMBED_DIM=1280 ;;
  uni2-h|gigapath) EMBED_DIM=1536 ;;
  *) echo "unknown model $MODEL (expected virchow2|uni2-h|gigapath)" >&2; exit 2 ;;
esac

export CONDA_PREFIX="$CONDA_ENV"
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8

run_cell() {
  local num_workers="$1"
  local ramp="${2:-300}"; local runtime="${3:-900}"
  local cell_name="train-mil-${MODEL}-${FEATURES_TAG}-bs1-nw${num_workers}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.B.3-${cell_name}"

  if [ ! -d "$FEATURES_DIR" ] || [ "$(ls "$FEATURES_DIR"/*.pt 2>/dev/null | wc -l)" -lt 50 ]; then
    echo "[ERR] $FEATURES_DIR has fewer than 50 .pt files; Stage 6.A.Tier2 must run first." >&2
    return 1
  fi

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name"
  echo "  features=$FEATURES_DIR  canonical-CLAM bs=1 num_workers=$num_workers ramp=${ramp}s steady=${runtime}s"
  echo "=========================================="

  local approval_tag=""
  [ "$MODEL" = "uni2-h" ] && approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "

  # D-30/D13: the roadmap's regime row — the full-cohort feature corpus (~53 GB/model)
  # fits host RAM, so the workload is memory-served steady-state by construction after
  # the first pass, identically on both legs. The note wording below IS the reconciler's
  # achieved-evidence for a warm declaration (wsi_agg_helper.reconcile_cache_state).
  CUDA_VISIBLE_DEVICES=2 \
  RECORD_CACHE_STATE=warm \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.B.3 \
    --note "${approval_tag}Stage 6.B.3 canonical CLAM MIL training cell — real features from 6.A. model=${MODEL} batch_size=1 num_workers=${num_workers}. WHY: grounds the Phase 2 metadata-stress story in actual production training context. Storage concurrency driven by DataLoader num_workers (each worker prefetches one slide); batch_size=1 matches mahmoodlab/CLAM canonical (collate_MIL + CLAM_SB.forward([N,D])). num_workers is the customer-quotable IO axis. Regime: warm — the per-model feature corpus fits host RAM, so this is memory-served steady-state by construction after the first pass (Stage-6 roadmap regime row); it measures MIL throughput, not storage bandwidth — the cold storage number belongs to 6.B.2's synthetic corpus." \
    -- "$PY" "$TRAINER" \
       --features-dir "$FEATURES_DIR" \
       --embedding-dim "$EMBED_DIM" \
       --num-workers "$num_workers" \
       --ramp "$ramp" --runtime "$runtime" \
       --training-steps-csv "$run_dir/training-steps.csv" \
       --summary-json "$run_dir/training-summary.json"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

smoke() {
  run_cell 2 30 60
}

all() {
  echo "=== Stage 6.B.3 MIL training (3 cells, canonical CLAM bs=1) — model=$MODEL features=$FEATURES_DIR ==="
  run_cell 4   300 900
  run_cell 16  300 900
  run_cell 32  300 900
}

# Convenience: run the full 3-cell sweep against each of the three foundation
# models' features. Re-invokes this script with MODEL= env override per model.
all_models() {
  echo "=== Stage 6.B.3 MIL training across all 3 foundation models (9 cells total) ==="
  for m in virchow2 gigapath uni2-h; do
    echo ""
    echo "--- MIL sweep against $m features ---"
    MODEL="$m" FEATURES_TAG="$FEATURES_TAG" "$0" all
  done
}

case "${1:-}" in
  smoke)       smoke ;;
  all)         all ;;
  all_models)  all_models ;;
  *) echo "usage: $0 {smoke|all|all_models}" >&2; exit 2 ;;
esac

if (( FAILED_CELLS > 0 )); then
  echo "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation)," >&2
  echo "        and this exit tells the chain a hole exists rather than letting the step be marked done." >&2
  exit 1
fi
