#!/usr/bin/env bash
# Stage 4.D — convert the FULL BRCA cohort (1073 slides) + the 50-slide
# CAMELYON16 subset to uncompressed 20x raw TIFF on ${FS_MOUNT}, RETAINED at
# rest (ratified 2026-08-15, was tracker D-28).
#
# WHY the full BRCA cohort rather than the 50-slide subset:
#   - Stage 7.2 (the SLA cell) walks the 1073-slide cohort through the
#     kvikIO/raw-TIFF backend with DISJOINT per-process slide chunks — its N=64
#     cell is arithmetically impossible on a 50-slide artifact — and 7.5's
#     inference workload shares the same configuration. The artifact must
#     pre-exist at rest; 6.A Tier 2's chunks are transient by design and stay
#     that way (the chunk cadence is part of what Tier 2 measures).
#   - Capacity fits on both legs (the open-items capacity arithmetic counts it).
#
# WHY this is a recorded "Stage 4.D" cell rather than a flat tee'd log:
#   - The full-cohort uncompressed output is order ~7 TB of sustained writes to
#     $FS_MOUNT (STAGES.md D4).
#   - That is a genuine recordable workload in its own right (substage 4.D), so it
#     runs through record-run.sh rather than as a side task: the recording captures
#     sustained write throughput under parallel conversion at scale.
#   - Per CLAUDE.md memory-hygiene rule + project preference for recording any
#     measurable WSI workload.
#
# WHY PARALLEL is a slide count (override-able):
#   - convert-rawtiff-20x.py is single-threaded per slide (OpenSlide tile reads
#     + tifffile write), so PARALLEL is the number of slides converted
#     concurrently. Its ceiling is set by the cores this instance actually has
#     and by the raw-TIFF write footprint resident at once — both properties of
#     the leg being run, so raising it is a tuning call that needs THIS target's
#     measured conversion rate, not an inference from the default below.
#   - It is workload shape for a write-heavy phase measured against the
#     filesystem, so whatever value is used must be the SAME on both legs:
#     changing it between legs makes the write pattern, not the filesystem, the
#     variable under test.
#
# WHY output tile-size 256 @ 20×:
#   - Keeps the Stage 4.C tile grid apples-to-apples with 4.A/4.B and matches
#     what UNI2-h / Virchow2 / GigaPath consume (20× / 256px, the published
#     foundation-model protocol).
#
# WHY idempotent skip on existing output:
#   - Keeping scripts idempotent is a project dependability default (CLAUDE.md):
#     a conversion killed part-way resumes cleanly without double-converting.
#   - The cost is a silent-skip hazard, which is why SKIP-EXISTS is a distinct
#     status in $LOG_TSV and in the summary counts: a run that converted nothing
#     because output was already present must be visible, not indistinguishable
#     from a run that did the work.
#
# RECORDING (was tracker D-15, ratified 2026-08-17): the conversion runs as ONE
# record-run.sh cell PER DATASET — the BRCA full cohort and the CAM16 subset are
# different scales, and separate cells give each its own telemetry window, cost
# inputs, and INDEX verdict. The script re-invokes itself with --inner for the
# wrapped work, so the recorded command is explicit in cmd.txt rather than an
# exported-function opaque blob. Cache declaration: na-mixed-rw-unmanaged (the
# 4.A convention — sustained read+write with no constructed regime).
#
# Usage:
#   ./scripts/convert-stage4c-rawtiff.sh           # convert 1073 BRCA + 50 CAM16
#   PARALLEL=8 ./scripts/convert-stage4c-rawtiff.sh  # override parallelism
#   (internal) --inner <dataset> <work_tsv> <run_dir>

set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PYTHON="$CONDA_ENV/bin/python3"
CONVERTER="$REPO/scripts/convert-rawtiff-20x.py"

# 20× (Option B): produce a TRUE 20× raw-TIFF via convert-rawtiff-20x.py.
# `cucim convert` can't target 20× (always emits the SVS 40× level-0 — verified
# vs cucim 26.4.0 cli.py), so we use a tifffile-based writer. Per-dataset read
# params are set in convert_one (CAM16 native level 1 @ 256; BRCA 512@40× → 256).
PARALLEL="${PARALLEL:-4}"

# Full-cohort BRCA (D-28, ratified): the uniform 1073-slide 40x-base cohort
# (STAGES.md D5). CAM16 stays the 50-slide subset — only 4.C, 6.A Tier 3 and
# 7.6 read CAM16 raw-TIFF, all subset-scoped.
BRCA_MANIFEST="$REPO/scripts/manifests/tcga-brca-full40x-stage4a-format.tsv"
CAM_MANIFEST="$REPO/scripts/manifests/camelyon16-stage4a-subset.tsv"

