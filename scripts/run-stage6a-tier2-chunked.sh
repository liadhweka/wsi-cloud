#!/usr/bin/env bash
# Stage 6.A Tier 2 chunked-raw-TIFF orchestrator.
#
# Full TCGA-BRCA (1131 slides with non-empty CLAM coords) raw-TIFF conversion +
# feature extraction in 6 chunks (200 + 200 + 200 + 200 + 200 + 131 slides per
# chunk by default). Each chunk:
#   1. Convert that chunk's SVS files → raw-TIFF on ${FS_MOUNT} (transient)
#   2. Run the Stage 6.A extractor against that chunk (writes per-slide .pt to
#      the persistent --output-dir; raw-TIFF is the transient input only)
#   3. Delete that chunk's raw-TIFF dir to reclaim disk
#
# WHY chunked:
#   Full-cohort raw-TIFF does not fit on the filesystem all-resident, so conversion
#   is chunked and each chunk's artifact is reclaimed before the next. That bounds
#   peak raw-TIFF usage to one chunk instead of the whole cohort.
#   ⏳ CHUNK_SIZE below was sized against a DIFFERENT environment's capacity. Re-derive
#   it from THIS leg's provisioned capacity ($WEKA_CAPACITY_TB / $FSX_CAPACITY_TIB) and
#   the measured per-slide raw-TIFF size before running Tier 2 — it is the parameter
#   that decides whether Tier 2 fits on disk at all, and a stale value either wastes
#   capacity or fails mid-cohort after hours of conversion.
#
# WHY inlined conversion (vs calling Stage 4.C's `convert-stage4c-rawtiff.sh`):
#   The Stage 4.C script hardcodes manifest paths + output dirs for the 50-slide
#   subset. Refactoring it would touch a closed-stage script. Cleaner to inline
#   the same logic (convert-rawtiff-20x.py, the tifffile-based TRUE-20x writer)
#   with our own chunk-specific paths.
#
# WHY one outer record-run.sh wrap (vs per-chunk record-run):
#   The customer-quotable cell is "model × backend × full-BRCA" — one number
#   per (model, backend) cell across the full dataset. record-run captures the
#   continuous time-series across all 6 chunks for that cell. Per-chunk timing
#   is emitted inline as a per-chunk-summary.csv inside the run dir for
#   forensic / debugging granularity.
#
# Usage (typically invoked by sweep-stage6a-extract.sh tier2):
#   ./run-stage6a-tier2-chunked.sh \\
#       --model virchow2 --n-gpus 4 --gpu-csv 0,1,2,3 \\
#       --output-dir ${FS_MOUNT}/features/6.A/virchow2/brca_full \\
#       --extraction-steps-csv <run-dir>/extraction-steps.csv \\
#       --per-slide-csv <run-dir>/per-slide.csv \\
#       --summary-json <run-dir>/extraction-summary.json \\
#       --per-chunk-summary <run-dir>/per-chunk-summary.csv \\
#       [--chunk-size 200] [--keep-rawtiff]
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
#
# CONVERT_PARALLEL = how many slides convert concurrently. convert-rawtiff-20x.py is
# single-threaded per slide (OpenSlide tile reads + tifffile write), so the knob is a
# count of concurrent slide conversions, bounded by the cores available and by the
# raw-TIFF write footprint a chunk holds at once. It is workload shape for a
# write-heavy phase measured against the filesystem, so it must be IDENTICAL on both
# legs: set it once in the environment for the whole comparison rather than editing a
# literal per leg, and it is recorded in the cell's summary JSON below so a cross-leg
# mismatch is visible instead of silently reshaping the write pattern being compared.
CONVERT_PARALLEL="${CONVERT_PARALLEL:-4}"
# Now that it comes from the environment, refuse a non-numeric value here rather than
# letting it reach `xargs -P` (which fails per chunk, after the run has started) and
# the summary JSON below (which interpolates it as a Python literal, at the very end).
case "$CONVERT_PARALLEL" in
  ''|*[!0-9]*|0) echo "CONVERT_PARALLEL must be a positive integer; got '$CONVERT_PARALLEL'" >&2; exit 2 ;;
