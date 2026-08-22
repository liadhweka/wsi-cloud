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
# 3D grid: datasets ∈ {tcga-brca, camelyon16} × concurrency ∈ {1, 8, 64, 256}
# × cache arm ∈ {cold, warm} = 16 cells (D13 route 3 — the explicit axis, because
# no corpus of slide headers can exceed either side's cache).
#
# Cache discipline (D13, Stage-2 roadmap):
#   cold — `sudo sysctl vm.drop_caches=3` (dentries+inodes, not just page cache:
#          a warm dentry cache serves open() client-side on BOTH legs alike,
#          compressing the very difference this stage exists to find). The
#          acknowledgment (rc + output) is written into the run dir as achieved
#          evidence; a failed drop aborts the sweep rather than mislabel a cell.
#          Server-side state is only partly ours — recorded, not asserted.
#   warm — an UNRECORDED warmup pass over the same dataset immediately before
#          the cell, so "warm" is established by construction regardless of
#          cell order, not inherited by accident from whatever ran before.
# Cell order is FIXED and deliberately de-ordered in concurrency (never
# ascending: warmth must not track the swept variable), identical on both legs.
#
# Per-cell isolation via record-run.sh: any cell failure leaves rest intact.
#
# Run with:
#   scripts/sweep-stage2-properties.sh
# Output:
#   - one runs/<TS>-<fs>-s2.0-properties-<dataset>-n<N>-<arm>/ per cell,
#     carrying cache-evidence.txt (the drop acknowledgment / warmup record)
#   - one consolidated log at runs/sweep-logs/<TS>-stage2-properties.log
#   - per-run per-slide-latencies.csv archived inside each run dir
#   - JSON sidecars at ${FS_MOUNT}/cataloging/2.0/<dataset>/n<N>-<arm>/
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

