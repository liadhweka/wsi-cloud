#!/usr/bin/env bash
# sweep-stage3-tissue-detection.sh — Stage 3.0 CLAM tissue detection sweep.
#
# Customer story: how fast does WEKA serve the low-resolution thumbnail reads
# CLAM's tissue detection needs, while CLAM's Otsu + morphology saturate the
# host's CPUs? Confirms empirically that Stage 3 is compute-bound, completing
# the "Stages 2+3 paint a complete picture: 2 is metadata-stress, 3 is
# compute-stress, WEKA never bottlenecks on either" narrative.
#
# 2D grid: datasets ∈ {tcga-brca, camelyon16} × concurrency ∈ {1, 8, 64}
# = 6 cells. Per cell: split the dataset manifest into N round-robin chunks
# (symlink dirs under /tmp/stage3-chunks/), then launch N parallel
# `create_patches_fp.py` instances all writing to the same per-cell
# --save_dir. CLAM's per-slide outputs go to per-slide files (HDF5 in patches/,
# JPEG in masks/) — collision-free since slide IDs are unique.
#
# Per-cell wallclock estimate based on smoke-test (3.65s/slide compute, no stitch):
#   BRCA  n=1 → ~68 min · n=8 → ~9 min · n=64 → ~70s
#   CAM   n=1 → ~24 min · n=8 → ~3 min · n=64 → ~30s
# Total estimated: ~2 hr 5 min, plus per-cell record-run.sh overhead.
#
# Per-cell isolation via record-run.sh: any cell failure leaves rest intact.
#
# Run with:
#   runs/lib/sweep-stage3-tissue-detection.sh
# Output:
#   - one runs/<TS>-s3.0-tissue-<dataset>-n<N>/ per cell
#   - one consolidated log at runs/sweep-logs/<TS>-stage3-tissue.log
#   - per-cell HDF5 + masks at ${FS_MOUNT}/tissue-detection/3.0/<dataset>/n<N>/
#
# Prerequisites:
#   - Python deps: numpy, pandas, tqdm, opencv-python, matplotlib, h5py, openslide-python (Stage 2 / 3 pre-flight)
#   - CLAM cloned at ${CLAM_DIR:-${PROJECT_HOME:-$HOME}/wsi-tools/CLAM} (Stage 3 pre-flight)
#   - Datasets at ${FS_MOUNT}/data/{tcga-brca,camelyon16}/ (Stage 1.2 / 1.3)
set -uo pipefail

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
CLAM=${CLAM_DIR:-${PROJECT_HOME:-$HOME}/wsi-tools/CLAM}
EXTRACTOR_SCRIPT=$CLAM/create_patches_fp.py
TISSUE_OUT=${FS_MOUNT}/tissue-detection/3.0
CHUNK_ROOT=/tmp/stage3-chunks
MANIFEST_DIR=/tmp/stage3-manifests
LOG_DIR=$REPO/runs/sweep-logs

mkdir -p "$LOG_DIR" "$TISSUE_OUT" "$CHUNK_ROOT" "$MANIFEST_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage3-tissue.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

# Sanity checks
if [[ ! -f "$EXTRACTOR_SCRIPT" ]]; then
  log "FATAL: CLAM not found at $EXTRACTOR_SCRIPT"
  log "  Clone via: git clone https://github.com/mahmoodlab/CLAM ${CLAM_DIR:-${PROJECT_HOME:-$HOME}/wsi-tools/CLAM}"
  exit 2
fi
if ! python3 -c "import openslide, cv2, h5py, numpy, pandas, matplotlib" 2>/dev/null; then
  log "FATAL: Stage 3 Python deps missing. Run pip install --user numpy pandas tqdm opencv-python matplotlib h5py"
  exit 2
fi

# Build per-dataset manifests (outside the recorded window)
log "=== building manifests ==="
BRCA_MANIFEST=$MANIFEST_DIR/tcga-brca.txt
CAM_MANIFEST=$MANIFEST_DIR/camelyon16.txt
find ${FS_MOUNT}/data/tcga-brca/ -name '*.svs' 2>/dev/null | sort > "$BRCA_MANIFEST"
find ${FS_MOUNT}/data/camelyon16/images/ -name '*.tif' 2>/dev/null | sort > "$CAM_MANIFEST"
BRCA_COUNT=$(wc -l < "$BRCA_MANIFEST")
CAM_COUNT=$(wc -l < "$CAM_MANIFEST")
log "  TCGA-BRCA:  $BRCA_COUNT slides"
log "  CAMELYON16: $CAM_COUNT slides"
if [[ $BRCA_COUNT -eq 0 || $CAM_COUNT -eq 0 ]]; then
  log "FATAL: empty manifest. Verify datasets at ${FS_MOUNT}/data/."
  exit 2
fi

# build_chunks: split a manifest into N round-robin symlink dirs.
# Args: manifest dataset N
build_chunks() {
  local manifest=$1 dataset=$2 N=$3
  local chunkroot=$CHUNK_ROOT/$dataset/n$N
  rm -rf "$chunkroot"
  mkdir -p "$chunkroot"
  for i in $(seq 0 $((N-1))); do mkdir -p "$chunkroot/chunk$i"; done
  # round-robin: line i goes to chunk (i % N)
  awk -v n="$N" -v root="$chunkroot" '
    {
      idx = (NR - 1) % n
      target = root "/chunk" idx
      cmd = "ln -sf " $0 " " target "/"
      system(cmd)
    }
  ' "$manifest"
  echo "$chunkroot"
}

