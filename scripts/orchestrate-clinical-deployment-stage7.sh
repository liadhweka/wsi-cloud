#!/usr/bin/env bash
# Stage 7 Clinical-Deployment multi-workload orchestrator.
#
# Mirrors the Stage 6.C orchestrator pattern (barrier-file synchronized start,
# per-workload subshells, kill-on-deadline + setsid pgid termination, awk %.6f
# for epoch arithmetic) — but the four workloads here model the CLINICAL
# INFERENCE deployment mix (per Stage 7 roadmap Q11) rather than the training
# mix:
#
#   inference      — N concurrent inference-per-slide-stage7 processes
#                    (per-process bs scales DOWN as N rises per Q8 revision:
#                     N=1/4 → bs=256; N=16 → bs=64; N=64 → bs=16)
#   heatmap-viewer — fio bs=4K random reads on heatmap output dir (the
#                    "pathologist views heatmaps that just landed" workload)
#   ingest         — fpsync n=4 (Stage 1.5 / 6.C pattern; scanner pace)
#   viewer         — fio bs=4K random reads on canonical SVS (Stage 1.6 / 6.C
#                    pattern; pathologist viewing original slides)
#
# Used for sub-tier 7.2 (inference-only at varying N) and sub-tier 7.5 (all-four
# mixed clinical deployment + 4-hr endurance). 7.1 / 7.3 / 7.4 / 7.6 invoke the
# inference worker directly from the sweep driver (single-process cells).
#
# Per-workload telemetry CSVs (in run-dir):
#   workload-inference.<proc>.csv         — per-process per-slide latency
#   per-slide-inference-latencies.csv      — merged across N processes (post-cell)
#   per-slide-heatmap-writes.csv           — merged across N processes (post-cell)
#   workload-heatmap-viewer.csv            — fio json+ status-interval timeline
#   workload-ingest.csv                    — du -sb timeline on ingest target
#   workload-viewer.csv                    — fio json+ status-interval timeline
#
# Time-bounding: each workload polls a per-cell deadline = t0 + ramp + runtime
# and exits cleanly (sends SIGTERM to its pgid via setsid). Awk %.6f for epoch
# arithmetic (default %.6g emits
# scientific notation that breaks bash lex compare).
#
# Usage (typically invoked by sweep-stage7-clinical.sh):
#   ./orchestrate-clinical-deployment-stage7.sh \
#     --workloads "inference" --n-concurrent 4 --inference-batch-size 256 \
#     --runtime 1500 --ramp 300 --run-dir <run-dir>
#
#   ./orchestrate-clinical-deployment-stage7.sh \
#     --workloads "inference,ingest,heatmap-viewer,viewer" --n-concurrent 4 \
#     --inference-batch-size 256 --runtime 1500 --ramp 300 --run-dir <run-dir>
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
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
INFER_WORKER="$REPO/scripts/inference-per-slide-stage7.py"

# Defaults (override via env or CLI)
INFER_MODEL="${INFER_MODEL:-virchow2}"
INFER_BACKEND="${INFER_BACKEND:-kvikio}"
INFER_CACHE_POLICY="${INFER_CACHE_POLICY:-warm}"
INFER_HEATMAP_FORMAT="${INFER_HEATMAP_FORMAT:-tiff5x}"
INFER_MANIFEST="${INFER_MANIFEST:-$REPO/scripts/manifests/tcga-brca-stage4a-subset.tsv}"
INFER_COORDS_DIR="${INFER_COORDS_DIR:-${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches}"
INFER_RAWTIFF_DIR="${INFER_RAWTIFF_DIR:-${FS_MOUNT}/data/tcga-brca-rawtiff}"
INFER_SVS_DIR="${INFER_SVS_DIR:-${FS_MOUNT}/data/tcga-brca}"

INGEST_N="${INGEST_N:-4}"
INGEST_SRC="${INGEST_SRC:-${SCRATCH_DIR:?SCRATCH_DIR is unset -- source env.sh}/fpsync-source/tcga-brca}"
INGEST_DST="${INGEST_DST:-${FS_MOUNT}/runs-stage7-ingest-target}"
VIEWER_N="${VIEWER_N:-4}"
VIEWER_SCRATCH="${VIEWER_SCRATCH:-${FS_MOUNT}/benchmarks/fio-scratch-7-viewer}"
HEATMAP_VIEWER_N="${HEATMAP_VIEWER_N:-4}"
HEATMAP_VIEWER_DIR="${HEATMAP_VIEWER_DIR:-${FS_MOUNT}/heatmaps/7.5/viewer-scratch}"