esac

# Args
MODEL=""
N_GPUS=""
GPU_CSV=""
OUTPUT_DIR=""
EXTRACTION_STEPS_CSV=""
PER_SLIDE_CSV=""
SUMMARY_JSON=""
PER_CHUNK_SUMMARY=""
CHUNK_SIZE=200
KEEP_RAWTIFF=0
MAX_SLIDES=0  # 0 = process full manifest; nonzero = truncate (for smoke tests)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --n-gpus) N_GPUS="$2"; shift 2 ;;
    --gpu-csv) GPU_CSV="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --extraction-steps-csv) EXTRACTION_STEPS_CSV="$2"; shift 2 ;;
    --per-slide-csv) PER_SLIDE_CSV="$2"; shift 2 ;;
    --summary-json) SUMMARY_JSON="$2"; shift 2 ;;
    --per-chunk-summary) PER_CHUNK_SUMMARY="$2"; shift 2 ;;
    --chunk-size) CHUNK_SIZE="$2"; shift 2 ;;
    --keep-rawtiff) KEEP_RAWTIFF=1; shift ;;
    --max-slides) MAX_SLIDES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -z "$MODEL" ] && { echo "missing --model" >&2; exit 2; }
[ -z "$N_GPUS" ] && { echo "missing --n-gpus" >&2; exit 2; }
[ -z "$GPU_CSV" ] && { echo "missing --gpu-csv" >&2; exit 2; }
[ -z "$OUTPUT_DIR" ] && { echo "missing --output-dir" >&2; exit 2; }
[ -z "$EXTRACTION_STEPS_CSV" ] && { echo "missing --extraction-steps-csv" >&2; exit 2; }
[ -z "$PER_SLIDE_CSV" ] && { echo "missing --per-slide-csv" >&2; exit 2; }
[ -z "$SUMMARY_JSON" ] && { echo "missing --summary-json" >&2; exit 2; }
[ -z "$PER_CHUNK_SUMMARY" ] && { echo "missing --per-chunk-summary" >&2; exit 2; }

# Sanity
[ -x "$PY" ] || { echo "missing python $PY" >&2; exit 1; }
[ -f "$CONVERTER" ] || { echo "missing 20x converter $CONVERTER" >&2; exit 1; }
[ -f "$EXTRACTOR" ] || { echo "missing extractor $EXTRACTOR" >&2; exit 1; }

# cuFile mode — Tier 2 runs each leg's BEST AVAILABLE mode (docs/STAGES.md);
# the per-leg value follows that leg's D8 answer. Same single-channel contract
# as the sweep drivers.
CUFILE_COMPAT_MODE="${CUFILE_COMPAT_MODE:-off}"
case "$CUFILE_COMPAT_MODE" in
  off|on|auto) ;;
  *) echo "CUFILE_COMPAT_MODE must be off|on|auto, got '$CUFILE_COMPAT_MODE'" >&2; exit 2 ;;
esac
[ -f "$BRCA_FULL_MANIFEST" ] || { echo "missing manifest $BRCA_FULL_MANIFEST" >&2; exit 1; }

