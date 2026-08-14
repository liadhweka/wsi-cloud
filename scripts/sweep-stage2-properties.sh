#!/usr/bin/env bash
# sweep-stage2-properties.sh — Stage 2.0 OpenSlide property extraction sweep.
#
# The question this answers: how fast does the filesystem under test absorb
# whole-dataset metadata extraction at varying parallelism? The metric is
# operations per second, not bytes per second — this is the stage where the two
# filesystems' metadata architectures differ most (Lustre concentrates metadata on
# dedicated targets with independently provisioned IOPS; WEKA distributes it).
# ⚠ Cross-leg headline is APP-LEVEL throughput. Filesystem-reported ops/s counts
# are within-leg diagnostics until counter equivalence is verified (open item 6).
#
# 2D grid: datasets ∈ {tcga-brca, camelyon16} × concurrency ∈ {1, 8, 64, 256}
# = 8 cells. Per cell: single-pass over the full dataset via openslide-python's
# multiprocessing.Pool, JSON sidecar per slide written under $FS_MOUNT.
#
# Per-cell wallclock estimate based on smoke-test timings (~30-75 ms per slide
# on warmed cache):
#   n=1:   ~60-120s
#   n=8:   ~10-15s
#   n=64:  ~2-5s
#   n=256: ~1-3s (likely metadata-server saturated)
# Plus per-cell record-run.sh overhead ~25-30s (pre/post snapshot, parser,
# INDEX.md append). Total estimated: ~6-8 min.
#
# Per-cell isolation via record-run.sh: any cell failure leaves rest intact.
#
# Run with:
#   scripts/sweep-stage2-properties.sh
# Output:
#   - one runs/<TS>-s2.0-properties-<dataset>-n<N>/ per cell
#   - one consolidated log at runs/sweep-logs/<TS>-stage2-properties.log
#   - per-run per-slide-latencies.csv archived inside each run dir
#   - JSON sidecars at ${FS_MOUNT}/cataloging/2.0/<dataset>/n<N>/
#
# Prerequisites:
#   - the pinned main conda env built (bootstrap does this) — it carries
#     openslide-python plus the bundled libopenslide, which AL2023 does not package
#   - ${FS_MOUNT}/data/{tcga-brca,camelyon16}/ populated (Stages 1.2, 1.3)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
# The pinned main env, same convention as every other python-exec'ing driver:
# it carries openslide-python + the bundled libopenslide, which the AL2023 system
# python cannot get (no distro libopenslide, no apt).
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PYTHON="$CONDA_ENV/bin/python"
EXTRACTOR=$REPO/scripts/extract-slide-properties.py
CATALOG_OUT=${FS_MOUNT}/cataloging/2.0
MANIFEST_DIR=/tmp/stage2-manifests
LOG_DIR=$REPO/runs/sweep-logs

mkdir -p "$LOG_DIR" "$CATALOG_OUT" "$MANIFEST_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage2-properties.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

# Sanity: openslide importable by the interpreter this driver actually uses
if [[ ! -x "$PYTHON" ]]; then
  log "FATAL: conda env python not found at $PYTHON — env not built on this instance yet."
  exit 2
fi
if ! CONDA_PREFIX="$CONDA_ENV" "$PYTHON" -c "import openslide" 2>/dev/null; then
  log "FATAL: '$PYTHON -c import openslide' failed — the pinned env should carry it; rebuild the env from scripts/env-specs."
  exit 2
fi

# Build per-dataset manifests (outside the recorded window — setup, not benchmark)
log "=== building manifests ==="
BRCA_MANIFEST=$MANIFEST_DIR/tcga-brca.txt
CAM_MANIFEST=$MANIFEST_DIR/camelyon16.txt
find ${FS_MOUNT}/data/tcga-brca/ -name '*.svs' 2>/dev/null | sort > "$BRCA_MANIFEST"
find ${FS_MOUNT}/data/camelyon16/images/ -name '*.tif' 2>/dev/null | sort > "$CAM_MANIFEST"
BRCA_COUNT=$(wc -l < "$BRCA_MANIFEST")
CAM_COUNT=$(wc -l < "$CAM_MANIFEST")
log "  TCGA-BRCA:  $BRCA_COUNT slides → $BRCA_MANIFEST"
log "  CAMELYON16: $CAM_COUNT slides → $CAM_MANIFEST"

