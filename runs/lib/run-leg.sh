#!/usr/bin/env bash
# run-leg.sh — drive one whole leg unattended, in dependency order (deferred item D-14).
#
# WHY THIS EXISTS
#   A leg is many hours of sweeps that must run in a specific order because each stage
#   produces inputs the next consumes. Driving that by hand across an overnight run
#   means a missed step or a silently-continued failure. This encodes the order, the
#   guards, and the resume behaviour once.
#
# WHAT IT DOES NOT DO
#   It does not run individual cells — each sweep driver does that via record-run.sh,
#   which owns per-cell recording and failure isolation. This orchestrates SWEEPS.
#
# THE FOUR GUARDS (without these, an unattended run is not trustworthy)
#   1. Abort the chain on any step failure. A 3am failure that gets skipped produces
#      hours of downstream cells built on missing inputs.
#   2. Checkpoint + resume: a completed step is skipped on re-run, so a crash re-does
#      only what is missing.
#   3. Sync to S3 after every step — both mounts and local scratch are ephemeral.
#   4. Tee everything. On an overnight run the log is the only forensic record.
#
# USAGE
#   run-leg.sh --leg weka                 # run the whole leg
#   run-leg.sh --leg weka --dry-run       # print the plan, run nothing
#   run-leg.sh --leg weka --from 3.0      # resume at a step (skips earlier ones)
#   run-leg.sh --leg weka --only 4.C      # run exactly one step
#   run-leg.sh --leg weka --list          # show steps + completion state
#
# PREREQUISITES (it refuses to start without them)
#   - cloud-setup/env.sh sourced (FS_MOUNT, LEG, S3_BUCKET, ...)
#   - Phase 0 done: provisioning verified, baseline captured and green-lit
#   - The deferred per-filesystem recording adapters in place (D-4/D-5), or the
#     canary cannot evaluate and the numbers are unverifiable.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO/runs/lib"
STATE="$REPO/runs/.leg-state"
LOGDIR="$REPO/runs/sweep-logs"

LEG_ARG=""; DRY=0; FROM=""; ONLY=""; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --leg)     LEG_ARG="${2:-}"; shift 2 ;;
    --from)    FROM="${2:-}";    shift 2 ;;
    --only)    ONLY="${2:-}";    shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --list)    LIST=1; shift ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "run-leg.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "run-leg.sh: $*" >&2; exit 1; }
log() { echo "[$(date -u +%FT%TZ)] run-leg: $*"; }

# ── The plan: dependency order from runs/STAGES.md. Sweep drivers are self-contained
#    (they take no arguments and run their full grid), so a step is just a command.
#    Format: "<step-id>|<description>|<command>"
#    A command of NOT_YET_BUILT is reported and aborts, rather than being skipped —
#    a silently-skipped step is how you get a leg with a hole in it.
STEPS=(
  "1.0a|Synthetic ceiling: sequential write|$LIB/sweep-stage1-seqw.sh"
  "1.0b|Synthetic ceiling: sequential read|$LIB/sweep-stage1-seqr.sh"
  "1.0c|Synthetic ceiling: random write IOPS|$LIB/sweep-stage1-randw.sh"
  "1.0d|Synthetic ceiling: random read IOPS|$LIB/sweep-stage1-randr.sh"
  "1.7|S3 -> filesystem hydration (head-to-head ingest)|NOT_YET_BUILT:D-13 sweep-stage1-hydrate.sh"
  "3.0|Tissue detection -- generates the 20x coords that gate 4/5/6/7|$LIB/sweep-stage3-tissue-detection.sh"
  "4.D|20x raw-TIFF conversion -- gates every kvikIO cell|$LIB/convert-stage4c-rawtiff.sh"
  "4.C|kvikIO/cuFile from raw-TIFF (both cuFile modes)|$LIB/sweep-stage4c-kvikio.sh"
  "4.B|On-the-fly tile reads (OpenSlide + cuCIM CPU)|$LIB/sweep-stage4b-tilesread.sh"
  "4.A|Pre-extract tiles to HDF5|$LIB/sweep-stage4a-patches.sh"
  "5|ResNet-50 DDP scaling, both backends|$LIB/sweep-stage5-training.sh"
  "6.A|Foundation-model extraction, Tier 1|$LIB/sweep-stage6a-extract.sh"
  "6.A.2|Foundation-model extraction, Tier 2 (full cohort, chunked)|$LIB/run-stage6a-tier2-chunked-multimodel.sh"
  "6.B.3|Attention-MIL on real features|$LIB/sweep-stage6b-mil.sh"
  "6.B.1|Synthetic feature corpus generation|NOT_YET_BUILT:needs corpus size decided (open item 5b)"
  "6.B.2|Small-file / metadata stress sweep|$LIB/sweep-stage6b-stress.sh"
  "6.C|Concurrent multi-workload + endurance|$LIB/sweep-stage6c.sh"
  "2.0|Cataloging / metadata sweep|$LIB/sweep-stage2-properties.sh"
  "7|Clinical inference deployment (7.1-7.6)|$LIB/sweep-stage7-clinical.sh"
  "1.5|Bulk local->filesystem copy|$LIB/sweep-stage1-fpsync.sh"
  "1.6|Mixed concurrent ingest + read|$LIB/sweep-stage1-mixed.sh"
)

