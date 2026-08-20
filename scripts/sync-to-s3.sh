#!/usr/bin/env bash
# sync-to-s3.sh — push everything that must survive an instance teardown to S3.
#
# Verified against the real bucket 2026-08-15: multiple real --mode full runs
# with object counts confirmed, and --self-test PASSED (mirror probe deleted on
# local delete; archive probe survived). Re-run --self-test before every
# teardown — it is cheap, and the archive assertion is the one that protects
# pruned telemetry's only remaining copy.
#
# WHY THIS EXISTS
#   Instance-local NVMe and BOTH filesystem mounts are ephemeral: they die with the
#   instance and the cluster, and the instance is deliberately rebuilt between the
#   WEKA and Lustre legs. Without this, a teardown destroys every run's raw time
#   series — which the project's recording rules forbid.
#
# AUTHORITY SPLIT (CLAUDE.md -> Recording -> Durability & backup)
#   git : authoritative for all SMALL TEXT — docs, results.json, metadata.json,
#         0_README.md, notes.md, cmd.txt, pre/, post/, configs, the memory mirror.
#   S3  : authoritative for the HEAVY WRITE-ONCE data git cannot hold — raw
#         telemetry and the datasets.
#   They do not overlap, which is why S3 versioning is unnecessary.
#
# TWO SYNC SEMANTICS — deliberately different. This is the whole point of the script.
#
#   MIRROR  (--delete)      docs + the memory mirror.
#                           Local is genuinely the source of truth and git backs it
#                           independently, so an exact reflection is safe and is what
#                           we want (a deleted doc should disappear from S3 too).
#
#   ARCHIVE (no --delete)   raw telemetry, run-root heavies (cmd.log, workload-*.csv)
#                           + datasets.
#                           New and changed files go up; NOTHING is ever removed from
#                           S3 by this script. We WILL want to reclaim local disk by
#                           cleaning old telemetry, and a --delete sync would then
#                           destroy the only remaining copy. Removing something from
#                           S3 is a deliberate manual act, never a side effect.
#
#   Why NOT --no-overwrite for the archive group, even though it sounds safer:
#   telemetry CSVs GROW while a run is in flight, and during-run syncs must be able
#   to update them. --no-overwrite only transfers files absent at the destination, so
#   the first sync would upload a partial CSV and no later sync would ever fix it.
#   Default comparison (size differs OR source newer) is what handles growing files
#   correctly. Overwrite risk is acceptable here because telemetry is append-only and
#   git independently holds every small text artifact.
#
# CONFIG — all via environment, nothing hardcoded (the bucket does not exist yet):
#   S3_BUCKET   (required for any S3 work)  e.g. my-wsi-benchmark-bucket
#   LEG         (required for run syncs)    weka | lustre
#   AWS_REGION  (optional)                 passed through if set
#   Credentials come from the instance profile. Never put keys on disk.
#
# USAGE
#   sync-to-s3.sh --mode full                      # everything (called by backup.sh)
#   sync-to-s3.sh --mode run --run-dir <path>      # one run's raw telemetry
#   sync-to-s3.sh --mode datasets --src <path>     # dataset staging
#   sync-to-s3.sh --mode full --dry-run            # show what WOULD happen
#   sync-to-s3.sh --self-test                      # prove BOTH sync semantics against
#                                                  # the real bucket under _selftest/
#                                                  # (the mechanised first-run check;
#                                                  # run before every teardown)
#
# The self-test proves the one property everything else rests on: a file deleted
# locally DISAPPEARS from a MIRROR path and SURVIVES under an ARCHIVE path. It
# works entirely under s3://$S3_BUCKET/_selftest/ and PRINTS (never runs) the
# cleanup command for its leftovers — removing anything from S3 is a deliberate
# manual act, per the archive semantics it exists to prove.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in <repo>/scripts, so the repo root is ONE level up. It was
# ../.. when the library lived at runs/lib/; after the restructure that resolved
# to the repo's PARENT, and every source path below silently pointed outside the
# repo -- so `--mode full` had nothing to upload and still reported success.
# That is the worst possible shape for the project's only durability path.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Fail loudly rather than syncing from a tree that is not this repo.
[ -d "$REPO_ROOT/runs" ] && [ -d "$REPO_ROOT/scripts" ] || {
  echo "FATAL: REPO_ROOT='$REPO_ROOT' does not look like the repo (no runs/ + scripts/)." >&2
  echo "       Refusing to sync: a wrong root uploads nothing and reports success." >&2
  exit 1
}

MODE=""
RUN_DIR=""
SRC=""
DRY_RUN=0

die() { echo "sync-to-s3.sh: $*" >&2; exit 1; }
log() { echo "sync-to-s3.sh: $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="${2:-}"; shift 2 ;;
    --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
    --src)     SRC="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --self-test) MODE="self-test"; shift ;;
    -h|--help) sed -n '1,70p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[ -n "$MODE" ] || die "--mode is required (full | run | datasets)"
[ -n "${S3_BUCKET:-}" ] || die "S3_BUCKET is not set — refusing to guess a bucket name"
command -v aws >/dev/null 2>&1 || die "aws CLI not found on PATH"

