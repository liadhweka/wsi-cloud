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
#   - env.sh sourced (FS_MOUNT, LEG, S3_BUCKET, ...)
#   - Phase 0 done: provisioning verified, baseline captured and green-lit
#   - The deferred per-filesystem recording adapters in place (D-4/D-5), or the
#     canary cannot evaluate and the numbers are unverifiable.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/scripts"
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

# ── The plan: dependency order from docs/STAGES.md.
#    Format: "<step-id>|<description>|<command> [args...]"
#
#    A command of NOT_YET_BUILT is reported and aborts, rather than being skipped —
#    a silently-skipped step is how you get a leg with a hole in it.
#
#    SEVEN of these drivers dispatch on $1 and exit 2 with a usage message when
#    invoked bare, so the target is part of the command and the runner word-splits
#    it. Which target, and why:
#      4.C   tier1  — Tier 2 is "adaptive from Tier 1 knees" and Tier 3 is
#                     conditional (Stage-4-Patching.md § 4.C), so neither can be
#                     pre-scheduled; run them by hand after reading Tier 1.
#      5     all    — both blocks are full sweeps over N ∈ {1,2,4}.
#      6.A   tier1  — Tier 3 gets its own step below; Tier 2 is step 6.A.2.
#      6.B.3 all    — the three num_workers cells against the model's features.
#      6.B.2 all    — b2a + b2b + b2c. Does NOT include `prep`; corpus generation
#                     is step 6.B.1, still blocked on the corpus-size decision.
#      6.C   all     · 7 all — every tier, ascending.
STEPS=(
  "1.0a|Synthetic ceiling: sequential write|$LIB/sweep-stage1-seqw.sh"
  "1.0b|Synthetic ceiling: sequential read|$LIB/sweep-stage1-seqr.sh"
  "1.0c|Synthetic ceiling: random write IOPS|$LIB/sweep-stage1-randw.sh"
  "1.0d|Synthetic ceiling: random read IOPS|$LIB/sweep-stage1-randr.sh"
  "1.7|S3 -> filesystem hydration (head-to-head ingest)|NOT_YET_BUILT:D-13 sweep-stage1-hydrate.sh"
  "3.0|Tissue detection -- generates the 20x coords that gate 4/5/6/7|$LIB/sweep-stage3-tissue-detection.sh"
  "4.D|20x raw-TIFF conversion -- gates every kvikIO cell|$LIB/convert-stage4c-rawtiff.sh"
  "4.C|kvikIO/cuFile from raw-TIFF, Tier 1 (both cuFile modes)|$LIB/sweep-stage4c-kvikio.sh tier1"
  "4.B|On-the-fly tile reads (OpenSlide + cuCIM CPU)|$LIB/sweep-stage4b-tilesread.sh"
  "4.A|Pre-extract tiles to HDF5|$LIB/sweep-stage4a-patches.sh"
  "5|ResNet-50 DDP scaling, both backends, N in {1,2,4}|$LIB/sweep-stage5-training.sh all"
  "6.A|Foundation-model extraction, Tier 1 (GPU-count scaling)|$LIB/sweep-stage6a-extract.sh tier1"
  "6.A.3|Foundation-model extraction, Tier 3 (CAMELYON16 cross-dataset)|$LIB/sweep-stage6a-extract.sh tier3"
  "6.A.2|Foundation-model extraction, Tier 2 (full cohort, chunked)|$LIB/run-stage6a-tier2-chunked-multimodel.sh"
  "6.B.3|Attention-MIL on real features|$LIB/sweep-stage6b-mil.sh all"
  "6.B.1|Synthetic feature corpus generation|NOT_YET_BUILT:needs corpus size decided (open item 5b)"
  "6.B.2|Small-file / metadata stress sweep|$LIB/sweep-stage6b-stress.sh all"
  "6.C|Concurrent multi-workload + endurance|$LIB/sweep-stage6c.sh all"
  "2.0|Cataloging / metadata sweep|$LIB/sweep-stage2-properties.sh"
  "7|Clinical inference deployment (7.1-7.6)|$LIB/sweep-stage7-clinical.sh all"
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

[ -n "${FS_MOUNT:-}" ] || die "FS_MOUNT is unset -- source env.sh"
case "$FS_MOUNT" in
  *"$LEG"*) ;;
  *) die "FATAL: --leg='$LEG' disagrees with FS_MOUNT='$FS_MOUNT'. Refusing to run a
       whole leg whose label may not match the filesystem being measured." ;;