step_id()   { echo "${1%%|*}"; }
step_desc() { local r="${1#*|}"; echo "${r%%|*}"; }
step_cmd()  { echo "${1##*|}"; }
done_marker() { echo "$STATE/$LEG/$1.done"; }

# ── --list needs no environment ──────────────────────────────────────────────────
if [ "$LIST" -eq 1 ]; then
  LEG="${LEG_ARG:-${LEG:-unknown}}"
  printf '%-8s %-8s %s\n' "STEP" "STATE" "DESCRIPTION"
  for s in "${STEPS[@]}"; do
    id=$(step_id "$s"); cmd=$(step_cmd "$s")
    if [ -f "$(done_marker "$id")" ]; then st="done"
    elif [[ "$cmd" == NOT_YET_BUILT:* ]]; then st="MISSING"
    else st="pending"; fi
    printf '%-8s %-8s %s\n' "$id" "$st" "$(step_desc "$s")"
  done
  exit 0
fi

# ── Preconditions ────────────────────────────────────────────────────────────────
[ -n "$LEG_ARG" ] || die "--leg is required (weka|lustre)"
case "$LEG_ARG" in weka|lustre) ;; *) die "--leg must be weka|lustre, got '$LEG_ARG'" ;; esac
LEG="$LEG_ARG"; export LEG

[ -n "${FS_MOUNT:-}" ] || die "FS_MOUNT is unset -- source cloud-setup/env.sh"
case "$FS_MOUNT" in
  *"$LEG"*) ;;
  *) die "FATAL: --leg='$LEG' disagrees with FS_MOUNT='$FS_MOUNT'. Refusing to run a
       whole leg whose label may not match the filesystem being measured." ;;
esac
[ -d "$FS_MOUNT" ] || die "FS_MOUNT='$FS_MOUNT' is not a mounted directory"
[ -n "${S3_BUCKET:-}" ] || die "S3_BUCKET is unset -- telemetry would not survive teardown"

mkdir -p "$STATE/$LEG" "$LOGDIR"
MASTER_LOG="$LOGDIR/$(date -u +%F-%H%M)-${LEG}-leg.log"

log "leg=$LEG  FS_MOUNT=$FS_MOUNT  bucket=$S3_BUCKET"
log "master log: $MASTER_LOG"
[ "$DRY" -eq 1 ] && log "DRY RUN — nothing will execute"

started=0; skipped=0; ran=0
for s in "${STEPS[@]}"; do
  id=$(step_id "$s"); desc=$(step_desc "$s"); cmd=$(step_cmd "$s")

  [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  if [ -n "$FROM" ] && [ "$started" -eq 0 ]; then
    if [ "$FROM" = "$id" ]; then started=1; else continue; fi
  fi

  if [ -f "$(done_marker "$id")" ]; then
    log "SKIP  $id  (already complete — remove $(done_marker "$id") to force)"
    skipped=$((skipped+1)); continue
  fi

  if [[ "$cmd" == NOT_YET_BUILT:* ]]; then
    log "ABORT $id  NOT BUILT: ${cmd#NOT_YET_BUILT:}"
    echo "run-leg.sh: step $id has no driver yet. Build it or pass --only/--from to" >&2
    echo "            work around it DELIBERATELY. Refusing to skip silently: a leg" >&2
    echo "            with a hole in it looks complete in INDEX.md." >&2
    exit 1
  fi

  [ -x "$cmd" ] || die "step $id: driver not executable: $cmd"

  if [ "$DRY" -eq 1 ]; then log "WOULD RUN $id  $desc  ->  $cmd"; continue; fi

  log "START $id  $desc"
  step_log="$LOGDIR/$(date -u +%F-%H%M)-${LEG}-s${id}.log"
  if ! "$cmd" 2>&1 | tee -a "$step_log" "$MASTER_LOG"; then
    log "FAILED $id — aborting the chain (see $step_log)"
    echo "run-leg.sh: step $id failed. NOT continuing: later steps consume this one's" >&2
    echo "            outputs, so proceeding would build cells on missing inputs." >&2
    exit 1
  fi
  log "OK    $id"
  ran=$((ran+1))

  # Guard 3: get this step's telemetry off the ephemeral disk immediately.
  if ! "$LIB/sync-to-s3.sh" --mode full 2>&1 | tee -a "$MASTER_LOG"; then
    log "FAILED S3 sync after $id — aborting"
    echo "run-leg.sh: telemetry sync failed. Continuing would risk losing hours of" >&2
    echo "            recording to a teardown. Fix the sync, then resume with --from." >&2
    exit 1
  fi
  touch "$(done_marker "$id")"
done

log "leg $LEG: $ran step(s) run, $skipped skipped"
[ "$DRY" -eq 1 ] && exit 0
log "Remaining: fill numbers into the roadmaps, write the environment contract"
log "  ($LIB/env-contract.py write --leg $LEG), then hand to the human for the commit."
