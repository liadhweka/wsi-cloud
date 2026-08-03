#!/usr/bin/env bash
# sync-to-s3.sh — push everything that must survive an instance teardown to S3.
#
# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ ⚠ UNVERIFIED AGAINST A REAL BUCKET.                                          │
# │ Written before the cloud environment existed. The LOGIC and the two sync      │
# │ semantics are deliberate and reviewed; the behaviour against real S3 has not  │
# │ been exercised. Run the FIRST-RUN PROCEDURE at the bottom of this header      │
# │ before trusting it, and remove this banner once it passes.                    │
# └──────────────────────────────────────────────────────────────────────────────┘
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
#   ARCHIVE (no --delete)   raw telemetry + datasets.
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
#
# FIRST-RUN PROCEDURE (do this once, in the cloud, before trusting it)
#   1. export S3_BUCKET=<bucket>; export LEG=weka
#   2. ./sync-to-s3.sh --mode full --dry-run       # read the plan; confirm the
#                                                  # semantics column looks right
#   3. ./sync-to-s3.sh --mode full                 # real run
#   4. Verify object counts non-zero and match expectations (the script prints them)
#   5. Create a throwaway file locally under a MIRROR path, sync, delete it locally,
#      sync again -> confirm it disappears from S3 (mirror semantics work).
#   6. Do the same under an ARCHIVE path -> confirm it does NOT disappear
#      (archive semantics work). THIS STEP IS THE ONE THAT MATTERS.
#   7. Remove the UNVERIFIED banner above and note the verification in
#      runs/INDEX.md or a Stage-0 run note.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
    do_sync mirror "$REPO_ROOT/runs/manifests/"       "s3://$S3_BUCKET/repo/manifests/"

    # ---- Environment contracts ----
    # These are what let Leg B prove it matched Leg A, so several consumers expect
    # them in S3: teardown-preflight.sh NO-GOes without them, and Leg B fetches
    # Leg A's contract from s3://<bucket>/env-contracts/ (NEW-CLOUD-SETUP.md § 8.7).
    # ARCHIVE, not MIRROR, deliberately: a --delete sync run from a checkout that
    # happens not to hold the other leg's contract would remove the one artifact
    # whose loss makes the whole comparison unverifiable. Tiny files; never prune.
    do_sync archive "$REPO_ROOT/runs/" "s3://$S3_BUCKET/env-contracts/" \
      --exclude '*' --include 'env-contract-leg-*.json'

    # ---- ARCHIVE group: heavy, write-once, may be pruned locally ----
    # Every run dir's raw/ for this leg. Requires LEG so two legs never collide.
    if [ -n "${LEG:-}" ]; then
      shopt -s nullglob
      for d in "$REPO_ROOT"/runs/*-"$LEG"-s*/; do
        [ -d "$d/raw" ] || continue
        do_sync archive "$d/raw/" "s3://$S3_BUCKET/runs/$LEG/$(basename "$d")/raw/"
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
    ;;

  datasets)
    [ -n "$SRC" ] || die "--mode datasets requires --src"
    do_sync archive "$SRC" "s3://$S3_BUCKET/datasets/$(basename "${SRC%/}")/"
    ;;

  *) die "unknown --mode '$MODE' (expected: full | run | datasets)" ;;
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
