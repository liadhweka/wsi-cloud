#!/usr/bin/env bash
# Stage 4.C sweep driver — kvikIO + raw TIFF + (optional) GDS.
#
# Tiered structure mirroring Stage 4.B's sweep design:
#   Tier 1 (saturation): n_buffer sweep × 2 GDS modes × 2 methodology modes × BRCA  = 20 cells
#   Tier 2 (bottleneck): cross-dataset + task_size + num_threads + preregister
#                        + multi-process scaling (4.C.2 only)                       ≈ 30 cells
#   Tier 3 (ceiling stress, conditional)                                            ≈ 6-10 cells
#
# WHY this structure:
#   - Tier 1 isolates the pipelining-depth axis (n_buffer) and answers the
#     GDS-vs-compat question at each depth, so the mode comparison is not read off
#     a single arbitrary configuration.
#   - Tier 2 explores secondary axes (task_size, num_threads, preregister) and
#     introduces the multi-process scaling cells, which answer whether the
#     GPU-direct path scales past a single process for an N-GPU pipeline.
#   - Tier 3 is conditional on Tier 1+2 not bottlenecking the filesystem. Same pattern as
#     Stage 4.B's tiered design.
#
# WHY BRCA-only for Tier 1:
#   - The kvikIO path reads raw uncompressed bytes, so it is insensitive to the
#     JPEG-decode cost that distinguishes the two datasets in 4.B; deferring
#     cross-dataset validation to Tier 2 roughly halves Tier 1 wallclock. Whether
#     the datasets in fact converge here is measured in Tier 2, not assumed.
#
# Every cell measures BOTH GDS-on (compat_mode=off) AND POSIX-compat
# (compat_mode=on) so the GDS speedup is characterized at every config.
#
# Required env (read by this script; every value is instance-specific — ⏳ D-10):
#   CUFILE_ENV_PATH_JSON → $CUFILE_ENV_PATH_JSON
#   LD_PRELOAD           → $LIBCUFILE_PRELOAD (the SYSTEM libcufile matched to nvidia-fs)
#   CONDA_PREFIX         → $CONDA_ENVS_DIR/$CONDA_ENV_MAIN
#   CUDA_VISIBLE_DEVICES → single GPU for the Tier 1/2 main sweep. ⏳ D-8: pick the
#                            NIC-adjacent GPU from the topology map re-derived on
#                            this instance; the index below is a placeholder.
#
# Usage:
#   ./sweep-stage4c-kvikio.sh tier1               # run all Tier 1 cells
#   ./sweep-stage4c-kvikio.sh tier1 1             # smoke (single cell)
#   ./sweep-stage4c-kvikio.sh tier2               # Tier 2 cells (after Tier 1)
#   ./sweep-stage4c-kvikio.sh tier3               # Tier 3 conditional
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
READER="$REPO/scripts/read-tiles-kvikio.py"
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
[ -f "$CUFILE_JSON" ] || { echo "missing corrected cufile.json at $CUFILE_JSON" >&2; exit 1; }
[ -f "$READER" ] || { echo "missing reader script at $READER" >&2; exit 1; }
[ -x "$RECORD" ] || { echo "missing or non-exec record-run.sh at $RECORD" >&2; exit 1; }
FAILED_CELLS=0

BRCA_RAWTIFF=${FS_MOUNT}/data/tcga-brca-rawtiff
CAM_RAWTIFF=${FS_MOUNT}/data/camelyon16-rawtiff
BRCA_MANIFEST=$REPO/scripts/manifests/tcga-brca-stage4a-subset.tsv
CAM_MANIFEST=$REPO/scripts/manifests/camelyon16-stage4a-subset.tsv
BRCA_COORDS=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches
CAM_COORDS=${FS_MOUNT}/tissue-detection/3.0/camelyon16/n64/patches

# Single-GPU pinning for the bulk of Tier 1/2 cells. Multi-process scaling cells
# override this.
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"   # ⏳ D-8: NIC-adjacent GPU TBD
export CONDA_PREFIX="$CONDA_ENV"
export CUFILE_ENV_PATH_JSON="$CUFILE_JSON"
export LD_PRELOAD="$LIBCUFILE_SYSTEM"

