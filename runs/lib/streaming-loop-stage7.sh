#!/usr/bin/env bash
# Stage 7.4.a streaming clinical loop.
#
# Models the realistic clinical scenario: scanner emits one slide every 60
# seconds; an inference worker picks up each new slide, runs the full
# tissue-detection → extract → MIL → heatmap-write pipeline; the per-slide
# end-to-end wallclock is the customer-quotable "scanner-to-pathologist-
# visibility latency" number.
#
# SEQUENTIAL not parallel: one slide hits storage every 60s; the single-GPU
# inference worker processes new arrivals one at a time. If inference takes
# <60s, the worker idles waiting for the next slide; if >60s, slides queue.
# Per-slide event log captures both regimes.
#
# Per-slide event log columns:
#   slide_idx, slide_id, t_arrived_s, t_inference_start_s, t_inference_done_s,
#   t_heatmap_written_s, t_viewer_received_s, queued_s, inference_s, end_to_end_s
#
# WHY warm-cache: production reality — a clinical lab processes many slides
# per shift, so the page cache is meaningfully warm after the first few.
#
# Usage:
#   ./streaming-loop-stage7.sh --run-dir <run-dir> \
#       [--n-slides 10] [--cadence-s 60] [--model virchow2] [--backend kvikio]
set -uo pipefail

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source cloud-setup/env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source cloud-setup/env.sh}"
PY="$CONDA_ENV/bin/python"
# The SYSTEM libcufile, matched to the installed kernel nvidia-fs module. Read from
# the environment (cloud-setup/NAMING-AND-VARIABLES.md Table 3) — never hardcoded:
# the conda env bundles an older copy, the right path is instance-specific, and a
# path pointing nowhere makes LD_PRELOAD a silent no-op, so the kvikIO cells would
# quietly run on the WRONG libcufile and still report numbers. ⏳ D-10: locate it on
# the real instance and export LIBCUFILE_PRELOAD before running any kvikIO sweep.
: "${LIBCUFILE_PRELOAD:?LIBCUFILE_PRELOAD is unset -- locate the system libcufile matched to the loaded nvidia-fs module and export it (see cloud-setup/NAMING-AND-VARIABLES.md Table 3)}"
LIBCUFILE_SYSTEM="$LIBCUFILE_PRELOAD"
[ -f "$LIBCUFILE_SYSTEM" ] || { echo "LIBCUFILE_PRELOAD points at a nonexistent file: $LIBCUFILE_SYSTEM" >&2; exit 1; }
CUFILE_JSON=${CUFILE_ENV_PATH_JSON}
INFER_WORKER="$REPO/runs/lib/inference-per-slide-stage7.py"

# Defaults
N_SLIDES=10
CADENCE_S=60
MODEL="virchow2"
BACKEND="kvikio"
COORDS_DIR="${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches"
RAWTIFF_DIR="${FS_MOUNT}/data/tcga-brca-rawtiff"
SVS_DIR="${FS_MOUNT}/data/tcga-brca"
MANIFEST="$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv"
RUN_DIR=""
INFERENCE_BATCH_SIZE=256

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)              RUN_DIR="$2"; shift 2 ;;
    --n-slides)             N_SLIDES="$2"; shift 2 ;;
    --cadence-s)            CADENCE_S="$2"; shift 2 ;;
    --model)                MODEL="$2"; shift 2 ;;
    --backend)              BACKEND="$2"; shift 2 ;;
    --manifest)             MANIFEST="$2"; shift 2 ;;
    --inference-batch-size) INFERENCE_BATCH_SIZE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$RUN_DIR" ] && { echo "missing --run-dir" >&2; exit 2; }
[ -f "$INFER_WORKER" ] || { echo "missing $INFER_WORKER" >&2; exit 1; }

mkdir -p "$RUN_DIR"
EVENT_LOG="$RUN_DIR/streaming-loop-events.csv"
ORCH_LOG="$RUN_DIR/streaming-loop.log"
HEATMAP_DIR="$RUN_DIR/heatmaps"
mkdir -p "$HEATMAP_DIR"

echo "slide_idx,slide_id,t_arrived_s,t_inference_start_s,t_inference_done_s,t_heatmap_written_s,t_viewer_received_s,queued_s,inference_s,end_to_end_s" > "$EVENT_LOG"

