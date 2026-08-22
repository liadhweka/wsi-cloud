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

# Default config (override via env)
EXTRACT_MODEL="${EXTRACT_MODEL:-virchow2}"
EXTRACT_DATASET_TAG="${EXTRACT_DATASET_TAG:-brca50}"
# GPU partition (D-25, ratified 2026-08-21): extract on GPUs 1-3, MIL pinned to
# GPU 0 -- TRUE isolation, so GPU contention stays out of a cell that exists to
# measure filesystem QoS. The Tier-1 solo baselines run at this exact config,
# so every retention denominator is internally consistent with its concurrent
# numerator. This partition is 6.C-specific: 6.D's phases are sequential, so
# PIPELINE_GPUS keeps the full 0,1,2,3 (it must match 6.A Tier 2's N to
# compose) -- do not "align" the two.
# D-8 CLOSED (2026-08-22, `nvidia-smi topo -m`): the instance is single-NUMA —
# all GPUs and CPUs on node 0 — so ordering is a non-axis; only the SET matters,
# and the guard below catches a wrong set.
EXTRACT_GPUS="${EXTRACT_GPUS:-1,2,3}"
EXTRACT_N_GPUS="${EXTRACT_N_GPUS:-3}"
MIL_FEATURES_TAG="${MIL_FEATURES_TAG:-brca_full}"
# The MIL workload runs at its 6.B.3 saturation knee (roadmap 6.C) — a MEASURED
# per-project value, not a constant: it is read from Leg A's 6.B.3 results at
# 6.C entry and then held identical on both legs (workload shape, Table 5).
# Deliberately NO default: a carried-over knee from another environment would
# run every 6.C cell at a wrong config and every retention figure would
# inherit it silently. Enforced at the point of use (the mil workload below),
# so cells that do not name the mil workload are unaffected.
INGEST_N="${INGEST_N:-4}"
INGEST_SRC="${INGEST_SRC:-${SCRATCH_DIR:?SCRATCH_DIR is unset -- source env.sh}/fpsync-source/tcga-brca}"
INGEST_DST="${INGEST_DST:-${FS_MOUNT}/runs-stage6c-ingest-target}"
VIEWER_N="${VIEWER_N:-4}"
VIEWER_SCRATCH="${VIEWER_SCRATCH:-${FS_MOUNT}/benchmarks/fio-scratch-6c-viewer}"

# ── Guard: every requested GPU index must actually exist ─────────────────────────
# CUDA_VISIBLE_DEVICES silently DROPS indices that do not exist rather than
# erroring, so a stale list does not fail -- the extract workload just runs on
# fewer GPUs than intended and reports its throughput as though it had them all.
# In a concurrent-workload cell that is doubly wrong: the number is low, AND the
# contention the cell exists to measure never happened at the intended level.
# Nothing downstream can see it, so this refuses up front.
_n_gpus_present="$(nvidia-smi -L 2>/dev/null | wc -l)"
if [ "${_n_gpus_present:-0}" -eq 0 ]; then
  echo "FATAL: no GPUs visible (nvidia-smi -L returned nothing) -- 6.C needs the extract workload." >&2
  exit 1
fi
IFS=',' read -ra _req_gpus <<< "$EXTRACT_GPUS"
for _g in "${_req_gpus[@]}"; do
  if ! [[ "$_g" =~ ^[0-9]+$ ]] || [ "$_g" -ge "$_n_gpus_present" ]; then
    echo "FATAL: EXTRACT_GPUS='$EXTRACT_GPUS' names GPU index '$_g', but this instance has" >&2
    echo "       $_n_gpus_present GPU(s) (valid indices 0..$((_n_gpus_present - 1)))." >&2
    echo "       CUDA_VISIBLE_DEVICES would silently drop it and the extract workload would run" >&2
    echo "       on fewer GPUs than this cell claims. Re-derive the GPU list for THIS instance" >&2
    echo "       (the set matters; order is a non-axis — D-8, closed) and export EXTRACT_GPUS." >&2
    exit 1
  fi
done
if [ "${#_req_gpus[@]}" -ne "$EXTRACT_N_GPUS" ]; then
  echo "FATAL: EXTRACT_GPUS lists ${#_req_gpus[@]} GPU(s) but EXTRACT_N_GPUS=$EXTRACT_N_GPUS." >&2
  echo "       These must agree, or the extractor's world size will not match its device list." >&2
  exit 1
fi

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

# Up-front, not only at use: the mil workload runs backgrounded, so a refusal
# inside it would kill that workload alone and the cell would silently run a
# DIFFERENT mix than it claims (the exact failure the MIL_FEATURES_TAG caveat
# documents). Fail the whole cell before anything launches.
if [[ ",$WORKLOADS," == *",mil,"* ]] && [ -z "${MIL_NUM_WORKERS:-}" ]; then
  echo "FATAL: this cell names the mil workload but MIL_NUM_WORKERS is unset." >&2
  echo "       Set it to the measured 6.B.3 saturation knee (docs/Stage-6-Feature-Extraction.md," >&2
  echo "       6.B.3 results row) — one value, identical on both legs (Table 5 workload shape)." >&2
  exit 2
fi
[ -z "$RUNTIME" ]   && { echo "missing --runtime" >&2; exit 2; }
[ -z "$RAMP" ]      && { echo "missing --ramp" >&2; exit 2; }
[ -z "$RUN_DIR" ]   && { echo "missing --run-dir" >&2; exit 2; }

mkdir -p "$RUN_DIR"
BARRIER="$RUN_DIR/.start-barrier"
ORCH_LOG="$RUN_DIR/orchestration.log"