# Build a cell name + invoke record-run.sh + reader.
#   args: mode (faithful|random), dataset (brca|cam16), compat (off|on),
#         n_buffer, num_threads, [extra reader args ...]
run_cell() {
  local mode="$1"; shift
  local dataset="$1"; shift
  local compat="$1"; shift
  local n_buffer="$1"; shift
  local num_threads="$1"; shift
  local extra_label="$1"; shift   # short tag to embed in the run name; e.g. ""  or "ts1m"
  # remaining args = extra reader CLI args

  local rawtiff_dir manifest coords_dir
  case "$dataset" in
    brca)  rawtiff_dir="$BRCA_RAWTIFF"; manifest="$BRCA_MANIFEST"; coords_dir="$BRCA_COORDS";;
    cam16) rawtiff_dir="$CAM_RAWTIFF"; manifest="$CAM_MANIFEST"; coords_dir="$CAM_COORDS";;
    *) echo "unknown dataset: $dataset" >&2; return 2;;
  esac

  local extra=""
  [ -n "$extra_label" ] && extra="-$extra_label"
  # NOTE: record-run.sh auto-prefixes the run dir with "s${STAGE}-" so we do
  # NOT include "s4.C-" in $run_name (would produce s4.C-s4.C-... double-prefix).
  local run_name="${mode}-${dataset}-nb${n_buffer}-nt${num_threads}-${compat}gds${extra}"

  local note="Stage 4.C ${mode} mode on fs=${LEG}. dataset=${dataset} compat_mode=${compat} n_buffer=${n_buffer} num_threads=${num_threads}. LD_PRELOAD=${LD_PRELOAD}, CUFILE_ENV_PATH_JSON=${CUFILE_ENV_PATH_JSON}, single GPU=${CUDA_VISIBLE_DEVICES}. 4096-byte aligned reads via NVIDIA's _get_aligned_read_props. Cold cache via cucim discard_page_cache between slides (faithful) / on first LRU fill (random). Reader: $READER. Extra: $*"

  # Per-cell summary file inside the run dir is written via the --summary-json
  # arg below; we point it inside the run dir after record-run.sh creates it.
  # record-run.sh's actual dir is $RUNS_ROOT/$TS-s$STAGE-$RUN_NAME.
  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s4.C-${run_name}"

  local reader_args=(
    --mode "$mode"
    --rawtiff-dir "$rawtiff_dir"
    --manifest "$manifest"
    --compat-mode "$compat"
    --n-buffer "$n_buffer"
    --num-threads "$num_threads"
    --summary-json "$run_dir/reader-summary.json"
  )
  if [ "$mode" = "random" ]; then
    reader_args+=( --coords-dir "$coords_dir"
                   --latency-csv "$run_dir/per-tile-latencies.csv" )
  fi
  reader_args+=( "$@" )

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $run_name"
  echo "  reader cmd: $PY $READER ${reader_args[*]}"
  echo "=========================================="

  RECORD_RUN_DIR="$run_dir" \
  RECORD_KVIKIO_CELL=1 \
  "$RECORD" \
    --run-name "$run_name" \
    --stage 4.C \
    --note "$note" \
    -- "$PY" "$READER" "${reader_args[@]}"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

tier1() {
  local smoke_only="${1:-}"
  echo "=== Stage 4.C Tier 1 — saturation curve (n_buffer × GDS × mode × BRCA) ==="
  local n_buffers="1 4 16 64 256"
  local modes="faithful random"
  local compats="off on"

  if [ "$smoke_only" = "1" ]; then
    # Smoke = one faithful cell at the peak preflight config + one random cell same
    run_cell faithful brca off 256 16 "" --level 0
    run_cell random   brca off 256 16 "" --level 0 --runtime 60 --ramp 10
    return
  fi

  for mode in $modes; do
    for compat in $compats; do
      for nb in $n_buffers; do
        if [ "$mode" = "random" ]; then
          run_cell "$mode" brca "$compat" "$nb" 16 "" --level 0 --runtime 60 --ramp 10
        else
          run_cell "$mode" brca "$compat" "$nb" 16 "" --level 0
        fi
      done
    done
  done
}

