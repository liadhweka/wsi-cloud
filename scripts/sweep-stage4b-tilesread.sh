#!/usr/bin/env bash
# sweep-stage4b-tilesread.sh — Stage 4.B on-the-fly random tile reads.
#
# Strategy B: random tile reads from many slides to model production DataLoader workloads.
# CPU-only methodology. The cuCIM GPU read_region axis is ruled out as a LIBRARY
# defect — filesystem-independent, therefore not a comparison axis and never to be
# reported as a storage finding for either side. See the
# `cucim-gpu-read-region-non-viable` memory; do not re-investigate.
#
# Two backends:
#   openslide: per-tile via multiprocessing.Pool of N processes — production-reality pattern (MONAI/Slideflow)
#   cucim:     batched API (locations_list + batch_size + num_workers) — documented production pattern
#
# Tier 1 (this script's default): Saturation curves
#   OpenSlide N ∈ {1, 4, 16, 64, 256}
#   cuCIM N ∈ {1, 4, 16, 64} at nw=16, bs=4 (peak from pre-flight)
#   × 2 datasets = 18 cells. ~30 min wallclock.
#
# Tier 2 + Tier 3 will be designed adaptively after Tier 1 results and invoked via this script
# with different positional args (TBD).
#
# Per-cell: time-based 60s runtime + 10s ramp. record-run.sh captures pre/raw/post + weka stats +
# RDMA + sar-cpu (per-core) + nvidia-smi (diagnostic-only, should be ~0% throughout).
#
# Usage:
#   scripts/sweep-stage4b-tilesread.sh             # default Tier 1
#   scripts/sweep-stage4b-tilesread.sh tier1       # explicit Tier 1
#   (Tier 2/3 invocations TBD after Tier 1)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_ALT:?CONDA_ENV_ALT is unset -- source env.sh}"
PYTHON=$CONDA_ENV/bin/python
READER=$REPO/scripts/read-tiles-onthefly.py
: "${SCRATCH_DIR:?SCRATCH_DIR is unset -- source env.sh}"
POOL_CACHE_DIR=${SCRATCH_DIR}/stage4b-pool-cache
LATENCY_DIR=/tmp/stage4b-latencies
LOG_DIR=$REPO/runs/sweep-logs
RUNTIME=60
RAMP=10

# tier selector
TIER=${1:-tier1}

mkdir -p "$LOG_DIR" "$POOL_CACHE_DIR" "$LATENCY_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage4b-tilesread-${TIER}.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

if [[ ! -x "$PYTHON" ]]; then
  log "FATAL: conda env Python not found at $PYTHON"; exit 2
fi
if [[ ! -f "$READER" ]]; then
  log "FATAL: reader not found at $READER"; exit 2
fi

# Dataset entries: name:svs_dir:coords_dir
DATASETS=(
  "tcga-brca:${FS_MOUNT}/data/tcga-brca:${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches"
  "camelyon16:${FS_MOUNT}/data/camelyon16/images:${FS_MOUNT}/tissue-detection/3.0/camelyon16/n64/patches"
)

# Cell definitions per tier. Every list is a FIXED, deliberately DE-ORDERED
# sequence (never ascending in N): at high worker counts the repeatedly
# re-drawn coord-pool subset becomes cache-resident, and if warmth rises with
# the swept variable the crossover cannot be located afterwards (D13; the
# Stage-4 roadmap's cache-discipline row). Identical on both legs by being
# committed here.
#
# Entries suffixed ':cold' are COLD REFERENCE CELLS (D13 route 2): the same
# grid point re-run after vm.drop_caches=3, with the acknowledgment recorded
# into the run dir. They sit at the worker counts where the working-set-vs-
# cache crossover is expected — the high-N points, run cold AFTER their warm
# twins so the comparison is steady-state-vs-cold at maximum accumulated
# warmth. Client-side only: the server side is not clearable from here and the
# residual is recorded, not asserted.
if [[ "$TIER" == "tier1" ]]; then
  OPENSLIDE_CELLS=(64 1 256 4 16 "256:cold" "64:cold")
  CUCIM_CELLS=("16:16:4" "1:16:4" "64:16:4" "4:16:4" "64:16:4:cold" "16:16:4:cold")   # N:nw:bs[:cold]
elif [[ "$TIER" == "tier2" ]]; then
  # Block A: OpenSlide further N values
  OPENSLIDE_CELLS=(128 32 768 96 1024 192 512 384)
  # Block B (N × nw surface) + Block C (bs sensitivity at the Tier-1 sweet spot)
  CUCIM_CELLS=("4:8:4" "1:4:4" "16:32:4" "4:4:4" "1:32:4" "16:4:4" "4:32:4" "1:8:4" "16:8:4"
               "16:16:16" "16:16:1" "16:16:64")
