#!/usr/bin/env bash
# sweep-stage1-seqr.sh — Stage 1.0b sequential-read fio sweep.
# Same grid as 1.0a (5 bs × 7 jobs = 35 cells), --rw=read, iodepth=1.
# fio creates the files during its layout phase, then reads for 600s.
# --unlink=1 cleans them up at end of each cell.
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
SCRATCH=${FS_MOUNT}/benchmarks/fio-scratch
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$SCRATCH"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-seqr.log"

BLOCK_SIZES=(4k 64k 256k 1M 4M)
CONCURRENCIES=(1 2 4 8 16 32 64)
TOTAL=$(( ${#BLOCK_SIZES[@]} * ${#CONCURRENCIES[@]} ))

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

log "=== Stage 1.0b seqr sweep starting ==="
log "  grid: bs ∈ {${BLOCK_SIZES[*]}} × jobs ∈ {${CONCURRENCIES[*]}}"
log "  $TOTAL cells, ~11 min each, est ~$(( TOTAL * 11 / 60 )) hours"

i=0
for bs in "${BLOCK_SIZES[@]}"; do
  for jobs in "${CONCURRENCIES[@]}"; do
    i=$(( i + 1 ))
    name="seqr-bs${bs}-jobs${jobs}"
    note="Stage 1.0b cell $i/$TOTAL: sequential read, bs=$bs, $jobs jobs, iodepth=1, libaio --direct=1, 600s steady + 60s ramp, --unlink=1. fio creates files during layout phase before timed window."

    log ""
    log "=== [cell $i/$TOTAL] $name ==="

    "$REPO/scripts/record-run.sh" \
      --run-name "$name" --stage "1.0b" --note "$note" \
      -- fio \
        --name="$name" --directory="$SCRATCH" \
        --rw=read --bs="$bs" --size=4G --numjobs="$jobs" --iodepth=1 \
        --ioengine=libaio --direct=1 \
        --runtime=600 --ramp_time=60 --time_based --group_reporting \
        --unlink=1 --output-format=json+ --status-interval=1 \
      2>&1 | tee -a "$SWEEP_LOG"
  done
done

log ""
log "=== Stage 1.0b seqr sweep done ==="
