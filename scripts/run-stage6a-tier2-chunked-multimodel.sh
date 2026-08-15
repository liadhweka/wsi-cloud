#!/usr/bin/env bash
# Stage 6.A Tier 2 chunked-raw-TIFF orchestrator — MULTI-MODEL variant.
#
# Same shape as run-stage6a-tier2-chunked.sh, but shares converted raw-TIFF
# across multiple foundation models within each chunk. Loop order:
#   for chunk in chunks:
#     convert chunk SVS → raw-TIFF (once)
#     for model in MODELS:
#       extract chunk → write per-slide .pt to <output_dir_base>/<model>/brca_full
#     cleanup chunk raw-TIFF
#
# WHY this exists (vs the single-model orchestrator):
#   For Stage 6.A Tier 2 across 3 models, the single-model orchestrator would
#   convert each slide 3 times (once per model run). Conversion is a large share of
#   per-chunk wallclock, so sharing it within each chunk's lifetime is STRUCTURAL,
#   not a micro-optimisation — full-cohort raw-TIFF does not fit at once, and the
#   saving scales with the model count. Each model's per-slide .pt output is still
#   produced for downstream Stage 6.B/6.D use.
#   Actual per-chunk convert-vs-extract split is RECORDED per run, not estimated
#   here — a wallclock estimate from another environment would be fiction.
#
# WHY a new file (vs editing the single-model orchestrator):
#   The single-model file is validated and correct for
#   the smoke + the future "one-off rerun a single model" workflow. New
#   surface area, new file. Conversion logic is duplicated; if a conversion
#   bug surfaces in one, fix both.
#
# Usage (typically invoked by sweep-stage6a-extract.sh tier2):
#   ./run-stage6a-tier2-chunked-multimodel.sh \\
#       --models virchow2,gigapath,uni2-h --n-gpus 4 --gpu-csv 0,1,2,3 \\
#       --output-dir-base ${FS_MOUNT}/features/6.A \\
#       --run-dir <run-dir-from-record-run> \\
#       [--chunk-size 200] [--max-slides N] [--keep-rawtiff]
#
# Per-model artifacts in --run-dir:
#   extraction-steps-<model>.csv      (merged across chunks)
#   per-slide-<model>.csv             (merged across chunks)
#   extraction-summary-<model>.json   (per-model headline — aggregator picks these up)
# Top-level artifacts in --run-dir:
#   per-chunk-summary.csv             (one row per (chunk, model) with timing)
#   extraction-summary.json           (multi-model aggregate)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
CONVERTER="$REPO/scripts/convert-rawtiff-20x.py"
EXTRACTOR="$REPO/scripts/extract-features-foundation-stage6.py"

# Fixed paths
BRCA_SVS=${FS_MOUNT}/data/tcga-brca
BRCA_COORDS=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches
BRCA_FULL_MANIFEST=$REPO/scripts/manifests/tcga-brca-full40x-stage4a-format.tsv

# Conversion: TRUE 20× raw-TIFF via convert-rawtiff-20x.py (see CONVERTER above).
# BRCA-only here → read-level 0, read-size 512 (set in convert_one_inline).
CONVERT_PARALLEL=4

# Args
MODELS=""
N_GPUS=""
GPU_CSV=""
OUTPUT_DIR_BASE=""
RUN_DIR=""
# ⏳ D-8/D-11: sized against a DIFFERENT environment's capacity. Re-derive from THIS
# leg's provisioned capacity ($WEKA_CAPACITY_TB / $FSX_CAPACITY_TIB) and the measured
# per-slide raw-TIFF size before running Tier 2 — this is the parameter that decides
# whether Tier 2 fits on disk, and a stale value either wastes capacity or fails
# mid-cohort after hours of conversion. Override with --chunk-size.
CHUNK_SIZE=200
KEEP_RAWTIFF=0
MAX_SLIDES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models) MODELS="$2"; shift 2 ;;
    --n-gpus) N_GPUS="$2"; shift 2 ;;
    --gpu-csv) GPU_CSV="$2"; shift 2 ;;
    --output-dir-base) OUTPUT_DIR_BASE="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --chunk-size) CHUNK_SIZE="$2"; shift 2 ;;
    --keep-rawtiff) KEEP_RAWTIFF=1; shift ;;
    --max-slides) MAX_SLIDES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -z "$MODELS" ] && { echo "missing --models (comma-separated)" >&2; exit 2; }
