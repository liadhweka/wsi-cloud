#!/usr/bin/env bash
# sweep-stage4a-patches.sh — Stage 4.A pre-extract tiles to per-slide HDF5.
#
# Strategy A: Pre-extract tiles to disk. The legacy-storage-friendly approach
# (NetApp/BeeGFS reference pipelines work fine here). Per `Modern WSI Pipeline.txt`:
# *"WEKA is fine, but so is anything else with decent throughput."*
# We benchmark it for completeness — establishing that WEKA absorbs the
# pre-extract write workload at expected rates — then move to 4.B for the
# differentiated WEKA-vs-legacy story.
#
# 2D grid: datasets ∈ {tcga-brca, camelyon16} × concurrency ∈ {1, 8, 64} = 6 cells.
# 50-slide random subset per dataset (seed=42, see scripts/manifests/<dataset>-stage4a-subset.tsv).
# Subsetting bounds total wallclock to ~10 hr — full datasets at n=1 would be
# ~6.7 days for BRCA (1131 slides × 8.5 min/slide based on smoke-verified
# ~52K tiles/slide × ~10 ms/tile read+JPEG-encode+write).
#
# Per slide: open SVS via OpenSlide; read CLAM tile coords from Stage 3.0;
# for each coord call read_region(level=0, 256x256), JPEG-encode (q=85), write to
# per-slide output HDF5 (variable-length JPEG bytes + coords + attrs).
#
# Per-cell wallclock at the 50-slide subset:
#   BRCA   n=64 ~7 min   |  n=8 ~53 min  |  n=1 ~7 hr
#   CAM16  n=64 ~1.5 min |  n=8 ~12 min  |  n=1 ~92 min
#
# Iteration: concurrency outer (descending) × dataset inner — cheapest cells run
# first so methodology validates fast before committing to the long-pole n=1 cell.
#
# Per-cell isolation via record-run.sh: any cell failure leaves rest of sweep intact.
#
# Usage:
#   scripts/sweep-stage4a-patches.sh                # default {64 8 1}
#   scripts/sweep-stage4a-patches.sh 64             # phase 1: just n=64 cells (~10 min)
#   scripts/sweep-stage4a-patches.sh 8 1            # phase 2: chain n=8 then n=1 (~9 hr)
#
# Output:
#   - one runs/<TS>-s4.A-patches-<dataset>-n<N>/ per cell
#   - per-slide tile HDF5s at ${FS_MOUNT}/patches/4.A/<dataset>/n<N>/<slide-id>.h5
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_ALT:?CONDA_ENV_ALT is unset -- source env.sh}"
PYTHON=$CONDA_ENV/bin/python
EXTRACTOR=$REPO/scripts/extract-tiles-to-hdf5.py
PATCHES_OUT=${FS_MOUNT}/patches/4.A
LATENCY_DIR=/tmp/stage4a-latencies
LOG_DIR=$REPO/runs/sweep-logs
MANIFEST_DIR=$REPO/scripts/manifests

mkdir -p "$LOG_DIR" "$PATCHES_OUT" "$LATENCY_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage4a-patches.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }
FAILED_CELLS=0

if [[ ! -x "$PYTHON" ]]; then
  log "FATAL: conda env Python not found at $PYTHON. See Stage-4-Patching.md install note."
  exit 2
fi
if [[ ! -f "$EXTRACTOR" ]]; then
  log "FATAL: extractor not found at $EXTRACTOR"
  exit 2
fi

# Concurrency list: positional args override default
if [[ $# -gt 0 ]]; then
  CONCURRENCIES=("$@")
else
  CONCURRENCIES=(64 8 1)
fi

DATASETS=(
  "tcga-brca:${FS_MOUNT}/data/tcga-brca:${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches:$MANIFEST_DIR/tcga-brca-stage4a-subset.tsv"
  "camelyon16:${FS_MOUNT}/data/camelyon16/images:${FS_MOUNT}/tissue-detection/3.0/camelyon16/n64/patches:$MANIFEST_DIR/camelyon16-stage4a-subset.tsv"
)
TOTAL=$(( ${#DATASETS[@]} * ${#CONCURRENCIES[@]} ))

log "=== Stage 4.A sweep starting ==="
log "  python:       $PYTHON (conda env: $CONDA_ENV)"
log "  concurrency:  ${CONCURRENCIES[*]}"
log "  datasets:     tcga-brca, camelyon16"
log "  grid:         concurrency × datasets = $TOTAL cells (concurrency outer)"
log "  output:       $PATCHES_OUT/<dataset>/n<N>/<slide-id>.h5"
log "  log:          $SWEEP_LOG"
log ""

i=0
for n in "${CONCURRENCIES[@]}"; do
  for ds_entry in "${DATASETS[@]}"; do
    IFS=':' read -r dataset svs_dir coords_dir manifest <<< "$ds_entry"
    if [[ ! -d "$coords_dir" ]]; then
      log "  SKIP: coords dir missing for $dataset: $coords_dir (Stage 3.0 outputs not present?)"
      continue
    fi
    if [[ ! -f "$manifest" ]]; then
      log "  SKIP: manifest missing for $dataset: $manifest"
      continue
    fi
    n_subset=$(grep -cv -E '^(#|slide_id|$)' "$manifest")

    i=$(( i + 1 ))
    name="patches-${dataset}-n${n}"
    cell_save="$PATCHES_OUT/${dataset}/n${n}"
    latency_csv="$LATENCY_DIR/${dataset}-n${n}-latencies.csv"

    note="Stage 4.A cell $i/$TOTAL: pre-extract tiles to per-slide HDF5. Dataset=$dataset (50-slide random subset, seed=42, manifest=$manifest, $n_subset slides), concurrency=$n. Per slide: openslide.OpenSlide + read_region(level=0, 256x256) for each CLAM coord (~52K BRCA / ~11K CAMELYON16 avg per slide), JPEG-encoded q=85, written to $cell_save/<slide-id>.h5 with variable-length JPEG bytes dataset + coords + attrs. Single-pass. Concurrency via Python multiprocessing.Pool (per-slide-level)."

    log "=== [cell $i/$TOTAL] $name ==="
    log "  dataset:     $dataset ($n_subset slides from manifest)"
    log "  concurrency: $n"
    log "  cell save:   $cell_save"
    log "  cleaning prior cell output ..."
    rm -rf "$cell_save"
    mkdir -p "$cell_save"

    "$REPO/scripts/record-run.sh" \
      --run-name "$name" \
      --stage 4.A \
      --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$EXTRACTOR" \
        --concurrency "$n" \
        --svs-dir "$svs_dir" \
        --coords-dir "$coords_dir" \
        --output-dir "$cell_save" \
        --latency-csv "$latency_csv" \
        --manifest "$manifest" \
      2>&1 | tee -a "$SWEEP_LOG"
      cell_rc=${PIPESTATUS[0]}
      if (( cell_rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$cell_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi

    # Archive per-slide latency CSV into the run dir
    RUN_DIR=$(ls -td "$REPO/runs/"*-s4.A-${name} 2>/dev/null | head -1)
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cp "$latency_csv" "$RUN_DIR/per-slide-latencies.csv" 2>/dev/null \
        && log "  archived per-slide latencies → $RUN_DIR/per-slide-latencies.csv"
    fi

    log ""
  done
done

log "=== sweep done ==="
log "review:  cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "next:    scripts/aggregate-stage4a-patches.py 'runs/2026-*-s4.A-patches-*'"

if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
