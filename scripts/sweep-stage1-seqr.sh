#!/usr/bin/env bash
# sweep-stage1-seqr.sh — Stage 1.0b sequential-read fio sweep, COLD BY
# CONSTRUCTION (D13 route 1; design ratified 2026-08-15, Stage-1-Ingest.md).
#
# Grid: bs ∈ {4K, 64K, 256K, 1M, 4M} × jobs ∈ {1, 2, 4, 8, 16, 32, 64}
#       = 35 cells, plus one WARM REFERENCE cell = 36.
#
# The cold construction, and why each piece exists:
#   - Cells read the PRE-STAGED shared scan corpus (prep-stage1-read-corpora.sh;
#     never laid out inside the timed window, never unlinked between cells).
#     Its size is >= ~2x the larger server-side cache: a sequential scan over a
#     corpus larger than an LRU cache continuously evicts the data just ahead
#     of the read pointer, so scans stay cold even when the corpus is re-read
#     across cells.
#   - SINGLE PASS per cell (no --time_based): each job reads its disjoint slice
#     at most once, stopping at min(slice, --runtime). time_based would wrap a
#     fast job back onto its own just-read slice — a small region trivially
#     served from server RAM.
#   - PER-CELL OFFSET ROTATION (4 slots x 192 GiB): consecutive low-rate cells
#     read from different windows, so a cell never starts on the head bytes its
#     predecessor just read. An engineering margin, not a proof — the warm
#     reference cell is the evidence either way.
#   - FIXED DE-ORDERED cell sequence, identical on both legs: jobs never ascend
#     monotonically, so warmth cannot track the swept variable.
#   - The WARM REFERENCE cell (D13 route 2, direction inverted because this
#     grid's default regime is cold): reads the corpus head twice back-to-back
#     (--loops=2, 64 GiB), so its second pass is deliberately server-cache-warm.
#     The cold-vs-warm contrast in its own timeline (split-window) is the
#     measured evidence that (a) the server cache exists and serves at a
#     distinguishable rate, and (b) the grid's cold construction is therefore
#     meaningful. Grid cells declare cold; this cell declares warm.
#
# Run with:  scripts/sweep-stage1-seqr.sh   (after prep-stage1-read-corpora.sh)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh}"
: "${STAGE1_SEQ_CORPUS_GIB:?STAGE1_SEQ_CORPUS_GIB is unset -- set it in env.sh (cache-derived provisioning parameter)}"

CORPUS_DIR="$FS_MOUNT/benchmarks/stage1-read-corpus"
CORPUS_FILE="$CORPUS_DIR/seq-corpus.bin"
MARKER="$REPO/runs/.leg-state/$LEG/stage1-read-corpus-staged"
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-$LEG-stage1-seqr.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

# Refuse without the staging marker — an unstaged corpus means fio would lay
# files out inside the timed window, which is the exact defect this rework
# removed. Cross-check the staged size against the env parameter: a corpus
# staged under different sizes invalidates the cold construction silently.
[ -f "$MARKER" ] || { log "FATAL: staging marker missing ($MARKER) — run prep-stage1-read-corpora.sh first."; exit 2; }
staged_gib=$(awk -F= '/^seq_corpus_gib=/{print $2}' "$MARKER")
[ "$staged_gib" = "$STAGE1_SEQ_CORPUS_GIB" ] || { log "FATAL: staged seq corpus is ${staged_gib} GiB but env says ${STAGE1_SEQ_CORPUS_GIB} GiB — restage or fix env.sh."; exit 2; }
[ -f "$CORPUS_FILE" ] || { log "FATAL: $CORPUS_FILE missing despite marker — restage."; exit 2; }

# Fixed de-ordered sequence: 5 passes over a de-ordered jobs list, block size
# rotated per pass so every (bs, jobs) pair appears exactly once and neither
# axis ascends monotonically. Committed here => identical on both legs.
JOBS_SEQ=(16 1 64 4 32 2 8)
BS_ALL=(1M 4k 256k 64k 4M)
ROT_SLOTS=4
ROT_STRIDE_GIB=192

TOTAL=36
log "=== Stage 1.0b seqr sweep starting (leg=$LEG) ==="
log "  corpus: $CORPUS_FILE (${STAGE1_SEQ_CORPUS_GIB} GiB, pre-staged + evicted)"
log "  grid: 35 cells (fixed de-ordered sequence) + 1 warm reference = $TOTAL"
log "  consolidated log: $SWEEP_LOG"

i=0
FAILED_CELLS=0