tier2() {
  echo "=== Stage 4.C Tier 2 — bottleneck characterization ==="
  # Tier 2 pins the peak (n_buffer, n_threads) at THIS leg's Tier-1 knee. The
  # peak is a per-leg measured result, not a constant: read PEAK_NB / PEAK_NT
  # from the environment, refuse when unset.
  if [ -z "${PEAK_NB:-}" ] || [ -z "${PEAK_NT:-}" ]; then
    echo "FATAL: PEAK_NB/PEAK_NT unset — set them from this leg's Tier-1 knee before tier2 runs." >&2
    exit 2
  fi
  # Multi-process scaling (subblock e) handled separately in tier2_mp() below — it
  # needs a wrapper script that launches N python processes in parallel.

  # ---- (a) Cross-dataset validation at peak n_buffer ----
  # WHY: Tier 1 was BRCA only; need to verify CAM16 doesn't diverge unexpectedly.
  # Both modes × 2 GDS × CAM16 = 4 cells.
  echo "--- Tier 2 (a) cross-dataset validation at peak ---"
  for mode in faithful random; do
    for compat in off on; do
      local extra_args=()
      [ "$mode" = "random" ] && extra_args+=(--level 0 --runtime 60 --ramp 10)
      [ "$mode" = "faithful" ] && extra_args+=(--level 0)
      run_cell "$mode" cam16 "$compat" "$PEAK_NB" "$PEAK_NT" "" "${extra_args[@]}"
    done
  done

  # ---- (b) kvikio.task_size sensitivity ----
  # WHY: NVIDIA's benchmark_read.py varies task_size {64 KB, 256 KB, 1 MB, 4 MB}.
  # The default is 4 MB; smaller task sizes break reads into more pieces (more
  # async ops, potentially better pipelining for many small reads).
  # 4 task sizes × 2 GDS × 1 dataset (BRCA, random mode at peak nb) = 8 cells.
  echo "--- Tier 2 (b) task_size sensitivity ---"
  for ts_bytes in 65536 262144 1048576 4194304; do
    for compat in off on; do
      local tag="ts$(numfmt --to=iec --suffix= "$ts_bytes" 2>/dev/null | tr -d ' ' || echo "$ts_bytes")"
      run_cell random brca "$compat" "$PEAK_NB" "$PEAK_NT" "$tag" \
        --level 0 --runtime 60 --ramp 10 --task-size "$ts_bytes"
    done
  done

  # ---- (c) num_threads sensitivity ----
  # WHY: kvikIO's internal thread pool handles the async preads. Tier 1 fixed
  # nt=16. Sweeping {4, 8, 32} (nt=16 already done in Tier 1) shows how the
  # thread pool size affects throughput at peak n_buffer.
  # 3 thread counts × 2 GDS × 1 dataset (BRCA) = 6 cells.
  echo "--- Tier 2 (c) num_threads sensitivity (nt=16 already in Tier 1) ---"
  for nt in 4 8 32; do
    for compat in off on; do
      run_cell random brca "$compat" "$PEAK_NB" "$nt" "" \
        --level 0 --runtime 60 --ramp 10
    done
  done

  # ---- (d) memory pre-registration ----
  # WHY: kvikio.memory_register(buf) pre-pins the GPU buffer for DMA, eliminating
  # per-call pinning overhead. NVIDIA's reference code supports this as a toggle.
  # 2 cells (preregister ON × 2 GDS; preregister OFF already covered in Tier 1).
  echo "--- Tier 2 (d) memory pre-registration ---"
  for compat in off on; do
    run_cell random brca "$compat" "$PEAK_NB" "$PEAK_NT" "prereg" \
      --level 0 --runtime 60 --ramp 10 --preregister
  done

  echo ""
  echo "=== Tier 2 single-process subblocks done. Multi-process scaling (subblock e) is in tier2_mp(). ==="
}

# Multi-process scaling cells. Runs N parallel Python processes, each with its
# own GPU and writing its own per-process summary. record-run.sh wraps the
# whole parallel-process group as one cell. Post-aggregation sums the per-process
# tiles/sec to get the cell-aggregate.
#
# GPU assignment: the map below is the identity list for this instance's GPU count,
# and must be re-derived here rather than carried over. A list from another machine
# names indices that may not exist, and CUDA_VISIBLE_DEVICES drops unknown indices
# silently rather than erroring -- so the cell runs at less than N-way width while
# reporting a scaling number as though it had them all. Adjacency criteria are also
# per-machine: this instance's data path is DPDK over ENA, not IB.
tier2_mp() {
  echo "=== Stage 4.C Tier 2 (e) — multi-process scaling for 4.C.2 random mode ==="

  # Tier 2 pins the peak (n_buffer, n_threads) at THIS leg's Tier-1 knee. The
  # peak is a per-leg measured result, not a constant: read PEAK_NB / PEAK_NT
  # from the environment, refuse when unset.
  if [ -z "${PEAK_NB:-}" ] || [ -z "${PEAK_NT:-}" ]; then
    echo "FATAL: PEAK_NB/PEAK_NT unset — set them from this leg's Tier-1 knee before tier2 runs." >&2
    exit 2
  fi
  local WRAPPER="$REPO/scripts/run-multiproc-kvikio.sh"
  if [ ! -x "$WRAPPER" ]; then
    echo "missing multi-process wrapper $WRAPPER — write it first" >&2
    return 2
  fi

  # GPU assignment per N
  declare -A GPUS_FOR_N=([1]="0" [2]="0,1" [4]="0,1,2,3")   # ⏳ D-8: NUMA/NIC-aware order TBD

  for N in 1 2 4; do
    local gpus="${GPUS_FOR_N[$N]}"
    for compat in off on; do
      local run_name="random-brca-N${N}-nb${PEAK_NB}-nt${PEAK_NT}-${compat}gds-mp"
      local note="Stage 4.C Tier 2 (e) multi-process scaling. N=${N} parallel Python processes, each on a different GPU (CUDA_VISIBLE_DEVICES split). GPUs used: ${gpus}. random mode, BRCA, n_buffer=${PEAK_NB}, num_threads=${PEAK_NT}, compat_mode=${compat}. WHY: this is the load-bearing customer-multi-GPU-DataLoader cell — answers 'can the kvikIO+GDS+raw-TIFF path scale past single-process for an N-GPU training pipeline?' Wrapper: $WRAPPER."
      local now_utc
      now_utc=$(date -u +%Y-%m-%d-%H%M%S)
      local run_dir="$REPO/runs/${now_utc}-${LEG}-s4.C-${run_name}"
      echo ""
      echo "=========================================="
      echo "[$now_utc] mp cell: $run_name  (gpus=$gpus)"
      echo "=========================================="
      RECORD_RUN_DIR="$run_dir" \
      "$RECORD" \
        --run-name "$run_name" --stage 4.C --note "$note" \
        -- "$WRAPPER" "$N" "$gpus" "$compat" "$PEAK_NB" "$PEAK_NT" "$run_dir"
      _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
    done
  done
}

