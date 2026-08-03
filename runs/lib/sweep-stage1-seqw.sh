#!/usr/bin/env bash
# sweep-stage1-seqw.sh — Stage 1.0 sequential-write fio sweep.
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
#   runs/lib/sweep-stage1-seqw.sh
# Output:
#   - one runs/<TS>-s1.0-seqw-bs<X>-jobs<N>/ per cell (with full recording)
#   - one consolidated log at runs/sweep-logs/<TS>-stage1-seqw.log
set -uo pipefail

REPO=/home/liadhermelin/wsi/rerun_new_TRUERESULTS
SCRATCH=/mnt/liad/benchmarks/fio-scratch
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$SCRATCH"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-seqw.log"

BLOCK_SIZES=(4k 64k 256k 1M 4M)
CONCURRENCIES=(1 2 4 8 16 32 64)
TOTAL=$(( ${#BLOCK_SIZES[@]} * ${#CONCURRENCIES[@]} ))

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

log "=== Stage 1.0 seqw sweep starting ==="
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
    note="Stage 1.0 sweep cell $i/$TOTAL: sequential write, bs=$bs, $jobs jobs, iodepth=1, libaio --direct=1, 600s steady + 60s ramp, --unlink=1 to keep scratch clean."

    log ""
    log "=== [cell $i/$TOTAL] $name ==="

    "$REPO/runs/lib/record-run.sh" \
      --run-name "$name" \
      --stage "1.0" \
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
  done
done

log ""
log "=== sweep done ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
