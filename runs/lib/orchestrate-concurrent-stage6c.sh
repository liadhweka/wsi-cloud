#!/usr/bin/env bash
# Stage 6.C concurrent multi-workload orchestrator.
#
# Launches some subset of the four production WSI workloads simultaneously and
# captures per-workload telemetry. Outer record-run.sh (called by sweep-stage6c.sh)
# captures the cluster-side time-series across the full concurrent window.
#
# The four workloads:
#   ingest   : Stage 1.5 fpsync pattern at fixed n=4 (the "scanner pace" baseline)
#   extract  : Stage 6.A pattern — Virchow2 (or other model) at N=4 kvikIO+GDS+raw-TIFF
#   mil      : Stage 6.B.3 pattern — attention-MIL training on 6.A features
#   viewer   : Stage 1.6 viewer pattern — fio bs=4K n=4 random reads on ${FS_MOUNT}
#
# Per-workload telemetry CSV (one per workload, in run dir):
#   workload-<name>.csv — time-series of that workload's app-level throughput
#
# Workload start: synchronized via a shared start-barrier file. All workload
# wrappers wait for the barrier file to appear before beginning their steady-
# state work, so per-workload windows align cleanly.
#
# Usage (typically invoked by sweep-stage6c.sh):
#   ./orchestrate-concurrent-stage6c.sh \\
#     --workloads "ingest,extract,mil,viewer" \\
#     --runtime 1800 --ramp 300 \\
#     --run-dir <run-dir>
#
# Available workload tags (comma-separated to --workloads):
#   ingest, extract, mil, viewer
set -uo pipefail

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604
PY="$CONDA_ENV/bin/python"
LIBCUFILE_117=/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0
CUFILE_JSON=${CUFILE_ENV_PATH_JSON}

# Default config (override via env)
EXTRACT_MODEL="${EXTRACT_MODEL:-virchow2}"
EXTRACT_DATASET_TAG="${EXTRACT_DATASET_TAG:-brca50}"
EXTRACT_GPUS="${EXTRACT_GPUS:-2,3,6,7}"
EXTRACT_N_GPUS="${EXTRACT_N_GPUS:-4}"
MIL_FEATURES_TAG="${MIL_FEATURES_TAG:-brca_full}"
INGEST_N="${INGEST_N:-4}"
INGEST_SRC="${INGEST_SRC:-/data/local-nvme/fpsync-source/tcga-brca}"
INGEST_DST="${INGEST_DST:-${FS_MOUNT}/runs-stage6c-ingest-target}"
VIEWER_N="${VIEWER_N:-4}"
VIEWER_SCRATCH="${VIEWER_SCRATCH:-${FS_MOUNT}/benchmarks/fio-scratch-6c-viewer}"

# Args
WORKLOADS=""
RUNTIME=""
RAMP=""
RUN_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workloads) WORKLOADS="$2"; shift 2 ;;
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --ramp)      RAMP="$2"; shift 2 ;;
    --run-dir)   RUN_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$WORKLOADS" ] && { echo "missing --workloads" >&2; exit 2; }
[ -z "$RUNTIME" ]   && { echo "missing --runtime" >&2; exit 2; }
[ -z "$RAMP" ]      && { echo "missing --ramp" >&2; exit 2; }
[ -z "$RUN_DIR" ]   && { echo "missing --run-dir" >&2; exit 2; }

mkdir -p "$RUN_DIR"
BARRIER="$RUN_DIR/.start-barrier"
ORCH_LOG="$RUN_DIR/orchestration.log"

echo "[orch] $(date -u +%FT%TZ) starting" | tee "$ORCH_LOG"
echo "[orch] workloads: $WORKLOADS" | tee -a "$ORCH_LOG"
echo "[orch] runtime=${RUNTIME}s ramp=${RAMP}s" | tee -a "$ORCH_LOG"

# Each workload runs in its own background subshell. They each wait for the
# barrier file to appear before kicking off their steady-state work. Once all
# workloads have signaled "ready", the orchestrator touches the barrier file.
PIDS=()
READY_DIR="$RUN_DIR/.ready"
mkdir -p "$READY_DIR"

# ---------- Workload: ingest (Stage 1.5 fpsync pattern) ----------
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
  # Telemetry: poll INGEST_DST size every second until runtime+ramp elapsed or fpsync dies
  # printf %.6f forces decimal form — awk default OFMT %.6g would emit scientific
  # notation for the ~1.78e9 epoch timestamps, breaking the lex compare below.
  local deadline; deadline=$(awk "BEGIN{printf \"%.6f\", $t0 + $RAMP + $RUNTIME}")
  while [ "$(date +%s.%N)" \< "$deadline" ]; do
    if ! kill -0 "$fpsync_pid" 2>/dev/null; then
      echo "[ingest] fpsync died early" >> "$log"
      break
    fi
    local sz; sz=$(du -sb "$INGEST_DST" 2>/dev/null | awk '{print $1}')
    echo "$(date +%s.%N),$sz" >> "$csv"
    sleep 1
  done
  kill -TERM "$fpsync_pid" 2>/dev/null || true
  wait "$fpsync_pid" 2>/dev/null || true
  echo "[ingest] done" >> "$log"
}

