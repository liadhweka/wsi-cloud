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
#   - Tier 1 isolates the dominant axis (n_buffer = pipelining depth) and answers
#     the GDS-vs-POSIX question per n_buffer; pre-flight already showed n_buffer
#     is the strongest knob.
#   - Tier 2 explores secondary axes (task_size, num_threads, preregister) and
#     introduces the multi-process scaling cells that drive the customer
#     multi-GPU-DataLoader story.
#   - Tier 3 is conditional on Tier 1+2 not bottlenecking WEKA. Same pattern as
#     Stage 4.B's tiered design.
#
# WHY BRCA-only for Tier 1:
#   - Both datasets converged within ~3% in Stage 4.B at peak configs; the
#     kvikIO+GDS path doesn't care about JPEG-decode cost (it's reading raw
#     uncompressed bytes); cross-dataset validation deferred to Tier 2 saves
#     ~50% of Tier 1 wallclock for marginal extra info.
#
# Every cell measures BOTH GDS-on (compat_mode=off) AND POSIX-compat
# (compat_mode=on) so the GDS speedup is characterized at every config.
#
# Required env (set by this script):
#   CUFILE_ENV_PATH_JSON → /home/liadhermelin/wsi-debug/p1-gdsio/cufile-full-rdma.json
#   LD_PRELOAD           → /usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0
#   CONDA_PREFIX         → /data/local-nvme/conda-envs/wsi-cucim-2604
#   CUDA_VISIBLE_DEVICES → 2 (single-GPU for Tier 1/2 main sweep; GPU 2 = NUMA-0,
#                            IB-adjacent per project_a100_state.md)
#
# Usage:
#   ./sweep-stage4c-kvikio.sh tier1               # run all Tier 1 cells
#   ./sweep-stage4c-kvikio.sh tier1 1             # smoke (single cell)
#   ./sweep-stage4c-kvikio.sh tier2               # Tier 2 cells (after Tier 1)
#   ./sweep-stage4c-kvikio.sh tier3               # Tier 3 conditional
set -uo pipefail

REPO=/home/liadhermelin/wsi/rerun_new_TRUERESULTS
CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604
PY="$CONDA_ENV/bin/python"
READER="$REPO/runs/lib/read-tiles-kvikio.py"
RECORD="$REPO/runs/lib/record-run.sh"

LIBCUFILE_117=/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0
CUFILE_JSON=/home/liadhermelin/wsi-debug/p1-gdsio/cufile-full-rdma.json

# Sanity checks
[ -f "$LIBCUFILE_117" ] || { echo "missing libcufile 1.17 at $LIBCUFILE_117" >&2; exit 1; }
[ -f "$CUFILE_JSON" ] || { echo "missing corrected cufile.json at $CUFILE_JSON" >&2; exit 1; }
[ -f "$READER" ] || { echo "missing reader script at $READER" >&2; exit 1; }
[ -x "$RECORD" ] || { echo "missing or non-exec record-run.sh at $RECORD" >&2; exit 1; }

BRCA_RAWTIFF=/mnt/liad/data/tcga-brca-rawtiff
CAM_RAWTIFF=/mnt/liad/data/camelyon16-rawtiff
BRCA_MANIFEST=$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv
CAM_MANIFEST=$REPO/runs/manifests/camelyon16-stage4a-subset.tsv
BRCA_COORDS=/mnt/liad/tissue-detection/3.0/tcga-brca/n64/patches
CAM_COORDS=/mnt/liad/tissue-detection/3.0/camelyon16/n64/patches

