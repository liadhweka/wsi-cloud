#!/usr/bin/env bash
# sweep-stage1-fpsync.sh — Stage 1.5 bulk copy, local NVMe → the filesystem
# under test ($FS_MOUNT). Runs identically on both legs.
#
# With the source pre-staged on local NVMe (Stage 1.4), fpsync drives a clean
# WRITE-path benchmark on real WSI data at varying parallelism: no WAN bottleneck
# and no cloud throttling, so the only variable is fpsync's -n concurrency against
# this leg's write ceiling. Compare each cell against the block-size-matched
# Stage 1.0a cell measured on THIS leg — never against a number from elsewhere.
#
# Grid: n ∈ {1, 4, 16, 64} = 4 cells. Each cell ingests the full TCGA-BRCA corpus
# (1133 SVS, 1.05 TiB per the manifest) into its own per-cell target subdir.
# Per-cell duration is n-dependent and is RECORDED, not estimated: n=1 is
# single-stream-bound, higher n is the point of the sweep.
#
# Per-cell isolation: each cell calls record-run.sh which captures pre/raw/post
# independently. A failed cell goes INCOMPLETE in INDEX.md without taking
# down the rest of the sweep.
#
# Run with:
#   scripts/sweep-stage1-fpsync.sh
# Output:
#   - one runs/<TS>-s1.5-fpsync-n<N>/ per cell (with full primary-source recording)
#   - one consolidated log at runs/sweep-logs/<TS>-stage1-fpsync.log
#   - one app-level bytes/duration record per cell at <run-dir>/notes.md
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${SCRATCH_DIR:?SCRATCH_DIR is unset -- source env.sh}"
SRC=${SCRATCH_DIR}/fpsync-source/tcga-brca/
TARGET_ROOT=${FS_MOUNT}/data/fpsync-target
SHDIR_ROOT=/tmp/fpsync-stage1.5
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$TARGET_ROOT"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-fpsync.log"

CONCURRENCIES=(1 4 16 64)
TOTAL=${#CONCURRENCIES[@]}

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }
FAILED_CELLS=0

# Sanity: source must exist and contain real data
if [[ ! -d "$SRC" ]]; then
  log "FATAL: source dir missing: $SRC"
  log "  Run the recorded re-stage first:"
  log "  scripts/record-run.sh --run-name restage-tcga-brca-for-1.5-prep-n16 --stage 1.5 --note '...' -- fpsync -v -n 16 -d /tmp/fpsync-prep ${FS_MOUNT}/data/tcga-brca/ \$SRC"
  exit 2
fi
SRC_BYTES=$(du -sb "$SRC" | awk '{print $1}')
SRC_FILES=$(find "$SRC" -type f | wc -l)

log "=== Stage 1.5 fpsync sweep starting ==="
log "  source:  $SRC"
log "  bytes:   $SRC_BYTES ($(numfmt --to=iec --suffix=B $SRC_BYTES))"
log "  files:   $SRC_FILES"
log "  targets: $TARGET_ROOT/n<N>/"
log "  grid:    n ∈ {${CONCURRENCIES[*]}}"
log "  total cells: $TOTAL"
log "  consolidated log: $SWEEP_LOG"

