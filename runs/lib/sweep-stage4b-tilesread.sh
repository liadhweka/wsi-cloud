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
#   runs/lib/sweep-stage4b-tilesread.sh             # default Tier 1
#   runs/lib/sweep-stage4b-tilesread.sh tier1       # explicit Tier 1
#   (Tier 2/3 invocations TBD after Tier 1)
set -uo pipefail

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source cloud-setup/env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_ALT:?CONDA_ENV_ALT is unset -- source cloud-setup/env.sh}"
PYTHON=$CONDA_ENV/bin/python
READER=$REPO/runs/lib/read-tiles-onthefly.py
: "${SCRATCH_DIR:?SCRATCH_DIR is unset -- source cloud-setup/env.sh}"
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

# Cell definitions per tier
if [[ "$TIER" == "tier1" ]]; then
  OPENSLIDE_CELLS=()
  for N in 1 4 16 64 256; do OPENSLIDE_CELLS+=("$N"); done
  CUCIM_CELLS=()
  for N in 1 4 16 64; do CUCIM_CELLS+=("$N:16:4"); done   # N:nw:bs
elif [[ "$TIER" == "tier2" ]]; then
  # Block A: OpenSlide further N values
  OPENSLIDE_CELLS=()
  for N in 32 96 128 192 384 512 768 1024; do OPENSLIDE_CELLS+=("$N"); done
  # Block B + C: cuCIM 2D (N × nw) surface + bs sensitivity
  CUCIM_CELLS=()
  # Block B: N ∈ {1,4,16} × nw ∈ {4,8,32}
  for N in 1 4 16; do for NW in 4 8 32; do CUCIM_CELLS+=("$N:$NW:4"); done; done
  # Block C: bs sensitivity at N=16 nw=16 (Tier 1 strong-scaling sweet spot)
  for BS in 1 16 64; do CUCIM_CELLS+=("16:16:$BS"); done
elif [[ "$TIER" == "tier3" ]]; then
  # Block E (OpenSlide + drop_caches) DROPPED — cold-WEKA-read story already covered by Tier 2 BRCA
  # cells (BRCA's 1.05 TiB compressed total exceeds host RAM, so caches were naturally busted).
  OPENSLIDE_CELLS=()
  # Block F: cuCIM at bs=64 across (N, nw). 12 cells.
  CUCIM_CELLS=()
  for N in 4 16 64; do for NW in 4 16; do CUCIM_CELLS+=("$N:$NW:64"); done; done
elif [[ "$TIER" == "tier4" ]]; then
  # Tier 4: push for WEKA's cold-read ceiling + find cuCIM saturation.
  OPENSLIDE_CELLS=()
  CUCIM_CELLS=()
  # Block G: cuCIM bs=64 at higher N (does scaling continue past N=64?)
  for N in 128 256; do for NW in 4 16; do CUCIM_CELLS+=("$N:$NW:64"); done; done
  # Block H: cuCIM at extreme bs (at peak N=64 nw=16). Tests if bs scaling continues past 64.
  for BS in 128 256; do CUCIM_CELLS+=("64:16:$BS"); done
elif [[ "$TIER" == "tier5" ]]; then
  # Tier 5 (2026-05-15): re-measure key cuCIM CPU configs WITH --sort-batches optimization.
  # Discovered in 2026-05-15 follow-up: sorting tile coords by tile-index within each
  # read_region batch delivers measurable speedup (1.4× at bs=64 from A/B test).
  OPENSLIDE_CELLS=()
  CUCIM_CELLS=()
  # Sweep the key (N, nw, bs) configs from Stage 4.B Tier 1/2/3 where sorting could matter
  # All cells will be invoked with --sort-batches by the per-cell command builder below.
  for N in 1 4 16 64; do CUCIM_CELLS+=("$N:16:64"); done       # bs=64 sweep
  for N in 16 64;   do CUCIM_CELLS+=("$N:4:64");  done       # bs=64 nw=4 to compare against Tier 2 nw=4 winner
  for N in 4 16 64; do CUCIM_CELLS+=("$N:16:4");  done       # bs=4 sweep at peak nw=16
else
  log "FATAL: unsupported tier '$TIER'"
  exit 2
fi
# Tier 5: pass --sort-batches to the reader for cuCIM cells
TIER5_SORT=0
if [[ "$TIER" == "tier5" ]]; then TIER5_SORT=1; fi