elif [[ "$TIER" == "tier3" ]]; then
  # Block F: cuCIM at bs=64 across (N, nw), de-ordered.
  OPENSLIDE_CELLS=()
  CUCIM_CELLS=("16:4:64" "4:16:64" "64:4:64" "4:4:64" "64:16:64" "16:16:64")
elif [[ "$TIER" == "tier4" ]]; then
  # Push past Tier 1's max toward the read ceiling; find cuCIM saturation.
  OPENSLIDE_CELLS=()
  CUCIM_CELLS=("256:4:64" "128:16:64" "64:16:256" "128:4:64" "64:16:128" "256:16:64")
elif [[ "$TIER" == "tier5" ]]; then
  # Re-measure key cuCIM configs WITH --sort-batches (within-batch tile-index
  # sorting for read locality); invoked with --sort-batches by the builder below.
  OPENSLIDE_CELLS=()
  CUCIM_CELLS=("16:16:64" "1:16:64" "64:4:64" "4:16:4" "64:16:64" "16:4:64" "4:16:64" "64:16:4" "16:16:4")
else
  log "FATAL: unsupported tier '$TIER'"
  exit 2
fi
# Tier 5: pass --sort-batches to the reader for cuCIM cells
TIER5_SORT=0
if [[ "$TIER" == "tier5" ]]; then TIER5_SORT=1; fi

drop_caches_evidenced() { # drop_caches_evidenced <evidence-file>
  local ev="$1" rc
  sync
  sudo -n sysctl vm.drop_caches=3 > "$ev.tmp" 2>&1
  rc=$?
  {
    echo "action=vm.drop_caches=3 (client page cache + dentries + inodes)"
    echo "timestamp=$(date -u +%FT%TZ)"
    echo "rc=$rc"
    cat "$ev.tmp"
    echo "server_side=not clearable from the client; residual uncertainty stated, not hidden (D13)"
  } > "$ev"
  rm -f "$ev.tmp"
  return $rc
}