# ---------- Workload: extract (Stage 6.A kvikIO Virchow2 N=4) ----------
workload_extract() {
  local log="$RUN_DIR/workload-extract.log"
  local csv="$RUN_DIR/workload-extract.csv"
  echo "[extract] init" >> "$log"
  local features_out="${FS_MOUNT}/features/6.A/${EXTRACT_MODEL}/${EXTRACT_DATASET_TAG}-6c-concurrent"
  mkdir -p "$features_out"
  touch "$READY_DIR/.extract-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done
  local t0; t0=$(date +%s.%N)

  # Time-bounded via kill-on-deadline (added 2026-05-25 after 6.C smoke exposed
  # the extractor ran to manifest exhaustion ignoring RUNTIME — see Stage-6-
  # Feature-Extraction.md change log for full rationale). Mirrors the ingest
  # pattern below. Uses setsid so the mp.spawn child process group can be killed
  # cleanly via SIGTERM to -$extract_pid (kills all DDP rank processes + master).
  local manifest="$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv"
  CUDA_VISIBLE_DEVICES="$EXTRACT_GPUS" \
  LD_PRELOAD="$LIBCUFILE_117" \
  CUFILE_ENV_PATH_JSON="$CUFILE_JSON" \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  setsid "$PY" "$REPO/runs/lib/extract-features-foundation-stage6.py" \
    --backend kvikio --world-size "$EXTRACT_N_GPUS" --model "$EXTRACT_MODEL" \
    --rawtiff-dir ${FS_MOUNT}/data/tcga-brca-rawtiff \
    --coords-dir ${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches \
    --manifest "$manifest" \
    --output-dir "$features_out" \
    --batch-size 256 \
    --extraction-steps-csv "$csv" \
    --per-slide-csv "$RUN_DIR/workload-extract-per-slide.csv" \
    --summary-json "$RUN_DIR/workload-extract-summary.json" \
    --n-buffer 256 --num-threads 16 \
    --force-reextract \
    >> "$log" 2>&1 &
  local extract_pid=$!

  # Poll until deadline; break early if extractor finishes natively (manifest exhausted).
  # printf %.6f forces decimal form — awk default OFMT %.6g would emit scientific
  # notation for the ~1.78e9 epoch timestamps, breaking the lex compare below.
  local deadline; deadline=$(awk "BEGIN{printf \"%.6f\", $t0 + $RAMP + $RUNTIME}")
  while [ "$(date +%s.%N)" \< "$deadline" ]; do
    if ! kill -0 "$extract_pid" 2>/dev/null; then
      echo "[extract] extractor finished natively (manifest exhausted before deadline)" >> "$log"
      break
    fi
    sleep 1
  done

  # If still running at deadline, send SIGTERM to the whole process group
  # (setsid put the extractor in its own pgid == $extract_pid).
  if kill -0 "$extract_pid" 2>/dev/null; then
    echo "[extract] deadline reached; SIGTERM to pgid -$extract_pid" >> "$log"
    kill -TERM -- "-$extract_pid" 2>/dev/null || true
    sleep 5
    if kill -0 "$extract_pid" 2>/dev/null; then
      echo "[extract] still alive after SIGTERM; SIGKILL to pgid -$extract_pid" >> "$log"
      kill -KILL -- "-$extract_pid" 2>/dev/null || true
    fi
  fi
  wait "$extract_pid" 2>/dev/null || true
  echo "[extract] done" >> "$log"
}

# ---------- Workload: mil (Stage 6.B.3 MIL training) ----------
workload_mil() {
  local log="$RUN_DIR/workload-mil.log"
  local csv="$RUN_DIR/workload-mil.csv"
  echo "[mil] init" >> "$log"
  local features_dir="${FS_MOUNT}/features/6.A/${EXTRACT_MODEL}/${MIL_FEATURES_TAG}"
  if [ ! -d "$features_dir" ] || [ "$(ls "$features_dir"/*.pt 2>/dev/null | wc -l)" -lt 10 ]; then
    echo "[mil] ERR: features dir $features_dir empty or missing — falling back to smoke test mode" >> "$log"
    # Try the 50-slide subset features instead
    features_dir="${FS_MOUNT}/features/6.A/${EXTRACT_MODEL}/brca50"
    if [ ! -d "$features_dir" ] || [ "$(ls "$features_dir"/*.pt 2>/dev/null | wc -l)" -lt 10 ]; then
      echo "[mil] ERR: no usable features dir; skipping" >> "$log"
      touch "$READY_DIR/.mil-skipped"
      return 0
    fi
  fi
  local embed_dim=1280
  [ "$EXTRACT_MODEL" = "uni2-h" ] && embed_dim=1536
  [ "$EXTRACT_MODEL" = "gigapath" ] && embed_dim=1536
  touch "$READY_DIR/.mil-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done

  # MIL uses GPU 0 (NUMA-1) to stay out of the extract workload's GPUs
  # Canonical CLAM bs=1 (revised 2026-05-25 — see Stage-6-Feature-Extraction.md Q10);
  # num_workers=16 is the saturation knee from 6.B.3 (peak ~8.6-8.8 slides/sec).
  CUDA_VISIBLE_DEVICES=0 \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  "$PY" "$REPO/runs/lib/train-mil-stage6b.py" \
    --features-dir "$features_dir" \
    --embedding-dim "$embed_dim" \
    --num-workers 16 \
    --ramp "$RAMP" --runtime "$RUNTIME" \
    --training-steps-csv "$csv" \
    --summary-json "$RUN_DIR/workload-mil-summary.json" \
    --gpu 0 \
    >> "$log" 2>&1
  echo "[mil] done" >> "$log"
}

# ---------- Workload: viewer (fio bs=4K n=4 random reads, viewer pattern) ----------
workload_viewer() {
  local log="$RUN_DIR/workload-viewer.log"
  local csv="$RUN_DIR/workload-viewer.csv"
  echo "[viewer] init" >> "$log"
  mkdir -p "$VIEWER_SCRATCH"
  touch "$READY_DIR/.viewer-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done
  # Stage 1.6 viewer pattern: bs=4K, iodepth=1, jobs=4, random reads
  local total_runtime; total_runtime=$(( ${RAMP%.*} + ${RUNTIME%.*} ))
  fio --name=viewer-6c --directory="$VIEWER_SCRATCH" \
      --rw=randread --bs=4K --size=4G --numjobs="$VIEWER_N" --iodepth=1 \
      --ioengine=libaio --direct=1 \
      --runtime="$total_runtime" --ramp_time=0 --time_based --group_reporting \
      --unlink=1 \
      --output-format=json+ --status-interval=1 --output="$csv" \
      >> "$log" 2>&1
  echo "[viewer] done" >> "$log"
}

# ---------- Launch the requested workloads ----------
IFS=',' read -ra WL_ARR <<< "$WORKLOADS"
for wl in "${WL_ARR[@]}"; do
  case "$wl" in
    ingest)  workload_ingest  & PIDS+=("$!") ;;
    extract) workload_extract & PIDS+=("$!") ;;
    mil)     workload_mil     & PIDS+=("$!") ;;
    viewer)  workload_viewer  & PIDS+=("$!") ;;
    *) echo "unknown workload: $wl" >&2 ;;
  esac
  echo "[orch] launched $wl (pid=${PIDS[-1]})" | tee -a "$ORCH_LOG"