# Args
WORKLOADS=""
N_CONCURRENT="${N_CONCURRENT:-4}"
INFERENCE_BATCH_SIZE="${INFERENCE_BATCH_SIZE:-256}"
RUNTIME=""
RAMP=""
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workloads)            WORKLOADS="$2"; shift 2 ;;
    --n-concurrent)         N_CONCURRENT="$2"; shift 2 ;;
    --inference-batch-size) INFERENCE_BATCH_SIZE="$2"; shift 2 ;;
    --runtime)              RUNTIME="$2"; shift 2 ;;
    --ramp)                 RAMP="$2"; shift 2 ;;
    --run-dir)              RUN_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$WORKLOADS" ] && { echo "missing --workloads" >&2; exit 2; }
[ -z "$RUNTIME" ]   && { echo "missing --runtime" >&2; exit 2; }
[ -z "$RAMP" ]      && { echo "missing --ramp" >&2; exit 2; }
[ -z "$RUN_DIR" ]   && { echo "missing --run-dir" >&2; exit 2; }
[ -f "$INFER_WORKER" ] || { echo "missing $INFER_WORKER" >&2; exit 1; }

mkdir -p "$RUN_DIR"
BARRIER="$RUN_DIR/.start-barrier"
ORCH_LOG="$RUN_DIR/orchestration.log"
READY_DIR="$RUN_DIR/.ready"
mkdir -p "$READY_DIR"

echo "[orch] $(date -u +%FT%TZ) starting" | tee "$ORCH_LOG"
echo "[orch] workloads=$WORKLOADS n_concurrent=$N_CONCURRENT inference_bs=$INFERENCE_BATCH_SIZE" | tee -a "$ORCH_LOG"
echo "[orch] model=$INFER_MODEL backend=$INFER_BACKEND cache=$INFER_CACHE_POLICY heatmap_format=$INFER_HEATMAP_FORMAT" | tee -a "$ORCH_LOG"
echo "[orch] ramp=${RAMP}s runtime=${RUNTIME}s" | tee -a "$ORCH_LOG"

PIDS=()

# GPU map for N concurrent inference processes. N greater than the instance's GPU
# count deliberately OVERSUBSCRIBES them — which is the point of the
# high-concurrency Stage 7.2 cells: they measure storage and queueing, not GPU
# throughput.
# ⏳ D-8: this is plain round-robin over 0..N_GPU_TOTAL-1. Substitute the
# NUMA/NIC-aware ordering once the topology map is derived on the real instance; on
# the previous hardware the pinning order measurably mattered for the GPU-direct
# path, so it is expected to matter here too — but the map itself must be
# re-derived, never copied.
#
# ── Guard: the GPU count is read from the instance, not assumed ──────────────────
# A hardcoded default is a hardware fact baked into a script that outlives the
# instance it was written for. Set too low, gpu_for_proc round-robins over a subset
# and the remaining GPUs sit idle while the cell reports a complete per-slide
# latency set for a layout nobody chose. Set too high, CUDA_VISIBLE_DEVICES is
# handed an index that does not exist and silently DROPS it rather than erroring.
# Both produce a plausible number, and nothing downstream can detect either. So:
# default to what is actually present, and refuse an explicit override above it.
_n_gpus_present="$(nvidia-smi -L 2>/dev/null | wc -l)"
if [ "${_n_gpus_present:-0}" -eq 0 ]; then
  echo "FATAL: no GPUs visible (nvidia-smi -L returned nothing) -- Stage 7 runs inference on GPU." >&2
  exit 1
fi
N_GPU_TOTAL="${N_GPU_TOTAL:-$_n_gpus_present}"
if ! [[ "$N_GPU_TOTAL" =~ ^[1-9][0-9]*$ ]] || [ "$N_GPU_TOTAL" -gt "$_n_gpus_present" ]; then
  echo "FATAL: N_GPU_TOTAL='$N_GPU_TOTAL', but this instance has $_n_gpus_present GPU(s)" >&2
  echo "       (valid indices 0..$((_n_gpus_present - 1)))." >&2
  echo "       gpu_for_proc would hand CUDA_VISIBLE_DEVICES an index that does not exist;" >&2
  echo "       it is dropped silently and the cell reports latencies for a GPU layout" >&2
  echo "       nobody chose. Unset N_GPU_TOTAL to use what is present." >&2
  exit 1
fi
gpu_for_proc() {
  local proc_id="$1"; local n="$2"
  echo $(( proc_id % N_GPU_TOTAL ))
}