CONCURRENCIES=(1 8 64)
DATASETS=(
  "tcga-brca:$BRCA_MANIFEST:$BRCA_COUNT"
  "camelyon16:$CAM_MANIFEST:$CAM_COUNT"
)
TOTAL=$(( ${#DATASETS[@]} * ${#CONCURRENCIES[@]} ))

log ""
log "=== Stage 3.0 sweep starting ==="
log "  tool:    CLAM create_patches_fp.py at $CLAM (commit: $(cd $CLAM && git log -1 --format=%h))"
log "  grid:    datasets × concurrency = $TOTAL cells"
log "  output:  $TISSUE_OUT/<dataset>/n<N>/{patches/,masks/}"
log "  log:     $SWEEP_LOG"
log ""

i=0
for ds_entry in "${DATASETS[@]}"; do
  dataset="${ds_entry%%:*}"
  rest="${ds_entry#*:}"
  manifest="${rest%%:*}"
  count="${rest##*:}"

  # 20× tiling args, per-dataset (the 20×-by-the-book change; see SCRIPT-TRACKER
  # "20× coord-space contract"). The published foundation-model protocol
  # (UNI/UNI2-h/Virchow2/GigaPath; Mahmood Lab Trident) tiles at 20× / 256px.
  # Stock CLAM is pyramid-level-index based, and the two datasets differ:
  #   - CAMELYON16 (.tif): native downsample-2.0 level (level 1 == true 20×) →
  #     read it directly at 256px (--patch_level 1).
  #   - TCGA-BRCA (.svs): native downsamples [1,4,16] — NO native 20× level →
  #     read 512px @ level 0 (40×); readers resize to 256px (= 20×). This is
  #     exactly what CLAM custom_downsample / Trident --mag 20 do internally.
  #     In stock CLAM: patch_size=512 step_size=512 at patch_level 0, so coords
  #     step by 512 in level-0 (40×) pixel space (footprint_level0 = 512 for both
  #     datasets — the divisor the raw-TIFF coord→tile mapping uses).
  # Tiles are 20× / 256px uniform across all 3 foundation models (1b decision
  # 2026-06-17): Virchow2's native 224 is reached by the model's own resize.
  case "$dataset" in
    camelyon16) PATCH_ARGS="--patch_level 1 --patch_size 256 --step_size 256" ;;
    tcga-brca)  PATCH_ARGS="--patch_level 0 --patch_size 512 --step_size 512" ;;
    *) log "FATAL: unknown dataset '$dataset' — no 20× patch args defined"; exit 2 ;;
  esac

  for n in "${CONCURRENCIES[@]}"; do
    i=$(( i + 1 ))
    name="tissue-${dataset}-n${n}"
    cell_save="$TISSUE_OUT/${dataset}/n${n}"

    note="Stage 3.0 cell $i/$TOTAL: CLAM tissue detection on $dataset ($count slides) at concurrency n=$n, 20× tiling ($PATCH_ARGS; CAM16 native level 1, BRCA 512px@40× resized to 256px@20× by downstream readers). Single-pass full dataset, --seg --patch (NO --stitch — visualization not needed downstream, also makes the workload more purely compute-bound for the 'Stage 3 is compute-stress' narrative). N parallel python3 create_patches_fp.py instances each consuming a round-robin chunk of the manifest, all writing to $cell_save. HDF5 tile coords + per-slide tissue mask JPEG."

    log "=== [cell $i/$TOTAL] $name ==="
    log "  dataset:     $dataset ($count slides)"
    log "  concurrency: $n"
    log "  cell save:   $cell_save"

    # Clean per-cell output dir
    rm -rf "$cell_save"
    mkdir -p "$cell_save"

    # Build per-cell chunked symlink dirs
    chunkroot=$(build_chunks "$manifest" "$dataset" "$n")
    log "  chunks:      $chunkroot/chunk{0..$((n-1))}"

    "$REPO/runs/lib/record-run.sh" \
      --run-name "$name" \
      --stage 3.0 \
      --note "$note" \
      -- bash -c "
        set +e
        # Launch N parallel CLAM instances, one per chunk, all writing to the same save_dir.
        # CLAM's per-slide outputs land in per-slide-named files inside patches/ and masks/,
        # so concurrent writes from N workers don't collide as long as no two chunks share a slide
        # (round-robin guarantees that).
        echo '[wrapper] launching $n parallel CLAM instances'
        for i in \$(seq 0 $((n-1))); do
          (
            cd $CLAM
            python3 create_patches_fp.py \\
              --source $chunkroot/chunk\$i \\
              --save_dir $cell_save \\
              --seg --patch \\
              $PATCH_ARGS
          ) &
        done
        wait
        echo '[wrapper] all CLAM instances done'

        # Quick app-level summary that the aggregator will parse from cmd.log
        n_h5=\$(find $cell_save/patches -name '*.h5' 2>/dev/null | wc -l)
        n_masks=\$(find $cell_save/masks -name '*.jpg' 2>/dev/null | wc -l)
        echo '=== summary ==='
        echo \"slides_total:        $count\"
        echo \"slides_with_h5:      \$n_h5\"
        echo \"slides_with_mask:    \$n_masks\"
        echo \"concurrency:         $n\"
        echo \"dataset:             $dataset\"
        # Note: total wallclock comes from record-run.sh's .run_start/.run_end
      " 2>&1 | tee -a "$SWEEP_LOG"

    log ""
  done
done

log "=== sweep done ==="
log "review:  cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "next:    runs/lib/aggregate-stage3-tissue-detection.py 'runs/2026-*-s3.0-tissue-*'"
log "cleanup: rm -rf $TISSUE_OUT (HDF5 sidecars + masks; ~few hundred MB total, removable post-presentation)"
log "         rm -rf $CHUNK_ROOT (per-cell symlink dirs in /tmp, ~MB total)"
