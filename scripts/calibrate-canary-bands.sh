#!/usr/bin/env bash
# calibrate-canary-bands.sh — the D-5 band calibration: run the probe-shaped
# Stage-0 cells >=3x per direction on the PROVISIONED cluster, then compute and
# write runs/.leg-state/$LEG/canary-bands.json via `wsi_agg_helper.py calibrate`.
#
# WHY: the post-cell consistency canary refuses (UNCALIBRATED) without a bands
# file, by design — a guessed tolerance can both mask a real inconsistency and
# manufacture a false one. The bands must come from repeats on the cluster that
# will run the leg, because the wire/app ratio carries the protocol share of
# THIS cluster's transport and EC scheme.
#
# Cells (all --stage 0, diagnostic, never quoted as results):
#   3x seqw  bs=4M jobs=16 iodepth=8 300s   — probe-shaped (2026-08-15 anchors:
#   3x seqr  bs=4M jobs=16 iodepth=8 480s     write 1.455, read 1.034 on 5+2)
#   3x randw bs=4K jobs=16 iodepth=8 180s   — the small-bs band is DERIVED at
#   3x randr bs=4K jobs=16 iodepth=8 180s     the block size under test
#                                             (Stage-1 register), never inherited
# The read cells deliberately read the just-written 160 GiB — backend-RAM-
# resident, so drives are out of the picture and the ratio is a pure wire/app
# measurement. Calibration files are left in place (cheap re-calibration).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh}"
: "${LEG:?LEG is unset -- source env.sh}"
# The D12 relation input is per-leg (the relation is never ported across):
# WEKA derives (D+P)/D from the EC scheme; Lustre derives from the recorded
# stripe layout. Requiring the other leg's input refuses a healthy leg.
case "$LEG" in
  weka)   : "${WEKA_EC_SCHEME:?WEKA_EC_SCHEME is unset -- the WEKA relation cannot be derived without it (D12)}" ;;
  lustre) : "${LUSTRE_STRIPE_LAYOUT:?LUSTRE_STRIPE_LAYOUT is unset -- the Lustre relation cannot be derived without it (D12)}" ;;
  *) echo "calibrate: FATAL: unknown LEG='$LEG'" >&2; exit 2 ;;
esac
RECORD="$REPO/scripts/record-run.sh"
HELPER="$REPO/scripts/wsi_agg_helper.py"
CALIB_DIR="$FS_MOUNT/benchmarks/fio-canary-calib"
mkdir -p "$CALIB_DIR"
LOG_DIR=$REPO/runs/sweep-logs; mkdir -p "$LOG_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-$LEG-calibrate-canary-bands.log"
log() { echo "[$(date -u +%FT%TZ)] calibrate: $*" | tee -a "$SWEEP_LOG"; }

RUN_DIRS=()
FAILED=0

cell() { # cell <name> <cache_state> <fio args...>
  local name=$1 cache=$2; shift 2
  local ts run_dir
  ts=$(date -u +%Y-%m-%d-%H%M%S)
  run_dir="$REPO/runs/${ts}-${LEG}-s0-${name}"
  log "cell $name"
  # if ! ...: with pipefail, the pipeline carries record-run's status while the
  # condition context keeps set -e from aborting the driver mid-sequence — every
  # cell is attempted and the script fails loud at the end.
  if RECORD_RUN_DIR="$run_dir" RECORD_CACHE_STATE="$cache" \
     "$RECORD" --stage 0 --run-name "$name" \
       --note "CANARY-BAND CALIBRATION cell (D-5), diagnostic, never quote: $name. Probe-shaped fio against $CALIB_DIR; wire/app ratio feeds runs/.leg-state/$LEG/canary-bands.json via wsi_agg_helper.py calibrate. Read cells are deliberately backend-RAM-resident (drives out of the picture; the ratio is the measurement)." \
       -- fio --name="$name" --directory="$CALIB_DIR" \
          --filename_format='calib.$jobnum' --size=10G --numjobs=16 \
          --ioengine=libaio --direct=1 --iodepth=8 --time_based \
          --group_reporting --output-format=json+ --status-interval=1 "$@" \
       2>&1 | tee -a "$SWEEP_LOG"; then
    RUN_DIRS+=("$run_dir")
  else
    FAILED=$(( FAILED + 1 ))
    log "WARN: $name failed — it will not feed the bands; calibration continues and fails loud at the end"
  fi
}

for rep in 1 2 3; do cell "calib-seqw-bs4m-jobs16-rep$rep"  "na-write-cell"                    --rw=write    --bs=4M --runtime=300; done
for rep in 1 2 3; do cell "calib-seqr-bs4m-jobs16-rep$rep"  "na-calibration-server-resident"   --rw=read     --bs=4M --runtime=480; done
for rep in 1 2 3; do cell "calib-randw-bs4k-jobs16-rep$rep" "na-write-cell"                    --rw=randwrite --bs=4K --runtime=180; done
for rep in 1 2 3; do cell "calib-randr-bs4k-jobs16-rep$rep" "na-calibration-server-resident"   --rw=randread  --bs=4K --runtime=180; done

if (( FAILED > 0 )); then
  log "FATAL: $FAILED calibration cell(s) failed — refusing to write bands from a partial set"
  exit 1
fi
log "computing bands from ${#RUN_DIRS[@]} cells"
python3 "$HELPER" calibrate "${RUN_DIRS[@]}" 2>&1 | tee -a "$SWEEP_LOG"
exit "${PIPESTATUS[0]}"