# Pre-load the manifest into an array (skipping comment + 'slide_id' header lines)
mapfile -t ALL_SLIDES < <(grep -vE '^(#|slide_id|$)' "$MANIFEST" | head -n "$N_SLIDES")
N_AVAIL=${#ALL_SLIDES[@]}
if [ "$N_AVAIL" -lt "$N_SLIDES" ]; then
  echo "[streaming] WARNING: requested $N_SLIDES slides, manifest has only $N_AVAIL" | tee -a "$ORCH_LOG"
  N_SLIDES="$N_AVAIL"
fi
echo "[streaming] $(date -u +%FT%TZ) start; N=$N_SLIDES cadence=${CADENCE_S}s model=$MODEL backend=$BACKEND" | tee "$ORCH_LOG"

# Backend-specific env (LD_PRELOAD scoping per cucim-segfaults-when-libcufile-is-ld-preloaded)
PRELOAD=""
[ "$BACKEND" = "kvikio" ] && PRELOAD="$LIBCUFILE_SYSTEM"

t_zero=$(date +%s.%N)

for ((i=0; i<N_SLIDES; i++)); do
  sid="${ALL_SLIDES[$i]}"
  # Scanner cadence: slide i hits storage at t_zero + cadence*i
  t_arrived_target=$(awk "BEGIN{printf \"%.6f\", $t_zero + $CADENCE_S * $i}")
  # Wait until the scanner's emit time
  while [ "$(date +%s.%N)" \< "$t_arrived_target" ]; do
    sleep 0.5
  done
  t_arrived=$(date +%s.%N)
  t_arrived_rel=$(awk "BEGIN{printf \"%.6f\", $t_arrived - $t_zero}")

  # "Scanner copy": we don't actually copy bytes (real Stage 1.5 fpsync is
  # measured separately). The slide is "available" the moment we move past
  # t_arrived_target. The inference worker then picks it up.

  # Build a 1-slide manifest for this iteration
  one_manifest="$RUN_DIR/.manifest-slide-$i.tsv"
  echo -e "slide_id\n$sid" > "$one_manifest"

  inf_csv="$RUN_DIR/per-slide-${i}-latencies.csv"
  inf_hm_csv="$RUN_DIR/per-slide-${i}-heatmap.csv"
  inf_summary="$RUN_DIR/per-slide-${i}-summary.json"
  inf_log="$RUN_DIR/per-slide-${i}.log"

  t_inf_start=$(date +%s.%N)
  t_inf_start_rel=$(awk "BEGIN{printf \"%.6f\", $t_inf_start - $t_zero}")

  CUDA_VISIBLE_DEVICES=2 \
  LD_PRELOAD="$PRELOAD" \
  CUFILE_ENV_PATH_JSON="$CUFILE_JSON" \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  "$PY" "$INFER_WORKER" \
    --backend "$BACKEND" --model "$MODEL" \
    --rawtiff-dir "$RAWTIFF_DIR" --svs-dir "$SVS_DIR" \
    --coords-dir "$COORDS_DIR" --manifest "$one_manifest" \
    --heatmap-dir "$HEATMAP_DIR" \
    --heatmap-format tiff5x \
    --inference-batch-size "$INFERENCE_BATCH_SIZE" \
    --cache-policy warm \
    --max-slides 1 \
    --per-slide-csv "$inf_csv" \
    --per-slide-heatmap-csv "$inf_hm_csv" \
    --summary-json "$inf_summary" \
    >> "$inf_log" 2>&1

  t_inf_done=$(date +%s.%N)
  t_inf_done_rel=$(awk "BEGIN{printf \"%.6f\", $t_inf_done - $t_zero}")

  # The heatmap is written by the inference worker as part of phase 4;
  # the file's mtime is effectively t_inf_done (worker writes-and-returns).
  # We can use the heatmap file existence + mtime as t_heatmap_written.
  hm_file="$HEATMAP_DIR/${sid}.tiff"
  if [ -f "$hm_file" ]; then
    t_hm_written=$(date -r "$hm_file" +%s.%N 2>/dev/null)  # mtime as epoch.ns (stat's %N is a date specifier, not a stat one)
    t_hm_written_rel=$(awk "BEGIN{printf \"%.6f\", $t_hm_written - $t_zero}")
  else
    t_hm_written_rel=""
  fi

  # "Viewer received": a separate read of the heatmap by a different process,
  # measures read-after-write visibility. Polls every 10ms for up to 1s.
  t_viewer_recv_rel=""
  if [ -f "$hm_file" ]; then
    t_poll_start=$(date +%s.%N)
    deadline_poll=$(awk "BEGIN{printf \"%.6f\", $t_poll_start + 1.0}")
    while [ "$(date +%s.%N)" \< "$deadline_poll" ]; do
      if dd if="$hm_file" of=/dev/null bs=4K count=1 status=none 2>/dev/null; then
        t_viewer_recv=$(date +%s.%N)
        t_viewer_recv_rel=$(awk "BEGIN{printf \"%.6f\", $t_viewer_recv - $t_zero}")
        break
      fi
      sleep 0.01
    done
  fi

  queued_s=$(awk "BEGIN{printf \"%.6f\", $t_inf_start - $t_arrived}")
  inference_s=$(awk "BEGIN{printf \"%.6f\", $t_inf_done - $t_inf_start}")
  end_to_end_s=$(awk "BEGIN{printf \"%.6f\", $t_inf_done - $t_arrived}")

  echo "$i,$sid,$t_arrived_rel,$t_inf_start_rel,$t_inf_done_rel,$t_hm_written_rel,$t_viewer_recv_rel,$queued_s,$inference_s,$end_to_end_s" >> "$EVENT_LOG"
  echo "[streaming] slide $i ($sid): queued=${queued_s}s inference=${inference_s}s e2e=${end_to_end_s}s viewer_recv=${t_viewer_recv_rel}" | tee -a "$ORCH_LOG"

  rm -f "$one_manifest"
done

echo "[streaming] $(date -u +%FT%TZ) done" | tee -a "$ORCH_LOG"
