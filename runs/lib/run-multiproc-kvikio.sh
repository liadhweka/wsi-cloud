#!/usr/bin/env bash
# run-multiproc-kvikio.sh — launch N parallel Python kvikIO readers on assigned GPUs.
#
# Usage:
#   run-multiproc-kvikio.sh <N> <gpu_csv> <compat_mode> <n_buffer> <num_threads> <run_dir>
#
# Each of the N processes:
#   - Gets one GPU from gpu_csv (e.g. "2,3,6,7" for N=4)
#   - Writes its own reader-summary.json to <run_dir>/proc<i>-summary.json
#   - Writes its own latency CSV to <run_dir>/proc<i>-latencies.csv
#
# This wrapper is invoked BY record-run.sh as the single "cell command", so all
# N processes run inside the same recording window. The aggregator sums the
# per-process summaries into a cell-aggregate.
#
# WHY: kvikIO's natural parallelism is internal threads + n_buffer pipelining.
# Multi-process scaling requires multiple Python interpreters because GIL still
# limits per-Python-process throughput once the wall-time is dominated by Python
# work (coord pool lookups, Python-side bookkeeping). This wrapper provides the
# N-process scaling axis without changing the reader's per-process logic.
set -uo pipefail

if [ $# -lt 6 ]; then
  echo "usage: $0 <N> <gpu_csv> <compat_mode_off|on> <n_buffer> <num_threads> <run_dir>" >&2
  exit 2
fi

N="$1"
GPU_CSV="$2"
COMPAT="$3"
N_BUFFER="$4"
NUM_THREADS="$5"
RUN_DIR="$6"

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604
PY="$CONDA_ENV/bin/python"
READER="$REPO/runs/lib/read-tiles-kvikio.py"

IFS=',' read -ra GPU_ARR <<< "$GPU_CSV"
if [ "${#GPU_ARR[@]}" -ne "$N" ]; then
  echo "GPU count (${#GPU_ARR[@]}) != N ($N) — gpu_csv=$GPU_CSV" >&2
  exit 2
fi

# Common env (the parent sweep driver already exports CONDA_PREFIX, LD_PRELOAD,
# CUFILE_ENV_PATH_JSON but we set them again here for safety since this is the
# direct child of record-run.sh).
export CONDA_PREFIX="${CONDA_PREFIX:-$CONDA_ENV}"
export LD_PRELOAD="${LD_PRELOAD:-/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0}"
export CUFILE_ENV_PATH_JSON="${CUFILE_ENV_PATH_JSON:-${CUFILE_ENV_PATH_JSON}}"

mkdir -p "$RUN_DIR"

# Dataset selection (BRCA default; allow override for cross-dataset cells)
DATASET="${DATASET:-brca}"
case "$DATASET" in
  brca)
    RAWTIFF_DIR=${FS_MOUNT}/data/tcga-brca-rawtiff
    MANIFEST=$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv
    COORDS_DIR=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches
    ;;
  cam16)
    RAWTIFF_DIR=${FS_MOUNT}/data/camelyon16-rawtiff
    MANIFEST=$REPO/runs/manifests/camelyon16-stage4a-subset.tsv
    COORDS_DIR=${FS_MOUNT}/tissue-detection/3.0/camelyon16/n64/patches
    ;;
  *) echo "unknown DATASET=$DATASET" >&2; exit 2;;
esac

echo "[multiproc] launching $N processes on GPUs: $GPU_CSV"
echo "[multiproc] dataset=$DATASET compat_mode=$COMPAT n_buffer=$N_BUFFER num_threads=$NUM_THREADS"
echo "[multiproc] reader: $READER"

pids=()
for i in $(seq 0 $((N - 1))); do
  gpu="${GPU_ARR[$i]}"
  summary="$RUN_DIR/proc${i}-summary.json"
  latcsv="$RUN_DIR/proc${i}-latencies.csv"
  log="$RUN_DIR/proc${i}.log"

  # Different seed per process so they don't read the same tile sequence
  seed=$((42 + i))

  echo "[multiproc] proc $i on GPU $gpu → $summary"
  CUDA_VISIBLE_DEVICES="$gpu" \
  "$PY" "$READER" \
    --mode random \
    --rawtiff-dir "$RAWTIFF_DIR" \
    --manifest "$MANIFEST" \
    --coords-dir "$COORDS_DIR" \
    --compat-mode "$COMPAT" \
    --n-buffer "$N_BUFFER" \
    --num-threads "$NUM_THREADS" \
    --level 0 --runtime 60 --ramp 10 \
    --seed "$seed" \
    --summary-json "$summary" \
    --latency-csv "$latcsv" \
    > "$log" 2>&1 &
  pids+=("$!")
done

# Wait for all
fail=0
for i in $(seq 0 $((N - 1))); do
  if ! wait "${pids[$i]}"; then
    echo "[multiproc] proc $i FAILED (pid ${pids[$i]})" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  # Quick local aggregate so the cmd.log has the headline
  echo ""
  echo "[multiproc] === per-process summary ==="
  total_tps=0
  total_gbps=0
  for i in $(seq 0 $((N - 1))); do
    summary="$RUN_DIR/proc${i}-summary.json"
    if [ -f "$summary" ]; then
      tps=$(python3 -c "import json,sys; print(json.load(open('$summary')).get('tiles_per_sec_steady',0))")
      gbps=$(python3 -c "import json,sys; print(json.load(open('$summary')).get('gbps_steady',0))")
      printf "  proc %d (GPU %s): %10.0f tiles/sec  %6.2f GB/s\n" "$i" "${GPU_ARR[$i]}" "$tps" "$gbps"
      total_tps=$(python3 -c "print($total_tps + $tps)")
      total_gbps=$(python3 -c "print($total_gbps + $gbps)")
    fi
  done
  printf "  AGGREGATE     : %10.0f tiles/sec  %6.2f GB/s  (N=%d procs)\n" "$total_tps" "$total_gbps" "$N"
fi

exit "$fail"
