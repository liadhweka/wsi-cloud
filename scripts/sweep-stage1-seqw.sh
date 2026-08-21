#!/usr/bin/env bash
# sweep-stage1-seqw.sh — Stage 1.0a sequential-write fio sweep.
#
# Grid: bs ∈ {4K, 64K, 256K, 1M, 4M} × jobs ∈ {1, 2, 4, 8, 16, 32, 64}
#       = 35 cells.
# Each cell: 600s steady-state + 60s ramp = ~11 min wall clock.
# Total estimated: ~35 × 11 = ~6.4 hours.
#
# Per-cell isolation: each cell calls record-run.sh which captures pre/raw/post
# independently. Single-cell failure (network blip, transient fio error) leaves
# that cell INCOMPLETE in INDEX.md; the sweep continues with the next cell.
#
# Run with:
#   scripts/sweep-stage1-seqw.sh
# Output:
#   - one runs/<TS>-<fs>-s1.0a-seqw-bs<X>-jobs<N>/ per cell (with full recording)
#   - one consolidated log at runs/sweep-logs/<TS>-stage1-seqw.log
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh (the D-36 resume-skip is leg-scoped)}"
SCRATCH=${FS_MOUNT}/benchmarks/fio-scratch
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$SCRATCH"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-seqw.log"

BLOCK_SIZES=(4k 64k 256k 1M 4M)
CONCURRENCIES=(1 2 4 8 16 32 64)
TOTAL=$(( ${#BLOCK_SIZES[@]} * ${#CONCURRENCIES[@]} ))

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }
FAILED_CELLS=0

# D-36 resume-skip: re-running the driver re-does only what is missing. A cell
# whose exact name already has an OK-verdict run dir for this leg+stage is
# skipped, keyed on the INDEX.md verdict. The glob is anchored at the cell name,
# so -repN repeats and -FAILED-* renames never match; a REP invocation (a D18
# repeat deliberately re-running a completed cell) never skips.
cell_done_ok() { # cell_done_ok <cell-name>
  local name="$1" d
  [ -n "${REP:-}" ] && return 1
  for d in "$REPO"/runs/*-"$LEG"-s1.0a-"$name"; do
    [ -d "$d" ] || continue
    grep -F -- "\`$(basename "$d")\`" "$REPO/runs/INDEX.md" 2>/dev/null \
      | grep -Eq 'rc=[^,]*, OK\)' && return 0
  done
  return 1
}

log "=== Stage 1.0a seqw sweep starting ==="
log "  grid: bs ∈ {${BLOCK_SIZES[*]}} × jobs ∈ {${CONCURRENCIES[*]}}"
log "  total cells: $TOTAL, runtime per cell: 600s + 60s ramp = ~11 min"
log "  estimated total: ~$(( TOTAL * 11 / 60 )) hours"
log "  scratch dir: $SCRATCH"
log "  consolidated log: $SWEEP_LOG"

i=0
for bs in "${BLOCK_SIZES[@]}"; do
  for jobs in "${CONCURRENCIES[@]}"; do
    i=$(( i + 1 ))
    name="seqw-bs${bs}-jobs${jobs}"
    note="Stage 1.0a cell $i/$TOTAL: sequential write, bs=$bs, $jobs jobs, iodepth=1, libaio --direct=1, 600s steady + 60s ramp, --unlink=1 to keep scratch clean."

    if cell_done_ok "$name"; then
      log ""
      log "=== [cell $i/$TOTAL] $name — SKIP: already recorded OK (D-36 resume) ==="
      continue
    fi

    log ""
    log "=== [cell $i/$TOTAL] $name ==="

    RECORD_CACHE_STATE="na-write-cell" \
    "$REPO/scripts/record-run.sh" \
      --run-name "$name" \
      --stage "1.0a" \
      --note "$note" \
      -- fio \
        --name="$name" \
        --directory="$SCRATCH" \
        --rw=write \
        --bs="$bs" \
        --size=4G \
        --numjobs="$jobs" \
        --iodepth=1 \
        --ioengine=libaio \
        --direct=1 \
        --runtime=600 \
        --ramp_time=60 \
        --time_based \
        --group_reporting \
        --unlink=1 \
        --output-format=json+ \
        --status-interval=1 \
      2>&1 | tee -a "$SWEEP_LOG"
      cell_rc=${PIPESTATUS[0]}
      if (( cell_rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$cell_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
  done
done

log ""
log "=== sweep done ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"

if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
