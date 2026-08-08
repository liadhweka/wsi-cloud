#!/usr/bin/env bash
# sweep-stage1-mixed.sh — Stage 1.6 concurrent fpsync ingest + fio read sweep.
#
# The question this answers: while ingest is running at a realistic scanner pace,
# can readers still work at acceptable latency — and does reader load throttle
# ingest? Both sides are captured, because either direction is a real answer.
#
# Maps to:
#   - WRITE side: fpsync local-NVMe -> $FS_MOUNT at a FIXED concurrency, chosen as
#     a FRACTION OF THIS LEG'S OWN 1.5 write curve, not an absolute rate — an
#     absolute rate carried between legs would make the two cells different
#     workloads. ⏳ Parameterise from this leg's 1.5 results before running.
#   - READ side:  fio --rw=randread --iodepth=8 against pre-existing fio scratch
#     on $FS_MOUNT, sweeping bs × jobs to characterise the read side under load
#
# Grid: bs ∈ {4K, 64K} × jobs ∈ {1, 4, 16, 64} = 8 cells.
# Per cell: ~600s steady + 60s ramp = 11 min fio, plus fpsync running concurrent.
# fpsync n=4 takes ~10m 51s for 1.05 TiB, so it covers ~100% of fio's timed window.
# Total estimated: ~8 × 12 min = ~1.5 hr.
#
# Per-cell isolation via record-run.sh: any single cell failure leaves rest intact.
#
# Run with:
#   scripts/sweep-stage1-mixed.sh
# Output:
#   - one runs/<TS>-s1.6-mixed-bs<X>-jobs<N>/ per cell (with full primary-source recording)
#   - one consolidated log at runs/sweep-logs/<TS>-stage1-mixed.log
#   - per-run notes.md with app-level fpsync bytes/duration sidecar
#
# Prerequisites:
#   - $SCRATCH_DIR/fpsync-source/tcga-brca/ populated (Stage 1.5 prep already did this)
#   - ${FS_MOUNT}/benchmarks/fio-scratch-mixed/ populated with 64×4G fio files
#     (run the Stage 1.6 prep first; see comment block at end of file)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${SCRATCH_DIR:?SCRATCH_DIR is unset -- source env.sh}"
SRC=${SCRATCH_DIR}/fpsync-source/tcga-brca/
WRITE_TARGET=${FS_MOUNT}/data/fpsync-target/mixed
READ_SCRATCH=${FS_MOUNT}/benchmarks/fio-scratch-mixed
SHDIR_ROOT=/tmp/fpsync-stage1.6
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$WRITE_TARGET" "$SHDIR_ROOT"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-mixed.log"