tier3() {
  echo "=== Stage 4.C Tier 3 — ceiling stress + cross-dataset multi-process ==="
  # Tier 3 is the CONDITIONAL ceiling-stress tier (Stage-4-Patching.md § 4.C): push
  # process count past Tier 2's peak until the filesystem-side read plateaus. The
  # instance has 4 GPUs, so "more processes" means OVERSUBSCRIBING them (8 procs
  # across 4 GPUs), not more GPUs. Plus CAM16 at the full GPU count for a
  # cross-dataset multi-process cross-check.
  # ⏳ D-8: the process→GPU mapping below is round-robin over 0-3; substitute the
  # NUMA/NIC-aware order once the topology map is derived on this instance.

  local WRAPPER="$REPO/scripts/run-multiproc-kvikio.sh"

  # ---- N=8 BRCA full NUMA spread (definitive ceiling stress) ----
  for compat in off on; do
    local run_name="random-brca-N8over4-nb${PEAK_NB}-nt${PEAK_NT}-${compat}gds-mp"
    local note="Stage 4.C Tier 3 on fs=${LEG} — ceiling stress: 8 reader processes oversubscribed across the instance's 4 GPUs, BRCA, compat_mode=${compat}. WHY: Tier 2 sweeps multi-process scaling up to one process per GPU; this cell asks whether adding processes beyond that extracts any more from a single client, or whether the plateau is the client rather than the filesystem. Compare against the block-size-matched Stage 1.0 ceiling for this leg. ⏳ D-8: process→GPU pinning order to be re-derived."
    local now_utc
    now_utc=$(date -u +%Y-%m-%d-%H%M%S)
    local run_dir="$REPO/runs/${now_utc}-${LEG}-s4.C-${run_name}"
    echo ""
    echo "=========================================="
    echo "[$now_utc] tier3 cell: $run_name (8 procs over gpus 0,1,2,3)"
    echo "=========================================="
    RECORD_RUN_DIR="$run_dir" \
    "$RECORD" \
      --run-name "$run_name" --stage 4.C --note "$note" \
      -- "$WRAPPER" 8 "0,1,2,3,0,1,2,3" "$compat" "$PEAK_NB" "$PEAK_NT" "$run_dir"
    _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
  done

  # ---- N=4 CAM16 (cross-dataset multi-process) ----
  for compat in off on; do
    local run_name="random-cam16-N4-nb${PEAK_NB}-nt${PEAK_NT}-${compat}gds-mp"
    local note="Stage 4.C Tier 3 on fs=${LEG} — N=4 multi-process scaling, CAMELYON16, one process per GPU, compat_mode=${compat}. WHY: cross-dataset cross-check of the Tier 2 multi-process BRCA cells — a scanner-vendor difference in tile layout would show up here. ⏳ D-8: GPU pinning order to be re-derived."
    local now_utc
    now_utc=$(date -u +%Y-%m-%d-%H%M%S)
    local run_dir="$REPO/runs/${now_utc}-${LEG}-s4.C-${run_name}"
    RECORD_RUN_DIR="$run_dir" \
    "$RECORD" \
      --run-name "$run_name" --stage 4.C --note "$note" \
      -- env DATASET=cam16 "$WRAPPER" 4 "0,1,2,3" "$compat" "$PEAK_NB" "$PEAK_NT" "$run_dir"
    _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
  done
}

case "${1:-}" in
  tier1)    tier1 "${2:-}";;
  tier2)    tier2;;
  tier2_mp) tier2_mp;;
  tier3)    tier3;;
  smoke)    tier1 1;;
  *) echo "usage: $0 {tier1 [smoke]|tier2|tier2_mp|tier3|smoke}" >&2; exit 2;;
esac

if (( FAILED_CELLS > 0 )); then
  echo "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation)," >&2
  echo "        and this exit tells the chain a hole exists rather than letting the step be marked done." >&2
  exit 1
fi