# Single-GPU pinning for the bulk of Tier 1/2 cells. Multi-process scaling cells
# override this.
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-2}"
export CONDA_PREFIX="$CONDA_ENV"
export CUFILE_ENV_PATH_JSON="$CUFILE_JSON"
export LD_PRELOAD="$LIBCUFILE_117"

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

  local note="Stage 4.C ${mode} mode. dataset=${dataset} compat_mode=${compat} n_buffer=${n_buffer} num_threads=${num_threads}. LD_PRELOAD=libcufile-1.17, CUFILE_ENV_PATH_JSON=corrected (6 IPs, allow_compat_mode), single GPU=${CUDA_VISIBLE_DEVICES}. 4096-byte aligned reads via NVIDIA's _get_aligned_read_props. Cold cache via cucim discard_page_cache between slides (faithful) / on first LRU fill (random). Reader: $READER. Extra: $*"

  # Per-cell summary file inside the run dir is written via the --summary-json
  # arg below; we point it inside the run dir after record-run.sh creates it.
  # record-run.sh's actual dir is $RUNS_ROOT/$TS-s$STAGE-$RUN_NAME.
  local now_utc
  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-s4.C-${run_name}"

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

  "$RECORD" \
    --run-name "$run_name" \
    --stage 4.C \
    --note "$note" \
    -- "$PY" "$READER" "${reader_args[@]}"
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
  # Designed from Tier 1 results: peak random GDS-on nb=256 = 24,376 tiles/sec / 4.89 GB/s.
  # Tier 2 fixes the peak config and sweeps secondary knobs.
  # Multi-process scaling (subblock e) handled separately in tier2_mp() below — it
  # needs a wrapper script that launches N python processes in parallel.

  local PEAK_NB=256
  local PEAK_NT=16

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
# GPU assignment (NUMA-aware per locked decision Q3):
#   N=1 → GPU 2 (NUMA-0, IB-adjacent)
#   N=2 → GPU 2, 3 (both NUMA-0)
#   N=4 → GPU 2, 3, 6, 7 (NUMA-0 + NUMA-2)
#   N=8 → all 8 GPUs (deferred to Tier 3 if needed)
tier2_mp() {
  echo "=== Stage 4.C Tier 2 (e) — multi-process scaling for 4.C.2 random mode ==="

  local PEAK_NB=256
  local PEAK_NT=16
  local WRAPPER="$REPO/runs/lib/run-multiproc-kvikio.sh"
  if [ ! -x "$WRAPPER" ]; then
    echo "missing multi-process wrapper $WRAPPER — write it first" >&2
    return 2
  fi

  # GPU assignment per N
  declare -A GPUS_FOR_N=([1]="2" [2]="2,3" [4]="2,3,6,7")

  for N in 1 2 4; do
    local gpus="${GPUS_FOR_N[$N]}"
    for compat in off on; do
      local run_name="random-brca-N${N}-nb${PEAK_NB}-nt${PEAK_NT}-${compat}gds-mp"
      local note="Stage 4.C Tier 2 (e) multi-process scaling. N=${N} parallel Python processes, each on a different GPU (CUDA_VISIBLE_DEVICES split). GPUs used: ${gpus}. random mode, BRCA, n_buffer=${PEAK_NB}, num_threads=${PEAK_NT}, compat_mode=${compat}. WHY: this is the load-bearing customer-multi-GPU-DataLoader cell — answers 'can the kvikIO+GDS+raw-TIFF path scale past single-process for an N-GPU training pipeline?' Wrapper: $WRAPPER."
      local now_utc
      now_utc=$(date -u +%Y-%m-%d-%H%M%S)
      local run_dir="$REPO/runs/${now_utc}-s4.C-${run_name}"
      echo ""
      echo "=========================================="
      echo "[$now_utc] mp cell: $run_name  (gpus=$gpus)"
      echo "=========================================="
      "$RECORD" \
        --run-name "$run_name" --stage 4.C --note "$note" \
        -- "$WRAPPER" "$N" "$gpus" "$compat" "$PEAK_NB" "$PEAK_NT" "$run_dir"
    done
  done
}

tier3() {
  echo "=== Stage 4.C Tier 3 — ceiling stress + cross-dataset multi-process ==="
  # Tier 2 found WEKA saturates around 5.36 GB/s at N=2-4 (BRCA random GDS-on).
  # Tier 3 confirms with N=8 across all 8 GPUs (full NUMA spread), and adds
  # CAM16 N=4 cells for cross-dataset multi-process validation.

  local PEAK_NB=256
  local PEAK_NT=16
  local WRAPPER="$REPO/runs/lib/run-multiproc-kvikio.sh"

  # ---- N=8 BRCA full NUMA spread (definitive ceiling stress) ----
  for compat in off on; do
    local run_name="random-brca-N8-nb${PEAK_NB}-nt${PEAK_NT}-${compat}gds-mp"
    local note="Stage 4.C Tier 3 — N=8 multi-process scaling, BRCA, all 8 GPUs spread NUMA-aware. WHY: Tier 2 found N=4 hits WEKA ceiling (~5.36 GB/s, matching Stage 1.0d synthetic 5.25 GB/s); N=8 confirms multi-process+multi-NUMA doesn't extract more from the single client."
    local now_utc
    now_utc=$(date -u +%Y-%m-%d-%H%M%S)
    local run_dir="$REPO/runs/${now_utc}-s4.C-${run_name}"
    echo ""
    echo "=========================================="
    echo "[$now_utc] tier3 cell: $run_name (gpus=0,1,2,3,4,5,6,7)"
    echo "=========================================="
    "$RECORD" \
      --run-name "$run_name" --stage 4.C --note "$note" \
      -- "$WRAPPER" 8 "0,1,2,3,4,5,6,7" "$compat" "$PEAK_NB" "$PEAK_NT" "$run_dir"
  done

  # ---- N=4 CAM16 (cross-dataset multi-process) ----
  for compat in off on; do
    local run_name="random-cam16-N4-nb${PEAK_NB}-nt${PEAK_NT}-${compat}gds-mp"
    local note="Stage 4.C Tier 3 — N=4 multi-process scaling, CAMELYON16, NUMA-aware GPU spread (2,3,6,7). Cross-dataset cross-check of Tier 2 (e) BRCA results."
    local now_utc
    now_utc=$(date -u +%Y-%m-%d-%H%M%S)
    local run_dir="$REPO/runs/${now_utc}-s4.C-${run_name}"
    # NOTE: the wrapper currently hardcodes BRCA paths. We need a CAM16 variant
    # or to parameterize it. For now we'll write a CAM16 wrapper inline.
    "$RECORD" \
      --run-name "$run_name" --stage 4.C --note "$note" \
      -- env DATASET=cam16 "$WRAPPER" 4 "2,3,6,7" "$compat" "$PEAK_NB" "$PEAK_NT" "$run_dir"
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