done

# Wait for all workloads to signal ready
echo "[orch] waiting for all workloads to signal ready..." | tee -a "$ORCH_LOG"
N_WORKLOADS=${#WL_ARR[@]}
DEADLINE_READY=$(($(date +%s) + 120))  # 2-minute cap
while true; do
  READY=0
  for wl in "${WL_ARR[@]}"; do
    if [ -f "$READY_DIR/.${wl}-ready" ] || [ -f "$READY_DIR/.${wl}-skipped" ]; then
      READY=$((READY + 1))
    fi
  done
  if [ "$READY" -eq "$N_WORKLOADS" ]; then break; fi
  if [ "$(date +%s)" -ge "$DEADLINE_READY" ]; then
    echo "[orch] timeout waiting for ready; proceeding with $READY/$N_WORKLOADS" | tee -a "$ORCH_LOG"
    break
  fi
  sleep 0.5
done

# Touch the barrier — all workloads now proceed
echo "[orch] $(date -u +%FT%TZ) BARRIER LIFTED — workloads starting concurrent execution" | tee -a "$ORCH_LOG"
touch "$BARRIER"

# Wait for all workloads to complete
EXIT_ALL=0
for pid in "${PIDS[@]}"; do
  if ! wait "$pid"; then
    echo "[orch] workload pid=$pid exited non-zero" | tee -a "$ORCH_LOG"
    EXIT_ALL=1
  fi
done

echo "[orch] $(date -u +%FT%TZ) all workloads done (exit=$EXIT_ALL)" | tee -a "$ORCH_LOG"
exit "$EXIT_ALL"