esac
[ -d "$FS_MOUNT" ] || die "FS_MOUNT='$FS_MOUNT' is not a mounted directory"
[ -n "${S3_BUCKET:-}" ] || die "S3_BUCKET is unset -- telemetry would not survive teardown"

# ── D16: each leg runs on its intended transport, or it does not run ──────────────
# WEKA on DPDK, Lustre on EFA. Both stacks have a fallback (UDP / TCP) that mounts
# cleanly, serves data, and reports plausible numbers for a transport this project
# decided not to measure. Every prompt already says STOP AND REPORT IMMEDIATELY, but
# an instruction is not a mechanism: this is the unattended entry point, so it refuses
# here rather than trusting that the instruction was followed hours earlier.
#
# FS_TRANSPORT is written into env.sh by the per-leg cluster-setup prompt FROM EVIDENCE
# (the client's own report), never from the mount options that were passed.
case "$LEG" in weka) WANT_TRANSPORT=dpdk ;; lustre) WANT_TRANSPORT=efa ;; esac
WAIVER="$STATE/$LEG/transport-waiver"
if [ -z "${FS_TRANSPORT:-}" ]; then
  die "FS_TRANSPORT is unset. D16 requires the transport to be EVIDENCED before a leg runs,
       and an unrecorded transport cannot be shown to be '$WANT_TRANSPORT'. The
       cluster-setup prompt for this leg records it; re-run that verification."
elif [ "$FS_TRANSPORT" != "$WANT_TRANSPORT" ]; then
  if [ -f "$WAIVER" ]; then
    log "WARNING: transport is '$FS_TRANSPORT', not '$WANT_TRANSPORT' -- proceeding on the"
    log "         written waiver at $WAIVER:"
    # Plain stdout on purpose: $MASTER_LOG is not defined until after the preconditions,
    # and this output is captured by the session log either way.
    sed 's/^/         | /' "$WAIVER"
    log "         Every cell in this leg carries that caveat. It is NOT a comparable leg."
  else
    die "FATAL: leg '$LEG' is on transport '$FS_TRANSPORT', but D16 requires '$WANT_TRANSPORT'.
       Refusing to run. A fallback transport (UDP / TCP) produces a COMPLETE and PLAUSIBLE
       set of numbers for a configuration this project explicitly decided not to measure,
       so running now and flagging it later spends the wallclock and the money first.
       Fix the transport, or -- if measuring the fallback is a deliberate human decision --
       record the reason in:  $WAIVER"
  fi
fi

# --from / --only must name a real step. Without this check a typo (a missing dot,
# the wrong case) silently matches nothing: every step is skipped and the script
# exits 0 reporting "0 step(s) run" — which reads as success on an overnight run.
_step_ids() { for s in "${STEPS[@]}"; do step_id "$s"; done; }
for _v in FROM ONLY; do
  _val="${!_v}"
  [ -n "$_val" ] || continue
  if ! _step_ids | grep -qxF "$_val"; then
    echo "run-leg.sh: --${_v,,}='$_val' matches no step. Valid step ids:" >&2
    _step_ids | tr '\n' ' ' >&2; echo >&2
    exit 2
  fi
done

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

  # The command may carry a target (e.g. "…/sweep-stage5-training.sh all"), so split
  # it into an argv array. Quoting the whole string would look for a file named
  # "<script> all"; leaving it unquoted would also glob.
  read -r -a argv <<< "$cmd"
  [ -x "${argv[0]}" ] || die "step $id: driver not executable: ${argv[0]}"

  if [ "$DRY" -eq 1 ]; then log "WOULD RUN $id  $desc  ->  $cmd"; continue; fi

  log "START $id  $desc"
  step_log="$LOGDIR/$(date -u +%F-%H%M)-${LEG}-s${id}.log"
  if ! "${argv[@]}" 2>&1 | tee -a "$step_log" "$MASTER_LOG"; then
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