# ---------- Workload: inference (N concurrent inference-per-slide processes) -
workload_inference() {
  local log="$RUN_DIR/workload-inference.log"
  local heatmap_dir="$RUN_DIR/heatmaps"
  local infer_barrier="$RUN_DIR/.inference-start-barrier"
  echo "[inference] init N=$N_CONCURRENT bs=$INFERENCE_BATCH_SIZE" >> "$log"
  mkdir -p "$heatmap_dir"
  touch "$READY_DIR/.inference-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done

  # Spawn N inference processes — each gets its own GPU, process_id, CSV files.
  # Each worker --max-runtime-s is set to ramp+runtime (NOT minus startup); the
  # workers wait at --start-barrier-file before entering their slide loop, so
  # the deadline clock starts AFTER all models are loaded. This matters mostly
  # for short cells (smoke); for production 25-min Tier 2 cells the startup is
  # noise — a cell can otherwise time out during model load.
  local proc_pids=()
  for ((i=0; i<N_CONCURRENT; i++)); do
    local gpu; gpu=$(gpu_for_proc "$i" "$N_CONCURRENT")
    local proc_log="$RUN_DIR/workload-inference.proc${i}.log"
    local proc_csv="$RUN_DIR/workload-inference.proc${i}.csv"
    local proc_hm_csv="$RUN_DIR/workload-inference.proc${i}-heatmap.csv"
    local proc_summary="$RUN_DIR/workload-inference.proc${i}-summary.json"

    # kvikIO cells need the SYSTEM libcufile preloaded; cuCIM cells leave it UNSET
    # (cuCIM segfaults under a preloaded newer libcufile — per
    # `docs/RUNBOOK.md` (mixed-backend sweeps)). Scope per-cell here.
    local preload=""
    if [ "$INFER_BACKEND" = "kvikio" ]; then preload="$LIBCUFILE_SYSTEM"; fi

    local total_budget=$(($RAMP + $RUNTIME))

    CUDA_VISIBLE_DEVICES="$gpu" \
    LD_PRELOAD="$preload" \
    CUFILE_ENV_PATH_JSON="$CUFILE_JSON" \
    CONDA_PREFIX="$CONDA_ENV" \
    OMP_NUM_THREADS=4 MKL_NUM_THREADS=4 \
    setsid "$PY" "$INFER_WORKER" \
      --backend "$INFER_BACKEND" --model "$INFER_MODEL" \
      --rawtiff-dir "$INFER_RAWTIFF_DIR" --svs-dir "$INFER_SVS_DIR" \
      --coords-dir "$INFER_COORDS_DIR" --manifest "$INFER_MANIFEST" \
      --heatmap-dir "$heatmap_dir/proc${i}" \
      --heatmap-format "$INFER_HEATMAP_FORMAT" \
      --inference-batch-size "$INFERENCE_BATCH_SIZE" \
      --cache-policy "$INFER_CACHE_POLICY" \
      --process-id "$i" --world-size "$N_CONCURRENT" \
      --max-runtime-s "$total_budget" \
      --start-barrier-file "$infer_barrier" \
      --per-slide-csv "$proc_csv" \
      --per-slide-heatmap-csv "$proc_hm_csv" \
      --summary-json "$proc_summary" \
      >> "$proc_log" 2>&1 &
    proc_pids+=("$!")
    echo "[inference] launched proc $i on GPU $gpu pid=${proc_pids[-1]}" >> "$log"
  done

  # Wait for all workers to load models — signal: per-process CSV file exists
  # (worker creates it AFTER load_foundation_model returns + writes header).
  # 10-min cap so a stuck loader doesn't hang the cell forever.
  local model_load_deadline=$(($(date +%s) + 600))
  echo "[inference] waiting for $N_CONCURRENT workers to load models..." >> "$log"
  while true; do
    local loaded=0
    for ((i=0; i<N_CONCURRENT; i++)); do
      if [ -s "$RUN_DIR/workload-inference.proc${i}.csv" ]; then
        loaded=$((loaded + 1))
      fi
    done
    if [ "$loaded" -ge "$N_CONCURRENT" ]; then
      echo "[inference] all $N_CONCURRENT workers loaded" >> "$log"
      break
    fi
    if [ "$(date +%s)" -ge "$model_load_deadline" ]; then
      echo "[inference] model-load timeout: $loaded/$N_CONCURRENT loaded after 10 min" >> "$log"
      break
    fi
    sleep 1
  done

  # NOW start the deadline clock — workers will start processing slides when
  # we touch the barrier file below.
  local t0; t0=$(date +%s.%N)
  local deadline; deadline=$(awk "BEGIN{printf \"%.6f\", $t0 + $RAMP + $RUNTIME}")
  echo "[inference] $(date -u +%FT%TZ) lifting inference start barrier; deadline=$RAMP+$RUNTIME=$(($RAMP+$RUNTIME))s away" >> "$log"
  touch "$infer_barrier"

  # Poll until deadline; reap any natural exits
  while [ "$(date +%s.%N)" \< "$deadline" ]; do
    local alive=0
    for pid in "${proc_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=$((alive + 1)); fi
    done
    if [ "$alive" -eq 0 ]; then
      echo "[inference] all processes exited natively" >> "$log"
      break
    fi
    sleep 2
  done

  # Send SIGTERM to any still-alive process group (setsid put each in own pgid)
  for pid in "${proc_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "[inference] deadline reached; SIGTERM pgid -$pid" >> "$log"
      kill -TERM -- "-$pid" 2>/dev/null || true
    fi
  done
  sleep 5
  for pid in "${proc_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "[inference] still alive; SIGKILL pgid -$pid" >> "$log"
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  done
  for pid in "${proc_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Merge per-process latency CSVs into the cell's headline CSVs
  local merged="$RUN_DIR/per-slide-inference-latencies.csv"
  local merged_hm="$RUN_DIR/per-slide-heatmap-writes.csv"
  : > "$merged"
  : > "$merged_hm"
  local first=1
  for ((i=0; i<N_CONCURRENT; i++)); do
    local f="$RUN_DIR/workload-inference.proc${i}.csv"
    [ -f "$f" ] || continue
    if [ "$first" -eq 1 ]; then
      cat "$f" >> "$merged"
      first=0
    else
      tail -n +2 "$f" >> "$merged"
    fi
  done
  first=1
  for ((i=0; i<N_CONCURRENT; i++)); do
    local f="$RUN_DIR/workload-inference.proc${i}-heatmap.csv"
    [ -f "$f" ] || continue
    if [ "$first" -eq 1 ]; then
      cat "$f" >> "$merged_hm"
      first=0
    else
      tail -n +2 "$f" >> "$merged_hm"
    fi
  done
  echo "[inference] done — merged $(wc -l < "$merged" 2>/dev/null || echo 0) rows" >> "$log"
}