BRCA_SRC_DIR=${FS_MOUNT}/data/tcga-brca
CAM_SRC_DIR=${FS_MOUNT}/data/camelyon16/images

BRCA_DST_DIR=${FS_MOUNT}/data/tcga-brca-rawtiff
CAM_DST_DIR=${FS_MOUNT}/data/camelyon16-rawtiff

mkdir -p "$BRCA_DST_DIR" "$CAM_DST_DIR"

# The full-cohort artifact is order ~7 TB (D4) and a conversion that dies on
# ENOSPC mid-cohort wastes hours — refuse up front without the headroom.
RAWTIFF_MIN_FREE_TB="${RAWTIFF_MIN_FREE_TB:-8}"
AVAIL_BYTES=$(df --output=avail -B1 "$FS_MOUNT" | tail -1 | tr -d ' ')
NEED_BYTES=$(( RAWTIFF_MIN_FREE_TB * 1000 * 1000 * 1000 * 1000 ))
if [ "$AVAIL_BYTES" -lt "$NEED_BYTES" ]; then
  echo "FATAL: $FS_MOUNT has $AVAIL_BYTES B free; the full-cohort raw-TIFF needs ~${RAWTIFF_MIN_FREE_TB} TB headroom." >&2
  exit 1
fi

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

# Work lists are "dataset\tslide_id\tsrc_path\tdst_path" lines — built per
# dataset in the outer path; the inner invocation receives its list's path.

# Comment-aware manifest parsing, NOT a fixed tail count: the full-cohort
# manifest carries a longer comment header AND commented excluded-slide IDs at
# the file end — a fixed line offset would ingest both as slide ids.
manifest_ids() { grep -v '^\s*#' "$1" | grep -v '^slide_id$' | grep -v '^\s*$'; }

