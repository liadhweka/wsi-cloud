#!/usr/bin/env bash
# sweep-stage1-randr.sh — Stage 1.0d random-read IOPS fio sweep.
# Grid: bs ∈ {4K, 16K, 64K} × jobs ∈ {1..64} = 21 cells.
# iodepth=8 per WEKA's IOPS recipe. Stage-5-relevant random-read profile.
# fio creates files during layout phase before reads begin. --unlink=1 cleans up.
set -uo pipefail

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
SCRATCH=${FS_MOUNT}/benchmarks/fio-scratch
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$SCRATCH"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-randr.log"

BLOCK_SIZES=(4k 16k 64k)
CONCURRENCIES=(1 2 4 8 16 32 64)
TOTAL=$(( ${#BLOCK_SIZES[@]} * ${#CONCURRENCIES[@]} ))

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

log "=== Stage 1.0d randr sweep starting ==="
log "  grid: bs ∈ {${BLOCK_SIZES[*]}} × jobs ∈ {${CONCURRENCIES[*]}}"
log "  $TOTAL cells, ~11 min each + layout overhead, est ~$(( TOTAL * 12 / 60 )) hours"

i=0
for bs in "${BLOCK_SIZES[@]}"; do
  for jobs in "${CONCURRENCIES[@]}"; do
    i=$(( i + 1 ))
    name="randr-bs${bs}-jobs${jobs}"
    note="Stage 1.0d cell $i/$TOTAL: random read IOPS, bs=$bs, $jobs jobs, iodepth=8 (WEKA recipe), libaio --direct=1, 600s steady + 60s ramp, --unlink=1. fio creates files during layout phase before timed window."

    log ""
    log "=== [cell $i/$TOTAL] $name ==="

    "$REPO/runs/lib/record-run.sh" \
      --run-name "$name" --stage "1.0d" --note "$note" \
      -- fio \
        --name="$name" --directory="$SCRATCH" \
        --rw=randread --bs="$bs" --size=4G --numjobs="$jobs" --iodepth=8 \
        --ioengine=libaio --direct=1 \
        --runtime=600 --ramp_time=60 --time_based --group_reporting \
        --unlink=1 --output-format=json+ --status-interval=1 \
      2>&1 | tee -a "$SWEEP_LOG"
  done
done

log ""
log "=== Stage 1.0d randr sweep done ==="