INGEST_N=4
BS_LIST=(4k 64k)
JOBS_LIST=(1 4 16 64)
TOTAL=$(( ${#BS_LIST[@]} * ${#JOBS_LIST[@]} ))

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

# Sanity checks
if [[ ! -d "$SRC" ]]; then
  log "FATAL: source dir missing: $SRC"
  log "  Stage 1.5 prep should have populated this. Re-run if needed."
  exit 2
fi
SRC_BYTES=$(du -sb "$SRC" | awk '{print $1}')
SRC_FILES=$(find "$SRC" -type f | wc -l)

if [[ ! -d "$READ_SCRATCH" ]]; then
  log "FATAL: read scratch dir missing: $READ_SCRATCH"
  log "  Run the Stage 1.6 prep first to pre-stage 64×4G fio scratch files."
  exit 2
fi
SCRATCH_FILES=$(find "$READ_SCRATCH" -type f | wc -l)
SCRATCH_BYTES=$(du -sb "$READ_SCRATCH" | awk '{print $1}')

log "=== Stage 1.6 mixed sweep starting ==="
log "  ingest source:  $SRC ($SRC_FILES files, $SRC_BYTES bytes)"
log "  ingest target:  $WRITE_TARGET (cleaned per-cell)"
log "  ingest tool:    fpsync -n $INGEST_N (FIXED across all cells)"
log "  read scratch:   $READ_SCRATCH ($SCRATCH_FILES files, $SCRATCH_BYTES bytes)"
log "  read grid:      bs ∈ {${BS_LIST[*]}} × jobs ∈ {${JOBS_LIST[*]}}"
log "  total cells:    $TOTAL"
log "  consolidated log: $SWEEP_LOG"

i=0
for bs in "${BS_LIST[@]}"; do
  for jobs in "${JOBS_LIST[@]}"; do
    i=$(( i + 1 ))
    name="mixed-bs${bs}-jobs${jobs}"
    SHDIR="$SHDIR_ROOT/bs${bs}-jobs${jobs}"
    note="Stage 1.6 mixed sweep cell $i/$TOTAL: concurrent ingest+read. Ingest = fpsync -n $INGEST_N (fixed, and set as a FRACTION OF THIS LEG'S OWN 1.5 write curve — an absolute rate carried across legs would make the two cells different workloads). Read = fio --rw=randread --bs=$bs --numjobs=$jobs --iodepth=8 --runtime=600 --ramp_time=60 libaio --direct=1 against pre-staged fio scratch ($SCRATCH_FILES files at $READ_SCRATCH). Wrapper: fpsync kicked off in background, fio runs in foreground for the timed window, fpsync killed when fio exits. Per-cell isolation via record-run.sh; any cell failure leaves rest of sweep intact."

    log ""
    log "=== [cell $i/$TOTAL] $name ==="
    log "  cleaning prior write target + fpsync shdir ..."
    rm -rf "$WRITE_TARGET" "$SHDIR"
    mkdir -p "$WRITE_TARGET" "$SHDIR"

    CELL_START=$(date -u +%FT%TZ)
    log "  starting cell at $CELL_START"

    # Wrapper: fpsync background + fio foreground. The wrapper is passed to
    # record-run.sh via `bash -c`, so all primary sources record across the
    # combined window.
    #
    # IMPORTANT (lesson learned 2026-05-07 mid-1.6-sweep): do NOT use
    # `pkill -f "fpsync -v -n $INGEST_N -d $SHDIR"` to clean up — that pattern
    # also matches the PARENT bash's argv (because the bash -c string contains
    # the same literal substring), causing the cleanup to SIGTERM its own
    # parent before reaching `exit $FIO_RC`. The parent bash dies with rc=143,
    # record-run.sh marks the cell INCOMPLETE despite the data being fully
    # valid (fio ran to completion, recorders captured the full window).
    #
    # Fix: launch fpsync via `setsid` so it gets its own process group/session,
    # then `kill -- -$FPSYNC_PID` (negative PID = process group) to kill the
    # whole fpsync subtree without any pattern matching that could match the
    # parent.
    "$REPO/scripts/record-run.sh" \
      --run-name "$name" \
      --stage 1.6 \
      --note "$note" \
      -- bash -c "
        set +e
        # Background: fpsync n=$INGEST_N in its own process group via setsid.
        # FPSYNC_PID is the session/process-group leader — kill -- -PGID
        # kills the whole tree (fpsync master + rsync workers) without
        # pattern-matching that could collide with the parent bash's argv.
        setsid /usr/bin/fpsync -v -n $INGEST_N -d $SHDIR $SRC $WRITE_TARGET/ &
        FPSYNC_PID=\$!
        echo '[wrapper] fpsync backgrounded in own session, pid='\$FPSYNC_PID

        # Foreground: fio. --output-format=json+ writes JSON to stdout (cmd.log).
        # Files already exist in scratch from prep, so fio skips layout phase.
        fio \\
          --name=read-$name \\
          --directory=$READ_SCRATCH \\
          --rw=randread --bs=$bs --size=4G \\
          --numjobs=$jobs --iodepth=8 \\
          --ioengine=libaio --direct=1 \\
          --runtime=600 --ramp_time=60 --time_based --group_reporting \\
          --output-format=json+ --status-interval=1
        FIO_RC=\$?
        echo '[wrapper] fio exited rc='\$FIO_RC

        # Kill the entire fpsync process group (negative PID syntax). No
        # pattern matching, so cannot accidentally kill the parent bash.
        kill -TERM -- -\$FPSYNC_PID 2>/dev/null
        sleep 2
        kill -KILL -- -\$FPSYNC_PID 2>/dev/null
        wait 2>/dev/null
        echo '[wrapper] fpsync tree cleaned up'
        exit \$FIO_RC
      " 2>&1 | tee -a "$SWEEP_LOG"

    CELL_END=$(date -u +%FT%TZ)
    POST_TARGET_BYTES=$(du -sb "$WRITE_TARGET" 2>/dev/null | awk '{print $1}')
    POST_TARGET_FILES=$(find "$WRITE_TARGET" -type f 2>/dev/null | wc -l)
    log "  cell ended at $CELL_END"
    log "  post-cell write target: $POST_TARGET_FILES files, $POST_TARGET_BYTES bytes (ingest stream)"

    RUN_DIR=$(ls -td "$REPO/runs/"*-s1.6-${name} 2>/dev/null | head -1)
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
      cat > "$RUN_DIR/notes.md" <<EOF
# Stage 1.6 cell $i/$TOTAL — mixed (fpsync n=$INGEST_N + fio randread bs=$bs jobs=$jobs)

## Ingest side (app-level, du-based)

- Source: $SRC ($SRC_FILES files, $SRC_BYTES bytes)
- Write target: $WRITE_TARGET (cleaned pre-cell)
- Post-cell target bytes: $POST_TARGET_BYTES
- Post-cell target files: $POST_TARGET_FILES
- fpsync concurrency: -n $INGEST_N (fixed)

## Read side

Headline numbers come from fio's JSON output in cmd.log. Use the parser /
aggregate-stage1-mixed.py for structured extraction:
- read bandwidth (mean, sustained)
- read IOPS
- read latency (mean, p99)

## Cell window

- Cell start (UTC): $CELL_START
- Cell end   (UTC): $CELL_END

The wall-clock duration in this notes file brackets the entire record-run.sh
operation. For the timed-window-only duration, use raw/.run_start and raw/.run_end.

## Cross-source check (post-aggregation)

Run the post-cell cross-source consistency canary using THIS leg's Primary
sources (docs/RUNBOOK.md § What gets recorded) and THIS leg's consistency
relation, derived per filesystem and never ported across (STAGES.md D12):
- filesystem-side Write sustained  vs  fpsync app-level
- filesystem-side Read  sustained  vs  fio app-level
- wire counters for the data path in use  vs  the app-level rate, at the
  amplification the relation implies (WEKA: from the provisioned EC scheme;
  Lustre: from the actual stripe layout)
⚠ Mixed read+write cells need WIDER bands than single-direction cells — the wire
carries payload plus acknowledgements in both directions, and at small block
sizes the non-payload share is material. Widen deliberately and say so here.
⏳ D-5: the relation itself is not derived yet. Do not fill numbers in from
another environment.
EOF
      if [[ -d "$SHDIR/log" ]]; then
        mkdir -p "$RUN_DIR/raw/fpsync-shdir-log"
        cp -a "$SHDIR/log/." "$RUN_DIR/raw/fpsync-shdir-log/" 2>/dev/null || true
        log "  copied fpsync shdir log into $RUN_DIR/raw/fpsync-shdir-log/"
      fi
    else
      log "  WARN: could not locate run dir to attach notes.md (sidecar lost)"
    fi
  done
done

log ""
log "=== sweep done ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
log "next:   scripts/aggregate-stage1-mixed.py 'runs/2026-*-s1.6-mixed-*'"
log "cleanup: rm -rf $WRITE_TARGET (ingest stream data, ~1 TiB transient)"
log "         rm -rf $SHDIR_ROOT/* (fpsync shared dirs, small)"

# ============================================================================
# Stage 1.6 PREP step (run BEFORE this sweep, also wrapped in record-run.sh):
#
#   scripts/record-run.sh \
#     --run-name fio-scratch-layout-prep \
#     --stage 1.6 \
#     --note "Stage 1.6 PREP (not a sweep cell): pre-stage 64×4G fio scratch
#             files at ${FS_MOUNT}/benchmarks/fio-scratch-mixed/ for the read
#             side of the mixed sweep. Created once, reused across all 8 cells
#             (avoids per-cell layout phase). Same fio --rw=write recipe as
#             1.0a's bs=1M/jobs=N to verify the filesystem absorbs the layout.
#             Side measurement: 256 GB sequential write to ${FS_MOUNT} at moderate
#             concurrency, useful as a 1.0a cross-check on real-world write." \
#     -- fio \
#         --name=fio-scratch-layout \
#         --directory=${FS_MOUNT}/benchmarks/fio-scratch-mixed \
#         --rw=write --bs=1M --size=4G --numjobs=64 --iodepth=1 \
#         --ioengine=libaio --direct=1 \
#         --create_only=1 \
#         --output-format=json+ --status-interval=1
# ============================================================================