build_brca_work() {
  manifest_ids "$BRCA_MANIFEST" | while read -r sid; do
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
  manifest_ids "$CAM_MANIFEST" | while read -r sid; do
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

# ── Outer/inner split (D-15). Inner: run one dataset's conversion under the
# recording wrapper. Outer (default): build + verify the work lists, then one
# recorded cell per dataset.
INNER_MODE=0
if [ "${1:-}" = "--inner" ]; then
  INNER_MODE=1; INNER_DS="$2"; WORK_TSV="$3"; INNER_RUN_DIR="$4"
else
  WORK_BRCA=$(mktemp); WORK_CAM=$(mktemp)
  trap 'rm -f "$WORK_BRCA" "$WORK_CAM"' EXIT
  build_brca_work > "$WORK_BRCA"
  build_cam_work  > "$WORK_CAM"

  # Fail loud on resolution holes (the D-15 second half): zero slides means the
  # manifest or the mount is wrong, and ANY unresolved id silently shrinks the
  # cohort — which the cross-leg gates would only catch after the wallclock.
  for pair in "brca:$WORK_BRCA:$BRCA_MANIFEST" "cam16:$WORK_CAM:$CAM_MANIFEST"; do
    ds=${pair%%:*}; rest=${pair#*:}; wf=${rest%%:*}; mf=${rest#*:}
    want=$(manifest_ids "$mf" | wc -l); have=$(wc -l < "$wf")
    if [ "$have" -eq 0 ] || [ "$have" -ne "$want" ]; then
      echo "FATAL: $ds resolved $have/$want manifest slides to sources — refusing: an unresolved id" >&2
      echo "       silently shrinks the cohort (see [warn] lines above for which ids)." >&2
      exit 2
    fi
  done
  echo "[$(date -u +%FT%TZ)] Stage 4.D convert (TRUE 20x raw-TIFF): brca=$(wc -l < "$WORK_BRCA") + cam16=$(wc -l < "$WORK_CAM") slides, $PARALLEL parallel"
  echo "[$(date -u +%FT%TZ)] Log: $LOG_TSV"
  echo ""
fi

# Per-slide worker: convert if dst doesn't exist; append result row to log.
#
# convert-rawtiff-20x.py streams tiles straight to $dst.partial via tifffile —
# no CWD mmap temp files, so the per-process scratch-dir workaround the old
# `cucim convert` path needed (its level*.mmap files collided + SIGBUS'd under
# parallelism) is GONE. Per-dataset 20× read params (the SAME
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

if [ "$INNER_MODE" -eq 1 ]; then
  # ── INNER: convert one dataset's work list inside the recording wrapper. ──
  # Per-invocation rows go to the run dir's conversion-log.tsv (the global
  # LOG_TSV keeps its append-only continuity, but THIS cell's verdict counts
  # only THIS invocation — the old summary counted historical rows).
  RUN_TSV="$INNER_RUN_DIR/conversion-log.tsv"
  printf "timestamp\tdataset\tslide_id\tsrc_size\tdst_size\twallclock_s\tstatus\n" > "$RUN_TSV"
  GLOBAL_TSV="$LOG_TSV"
  # Workers write rows to THIS invocation's TSV only (single log per cell — no
  # cross-worker tail race against the global file); the global append-only log
  # gets this cell's rows folded in once, by one writer, after the pool drains.
  export LOG_TSV="$RUN_TSV"
  awk -F'\t' 'BEGIN{ORS="\0"} {print $1"\t"$2"\t"$3"\t"$4}' "$WORK_TSV" | \
    xargs -0 -P "$PARALLEL" -n 1 -I {} bash -c '
      IFS=$'"'"'\t'"'"' read -r ds sid src dst <<< "{}"
      convert_one "$ds" "$sid" "$src" "$dst"
    '
  tail -n +2 "$RUN_TSV" >> "$GLOBAL_TSV"
  n_ok=$(tail -n +2 "$RUN_TSV" | awk -F'\t' '$7=="OK"' | wc -l)
  n_skip=$(tail -n +2 "$RUN_TSV" | awk -F'\t' '$7=="SKIP-EXISTS"' | wc -l)
  n_fail=$(tail -n +2 "$RUN_TSV" | awk -F'\t' '$7=="FAIL"' | wc -l)
  n_bytes=$(tail -n +2 "$RUN_TSV" | awk -F'\t' '$7=="OK"{s+=$5} END{print s+0}')
  echo ""
  echo "=== summary ==="
  echo "dataset:            $INNER_DS"
  echo "slides_queued:      $(wc -l < "$WORK_TSV")"
  echo "converted_ok:       $n_ok"
  echo "skipped_existing:   $n_skip"
  echo "failed:             $n_fail"
  echo "bytes_written_ok:   $n_bytes"
  if [ "$n_fail" -gt 0 ]; then
    echo "FAILED slides (an mpp-guard rejection here means the manifest and the cohort disagree — investigate, don't proceed):"
    tail -n +2 "$RUN_TSV" | awk -F'\t' '$7=="FAIL" {print "  "$2"/"$3}'
    exit 1
  fi
  exit 0
fi

# ── OUTER: one recorded cell per dataset (D-15). ──
overall_rc=0
for pair in "brca:$WORK_BRCA" "cam16:$WORK_CAM"; do
  ds=${pair%%:*}; wf=${pair#*:}
  n=$(wc -l < "$wf")
  ts=$(date -u +%Y-%m-%d-%H%M%S)
  run_dir="$REPO/runs/${ts}-${LEG:?LEG is unset -- source env.sh}-s4.D-rawtiff-${ds}-par${PARALLEL}"
  note="Stage 4.D: TRUE 20x raw-TIFF conversion of $ds ($n slides, PARALLEL=$PARALLEL — workload shape, must match on both legs). Sustained large-read (canonical source) + large-write (single-level 256px-tiled uncompressed 20x TIFF, D4) via convert-rawtiff-20x.py; per-dataset read params per the coord contract (CAM16 native L1@256; BRCA 512@40x resized to 256). Fail-loud mpp guard; write-to-.partial-then-rename; idempotent skip on existing non-empty output (SKIP-EXISTS is a distinct status — verify cleanup before regenerating, RUNBOOK silent-skip hazard). Artifact RETAINED at rest (Stage-4 register). Per-invocation log: conversion-log.tsv in this run dir."
  if ! RECORD_RUN_DIR="$run_dir" RECORD_CACHE_STATE="na-mixed-rw-unmanaged" \
       "$REPO/scripts/record-run.sh" \
         --stage 4.D --run-name "rawtiff-${ds}-par${PARALLEL}" --note "$note" \
         -- "$REPO/scripts/convert-stage4c-rawtiff.sh" --inner "$ds" "$wf" "$run_dir"; then
    echo "[$(date -u +%FT%TZ)] FATAL: $ds conversion cell failed — not continuing to the next dataset:" >&2
    echo "       downstream stages consume this artifact, and a partial cohort read as complete is the" >&2
    echo "       silent-skip hazard the RUNBOOK warns about." >&2
    overall_rc=1
    break
  fi
done
exit $overall_rc