# Fail EARLY and LOUD on credentials/bucket, so a sweep does not discover at 4am
# that hours of telemetry had nowhere to land.
if [ "$DRY_RUN" -eq 0 ]; then
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no working AWS credentials (expected an instance profile) — refusing to continue"
  aws s3 ls "s3://$S3_BUCKET/" >/dev/null 2>&1 \
    || die "cannot list s3://$S3_BUCKET/ — wrong bucket name, or the instance profile lacks s3:ListBucket"
fi

AWS_ARGS=()
[ -n "${AWS_REGION:-}" ] && AWS_ARGS+=(--region "$AWS_REGION")
[ "$DRY_RUN" -eq 1 ] && AWS_ARGS+=(--dryrun)

FAILED=0

# do_sync <semantics: mirror|archive> <local-src> <s3-dest> [extra aws args...]
do_sync() {
  local semantics="$1" src="$2" dest="$3"; shift 3
  if [ ! -e "$src" ]; then
    log "SKIP    [$semantics] $src (does not exist yet)"
    return 0
  fi
  local extra=()
  case "$semantics" in
    mirror)  extra=(--delete) ;;   # exact reflection; safe because git backs these
    archive) extra=() ;;           # NEVER --delete; see header
    *)       die "internal error: unknown semantics '$semantics'" ;;
  esac
  log "SYNC    [$semantics] $src -> $dest"
  if ! aws s3 sync "$src" "$dest" "${AWS_ARGS[@]}" "${extra[@]}" "$@"; then
    log "FAILED  [$semantics] $src -> $dest"
    FAILED=$((FAILED + 1))
  fi
}

