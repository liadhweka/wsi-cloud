#!/usr/bin/env bash
# Stage 4.C prep — convert Stage 4.A subset slides (50 BRCA + 50 CAMELYON16) to
# uncompressed raw TIFF on /mnt/liad for the kvikIO+GDS sweep.
#
# WHY this is a recorded "Stage 4.C-convert" cell rather than a flat tee'd log:
#   - 100 slides × ~30-80 GB raw output each = ~6-10 TB sustained writes to wekafs.
#   - That's a genuine recordable workload (matches Stage 1.5's recording pattern
#     for the local-NVMe-staged re-stage). The recording captures sustained wekafs
#     write throughput under 4-way-parallel conversion at scale as a side
#     data point.
#   - Per CLAUDE.md memory-hygiene rule + project preference for recording any
#     measurable WSI workload.
#
# WHY 4-way parallelism (PARALLEL, override-able):
#   - convert-rawtiff-20x.py is single-threaded per slide (OpenSlide tile reads
#     + tifffile write), so PARALLEL = slides converted concurrently. 4 is
#     conservative on a 256-core box; raise it (PARALLEL=8/16) if conversion
#     wallclock matters at Tier-2 scale — tune at the Step-5 pre-flight.
#
# WHY output tile-size 256 @ 20×:
#   - Keeps the Stage 4.C tile grid apples-to-apples with 4.A/4.B and matches
#     what UNI2-h / Virchow2 / GigaPath consume (20× / 256px, the published
#     foundation-model protocol).
#
# WHY idempotent skip on existing output:
#   - Per project memory `feedback_accuracy_safety_dependability.md`: idempotent
#     scripts let us resume cleanly without double-converting.
#
# Usage:
#   ./runs/lib/convert-stage4c-rawtiff.sh           # convert all 100 slides
#   PARALLEL=8 ./runs/lib/convert-stage4c-rawtiff.sh  # override parallelism

set -uo pipefail

REPO=/home/liadhermelin/wsi/rerun_new_TRUERESULTS
CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604
PYTHON="$CONDA_ENV/bin/python3"
CONVERTER="$REPO/runs/lib/convert-rawtiff-20x.py"

# 20× (Option B): produce a TRUE 20× raw-TIFF via convert-rawtiff-20x.py.
# `cucim convert` can't target 20× (always emits the SVS 40× level-0 — verified
# vs cucim 26.4.0 cli.py), so we use a tifffile-based writer. Per-dataset read
# params are set in convert_one (CAM16 native level 1 @ 256; BRCA 512@40× → 256).
PARALLEL="${PARALLEL:-4}"

BRCA_MANIFEST="$REPO/runs/manifests/tcga-brca-stage4a-subset.tsv"
CAM_MANIFEST="$REPO/runs/manifests/camelyon16-stage4a-subset.tsv"

BRCA_SRC_DIR=/mnt/liad/data/tcga-brca
CAM_SRC_DIR=/mnt/liad/data/camelyon16/images

BRCA_DST_DIR=/mnt/liad/data/tcga-brca-rawtiff
CAM_DST_DIR=/mnt/liad/data/camelyon16-rawtiff

mkdir -p "$BRCA_DST_DIR" "$CAM_DST_DIR"

# Per-slide conversion log — one row per slide attempted.
LOG_TSV="${LOG_TSV:-$REPO/runs/stage4c-convert-log.tsv}"
if [ ! -f "$LOG_TSV" ]; then
  printf "timestamp\tdataset\tslide_id\tsrc_size\tdst_size\twallclock_s\tstatus\n" > "$LOG_TSV"
fi

# Run all our work in our own process group so a SIGTERM to the script
# cascades to xargs + bash -c subshells + converter children.
# Without this, a SIGTERM to the script leaves the xargs tree orphaned.
set -m  # job control on
trap 'echo "[$(date -u +%FT%TZ)] got SIGTERM, killing process group"; kill -TERM 0; wait; exit 143' TERM INT

# Build the work list: lines of "dataset\tslide_id\tsrc_path\tdst_path"
WORK_TSV=$(mktemp)
trap 'rm -f "$WORK_TSV"' EXIT

build_brca_work() {
  tail -n +6 "$BRCA_MANIFEST" | while read -r sid; do
    [ -z "$sid" ] && continue
    src=$(find "$BRCA_SRC_DIR" -name "${sid}.svs" 2>/dev/null | head -1)
    if [ -z "$src" ]; then
      echo "[warn] BRCA source not found for $sid" >&2
      continue
    fi
    dst="$BRCA_DST_DIR/${sid}.tiff"
    printf "brca\t%s\t%s\t%s\n" "$sid" "$src" "$dst"
  done
}