i=0
for n in "${CONCURRENCIES[@]}"; do
  i=$(( i + 1 ))
  TARGET="$TARGET_ROOT/n${n}"
  SHDIR="$SHDIR_ROOT/n${n}"
  name="fpsync-n${n}"
  note="Stage 1.5 fpsync sweep cell $i/$TOTAL on fs=${LEG}: local NVMe -> ${FS_MOUNT}, fpsync -n $n. Source: $SRC ($SRC_FILES files, $SRC_BYTES bytes). Target: $TARGET (cleaned pre-cell). fpsync default partition (-f 2000 -s 4G), default rsync opts (-lptgoD -v --numeric-ids), shdir $SHDIR. Per-cell isolation via record-run.sh: any single cell failure leaves rest of sweep intact."

  log ""
  log "=== [cell $i/$TOTAL] $name ==="
  log "  cleaning prior target subdir (if any) ..."
  rm -rf "$TARGET" "$SHDIR"
  mkdir -p "$TARGET" "$SHDIR_ROOT"
  PRE_TARGET_BYTES=$(du -sb "$TARGET" | awk '{print $1}')
  log "  pre-cell target bytes: $PRE_TARGET_BYTES (must be 0)"

  CELL_START=$(date -u +%FT%TZ)
  log "  starting cell at $CELL_START"

  RECORD_CACHE_STATE=na-write-cell \
  "$REPO/scripts/record-run.sh" \
    --run-name "$name" \
    --stage "1.5" \
    --note "$note" \
    -- fpsync -v \
        -n "$n" \
        -d "$SHDIR" \
        "$SRC" \
        "$TARGET/" \
    2>&1 | tee -a "$SWEEP_LOG"
    cell_rc=${PIPESTATUS[0]}
    if (( cell_rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$cell_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi

  CELL_END=$(date -u +%FT%TZ)
  POST_TARGET_BYTES=$(du -sb "$TARGET" | awk '{print $1}')
  POST_TARGET_FILES=$(find "$TARGET" -type f | wc -l)
  log "  cell ended at $CELL_END"
  log "  post-cell target: $POST_TARGET_FILES files, $POST_TARGET_BYTES bytes"

  # Find the run dir we just created (most recent s1.5-fpsync-n${n})
  RUN_DIR=$(ls -td "$REPO/runs/"*-s1.5-${name} 2>/dev/null | head -1)
  if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    # Append app-level bytes/duration sidecar (separate from the parsed
    # results.json which doesn't know about fpsync's progress).
    cat > "$RUN_DIR/notes.md" <<EOF
# Stage 1.5 cell $i/$TOTAL — fpsync n=$n

## App-level (du-based, authoritative for bytes-transferred)

- Source bytes: $SRC_BYTES
- Source files: $SRC_FILES
- Target bytes (post): $POST_TARGET_BYTES
- Target files (post): $POST_TARGET_FILES
- Cell start (UTC): $CELL_START
- Cell end (UTC):   $CELL_END

The wall-clock duration in this notes file brackets the entire record-run.sh
operation (including pre-snapshot, fpsync run, post-snapshot, parser).
For the timed-window-only duration, use raw/.run_start and raw/.run_end.

## Cross-source check

After running aggregate-stage1-fpsync.py (or eyeballing results.json), run the
post-cell cross-source consistency canary using THIS leg's Primary sources
(docs/RUNBOOK.md § What gets recorded) and THIS leg's consistency relation, derived
per filesystem and never ported across (STAGES.md D12):
- App-level bytes/sec = $POST_TARGET_BYTES / wall-time
- Compare to the filesystem-side client Write sustained_mean
- Compare to the wire counters for the data path in use, at the write amplification
  this leg's relation implies (WEKA: from the provisioned EC scheme; Lustre: from the
  actual stripe layout)
⏳ D-5: the relation is not derived yet. Do not fill numbers in from another
environment.
EOF
    # Copy fpsync's own per-partition rsync logs into the run dir for
    # archival (they live under \$SHDIR/log/ during the run).
    if [[ -d "$SHDIR/log" ]]; then
      mkdir -p "$RUN_DIR/raw/fpsync-shdir-log"
      cp -a "$SHDIR/log/." "$RUN_DIR/raw/fpsync-shdir-log/" 2>/dev/null || true
      log "  copied fpsync shdir log into $RUN_DIR/raw/fpsync-shdir-log/"
    fi
  else
    log "  WARN: could not locate run dir to attach notes.md (sidecar lost)"
  fi
done

log ""
log "=== sweep done ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "next:   scripts/aggregate-stage1-fpsync.py 'runs/2026-*-s1.5-fpsync-n*'"

if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