# ---------- Workload: ingest (Stage 1.5 fpsync pattern, reused from 6.C) ----
workload_ingest() {
  local log="$RUN_DIR/workload-ingest.log"
  local csv="$RUN_DIR/workload-ingest.csv"
  echo "[ingest] init" >> "$log"
  mkdir -p "$INGEST_DST"
  if [ ! -d "$INGEST_SRC" ]; then
    echo "[ingest] ERR: missing source $INGEST_SRC" >> "$log"
    touch "$READY_DIR/.ingest-failed"
    return 1
  fi
  touch "$READY_DIR/.ingest-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done
  local t0; t0=$(date +%s.%N)
  echo "timestamp,bytes_written_so_far" > "$csv"
  fpsync -n "$INGEST_N" "$INGEST_SRC" "$INGEST_DST" >> "$log" 2>&1 &
  local fpsync_pid=$!
  local deadline; deadline=$(awk "BEGIN{printf \"%.6f\", $t0 + $RAMP + $RUNTIME}")
  while [ "$(date +%s.%N)" \< "$deadline" ]; do
    if ! kill -0 "$fpsync_pid" 2>/dev/null; then
      echo "[ingest] fpsync died early" >> "$log"; break
    fi
    local sz; sz=$(du -sb "$INGEST_DST" 2>/dev/null | awk '{print $1}')
    echo "$(date +%s.%N),$sz" >> "$csv"
    sleep 1
  done
  kill -TERM "$fpsync_pid" 2>/dev/null || true
  wait "$fpsync_pid" 2>/dev/null || true
  echo "[ingest] done" >> "$log"
}

# ---------- Workload: viewer (Stage 1.6 SVS viewer pattern, reused from 6.C) -
workload_viewer() {
  local log="$RUN_DIR/workload-viewer.log"
  local csv="$RUN_DIR/workload-viewer.csv"
  echo "[viewer] init" >> "$log"
  mkdir -p "$VIEWER_SCRATCH"
  touch "$READY_DIR/.viewer-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done
  local total_runtime; total_runtime=$(( ${RAMP%.*} + ${RUNTIME%.*} ))
  fio --name=viewer-s7 --directory="$VIEWER_SCRATCH" \
      --rw=randread --bs=4K --size=4G --numjobs="$VIEWER_N" --iodepth=1 \
      --ioengine=libaio --direct=1 \
      --runtime="$total_runtime" --ramp_time=0 --time_based --group_reporting \
      --unlink=1 \
      --output-format=json+ --status-interval=1 --output="$csv" \
      >> "$log" 2>&1
  echo "[viewer] done" >> "$log"
}