# Fixed de-ordered (n, arm) sequence — NOT ascending in n, arms interleaved,
# identical on both legs by being committed here. 8 cells per dataset.
CELLS=("64:cold" "1:warm" "256:cold" "8:warm" "1:cold" "64:warm" "8:cold" "256:warm")
DATASETS=(
  "tcga-brca:$BRCA_MANIFEST:$BRCA_COUNT"
  "camelyon16:$CAM_MANIFEST:$CAM_COUNT"
)
TOTAL=$(( ${#DATASETS[@]} * ${#CELLS[@]} ))

drop_caches_evidenced() { # drop_caches_evidenced <evidence-file>
  # vm.drop_caches=3: page cache + dentries + inodes. sudo -n so an unattended
  # chain fails fast instead of hanging on a password prompt.
  local ev="$1" rc
  sync
  sudo -n sysctl vm.drop_caches=3 > "$ev.tmp" 2>&1
  rc=$?
  {
    echo "action=vm.drop_caches=3 (client page cache + dentries + inodes)"
    echo "timestamp=$(date -u +%FT%TZ)"
    echo "rc=$rc"
    cat "$ev.tmp"
    echo "server_side=not clearable from the client; state recorded, not asserted (D13)"
  } > "$ev"
  rm -f "$ev.tmp"
  # Lustre cold set (ratified 2026-08-21, D13/D-4): ALSO clear the client's DLM
  # locks — a held lock can keep data/attrs servable client-side after the
  # page-cache drop. Second acknowledgment appended; the reconciler requires it
  # on lustre cold cells.
  if [ "${LEG:-}" = "lustre" ] && (( rc == 0 )); then
    sudo -n lctl set_param -n ldlm.namespaces.*.lru_size=clear > "$ev.tmp" 2>&1
    rc=$?
    {
      echo "action=ldlm.namespaces.*.lru_size=clear (client DLM locks, lustre cold set)"
      echo "timestamp=$(date -u +%FT%TZ)"
      echo "rc=$rc"
      cat "$ev.tmp"
    } >> "$ev"
    rm -f "$ev.tmp"
  fi
  return $rc
}

log ""
log "=== Stage 2.0 sweep starting ==="
log "  tool:    openslide-python $(CONDA_PREFIX="$CONDA_ENV" "$PYTHON" -c 'import openslide; print(openslide.__version__)') / libopenslide $(CONDA_PREFIX="$CONDA_ENV" "$PYTHON" -c 'import openslide; print(openslide.__library_version__)')"
log "  grid:    datasets × concurrency = $TOTAL cells"
log "  output:  $CATALOG_OUT/<dataset>/n<N>/<slide-id>.json"
log "  log:     $SWEEP_LOG"
log ""

i=0
FAILED_CELLS=0
for ds_entry in "${DATASETS[@]}"; do
  dataset="${ds_entry%%:*}"
  rest="${ds_entry#*:}"
  manifest="${rest%%:*}"
  count="${rest##*:}"

  for cell in "${CELLS[@]}"; do
    n="${cell%%:*}"
    arm="${cell##*:}"
    i=$(( i + 1 ))
    name="properties-${dataset}-n${n}-${arm}"
    out_dir="$CATALOG_OUT/${dataset}/n${n}-${arm}"
    latency_csv="$MANIFEST_DIR/${dataset}-n${n}-${arm}-latencies.csv"

    note="Stage 2.0 cell $i/$TOTAL: OpenSlide property extraction. Dataset=${dataset} ($count slides), concurrency=$n, cache arm=$arm (cold: vm.drop_caches=3 with recorded acknowledgment; warm: unrecorded n=64 warmup pass immediately before). Single-pass full dataset via openslide-python + multiprocessing.Pool. Headline: 'cataloged $count slides in X seconds at concurrency $n, $arm'."

    log "=== [cell $i/$TOTAL] $name ==="
    log "  dataset: $dataset ($count slides) · n=$n · arm=$arm · out: $out_dir"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    # Pre-compute the run dir (pattern #4) so the cache-arm evidence lands
    # inside it before the wrapper starts.
    export RECORD_RUN_DIR="$REPO/runs/$(date -u +%Y-%m-%d-%H%M%S)-${LEG:?LEG is unset}-s2.0-${name}"
    mkdir -p "$RECORD_RUN_DIR"

    if [[ "$arm" == "cold" ]]; then
      if ! drop_caches_evidenced "$RECORD_RUN_DIR/cache-evidence.txt"; then
        log "FATAL: vm.drop_caches=3 failed — a cell run now would be warm while labelled cold."
        log "       Aborting the sweep rather than mislabel; evidence: $RECORD_RUN_DIR/cache-evidence.txt"
        exit 1
      fi
      log "  cold: caches dropped (acknowledgment in the run dir)"
    else
      # Warm by construction: an unrecorded warmup pass reads every slide's
      # header once, immediately before the cell — so warm does not depend on
      # what happened to run earlier in the de-ordered sequence.
      warm_dir="$MANIFEST_DIR/warmup-${dataset}"
      rm -rf "$warm_dir"; mkdir -p "$warm_dir"
      if CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$EXTRACTOR" \
           --concurrency 64 --output-dir "$warm_dir" --manifest "$manifest" \
           --latency-csv "$warm_dir/latencies.csv" > /dev/null 2>&1; then
        printf 'action=warmup pass (unrecorded, n=64, full dataset)\ntimestamp=%s\nrc=0\n' \
          "$(date -u +%FT%TZ)" > "$RECORD_RUN_DIR/cache-evidence.txt"
        log "  warm: warmup pass complete (evidence in the run dir)"
      else
        log "FATAL: warmup pass failed — the warm label would be an assertion, not a construction."
        exit 1
      fi
      rm -rf "$warm_dir"
    fi

    RECORD_POLL_HZ=10 \
    RECORD_CACHE_STATE="$arm" "$REPO/scripts/record-run.sh" \
      --run-name "$name" \
      --stage 2.0 \
      --note "$note" \
      -- env CONDA_PREFIX="$CONDA_ENV" "$PYTHON" "$EXTRACTOR" \
        --concurrency "$n" \
        --output-dir "$out_dir" \
        --manifest "$manifest" \
        --latency-csv "$latency_csv" \
      2>&1 | tee -a "$SWEEP_LOG"
    cell_rc=${PIPESTATUS[0]}
    if (( cell_rc != 0 )); then
      FAILED_CELLS=$(( FAILED_CELLS + 1 ))
      log "  WARN: cell exited rc=$cell_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"
    fi

    # Archive the per-slide latency CSV into the run dir for offline analysis
    if [[ -d "$RECORD_RUN_DIR" ]]; then
      cp "$latency_csv" "$RECORD_RUN_DIR/per-slide-latencies.csv" 2>/dev/null && \
        log "  archived per-slide latencies → $RECORD_RUN_DIR/per-slide-latencies.csv"
    fi
    unset RECORD_RUN_DIR
    log ""
  done
done

log "=== sweep done ==="
log "review:  cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "next:    scripts/aggregate-stage2-properties.py 'runs/2026-*-s2.0-properties-*'"
log "cleanup: rm -rf $CATALOG_OUT (JSON sidecars; removable post-presentation)"
if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