# D-36 resume-skip: re-running the driver re-does only what is missing. A cell
# whose exact name already has an OK-verdict run dir for this leg+stage is
# skipped, keyed on the INDEX.md verdict. The glob is anchored at the cell name,
# so -repN repeats and -FAILED-* renames never match; a REP invocation (a D18
# repeat deliberately re-running a completed cell) never skips. Skip-safe by
# construction here: each cell's offset slot is fixed by its index, and the scan
# corpus is retained across invocations, so remaining cells are unaffected.
cell_done_ok() { # cell_done_ok <cell-name>
  local name="$1" d
  [ -n "${REP:-}" ] && return 1
  for d in "$REPO"/runs/*-"$LEG"-s1.0b-"$name"; do
    [ -d "$d" ] || continue
    grep -F -- "\`$(basename "$d")\`" "$REPO/runs/INDEX.md" 2>/dev/null \
      | grep -Eq 'rc=[^,]*, OK\)' && return 0
  done
  return 1
}

run_seqr_cell() { # run_seqr_cell <bs> <jobs> <cellindex>
  local bs="$1" jobs="$2" idx="$3"
  local offset_gib=$(( (idx % ROT_SLOTS) * ROT_STRIDE_GIB ))
  local span_gib=$(( STAGE1_SEQ_CORPUS_GIB - offset_gib ))
  local slice_gib=$(( span_gib / jobs ))
  local name="seqr-bs${bs}-jobs${jobs}"
  if cell_done_ok "$name"; then
    log ""
    log "=== [cell $((idx+1))/$TOTAL] $name — SKIP: already recorded OK (D-36 resume) ==="
    return 0
  fi
  local note="Stage 1.0b cell $((idx+1))/$TOTAL: sequential read, bs=$bs jobs=$jobs iodepth=1 libaio --direct=1. COLD BY CONSTRUCTION (D13 route 1): pre-staged ${STAGE1_SEQ_CORPUS_GIB} GiB scan corpus (>= ~2x the larger server cache; cyclic-scan LRU self-eviction), single pass per cell (no time_based; stops at min(slice, 600s)), per-cell offset rotation (slot $((idx % ROT_SLOTS)), offset ${offset_gib} GiB), fixed de-ordered cell order. Per-job disjoint slice ${slice_gib} GiB. Evidence cell: the sweep's warm reference. Server-side residual recorded, not asserted."

  log ""
  log "=== [cell $((idx+1))/$TOTAL] $name (offset ${offset_gib}G, slice ${slice_gib}G/job) ==="
  RECORD_CACHE_STATE=cold "$REPO/scripts/record-run.sh" \
    --run-name "$name" --stage "1.0b" --note "$note" \
    -- fio \
      --name="$name" \
      --filename="$CORPUS_FILE" \
      --rw=read --bs="$bs" \
      --numjobs="$jobs" --iodepth=1 --ioengine=libaio --direct=1 \
      --offset="${offset_gib}G" --offset_increment="${slice_gib}G" --size="${slice_gib}G" \
      --runtime=600 --ramp_time=60 \
      --group_reporting --output-format=json+ --status-interval=1 \
    2>&1 | tee -a "$SWEEP_LOG"
  local rc=${PIPESTATUS[0]}
  (( rc != 0 )) && { FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$rc — INCOMPLETE; sweep continues (fails loud at the end)"; }
}

for p in 0 1 2 3 4; do
  for q in 0 1 2 3 4 5 6; do
    bs="${BS_ALL[$(( (p + q) % 5 ))]}"
    jobs="${JOBS_SEQ[$q]}"
    run_seqr_cell "$bs" "$jobs" "$i"
    i=$(( i + 1 ))
  done
done

# Warm reference cell: 4 jobs x 16 GiB disjoint slices of the corpus head,
# --loops=2 — pass 1 approximately cold, pass 2 deliberately server-cache-warm
# (64 GiB just read, far under the server cache). The pass-1-vs-pass-2 contrast
# in the cell's own timeline is the D13 evidence for the whole grid's cold
# construction, and pass 2 doubles as the server-cache-served read rate.
i=$(( i + 1 ))
name="seqr-warmref-bs1M-jobs4"
if cell_done_ok "$name"; then
  log ""
  log "=== [cell $i/$TOTAL] $name — SKIP: already recorded OK (D-36 resume) ==="
else
  log ""
  log "=== [cell $i/$TOTAL] $name (warm reference: 64 GiB head read twice) ==="
  RECORD_CACHE_STATE=warm "$REPO/scripts/record-run.sh" \
    --run-name "$name" --stage "1.0b" \
    --note "Stage 1.0b WARM REFERENCE cell (D13 route 2, inverted: the grid's default regime is cold, so the reference is warm). 4 jobs x 16 GiB disjoint head slices, --loops=2: pass 1 ~cold, pass 2 deliberately server-cache-warm. The split-window (first-half vs second-half) contrast is the evidence the grid's cold construction rests on; pass 2 is also the server-cache-served sequential read rate." \
    -- fio \
      --name="$name" \
      --filename="$CORPUS_FILE" \
      --rw=read --bs=1M \
      --numjobs=4 --iodepth=1 --ioengine=libaio --direct=1 \
      --offset=0 --offset_increment=16G --size=16G --loops=2 \
      --group_reporting --output-format=json+ --status-interval=1 \
    2>&1 | tee -a "$SWEEP_LOG"
  rc=${PIPESTATUS[0]}
  (( rc != 0 )) && { FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: warmref rc=$rc — INCOMPLETE"; }
fi

log ""
log "=== sweep done ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