echo "[orch] $(date -u +%FT%TZ) starting" | tee "$ORCH_LOG"
echo "[orch] workloads: $WORKLOADS" | tee -a "$ORCH_LOG"
echo "[orch] runtime=${RUNTIME}s ramp=${RAMP}s" | tee -a "$ORCH_LOG"
# The resolved workload shape. None of it is recoverable from anywhere else: the
# command record-run.sh captures is only --workloads/--ramp/--runtime/--run-dir, and
# metadata.json carries no workload fields. EXTRACT_GPUS sets the concurrency the
# extract workload actually ran at and MIL_FEATURES_TAG sets which corpus MIL trained
# from — the two values that most directly determine what this contention cell
# measured. Without them a 6.C cell cannot be shown to have run the same shape as its
# other-leg counterpart even by hand, and a contention cell whose shape is unknown is
# not comparable to anything.
echo "[orch] extract: model=$EXTRACT_MODEL dataset_tag=$EXTRACT_DATASET_TAG gpus=$EXTRACT_GPUS n_gpus=$EXTRACT_N_GPUS" | tee -a "$ORCH_LOG"
echo "[orch] mil:     features_tag=$MIL_FEATURES_TAG" | tee -a "$ORCH_LOG"
echo "[orch] ingest:  n=$INGEST_N src=$INGEST_SRC dst=$INGEST_DST" | tee -a "$ORCH_LOG"
echo "[orch] viewer:  n=$VIEWER_N scratch=$VIEWER_SCRATCH" | tee -a "$ORCH_LOG"

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
  # Wipe the target BEFORE the start barrier (setup, not measurement): fpsync
  # is rsync underneath, so a populated target from ANY earlier cell turns this
  # workload into a metadata-only no-op scan that writes nothing — the cell then
  # runs a mix its name does not claim (bit 6.C 2026-08-22: every
  # ingest-containing concurrent cell after the solo re-scanned the solo's
  # output; the canary exposed it as a trickle-shaped write ratio).
  rm -rf "$INGEST_DST"
  mkdir -p "$INGEST_DST"
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

  # Time-bounded via kill-on-deadline (the extractor otherwise runs to manifest
  # exhaustion, ignoring RUNTIME). Mirrors the ingest
  # pattern below. Uses setsid so the mp.spawn child process group can be killed
  # cleanly via SIGTERM to -$extract_pid (kills all DDP rank processes + master).
  local manifest="$REPO/scripts/manifests/tcga-brca-stage4a-subset.tsv"
  CUDA_VISIBLE_DEVICES="$EXTRACT_GPUS" \
  LD_PRELOAD="$LIBCUFILE_SYSTEM" \
  CUFILE_ENV_PATH_JSON="$CUFILE_JSON" \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  setsid "$PY" "$REPO/scripts/extract-features-foundation-stage6.py" \
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
  # FAIL, never substitute or skip (ratified 2026-08-15, with the sweep-level
  # fail-loud pattern): 6.C exists to measure four named workloads contending,
  # so a cell that silently ran three of them — or ran MIL against a corpus
  # nobody configured — reports a concurrency figure for a mix nobody chose,
  # and only a log line would know. The .mil-failed marker lets the orchestrator
  # abort BEFORE the barrier instead of burning the cell's full runtime on a
  # cell already known INCOMPLETE.
  if [ ! -d "$features_dir" ] || [ "$(ls "$features_dir"/*.pt 2>/dev/null | wc -l)" -lt 10 ]; then
    echo "[mil] FATAL: features dir $features_dir missing or under 10 .pt files — refusing to substitute or skip (the cell FAILS)" >> "$log"
    touch "$READY_DIR/.mil-failed"
    return 1
  fi
  local embed_dim=1280
  [ "$EXTRACT_MODEL" = "uni2-h" ] && embed_dim=1536
  [ "$EXTRACT_MODEL" = "gigapath" ] && embed_dim=1536
  touch "$READY_DIR/.mil-ready"
  while [ ! -f "$BARRIER" ]; do sleep 0.1; done

  # MIL is pinned to GPU 0; extract runs on GPUs 1-3 (D-25 partition — true
  # isolation, so GPU contention stays out of the QoS measurement). Canonical
  # CLAM bs=1 (see Stage-6-Feature-Extraction.md); num_workers is the measured
  # 6.B.3 saturation knee, required from the environment above — never a
  # carried-over constant.
  CUDA_VISIBLE_DEVICES=0 \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  "$PY" "$REPO/scripts/train-mil-stage6b.py" \
    --features-dir "$features_dir" \
    --embedding-dim "$embed_dim" \
    --num-workers "${MIL_NUM_WORKERS:?MIL_NUM_WORKERS is unset -- set it to the measured 6.B.3 saturation knee (docs/Stage-6-Feature-Extraction.md 6.B.3 results row; identical on both legs)}" \
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
    if [ -f "$READY_DIR/.${wl}-ready" ] || [ -f "$READY_DIR/.${wl}-skipped" ] \
       || [ -f "$READY_DIR/.${wl}-failed" ]; then
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

# A workload that FAILED at init aborts the whole cell before the barrier: the
# cell is already INCOMPLETE by definition (a named workload is missing), so
# running the survivors would spend the full runtime measuring a mix nobody
# chose. Never lift the barrier; kill the waiting workloads and fail loud.
for wl in "${WL_ARR[@]}"; do
  if [ -f "$READY_DIR/.${wl}-failed" ]; then
    echo "[orch] FATAL: workload '$wl' failed at init — aborting the cell before the barrier" | tee -a "$ORCH_LOG"
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    wait 2>/dev/null
    exit 1
  fi
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