case "$MODE" in
  full)
    # ---- MIRROR group: local is source of truth, git backs it independently ----
    do_sync mirror "$REPO_ROOT/claude-memory-mirror/" "s3://$S3_BUCKET/repo/claude-memory-mirror/"
    do_sync mirror "$REPO_ROOT/scripts/manifests/"       "s3://$S3_BUCKET/repo/manifests/"

    # ---- Environment contracts ----
    # These are what let Leg B prove it matched Leg A, so several consumers expect
    # them in S3: teardown-preflight.sh NO-GOes without them, and Leg B fetches
    # Leg A's contract from s3://<bucket>/env-contracts/ before provisioning
    # anything (docs/cloud-setup/LUSTRE-PROVISIONING.md, "Verify comparability
    # against Leg A first"; generic form in TEARDOWN-AND-REBUILD.md, Rebuild step 4).
    # ARCHIVE, not MIRROR, deliberately: a --delete sync run from a checkout that
    # happens not to hold the other leg's contract would remove the one artifact
    # whose loss makes the whole comparison unverifiable. Tiny files; never prune.
    # --no-follow-symlinks (ratified 2026-08-20): this op walks ALL of runs/ just to
    # match two filenames, and the other leg's git-committed raw -> local-NVMe
    # symlinks dangle on this box — following them poisons the exit code into a
    # false FAILED while both contracts upload fine. The filter never matched
    # symlinked content, so skipping links changes nothing about what uploads.
    do_sync archive "$REPO_ROOT/runs/" "s3://$S3_BUCKET/env-contracts/" \
      --exclude '*' --include 'env-contract-leg-*.json' --no-follow-symlinks

    # ---- ARCHIVE group: heavy, write-once, may be pruned locally ----
    # Every run dir's raw/ for this leg. Requires LEG so two legs never collide.
    if [ -n "${LEG:-}" ]; then
      shopt -s nullglob
      for d in "$REPO_ROOT"/runs/*-"$LEG"-s*/; do
        [ -d "$d/raw" ] || continue
        do_sync archive "$d/raw/" "s3://$S3_BUCKET/runs/$LEG/$(basename "$d")/raw/"
        # The run-root heavies that git deliberately excludes (.gitignore assigns
        # them to S3): the benchmark's tee'd stdout+stderr, and the workloads' own
        # per-interval/per-process CSVs — for Stage 7 those are PRIMARY latency
        # measurements, not derivable from raw/ telemetry.
        do_sync archive "$d" "s3://$S3_BUCKET/runs/$LEG/$(basename "$d")/" \
          --exclude '*' --include 'cmd.log' --include 'workload-*.csv'
      done
      shopt -u nullglob
      do_sync archive "$REPO_ROOT/runs/sweep-logs/" "s3://$S3_BUCKET/runs/$LEG/sweep-logs/"
    else
      log "SKIP    run telemetry (LEG not set — set LEG=weka or LEG=lustre)"
    fi
    ;;

  run)
    [ -n "$RUN_DIR" ]     || die "--mode run requires --run-dir"
    [ -n "${LEG:-}" ]     || die "--mode run requires LEG (weka|lustre)"
    [ -d "$RUN_DIR" ]     || die "run dir not found: $RUN_DIR"
    do_sync archive "$RUN_DIR/raw/" "s3://$S3_BUCKET/runs/$LEG/$(basename "${RUN_DIR%/}")/raw/"
    do_sync archive "$RUN_DIR" "s3://$S3_BUCKET/runs/$LEG/$(basename "${RUN_DIR%/}")/" \
      --exclude '*' --include 'cmd.log' --include 'workload-*.csv'
    ;;

  datasets)
    [ -n "$SRC" ] || die "--mode datasets requires --src"
    do_sync archive "$SRC" "s3://$S3_BUCKET/datasets/$(basename "${SRC%/}")/"
    ;;

  self-test)
    # Prove both semantics against the REAL bucket, entirely under _selftest/.
    # Named non-zero exits per failed assertion; leftovers cleaned only by the
    # printed (never executed) command.
    [ "$DRY_RUN" -eq 0 ] || die "--self-test is meaningless with --dry-run"
    ST_LOCAL=$(mktemp -d)
    ST_S3="s3://$S3_BUCKET/_selftest"
    STAMP=$(date -u +%Y%m%d-%H%M%S)
    mkdir -p "$ST_LOCAL/mirror" "$ST_LOCAL/archive"
    echo "selftest $STAMP" > "$ST_LOCAL/mirror/probe-$STAMP.txt"
    echo "selftest $STAMP" > "$ST_LOCAL/archive/probe-$STAMP.txt"

    log "SELFTEST phase 1: sync both probes up"
    do_sync mirror  "$ST_LOCAL/mirror/"  "$ST_S3/mirror/"
    do_sync archive "$ST_LOCAL/archive/" "$ST_S3/archive/"
    [ "$FAILED" -eq 0 ] || { rm -rf "$ST_LOCAL"; die "SELFTEST: initial sync failed (exit 20)"; }
    aws s3 ls "$ST_S3/mirror/probe-$STAMP.txt"  "${AWS_ARGS[@]}" >/dev/null \
      || { rm -rf "$ST_LOCAL"; echo "SELFTEST FAILED (exit 21): mirror probe never landed in S3" >&2; exit 21; }
    aws s3 ls "$ST_S3/archive/probe-$STAMP.txt" "${AWS_ARGS[@]}" >/dev/null \
      || { rm -rf "$ST_LOCAL"; echo "SELFTEST FAILED (exit 22): archive probe never landed in S3" >&2; exit 22; }
    log "SELFTEST phase 1 OK: both probes present in S3"

    log "SELFTEST phase 2: delete both probes locally, sync again"
    rm -f "$ST_LOCAL/mirror/probe-$STAMP.txt" "$ST_LOCAL/archive/probe-$STAMP.txt"
    do_sync mirror  "$ST_LOCAL/mirror/"  "$ST_S3/mirror/"
    do_sync archive "$ST_LOCAL/archive/" "$ST_S3/archive/"
    [ "$FAILED" -eq 0 ] || { rm -rf "$ST_LOCAL"; die "SELFTEST: second sync failed (exit 23)"; }

    if aws s3 ls "$ST_S3/mirror/probe-$STAMP.txt" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
      rm -rf "$ST_LOCAL"
      echo "SELFTEST FAILED (exit 24): MIRROR probe still in S3 after local delete — --delete semantics broken" >&2
      exit 24
    fi
    log "SELFTEST assertion OK: mirror probe disappeared with the local delete"
    if ! aws s3 ls "$ST_S3/archive/probe-$STAMP.txt" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
      rm -rf "$ST_LOCAL"
      echo "SELFTEST FAILED (exit 25): ARCHIVE probe VANISHED from S3 after a local delete —" >&2
      echo "  the archive path can destroy the only remaining copy of pruned telemetry. DO NOT" >&2
      echo "  prune anything locally, and do not tear down, until this is fixed." >&2
      exit 25
    fi
    log "SELFTEST assertion OK: archive probe SURVIVED the local delete — THE assertion that matters"

    rm -rf "$ST_LOCAL"
    log "SELFTEST PASSED — both sync semantics proven against s3://$S3_BUCKET"
    log "leftover to clean MANUALLY when convenient (never automated, by the very semantics just proven):"
    log "    aws s3 rm --recursive $ST_S3/"
    exit 0
    ;;

  *) die "unknown --mode '$MODE' (expected: full | run | datasets | self-test)" ;;
esac

# ---- Verify, do not assume (Rule 11: "backed up" is wrong if 3 files errored) ----
if [ "$FAILED" -gt 0 ]; then
  die "$FAILED sync operation(s) FAILED — treat this as NOT backed up and fix before teardown"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN complete — nothing was transferred. Review the plan above."
  exit 0
fi

OBJECTS=$(aws s3 ls "s3://$S3_BUCKET/" --recursive --summarize "${AWS_ARGS[@]}" 2>/dev/null \
          | awk '/Total Objects:/ {print $3}')
SIZE=$(aws s3 ls "s3://$S3_BUCKET/" --recursive --summarize "${AWS_ARGS[@]}" 2>/dev/null \
       | awk '/Total Size:/ {print $3}')
log "OK — bucket now holds ${OBJECTS:-?} objects, ${SIZE:-?} bytes"
[ "${OBJECTS:-0}" -gt 0 ] 2>/dev/null \
  || die "bucket reports zero objects after a successful sync — investigate before trusting this"