TOTAL=$(( ${#DATASETS[@]} * ( ${#OPENSLIDE_CELLS[@]} + ${#CUCIM_CELLS[@]} ) ))
log "=== Stage 4.B $TIER sweep starting ==="
log "  python:    $PYTHON"
log "  reader:    $READER"
log "  runtime:   ${RUNTIME}s steady + ${RAMP}s ramp"
log "  datasets:  $(echo "${DATASETS[@]}" | sed 's/:[^ ]*//g')"
log "  openslide N: ${OPENSLIDE_CELLS[*]}"
log "  cucim N:nw:bs: ${CUCIM_CELLS[*]}"
log "  total cells: $TOTAL"
log ""

i=0
FAILED_CELLS=0
for ds_entry in "${DATASETS[@]}"; do
  IFS=':' read -r dataset svs_dir coords_dir <<< "$ds_entry"
  pool_cache="$POOL_CACHE_DIR/${dataset}.pkl"
  if [[ ! -d "$coords_dir" ]]; then
    log "  SKIP: coords dir missing for $dataset: $coords_dir"
    continue
  fi

  # ===== OpenSlide cells =====
  for cellspec in "${OPENSLIDE_CELLS[@]}"; do
    N="${cellspec%%:*}"
    arm=$([[ "$cellspec" == *:cold ]] && echo cold || echo warm)
    i=$(( i + 1 ))
    name="tilesread-${dataset}-openslide-N${N}$([[ "$arm" == cold ]] && echo "-coldref")"
    latency_csv="$LATENCY_DIR/${name}.csv"
    summary_json="$LATENCY_DIR/${name}.summary.json"
    note="Stage 4.B $TIER cell $i/$TOTAL: random tile reads. Backend=openslide (per-tile via multiprocessing.Pool). Dataset=$dataset (full coord pool from CLAM 3.0 n64 outputs). N_processes=$N. LRU(8) slide handle cache per worker. seed=42. runtime=${RUNTIME}s + ${RAMP}s ramp. Cache arm=$arm$([[ "$arm" == cold ]] && echo ' (COLD REFERENCE CELL at an expected crossover point: vm.drop_caches=3 with recorded acknowledgment, run after its warm twin; server-side residual stated)'). Cell order fixed and de-ordered in N (D13)."
    log "=== [cell $i/$TOTAL] $name (arm=$arm) ==="

    export RECORD_RUN_DIR="$REPO/runs/$(date -u +%Y-%m-%d-%H%M%S)-${LEG:?LEG is unset}-s4.B-${name}"
    mkdir -p "$RECORD_RUN_DIR"
    if [[ "$arm" == "cold" ]]; then
      if ! drop_caches_evidenced "$RECORD_RUN_DIR/cache-evidence.txt"; then
        log "FATAL: vm.drop_caches=3 failed — the cold reference cell would be mislabelled. Aborting."
        exit 1
      fi
      sleep 2
    fi

    RECORD_CACHE_STATE="$arm" "$REPO/scripts/record-run.sh" \
      --run-name "$name" --stage 4.B --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$READER" \
        --backend openslide --n-processes "$N" \
        --svs-dir "$svs_dir" --coords-dir "$coords_dir" \
        --runtime "$RUNTIME" --ramp "$RAMP" \
        --coord-pool-pickle "$pool_cache" \
        --latency-csv "$latency_csv" --summary-json "$summary_json" \
        --seed 42 2>&1 | tee -a "$SWEEP_LOG"
    cell_rc=${PIPESTATUS[0]}
    (( cell_rc != 0 )) && { FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$cell_rc — INCOMPLETE; sweep continues (fails loud at the end)"; }

    # Archive per-cell artifacts into the run dir
    RUN_DIR="$RECORD_RUN_DIR"; unset RECORD_RUN_DIR
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cp "$latency_csv" "$RUN_DIR/per-tile-latencies.csv" 2>/dev/null && log "  archived latencies"
      cp "$summary_json" "$RUN_DIR/reader-summary.json" 2>/dev/null && log "  archived summary"
    fi
    log ""
  done

  # ===== cuCIM batched-CPU cells =====
  for spec in "${CUCIM_CELLS[@]}"; do
    IFS=':' read -r N NW BS ARM <<< "$spec"
    arm=$([[ "${ARM:-}" == "cold" ]] && echo cold || echo warm)
    i=$(( i + 1 ))
    sort_tag=""
    sort_flag=()
    if [[ "$TIER5_SORT" -eq 1 ]]; then
      sort_tag="-sorted"
      sort_flag=(--sort-batches)
    fi
    name="tilesread-${dataset}-cucim-N${N}-nw${NW}-bs${BS}${sort_tag}$([[ "$arm" == cold ]] && echo "-coldref")"
    latency_csv="$LATENCY_DIR/${name}.csv"
    summary_json="$LATENCY_DIR/${name}.summary.json"
    note="Stage 4.B $TIER cell $i/$TOTAL: random tile reads. Backend=cucim CPU batched$([ -n "$sort_tag" ] && echo " (with --sort-batches optimization)"). Dataset=$dataset. N_processes=$N, num_workers=$NW (cuCIM C++ thread pool), batch_size=$BS, prefetch_factor=2. LRU(8) slide handle cache per worker. seed=42. runtime=${RUNTIME}s + ${RAMP}s ramp. Cache arm=$arm$([[ "$arm" == cold ]] && echo ' (COLD REFERENCE CELL at an expected crossover point: vm.drop_caches=3 with recorded acknowledgment, run after its warm twin; server-side residual stated)'). Cell order fixed and de-ordered in N (D13)."
    log "=== [cell $i/$TOTAL] $name (arm=$arm) ==="

    export RECORD_RUN_DIR="$REPO/runs/$(date -u +%Y-%m-%d-%H%M%S)-${LEG:?LEG is unset}-s4.B-${name}"
    mkdir -p "$RECORD_RUN_DIR"
    if [[ "$arm" == "cold" ]]; then
      if ! drop_caches_evidenced "$RECORD_RUN_DIR/cache-evidence.txt"; then
        log "FATAL: vm.drop_caches=3 failed — the cold reference cell would be mislabelled. Aborting."
        exit 1
      fi
      sleep 2
    fi

    RECORD_CACHE_STATE="$arm" "$REPO/scripts/record-run.sh" \
      --run-name "$name" --stage 4.B --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$READER" \
        --backend cucim --n-processes "$N" --num-workers "$NW" --batch-size "$BS" \
        "${sort_flag[@]}" \
        --svs-dir "$svs_dir" --coords-dir "$coords_dir" \
        --runtime "$RUNTIME" --ramp "$RAMP" \
        --coord-pool-pickle "$pool_cache" \
        --latency-csv "$latency_csv" --summary-json "$summary_json" \
        --seed 42 2>&1 | tee -a "$SWEEP_LOG"
    cell_rc=${PIPESTATUS[0]}
    (( cell_rc != 0 )) && { FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$cell_rc — INCOMPLETE; sweep continues (fails loud at the end)"; }

    RUN_DIR="$RECORD_RUN_DIR"; unset RECORD_RUN_DIR
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cp "$latency_csv" "$RUN_DIR/per-tile-latencies.csv" 2>/dev/null && log "  archived latencies"
      cp "$summary_json" "$RUN_DIR/reader-summary.json" 2>/dev/null && log "  archived summary"
    fi
    log ""
  done
done

log "=== sweep done ==="
log "review:  cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "aggregate next: scripts/aggregate-stage4b-tilesread.py 'runs/2026-*-s4.B-tilesread-*'"
if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