if [[ $BRCA_COUNT -eq 0 || $CAM_COUNT -eq 0 ]]; then
  log "FATAL: one or both manifests empty. Verify ${FS_MOUNT}/data/ contains the datasets."
  exit 2
fi

CONCURRENCIES=(1 8 64 256)
DATASETS=(
  "tcga-brca:$BRCA_MANIFEST:$BRCA_COUNT"
  "camelyon16:$CAM_MANIFEST:$CAM_COUNT"
)
TOTAL=$(( ${#DATASETS[@]} * ${#CONCURRENCIES[@]} ))

log ""
log "=== Stage 2.0 sweep starting ==="
log "  tool:    openslide-python $(CONDA_PREFIX="$CONDA_ENV" "$PYTHON" -c 'import openslide; print(openslide.__version__)') / libopenslide $(CONDA_PREFIX="$CONDA_ENV" "$PYTHON" -c 'import openslide; print(openslide.__library_version__)')"
log "  grid:    datasets × concurrency = $TOTAL cells"
log "  output:  $CATALOG_OUT/<dataset>/n<N>/<slide-id>.json"
log "  log:     $SWEEP_LOG"
log ""

i=0
for ds_entry in "${DATASETS[@]}"; do
  dataset="${ds_entry%%:*}"
  rest="${ds_entry#*:}"
  manifest="${rest%%:*}"
  count="${rest##*:}"

  for n in "${CONCURRENCIES[@]}"; do
    i=$(( i + 1 ))
    name="properties-${dataset}-n${n}"
    out_dir="$CATALOG_OUT/${dataset}/n${n}"
    latency_csv="$MANIFEST_DIR/${dataset}-n${n}-latencies.csv"

    note="Stage 2.0 cell $i/$TOTAL: OpenSlide property extraction. Dataset=${dataset} ($count slides), concurrency=$n. Single-pass full dataset via openslide-python + multiprocessing.Pool. JSON sidecars to $out_dir; per-slide latency to $latency_csv (archived into the run dir post-cell). The customer-quotable headline number is 'cataloged $count slides in X seconds at concurrency $n.'"

    log "=== [cell $i/$TOTAL] $name ==="
    log "  dataset:     $dataset ($count slides)"
    log "  concurrency: $n"
    log "  out_dir:     $out_dir"
    log "  cleaning prior output dir ..."
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    "$REPO/scripts/record-run.sh" \
      --run-name "$name" \
      --stage 2.0 \
      --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$EXTRACTOR" \
        --concurrency "$n" \
        --output-dir "$out_dir" \
        --manifest "$manifest" \
        --latency-csv "$latency_csv" \
      2>&1 | tee -a "$SWEEP_LOG"

    # Archive the per-slide latency CSV into the run dir for offline analysis
    RUN_DIR=$(ls -td "$REPO/runs/"*-s2.0-${name} 2>/dev/null | head -1)
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cp "$latency_csv" "$RUN_DIR/per-slide-latencies.csv" 2>/dev/null && \
        log "  archived per-slide latencies → $RUN_DIR/per-slide-latencies.csv"
    else
      log "  WARN: could not locate run dir to archive per-slide-latencies.csv"
    fi
    log ""
  done
done

log "=== sweep done ==="
log "review:  cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "next:    scripts/aggregate-stage2-properties.py 'runs/2026-*-s2.0-properties-*'"
log "cleanup: rm -rf $CATALOG_OUT (JSON sidecars; ~280 MB across all cells, removable post-presentation)"