# ---------- Workload: heatmap-viewer (new in Stage 7) -----------------------
# Pathologist views heatmaps that the inference workload just wrote. Uses a
# pre-staged heatmap pool (pre-populated by a separate prep step OR by the
# concurrent inference workload's outputs in 7.5 mixed). fio bs=4K random
# reads — same pattern as the SVS viewer, but against the heatmap dir.
workload_heatmap_viewer() {
  local log="$RUN_DIR/workload-heatmap-viewer.log"
  local csv="$RUN_DIR/workload-heatmap-viewer.csv"
  echo "[hm-viewer] init" >> "$log"
  mkdir -p "$HEATMAP_VIEWER_DIR"
  # Pre-stage heatmap viewer scratch: pre-create 4 × 1 GB files for fio random
  # reads (independent of inference's heatmap output stream). This isolates the
  # "viewer reads heatmaps" pattern from "inference writes heatmaps" — they
  # share the filesystem but not the same files. Realistic clinical: pathologists view
  # heatmaps that have been on disk for a while AS WELL AS just-written ones.
  touch "$READY_DIR/.heatmap-viewer-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done
  local total_runtime; total_runtime=$(( ${RAMP%.*} + ${RUNTIME%.*} ))
  fio --name=hm-viewer-s7 --directory="$HEATMAP_VIEWER_DIR" \
      --rw=randread --bs=4K --size=1G --numjobs="$HEATMAP_VIEWER_N" --iodepth=1 \
      --ioengine=libaio --direct=1 \
      --runtime="$total_runtime" --ramp_time=0 --time_based --group_reporting \
      --unlink=1 \
      --output-format=json+ --status-interval=1 --output="$csv" \
      >> "$log" 2>&1
  echo "[hm-viewer] done" >> "$log"
}

# ---------- Launch requested workloads --------------------------------------
IFS=',' read -ra WL_ARR <<< "$WORKLOADS"
for wl in "${WL_ARR[@]}"; do
  case "$wl" in
    inference)      workload_inference      & PIDS+=("$!") ;;
    ingest)         workload_ingest         & PIDS+=("$!") ;;
    viewer)         workload_viewer         & PIDS+=("$!") ;;
    heatmap-viewer) workload_heatmap_viewer & PIDS+=("$!") ;;
    *) echo "unknown workload: $wl" >&2 ;;
  esac
  echo "[orch] launched $wl (pid=${PIDS[-1]})" | tee -a "$ORCH_LOG"
done

# Wait for all workloads to signal ready (or skipped)
echo "[orch] waiting for workloads to signal ready..." | tee -a "$ORCH_LOG"
N_WL=${#WL_ARR[@]}
DEADLINE_READY=$(($(date +%s) + 180))  # 3-minute cap (inference proc startup can be ~30s/proc)
while true; do
  READY=0
  for wl in "${WL_ARR[@]}"; do
    if [ -f "$READY_DIR/.${wl}-ready" ] || [ -f "$READY_DIR/.${wl}-skipped" ] || [ -f "$READY_DIR/.${wl}-failed" ]; then
      READY=$((READY + 1))
    fi
  done
  if [ "$READY" -eq "$N_WL" ]; then break; fi
  if [ "$(date +%s)" -ge "$DEADLINE_READY" ]; then
    echo "[orch] timeout waiting for ready; proceeding with $READY/$N_WL" | tee -a "$ORCH_LOG"
    break
  fi
  sleep 0.5
done

# Touch the barrier — all workloads now proceed concurrently
echo "[orch] $(date -u +%FT%TZ) BARRIER LIFTED — workloads starting" | tee -a "$ORCH_LOG"
touch "$BARRIER"

# Wait for completion
EXIT_ALL=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    echo "[orch] workload pid=$pid exited non-zero" | tee -a "$ORCH_LOG"
    EXIT_ALL=1
  fi
done

echo "[orch] $(date -u +%FT%TZ) all workloads done (exit=$EXIT_ALL)" | tee -a "$ORCH_LOG"
exit "$EXIT_ALL"