# Read all slide IDs (strip comments + header)
mapfile -t ALL_SLIDES < <(grep -v '^#' "$BRCA_FULL_MANIFEST" | grep -v '^slide_id$' | grep -v '^[[:space:]]*$')
N_TOTAL=${#ALL_SLIDES[@]}

# Truncate for smoke tests
if [ "$MAX_SLIDES" -gt 0 ] && [ "$MAX_SLIDES" -lt "$N_TOTAL" ]; then
  ALL_SLIDES=("${ALL_SLIDES[@]:0:$MAX_SLIDES}")
  N_TOTAL=${#ALL_SLIDES[@]}
  echo "[chunked] --max-slides $MAX_SLIDES: truncated manifest to $N_TOTAL slides"
fi

echo "[chunked] manifest: $N_TOTAL slides; chunk size $CHUNK_SIZE"
N_CHUNKS=$(( (N_TOTAL + CHUNK_SIZE - 1) / CHUNK_SIZE ))
echo "[chunked] $N_CHUNKS chunks total"

# Initialize per-chunk summary CSV
{
  echo "chunk_idx,n_slides_in_chunk,t_chunk_start_s,t_convert_end_s,t_extract_end_s,t_cleanup_end_s,convert_wallclock_s,extract_wallclock_s,cleanup_wallclock_s,convert_status,extract_status,n_slides_converted_ok,n_slides_extracted"
} > "$PER_CHUNK_SUMMARY"

T_ORCH_START=$(date +%s.%N)

# Working state
CHUNK_BASE=${FS_MOUNT}/data/tcga-brca-rawtiff-chunk
TMP_BASE=$(mktemp -d /tmp/stage6a-tier2-chunked-XXXXXX)
trap 'echo "[chunked] cleanup tmp"; rm -rf "$TMP_BASE"' EXIT

# Per-chunk extraction CSVs (per-rank within the extractor; orchestrator concats at end)
EX_STEPS_CHUNK_DIR="$TMP_BASE/ex-steps"
PER_SLIDE_CHUNK_DIR="$TMP_BASE/per-slide"
mkdir -p "$EX_STEPS_CHUNK_DIR" "$PER_SLIDE_CHUNK_DIR"

# ---------- Inline convert_one (lifted from convert-stage4c-rawtiff.sh) ----------
# 20× (Option B): TRUE 20× raw-TIFF via convert-rawtiff-20x.py (tifffile writer;
# `cucim convert` can't target 20×). BRCA-only here → fixed read-level 0,
# read-size 512 (read 512px@40× → resize to 256 = 20×). No CWD mmap temp files,
# so the old cucim per-process scratch-dir SIGBUS workaround is gone.
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

# ---------- Main loop over chunks ----------
mkdir -p "$OUTPUT_DIR"

for ((CHUNK_IDX=0; CHUNK_IDX<N_CHUNKS; CHUNK_IDX++)); do
  CHUNK_START=$((CHUNK_IDX * CHUNK_SIZE))
  CHUNK_END=$((CHUNK_START + CHUNK_SIZE))
  [ $CHUNK_END -gt $N_TOTAL ] && CHUNK_END=$N_TOTAL
  N_IN_CHUNK=$((CHUNK_END - CHUNK_START))

  CHUNK_RAWTIFF_DIR="${CHUNK_BASE}-${CHUNK_IDX}"
  CHUNK_MANIFEST="$TMP_BASE/chunk-${CHUNK_IDX}-manifest.tsv"
  EX_STEPS_CHUNK="$EX_STEPS_CHUNK_DIR/extraction-steps-chunk-${CHUNK_IDX}.csv"
  PER_SLIDE_CHUNK="$PER_SLIDE_CHUNK_DIR/per-slide-chunk-${CHUNK_IDX}.csv"

  echo ""
  echo "========================================================"
  echo "[chunk $CHUNK_IDX/$N_CHUNKS] slides $CHUNK_START..$((CHUNK_END-1)) ($N_IN_CHUNK slides)"
  echo "  rawtiff dir: $CHUNK_RAWTIFF_DIR"
  echo "========================================================"

  T_CHUNK_START=$(date +%s.%N)

  # Build chunk-specific manifest (Stage 4.A format)
  {
    echo "# Stage 6.A Tier 2 chunk $CHUNK_IDX of $N_CHUNKS"
    echo "# Generated $(date -u +%FT%TZ)"
    echo "# Slides $CHUNK_START..$((CHUNK_END-1)) of $N_TOTAL"
    echo "slide_id"
    for ((i=CHUNK_START; i<CHUNK_END; i++)); do
      echo "${ALL_SLIDES[$i]}"
    done
  } > "$CHUNK_MANIFEST"

  # ---------- Step 1: Convert SVS → raw-TIFF in parallel ----------
  mkdir -p "$CHUNK_RAWTIFF_DIR"

  set -m  # job control on
  trap 'echo "[chunk-${CHUNK_IDX}] got SIGTERM, killing process group"; kill -TERM 0; wait; exit 143' TERM INT

  # Slide IDs for this chunk, fed via xargs to parallel converters
  CONVERT_OK_COUNT=0
  {
    for ((i=CHUNK_START; i<CHUNK_END; i++)); do
      echo "${ALL_SLIDES[$i]}"
    done
  } | xargs -P "$CONVERT_PARALLEL" -n 1 -I {} bash -c \
       'convert_one_inline "$1" "'"$BRCA_SVS"'" "'"$CHUNK_RAWTIFF_DIR"'"' _ {} || true

  CONVERT_OK_COUNT=$(ls "$CHUNK_RAWTIFF_DIR"/*.tiff 2>/dev/null | wc -l)

  # convert_status is DERIVED from the count, never asserted. The xargs above ends in
  # `|| true` (it exits non-zero whenever any child failed, which is expected and
  # already counted), so nothing else carries the conversion's outcome. Hardcoding "OK"
  # lets a chunk that converted 12 of 200 slides proceed to extraction, record OK, and
  # contribute its (short) conversion wallclock to the cell's cost-to-complete — while
  # the one column that exists to answer "did this chunk convert?" says it did, and only
  # cross-reading n_slides_converted_ok against n_slides_in_chunk reveals otherwise.
  if [ "$CONVERT_OK_COUNT" -eq "$N_IN_CHUNK" ]; then
    CONVERT_STATUS="OK"
  elif [ "$CONVERT_OK_COUNT" -eq 0 ]; then
    CONVERT_STATUS="FAIL"
  else
    CONVERT_STATUS="PARTIAL"
  fi

  T_CONVERT_END=$(date +%s.%N)
  CONVERT_WALL=$(awk "BEGIN{print $T_CONVERT_END - $T_CHUNK_START}")
  echo "[chunk $CHUNK_IDX] convert: $CONVERT_STATUS — $CONVERT_OK_COUNT/$N_IN_CHUNK slides ok in ${CONVERT_WALL}s"

  if [ "$CONVERT_OK_COUNT" -eq 0 ]; then
    echo "[chunk $CHUNK_IDX] FATAL: no slides converted; aborting chunk"
    printf "%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d\n" \
      "$CHUNK_IDX" "$N_IN_CHUNK" "$T_CHUNK_START" "$T_CONVERT_END" "$T_CONVERT_END" "$T_CONVERT_END" \
      "$CONVERT_WALL" "0" "0" "$CONVERT_STATUS" "SKIP" "0" "0" >> "$PER_CHUNK_SUMMARY"
    rm -rf "$CHUNK_RAWTIFF_DIR"
    continue
  fi

  # ---------- Step 2: Extract features for this chunk ----------
  EXTRACT_STATUS="OK"
  CUDA_VISIBLE_DEVICES="$GPU_CSV" \
  "$PY" "$EXTRACTOR" \
    --backend kvikio --world-size "$N_GPUS" --model "$MODEL" \
    --rawtiff-dir "$CHUNK_RAWTIFF_DIR" \
    --coords-dir "$BRCA_COORDS" \
    --manifest "$CHUNK_MANIFEST" \
    --output-dir "$OUTPUT_DIR" \
    --batch-size 256 \
    --extraction-steps-csv "$EX_STEPS_CHUNK" \
    --per-slide-csv "$PER_SLIDE_CHUNK" \
    --summary-json "$TMP_BASE/chunk-${CHUNK_IDX}-summary.json" \
    --n-buffer 256 --num-threads 16 --compat-mode "$CUFILE_COMPAT_MODE" || EXTRACT_STATUS="FAIL"

  T_EXTRACT_END=$(date +%s.%N)
  EXTRACT_WALL=$(awk "BEGIN{print $T_EXTRACT_END - $T_CONVERT_END}")
  N_EXTRACTED=$(ls "$OUTPUT_DIR"/*.pt 2>/dev/null | wc -l)
  echo "[chunk $CHUNK_IDX] extract: $EXTRACT_STATUS in ${EXTRACT_WALL}s; persistent .pt count now $N_EXTRACTED"

  # ---------- Step 3: Cleanup chunk raw-TIFF (free disk for next chunk) ----------
  if [ "$KEEP_RAWTIFF" -eq 0 ]; then
    rm -rf "$CHUNK_RAWTIFF_DIR"
    echo "[chunk $CHUNK_IDX] cleaned $CHUNK_RAWTIFF_DIR"
  else
    echo "[chunk $CHUNK_IDX] --keep-rawtiff set; retaining $CHUNK_RAWTIFF_DIR"
  fi
  T_CLEANUP_END=$(date +%s.%N)
  CLEANUP_WALL=$(awk "BEGIN{print $T_CLEANUP_END - $T_EXTRACT_END}")

  # Per-chunk row
  printf "%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d\n" \
    "$CHUNK_IDX" "$N_IN_CHUNK" "$T_CHUNK_START" "$T_CONVERT_END" "$T_EXTRACT_END" "$T_CLEANUP_END" \
    "$CONVERT_WALL" "$EXTRACT_WALL" "$CLEANUP_WALL" "$CONVERT_STATUS" "$EXTRACT_STATUS" \
    "$CONVERT_OK_COUNT" "$N_EXTRACTED" >> "$PER_CHUNK_SUMMARY"
done

# ---------- Merge per-chunk CSVs into the outer extraction-steps + per-slide ----------
T_MERGE_START=$(date +%s.%N)
mkdir -p "$(dirname "$EXTRACTION_STEPS_CSV")" "$(dirname "$PER_SLIDE_CSV")"

# extraction-steps.csv: concat all chunk CSVs (keep header from first; skip in rest)
FIRST=1
for f in "$EX_STEPS_CHUNK_DIR"/*.csv; do
  [ -f "$f" ] || continue
  if [ "$FIRST" -eq 1 ]; then
    cat "$f" > "$EXTRACTION_STEPS_CSV"
    FIRST=0
  else
    tail -n +2 "$f" >> "$EXTRACTION_STEPS_CSV"
  fi
done

# per-slide.csv: same pattern
FIRST=1
for f in "$PER_SLIDE_CHUNK_DIR"/*.csv; do
  [ -f "$f" ] || continue
  if [ "$FIRST" -eq 1 ]; then
    cat "$f" > "$PER_SLIDE_CSV"
    FIRST=0
  else
    tail -n +2 "$f" >> "$PER_SLIDE_CSV"
  fi
done

T_END=$(date +%s.%N)
TOTAL_WALL=$(awk "BEGIN{print $T_END - $T_ORCH_START}")

# Aggregate summary JSON (concat-style — keeps Stage 6.A extraction-summary.json contract)
N_TOTAL_EXTRACTED=$(ls "$OUTPUT_DIR"/*.pt 2>/dev/null | wc -l)
"$PY" -c "
import json
summary = {
    'model': '$MODEL',
    'backend': 'kvikio',
    'world_size': $N_GPUS,
    'orchestrator': 'run-stage6a-tier2-chunked.sh',
    'n_chunks': $N_CHUNKS,
    'chunk_size_target': $CHUNK_SIZE,
    'convert_parallel': $CONVERT_PARALLEL,
    'n_slides_manifest': $N_TOTAL,
    'n_slides_extracted_total': $N_TOTAL_EXTRACTED,
    'cell_wallclock_s': $TOTAL_WALL,
    'per_chunk_summary_csv': '$PER_CHUNK_SUMMARY',
    'extraction_steps_csv_merged': '$EXTRACTION_STEPS_CSV',
    'per_slide_csv_merged': '$PER_SLIDE_CSV',
    'output_dir': '$OUTPUT_DIR',
    'dataset_tag': 'brca_full',
    'note': 'Aggregate of per-chunk extractions; per-chunk timing is in per_chunk_summary_csv. WEKA-side time-series (raw/) covers the full orchestrator wallclock including chunk-conversion phases.',
}
with open('$SUMMARY_JSON', 'w') as f:
    json.dump(summary, f, indent=2)
print('=== summary ===')
print(json.dumps(summary, indent=2))
"

echo ""
echo "[chunked] DONE. $N_TOTAL_EXTRACTED .pt files in $OUTPUT_DIR. Total wallclock: ${TOTAL_WALL}s"