[ -z "$N_GPUS" ] && { echo "missing --n-gpus" >&2; exit 2; }
[ -z "$GPU_CSV" ] && { echo "missing --gpu-csv" >&2; exit 2; }
[ -z "$OUTPUT_DIR_BASE" ] && { echo "missing --output-dir-base" >&2; exit 2; }
[ -z "$RUN_DIR" ] && { echo "missing --run-dir" >&2; exit 2; }

# Sanity
[ -x "$PY" ] || { echo "missing python $PY" >&2; exit 1; }
[ -f "$CONVERTER" ] || { echo "missing 20x converter $CONVERTER" >&2; exit 1; }
[ -f "$EXTRACTOR" ] || { echo "missing extractor $EXTRACTOR" >&2; exit 1; }
[ -f "$BRCA_FULL_MANIFEST" ] || { echo "missing manifest $BRCA_FULL_MANIFEST" >&2; exit 1; }
[ -d "$RUN_DIR" ] || { echo "missing --run-dir $RUN_DIR (record-run.sh should create it)" >&2; exit 1; }

# Split MODELS
IFS=',' read -ra MODEL_ARR <<< "$MODELS"
N_MODELS=${#MODEL_ARR[@]}
[ "$N_MODELS" -lt 1 ] && { echo "no models parsed from --models=$MODELS" >&2; exit 2; }

echo "[chunked-multi] models: ${MODEL_ARR[*]} (count=$N_MODELS)"
echo "[chunked-multi] output base: $OUTPUT_DIR_BASE"

# Read all slide IDs
mapfile -t ALL_SLIDES < <(grep -v '^#' "$BRCA_FULL_MANIFEST" | grep -v '^slide_id$' | grep -v '^[[:space:]]*$')
N_TOTAL=${#ALL_SLIDES[@]}

if [ "$MAX_SLIDES" -gt 0 ] && [ "$MAX_SLIDES" -lt "$N_TOTAL" ]; then
  ALL_SLIDES=("${ALL_SLIDES[@]:0:$MAX_SLIDES}")
  N_TOTAL=${#ALL_SLIDES[@]}
  echo "[chunked-multi] --max-slides $MAX_SLIDES: truncated manifest to $N_TOTAL slides"
fi

echo "[chunked-multi] manifest: $N_TOTAL slides; chunk size $CHUNK_SIZE"
N_CHUNKS=$(( (N_TOTAL + CHUNK_SIZE - 1) / CHUNK_SIZE ))
echo "[chunked-multi] $N_CHUNKS chunks total"

# Per-chunk-summary header (model column added)
PER_CHUNK_SUMMARY="$RUN_DIR/per-chunk-summary.csv"
{
  echo "chunk_idx,model,n_slides_in_chunk,t_chunk_start_s,t_convert_end_s,t_extract_end_s,t_cleanup_end_s,convert_wallclock_s,extract_wallclock_s,cleanup_wallclock_s,convert_status,extract_status,n_slides_converted_ok,n_slides_extracted_for_model"
} > "$PER_CHUNK_SUMMARY"

T_ORCH_START=$(date +%s.%N)

# Working state
CHUNK_BASE=${FS_MOUNT}/data/tcga-brca-rawtiff-chunk
TMP_BASE=$(mktemp -d /tmp/stage6a-tier2-chunked-multi-XXXXXX)
trap 'echo "[chunked-multi] cleanup tmp $TMP_BASE"; rm -rf "$TMP_BASE"' EXIT

# Per-model per-chunk CSV dirs (orchestrator concats at end)
for model in "${MODEL_ARR[@]}"; do
  mkdir -p "$TMP_BASE/$model/ex-steps" "$TMP_BASE/$model/per-slide" "$TMP_BASE/$model/summary"
done

# ---------- convert_one_inline (TRUE 20× raw-TIFF; BRCA-only) ----------
# 20× (Option B): via convert-rawtiff-20x.py (tifffile writer; `cucim convert`
# can't target 20×). BRCA-only → fixed read-level 0, read-size 512 (read
# 512px@40× → resize to 256 = 20×). No CWD mmap temp files, so the old cucim
# per-process scratch-dir SIGBUS workaround is gone.
convert_one_inline() {
  local sid="$1"
  local src_dir="$2"
  local dst_dir="$3"
  local src dst dst_partial t0 t1 wall status

  src=$(find "$src_dir" -name "${sid}.svs" 2>/dev/null | head -1)
  if [ -z "$src" ]; then
    echo "[convert-fail-nosrc] $sid"
    return 1
  fi
  dst="$dst_dir/${sid}.tiff"
  dst_partial="${dst}.partial"

  if [ -f "$dst" ] && [ -s "$dst" ]; then
    echo "[convert-skip-exists] $sid"
    return 0
  fi

  rm -f "$dst_partial"

  t0=$(date +%s)
  if CONDA_PREFIX="$CONDA_ENV" "$PY" "$CONVERTER" \
       --src "$src" --dst "$dst_partial" \
       --read-level 0 --read-size 512 \
       >/dev/null 2>&1; then
    mv "$dst_partial" "$dst"
    status="OK"
  else
    rm -f "$dst_partial"
    status="FAIL"
  fi
  t1=$(date +%s)
  wall=$((t1 - t0))
  echo "[$status] $sid wall=${wall}s"
  [ "$status" = "OK" ] && return 0 || return 1
}
export -f convert_one_inline
export CONDA_ENV PY CONVERTER

# ---------- Pre-create per-model output dirs ----------
declare -A MODEL_OUTPUT_DIR
for model in "${MODEL_ARR[@]}"; do
  MODEL_OUTPUT_DIR[$model]="${OUTPUT_DIR_BASE}/${model}/brca_full"
  mkdir -p "${MODEL_OUTPUT_DIR[$model]}"
done

# ---------- Main loop over chunks ----------
for ((CHUNK_IDX=0; CHUNK_IDX<N_CHUNKS; CHUNK_IDX++)); do
  CHUNK_START=$((CHUNK_IDX * CHUNK_SIZE))
  CHUNK_END=$((CHUNK_START + CHUNK_SIZE))
  [ $CHUNK_END -gt $N_TOTAL ] && CHUNK_END=$N_TOTAL
  N_IN_CHUNK=$((CHUNK_END - CHUNK_START))

  CHUNK_RAWTIFF_DIR="${CHUNK_BASE}-${CHUNK_IDX}"
  CHUNK_MANIFEST="$TMP_BASE/chunk-${CHUNK_IDX}-manifest.tsv"

  echo ""
  echo "========================================================"
  echo "[chunk $CHUNK_IDX/$N_CHUNKS] slides $CHUNK_START..$((CHUNK_END-1)) ($N_IN_CHUNK slides)"
  echo "  rawtiff dir: $CHUNK_RAWTIFF_DIR"
  echo "  models: ${MODEL_ARR[*]}"
  echo "========================================================"

  T_CHUNK_START=$(date +%s.%N)

  # Build chunk-specific manifest
  {
    echo "# Stage 6.A Tier 2 chunk $CHUNK_IDX of $N_CHUNKS (multi-model)"
    echo "# Generated $(date -u +%FT%TZ)"
    echo "# Slides $CHUNK_START..$((CHUNK_END-1)) of $N_TOTAL"
    echo "slide_id"
    for ((i=CHUNK_START; i<CHUNK_END; i++)); do
      echo "${ALL_SLIDES[$i]}"
    done
  } > "$CHUNK_MANIFEST"

  # ---------- Step 1: Convert SVS → raw-TIFF in parallel (ONCE per chunk) ----------
  mkdir -p "$CHUNK_RAWTIFF_DIR"

  set -m
  trap 'echo "[chunk-${CHUNK_IDX}] got SIGTERM, killing process group"; kill -TERM 0; wait; exit 143' TERM INT

  {
    for ((i=CHUNK_START; i<CHUNK_END; i++)); do
      echo "${ALL_SLIDES[$i]}"
    done
  } | xargs -P "$CONVERT_PARALLEL" -n 1 -I {} bash -c \
       'convert_one_inline "$1" "'"$BRCA_SVS"'" "'"$CHUNK_RAWTIFF_DIR"'"' _ {} || true

  CONVERT_OK_COUNT=$(ls "$CHUNK_RAWTIFF_DIR"/*.tiff 2>/dev/null | wc -l)
  T_CONVERT_END=$(date +%s.%N)
  CONVERT_WALL=$(awk "BEGIN{print $T_CONVERT_END - $T_CHUNK_START}")
  echo "[chunk $CHUNK_IDX] convert: $CONVERT_OK_COUNT/$N_IN_CHUNK slides ok in ${CONVERT_WALL}s"

  if [ "$CONVERT_OK_COUNT" -eq 0 ]; then
    echo "[chunk $CHUNK_IDX] FATAL: no slides converted; aborting chunk"
    for model in "${MODEL_ARR[@]}"; do
      printf "%d,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d\n" \
        "$CHUNK_IDX" "$model" "$N_IN_CHUNK" "$T_CHUNK_START" "$T_CONVERT_END" "$T_CONVERT_END" "$T_CONVERT_END" \
        "$CONVERT_WALL" "0" "0" "FAIL" "SKIP" "0" "0" >> "$PER_CHUNK_SUMMARY"
    done
    rm -rf "$CHUNK_RAWTIFF_DIR"
    continue
  fi

  # ---------- Step 2: Extract features for each model from this chunk ----------
  T_EXTRACT_PHASE_START=$(date +%s.%N)
  for model in "${MODEL_ARR[@]}"; do
    echo ""
    echo "[chunk $CHUNK_IDX] extracting model=$model"
    T_MODEL_START=$(date +%s.%N)

    EX_STEPS_CHUNK="$TMP_BASE/$model/ex-steps/extraction-steps-chunk-${CHUNK_IDX}.csv"
    PER_SLIDE_CHUNK="$TMP_BASE/$model/per-slide/per-slide-chunk-${CHUNK_IDX}.csv"
    SUMMARY_CHUNK="$TMP_BASE/$model/summary/summary-chunk-${CHUNK_IDX}.json"

    EXTRACT_STATUS="OK"
    CUDA_VISIBLE_DEVICES="$GPU_CSV" \
    "$PY" "$EXTRACTOR" \
      --backend kvikio --world-size "$N_GPUS" --model "$model" \
      --rawtiff-dir "$CHUNK_RAWTIFF_DIR" \
      --coords-dir "$BRCA_COORDS" \
      --manifest "$CHUNK_MANIFEST" \
      --output-dir "${MODEL_OUTPUT_DIR[$model]}" \
      --batch-size 256 \
      --extraction-steps-csv "$EX_STEPS_CHUNK" \
      --per-slide-csv "$PER_SLIDE_CHUNK" \
      --summary-json "$SUMMARY_CHUNK" \
      --n-buffer 256 --num-threads 16 || EXTRACT_STATUS="FAIL"

    T_MODEL_END=$(date +%s.%N)
    EXTRACT_WALL=$(awk "BEGIN{print $T_MODEL_END - $T_MODEL_START}")
    N_EXTRACTED_FOR_MODEL=$(ls "${MODEL_OUTPUT_DIR[$model]}"/*.pt 2>/dev/null | wc -l)
    echo "[chunk $CHUNK_IDX][$model] extract: $EXTRACT_STATUS in ${EXTRACT_WALL}s; persistent .pt count for $model now $N_EXTRACTED_FOR_MODEL"

    # Per-chunk per-model row
    printf "%d,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d\n" \
      "$CHUNK_IDX" "$model" "$N_IN_CHUNK" "$T_CHUNK_START" "$T_CONVERT_END" "$T_MODEL_END" "$T_MODEL_END" \
      "$CONVERT_WALL" "$EXTRACT_WALL" "0" "OK" "$EXTRACT_STATUS" \
      "$CONVERT_OK_COUNT" "$N_EXTRACTED_FOR_MODEL" >> "$PER_CHUNK_SUMMARY"
  done
  T_EXTRACT_PHASE_END=$(date +%s.%N)
  EXTRACT_PHASE_WALL=$(awk "BEGIN{print $T_EXTRACT_PHASE_END - $T_EXTRACT_PHASE_START}")
  echo "[chunk $CHUNK_IDX] all-model extract phase: ${EXTRACT_PHASE_WALL}s"

  # ---------- Step 3: Cleanup chunk raw-TIFF ----------
  if [ "$KEEP_RAWTIFF" -eq 0 ]; then
    rm -rf "$CHUNK_RAWTIFF_DIR"
    echo "[chunk $CHUNK_IDX] cleaned $CHUNK_RAWTIFF_DIR"
  else
    echo "[chunk $CHUNK_IDX] --keep-rawtiff set; retaining $CHUNK_RAWTIFF_DIR"
  fi
done

# ---------- Per-model CSV merging + summary JSONs ----------
T_MERGE_START=$(date +%s.%N)

for model in "${MODEL_ARR[@]}"; do
  EX_STEPS_OUT="$RUN_DIR/extraction-steps-${model}.csv"
  PER_SLIDE_OUT="$RUN_DIR/per-slide-${model}.csv"
  SUMMARY_OUT="$RUN_DIR/extraction-summary-${model}.json"

  # extraction-steps merge
  FIRST=1
  for f in "$TMP_BASE/$model/ex-steps"/*.csv; do
    [ -f "$f" ] || continue
    if [ "$FIRST" -eq 1 ]; then
      cat "$f" > "$EX_STEPS_OUT"; FIRST=0
    else
      tail -n +2 "$f" >> "$EX_STEPS_OUT"
    fi
  done

  # per-slide merge
  FIRST=1
  for f in "$TMP_BASE/$model/per-slide"/*.csv; do
    [ -f "$f" ] || continue
    if [ "$FIRST" -eq 1 ]; then
      cat "$f" > "$PER_SLIDE_OUT"; FIRST=0
    else
      tail -n +2 "$f" >> "$PER_SLIDE_OUT"
    fi
  done

  # Per-model summary JSON: aggregate per-chunk stats by reading per-chunk summaries
  N_THIS_MODEL=$(ls "${MODEL_OUTPUT_DIR[$model]}"/*.pt 2>/dev/null | wc -l)
  "$PY" -c "
import json, glob, sys
chunk_files = sorted(glob.glob('$TMP_BASE/$model/summary/summary-chunk-*.json'))
total_tiles_steady = 0.0
total_steady_steps = 0.0
total_extract_wall = 0.0
n_chunks_with_data = 0
embed_dim = None
for cf in chunk_files:
    try:
        with open(cf) as h: d = json.load(h)
    except Exception:
        continue
    total_tiles_steady += d.get('total_tiles_steady_phase', 0.0)
    total_steady_steps += d.get('total_steady_steps', 0.0)
    total_extract_wall += d.get('cell_wallclock_s', 0.0)
    embed_dim = embed_dim or d.get('embedding_dim')
    n_chunks_with_data += 1
tps = (total_tiles_steady / total_extract_wall) if total_extract_wall > 0 else 0.0
summary = {
    'model': '$model',
    'backend': 'kvikio',
    'world_size': $N_GPUS,
    'orchestrator': 'run-stage6a-tier2-chunked-multimodel.sh',
    'n_chunks_with_data': n_chunks_with_data,
    'chunk_size_target': $CHUNK_SIZE,
    'n_slides_manifest': $N_TOTAL,
    'n_slides_extracted_total': $N_THIS_MODEL,
    'total_tiles_steady_phase': total_tiles_steady,
    'total_steady_steps': total_steady_steps,
    'cell_wallclock_s': total_extract_wall,
    'tiles_per_sec_aggregate_steady': tps,
    'embedding_dim': embed_dim,
    'extraction_steps_csv': '$EX_STEPS_OUT',
    'per_slide_csv': '$PER_SLIDE_OUT',
    'output_dir': '${MODEL_OUTPUT_DIR[$model]}',
    'dataset_tag': 'brca_full',
    'n_ramp_steps_excluded': 10,
    'dtype_out': 'fp32',
}
with open('$SUMMARY_OUT', 'w') as h: json.dump(summary, h, indent=2)
"
done

T_END=$(date +%s.%N)
TOTAL_WALL=$(awk "BEGIN{print $T_END - $T_ORCH_START}")

# ---------- Outer multi-model summary JSON ----------
"$PY" -c "
import json
models = '${MODEL_ARR[*]}'.split()
summary = {
    'orchestrator': 'run-stage6a-tier2-chunked-multimodel.sh',
    'models': models,
    'backend': 'kvikio',
    'world_size': $N_GPUS,
    'n_chunks': $N_CHUNKS,
    'chunk_size_target': $CHUNK_SIZE,
    'n_slides_manifest': $N_TOTAL,
    'cell_wallclock_s': $TOTAL_WALL,
    'per_chunk_summary_csv': '$PER_CHUNK_SUMMARY',
    'per_model_summaries': ['$RUN_DIR/extraction-summary-' + m + '.json' for m in models],
    'dataset_tag': 'brca_full',
    'note': 'Multi-model chunked Tier 2 — convert-once-per-chunk shared across models. Per-model headlines in extraction-summary-<model>.json (aggregator picks these up).',
}
with open('$RUN_DIR/extraction-summary.json', 'w') as h:
    json.dump(summary, h, indent=2)
print(json.dumps(summary, indent=2))
"

echo ""
echo "[chunked-multi] DONE. Total wallclock: ${TOTAL_WALL}s"
for model in "${MODEL_ARR[@]}"; do
  N=$(ls "${MODEL_OUTPUT_DIR[$model]}"/*.pt 2>/dev/null | wc -l)
  echo "  $model: $N .pt files in ${MODEL_OUTPUT_DIR[$model]}"
done