build_cam_work() {
  tail -n +6 "$CAM_MANIFEST" | while read -r sid; do
    [ -z "$sid" ] && continue
    src="$CAM_SRC_DIR/${sid}.tif"
    if [ ! -f "$src" ]; then
      echo "[warn] CAM16 source not found for $sid" >&2
      continue
    fi
    dst="$CAM_DST_DIR/${sid}.tiff"
    printf "cam16\t%s\t%s\t%s\n" "$sid" "$src" "$dst"
  done
}

build_brca_work > "$WORK_TSV"
build_cam_work >> "$WORK_TSV"

n_total=$(wc -l < "$WORK_TSV")
echo "[$(date -u +%FT%TZ)] Stage 4.C convert (TRUE 20× raw-TIFF): $n_total slides queued, $PARALLEL parallel"
echo "[$(date -u +%FT%TZ)] Log: $LOG_TSV"
echo ""

# Per-slide worker: convert if dst doesn't exist; append result row to log.
#
# convert-rawtiff-20x.py streams tiles straight to $dst.partial via tifffile —
# no CWD mmap temp files, so the per-process scratch-dir workaround the old
# `cucim convert` path needed (its level*.mmap files collided + SIGBUS'd under
# parallelism, 2026-05-16) is GONE. Per-dataset 20× read params (the SAME
# contract as the readers): CAM16 reads native level 1 @ 256px (no resize);
# BRCA reads 512px@40× and resizes to 256 (= 20×).
#
# Robustness: writes to "$dst.partial" first, then renames to final on success.
# A killed conversion leaves $dst.partial (or nothing) but never a half-written
# $dst masquerading as complete.
convert_one() {
  local dataset="$1"; local sid="$2"; local src="$3"; local dst="$4"
  local dst_partial="${dst}.partial"
  local src_size dst_size t0 t1 wall status read_level read_size

  case "$dataset" in
    cam16|camelyon16) read_level=1; read_size=256 ;;
    brca|tcga-brca)   read_level=0; read_size=512 ;;
    *) echo "[FAIL-UNKNOWN-DATASET] $dataset/$sid"
       printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
         "$(date -u +%FT%TZ)" "$dataset" "$sid" "0" "0" "0" "FAIL-UNKNOWN-DATASET" \
         >> "$LOG_TSV"
       return 1 ;;
  esac

  src_size=$(stat -c '%s' "$src" 2>/dev/null || echo "0")

  if [ -f "$dst" ] && [ -s "$dst" ]; then
    dst_size=$(stat -c '%s' "$dst")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(date -u +%FT%TZ)" "$dataset" "$sid" "$src_size" "$dst_size" "0" "SKIP-EXISTS" \
      >> "$LOG_TSV"
    echo "[skip] $dataset/$sid (already converted, $dst_size bytes)"
    return 0
  fi

  # Clean up any leftover .partial from a previous killed run
  rm -f "$dst_partial"

  t0=$(date +%s)
  if CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$CONVERTER" \
       --src "$src" --dst "$dst_partial" \
       --read-level "$read_level" --read-size "$read_size" \
       >/dev/null 2>&1; then
    # Only promote to final name on successful exit
    mv "$dst_partial" "$dst"
    status="OK"
  else
    # Leave or remove .partial; either way $dst doesn't exist → next run retries
    rm -f "$dst_partial"
    status="FAIL"
  fi

  t1=$(date +%s)
  wall=$((t1 - t0))
  dst_size=$(stat -c '%s' "$dst" 2>/dev/null || echo "0")
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(date -u +%FT%TZ)" "$dataset" "$sid" "$src_size" "$dst_size" "$wall" "$status" \
    >> "$LOG_TSV"
  echo "[$status] $dataset/$sid src=${src_size} dst=${dst_size} wall=${wall}s"
}
export -f convert_one
export CONDA_ENV PYTHON CONVERTER LOG_TSV

# Process in parallel via xargs. Use null-delimited input for safety.
awk -F'\t' 'BEGIN{ORS="\0"} {print $1"\t"$2"\t"$3"\t"$4}' "$WORK_TSV" | \
  xargs -0 -P "$PARALLEL" -n 1 -I {} bash -c '
    IFS=$'"'"'\t'"'"' read -r ds sid src dst <<< "{}"
    convert_one "$ds" "$sid" "$src" "$dst"
  '

# Summary
n_ok=$(tail -n +2 "$LOG_TSV" | awk -F'\t' '$7=="OK"' | wc -l)
n_skip=$(tail -n +2 "$LOG_TSV" | awk -F'\t' '$7=="SKIP-EXISTS"' | wc -l)
n_fail=$(tail -n +2 "$LOG_TSV" | awk -F'\t' '$7=="FAIL"' | wc -l)
echo ""
echo "[$(date -u +%FT%TZ)] DONE: OK=$n_ok SKIP=$n_skip FAIL=$n_fail (of $n_total queued)"
if [ "$n_fail" -gt 0 ]; then
  echo "FAILED slides:"
  tail -n +2 "$LOG_TSV" | awk -F'\t' '$7=="FAIL" {print "  "$2"/"$3}'
  exit 1
fi
exit 0
