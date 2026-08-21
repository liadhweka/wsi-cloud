#!/usr/bin/env bash
# sweep-stability-canary.sh — the run-to-run noise band (STAGES.md D18).
#
# Two fixed, short cells (~3 min the pair), invoked repeatedly across the leg —
# run-leg.sh interleaves them between the major sweeps, giving roughly three
# pairs per day on a multi-day leg plus a natural start-of-leg / end-of-leg
# pair. The spread of these fixed cells across the leg IS the leg's empirical
# noise band: a cross-leg delta is quoted only where it clears BOTH legs' bands
# (RUNBOOK.md, "Run-to-run variance").
#
# The canary measures PATH STABILITY, not absolute capability:
#   io cell   — fio 60s sequential + 60s random read, O_DIRECT, one fixed 8 GiB
#               file. O_DIRECT keeps the client page cache out; the server side
#               stays warm by design — CONSISTENTLY warm is exactly what a drift
#               canary wants.
#   meta cell — create/stat/unlink 2000 files, one timed phase each; the
#               metadata path's stability.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
# D-7 watchdog: the io pair is ~3 min; past 15 min it is hung, not slow.
export RECORD_TIMEOUT_S=${RECORD_TIMEOUT_S:-900}

CANARY_DIR=${FS_MOUNT}/benchmarks/stability-canary
mkdir -p "$CANARY_DIR"
LOG_DIR=$REPO/runs/sweep-logs; mkdir -p "$LOG_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-stability-canary.log"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

log "=== stability canary pair (D18) ==="

# na-*: NOT_APPLICABLE to the D13 reconciler — cache regime is deliberately not an
# axis here. The io cell's fixture is client-cold (O_DIRECT) and server-warm BY
# DESIGN (D18: it measures path stability, not absolute capability).
RECORD_CACHE_STATE="na-stability-fixture" \
bash "$REPO/scripts/record-run.sh" --stage stability --run-name canary-io \
  --note "D18 stability canary (io): fio 60s seqread (1M, iodepth 8) + 60s randread (64k, iodepth 16), O_DIRECT, one fixed 8 GiB file at ${CANARY_DIR}. Fixed config by design — this cell's spread across the leg is the leg's noise band for throughput-class cells. It measures path stability, not absolute capability: O_DIRECT keeps the client cache out; the server side is consistently warm." \
  -- fio --name=canary-seqread --filename="$CANARY_DIR/canary-io.bin" --size=8G \
         --rw=read --bs=1M --direct=1 --ioengine=libaio --iodepth=8 \
         --runtime=60 --time_based \
         --name=canary-randread --stonewall --filename="$CANARY_DIR/canary-io.bin" --size=8G \
         --rw=randread --bs=64k --direct=1 --ioengine=libaio --iodepth=16 \
         --runtime=60 --time_based \
  || log "WARN: canary io cell failed"

RECORD_CACHE_STATE="na-stability-fixture" \
bash "$REPO/scripts/record-run.sh" --stage stability --run-name canary-meta \
  --note "D18 stability canary (meta): create/stat/unlink 2000 empty files in a fresh dir, one timed phase each, ops/s printed to stdout. Fixed config by design — this cell's spread across the leg is the leg's noise band for metadata-class cells." \
  -- bash -c '
    set -u
    d="'"$CANARY_DIR"'/meta.$$"; mkdir -p "$d"; n=2000
    t0=$(date +%s.%N); for i in $(seq 1 $n); do : > "$d/f$i"; done
    t1=$(date +%s.%N); for i in $(seq 1 $n); do stat -c %s "$d/f$i" >/dev/null; done
    t2=$(date +%s.%N); for i in $(seq 1 $n); do rm -f "$d/f$i"; done
    t3=$(date +%s.%N); rmdir "$d"
    awk -v n=$n -v a=$t0 -v b=$t1 -v c=$t2 -v e=$t3 \
      "BEGIN{printf \"canary_meta create_ops_s=%.1f stat_ops_s=%.1f unlink_ops_s=%.1f\n\", n/(b-a), n/(c-b), n/(e-c)}"
  ' || log "WARN: canary meta cell failed"

log "=== stability canary pair done ==="