# (Tier 3 drop_caches disabled — see Block E comment above.)
TIER3_DROP_CACHES=0

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
for ds_entry in "${DATASETS[@]}"; do
  IFS=':' read -r dataset svs_dir coords_dir <<< "$ds_entry"
  pool_cache="$POOL_CACHE_DIR/${dataset}.pkl"
  if [[ ! -d "$coords_dir" ]]; then
    log "  SKIP: coords dir missing for $dataset: $coords_dir"
    continue
  fi

  # ===== OpenSlide cells =====
  for N in "${OPENSLIDE_CELLS[@]}"; do
    i=$(( i + 1 ))
    # Tier 3: drop caches before OpenSlide cells to expose cold WEKA reads
    if [[ "$TIER3_DROP_CACHES" -eq 1 ]]; then
      log "  dropping kernel page caches (vm.drop_caches=3) for cold-read measurement..."
      sync && sudo sysctl vm.drop_caches=3 2>&1 | tee -a "$SWEEP_LOG"
      sleep 2
    fi
    name="tilesread-${dataset}-openslide-N${N}$([ "$TIER" = "tier3" ] && echo "-cold")"
    latency_csv="$LATENCY_DIR/${name}.csv"
    summary_json="$LATENCY_DIR/${name}.summary.json"
    note="Stage 4.B Tier 1 cell $i/$TOTAL: random tile reads. Backend=openslide (per-tile via multiprocessing.Pool). Dataset=$dataset (full coord pool from CLAM 3.0 n64 outputs). N_processes=$N. LRU(8) slide handle cache per worker. seed=42. runtime=${RUNTIME}s + ${RAMP}s ramp."
    log "=== [cell $i/$TOTAL] $name ==="
    "$REPO/runs/lib/record-run.sh" \
      --run-name "$name" --stage 4.B --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$READER" \
        --backend openslide --n-processes "$N" \
        --svs-dir "$svs_dir" --coords-dir "$coords_dir" \
        --runtime "$RUNTIME" --ramp "$RAMP" \
        --coord-pool-pickle "$pool_cache" \
        --latency-csv "$latency_csv" --summary-json "$summary_json" \
        --seed 42 2>&1 | tee -a "$SWEEP_LOG"

    # Archive per-cell artifacts into the run dir
    RUN_DIR=$(ls -td "$REPO/runs/"*-s4.B-${name} 2>/dev/null | head -1)
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cp "$latency_csv" "$RUN_DIR/per-tile-latencies.csv" 2>/dev/null && log "  archived latencies"
      cp "$summary_json" "$RUN_DIR/reader-summary.json" 2>/dev/null && log "  archived summary"
    fi
    log ""
  done

  # ===== cuCIM batched-CPU cells =====
  for spec in "${CUCIM_CELLS[@]}"; do
    IFS=':' read -r N NW BS <<< "$spec"
    i=$(( i + 1 ))
    sort_tag=""
    sort_flag=()
    if [[ "$TIER5_SORT" -eq 1 ]]; then
      sort_tag="-sorted"
      sort_flag=(--sort-batches)
    fi
    name="tilesread-${dataset}-cucim-N${N}-nw${NW}-bs${BS}${sort_tag}"
    latency_csv="$LATENCY_DIR/${name}.csv"
    summary_json="$LATENCY_DIR/${name}.summary.json"
    note="Stage 4.B $TIER cell $i/$TOTAL: random tile reads. Backend=cucim CPU batched$([ -n "$sort_tag" ] && echo " (with --sort-batches optimization)"). Dataset=$dataset. N_processes=$N, num_workers=$NW (cuCIM C++ thread pool), batch_size=$BS, prefetch_factor=2. LRU(8) slide handle cache per worker. seed=42. runtime=${RUNTIME}s + ${RAMP}s ramp."
    log "=== [cell $i/$TOTAL] $name ==="
    "$REPO/runs/lib/record-run.sh" \
      --run-name "$name" --stage 4.B --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$READER" \
        --backend cucim --n-processes "$N" --num-workers "$NW" --batch-size "$BS" \
        "${sort_flag[@]}" \
        --svs-dir "$svs_dir" --coords-dir "$coords_dir" \
        --runtime "$RUNTIME" --ramp "$RAMP" \
        --coord-pool-pickle "$pool_cache" \
        --latency-csv "$latency_csv" --summary-json "$summary_json" \
        --seed 42 2>&1 | tee -a "$SWEEP_LOG"

    RUN_DIR=$(ls -td "$REPO/runs/"*-s4.B-${name} 2>/dev/null | head -1)
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cp "$latency_csv" "$RUN_DIR/per-tile-latencies.csv" 2>/dev/null && log "  archived latencies"
      cp "$summary_json" "$RUN_DIR/reader-summary.json" 2>/dev/null && log "  archived summary"
    fi
    log ""
  done
done

log "=== sweep done ==="
log "review:  cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "aggregate next: runs/lib/aggregate-stage4b-tilesread.py 'runs/2026-*-s4.B-tilesread-*'"
