#!/usr/bin/env bash
# sweep-stage1-randw.sh — Stage 1.0c random-write IOPS fio sweep.
# Grid: bs ∈ {4K, 16K, 64K} × jobs ∈ {1..64} = 21 cells.
# iodepth=8 per WEKA's IOPS recipe; this is the WEKA-stresses-metadata story.
# 600s steady + 60s ramp per cell, --unlink=1.
set -uo pipefail

REPO=/home/liadhermelin/wsi/rerun_new_TRUERESULTS
SCRATCH=/mnt/liad/benchmarks/fio-scratch
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR" "$SCRATCH"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stage1-randw.log"

BLOCK_SIZES=(4k 16k 64k)
CONCURRENCIES=(1 2 4 8 16 32 64)
TOTAL=$(( ${#BLOCK_SIZES[@]} * ${#CONCURRENCIES[@]} ))

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

log "=== Stage 1.0c randw sweep starting ==="
log "  grid: bs ∈ {${BLOCK_SIZES[*]}} × jobs ∈ {${CONCURRENCIES[*]}}"
log "  $TOTAL cells, ~11 min each, est ~$(( TOTAL * 11 / 60 )) hours"

i=0
for bs in "${BLOCK_SIZES[@]}"; do
  for jobs in "${CONCURRENCIES[@]}"; do
    i=$(( i + 1 ))
    name="randw-bs${bs}-jobs${jobs}"
    note="Stage 1.0c cell $i/$TOTAL: random write IOPS, bs=$bs, $jobs jobs, iodepth=8 (WEKA recipe), libaio --direct=1, 600s steady + 60s ramp, --unlink=1."

    log ""
    log "=== [cell $i/$TOTAL] $name ==="

    "$REPO/runs/lib/record-run.sh" \
      --run-name "$name" --stage "1.0c" --note "$note" \
      -- fio \
        --name="$name" --directory="$SCRATCH" \
        --rw=randwrite --bs="$bs" --size=4G --numjobs="$jobs" --iodepth=8 \
        --ioengine=libaio --direct=1 \
        --runtime=600 --ramp_time=60 --time_based --group_reporting \
        --unlink=1 --output-format=json+ --status-interval=1 \
      2>&1 | tee -a "$SWEEP_LOG"
  done
done

log ""
log "=== Stage 1.0c randw sweep done ==="
