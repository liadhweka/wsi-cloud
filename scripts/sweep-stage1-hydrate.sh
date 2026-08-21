#!/usr/bin/env bash
# sweep-stage1-hydrate.sh — Stage 1.7: S3 -> filesystem hydration, the
# head-to-head ingest cell (D-13).
#
# Grid: max_concurrent_requests ∈ {4, 16, 64, 256} = 4 cells. Each cell is a
# FULL hydration of both dataset prefixes with the target wiped before it
# (same-region S3 transfer is free; the write workload IS the measurement).
# The FINAL cell's data is kept, byte-verified against the manifests, and only
# then is runs/.leg-state/$LEG/hydration-complete written — the marker the
# leg orchestrator and the bootstrap's re-hydration guard key on.
#
# Byte-verification basis (recorded in the verification report):
#   TCGA-BRCA   — per-file md5 against the manifest (full), plus count + size.
#   CAMELYON16  — count + per-file size against the manifest; its manifest
#                 carries multipart ETags, not md5s, and the S3->S3 staging
#                 copy was checksummed end-to-end by S3 itself.
#
# Identical tool, flags and grid on both legs — FSx's native S3 import is a
# different mechanism and is measured separately as 1.8 (Lustre leg only).
#
# Run with:
#   scripts/sweep-stage1-hydrate.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh}"
: "${S3_BUCKET:?S3_BUCKET is unset -- source env.sh}"
: "${AWS_REGION:?AWS_REGION is unset -- source env.sh}"
# D-7 watchdog: Leg A's slowest full hydration cell ran 5729 s (S3-bound);
# 4 h is generous headroom before "slow" becomes "hung".
export RECORD_TIMEOUT_S=${RECORD_TIMEOUT_S:-14400}

MANIFESTS="$REPO/scripts/manifests"
TCGA_MANIFEST="$MANIFESTS/tcga-brca-full.tsv"
CAM_MANIFEST="$MANIFESTS/camelyon16-full.tsv"
LOG_DIR=$REPO/runs/sweep-logs
STATE_DIR=$REPO/runs/.leg-state/$LEG
mkdir -p "$LOG_DIR" "$STATE_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-$LEG-stage1-hydrate.log"

CONCURRENCIES=(4 16 64 256)
DATA_ROOT="$FS_MOUNT/data"
TARGETS=(tcga-brca camelyon16)

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }
die() { log "FATAL: $*"; exit 1; }

# ---- preflight: refuse before spending hours, not after -----------------------
[ -f "$TCGA_MANIFEST" ] || die "manifest missing: $TCGA_MANIFEST"
[ -f "$CAM_MANIFEST" ]  || die "manifest missing: $CAM_MANIFEST"

# The S3 corpus must be COMPLETE (the full-mode prefetch marker, which the
# prefetch script refuses to write over any per-file failure). Hydrating from a
# partial corpus would fail the byte-verify only after every pass has run.
aws s3api head-object --bucket "$S3_BUCKET" --key "datasets/.prefetch-complete-full" >/dev/null 2>&1 \
  || die "s3://$S3_BUCKET/datasets/.prefetch-complete-full is absent — the full prefetch has not completed cleanly; refusing to hydrate from a possibly-partial corpus"

EXPECTED_TCGA_BYTES=$(awk -F'\t' 'NR>1{s+=$4}END{print s}' "$TCGA_MANIFEST")
EXPECTED_TCGA_COUNT=$(awk -F'\t' 'NR>1{n++}END{print n}' "$TCGA_MANIFEST")
EXPECTED_CAM_BYTES=$(awk -F'\t' 'NR>1 && $2!=0 && $1 !~ /\/$/{s+=$2}END{print s}' "$CAM_MANIFEST")
EXPECTED_CAM_COUNT=$(awk -F'\t' 'NR>1 && $2!=0 && $1 !~ /\/$/{n++}END{print n}' "$CAM_MANIFEST")
CORPUS_BYTES=$(( EXPECTED_TCGA_BYTES + EXPECTED_CAM_BYTES ))

AVAIL_BYTES=$(df --output=avail -B1 "$FS_MOUNT" | tail -1 | tr -d ' ')
(( AVAIL_BYTES > CORPUS_BYTES + (CORPUS_BYTES / 10) )) \
  || die "free space on $FS_MOUNT ($AVAIL_BYTES B) is below corpus size + 10% ($CORPUS_BYTES B)"

TOTAL=${#CONCURRENCIES[@]}
log "=== Stage 1.7 hydration sweep starting (leg=$LEG) ==="
log "  grid: max_concurrent_requests ∈ {${CONCURRENCIES[*]}} — $TOTAL full passes"
log "  corpus: TCGA $EXPECTED_TCGA_COUNT files / $EXPECTED_TCGA_BYTES B + CAM16 $EXPECTED_CAM_COUNT files / $EXPECTED_CAM_BYTES B"
log "  target: $DATA_ROOT/{${TARGETS[*]}} — wiped before each cell; the FINAL cell's data is kept"
log "  consolidated log: $SWEEP_LOG"

# Per-cell AWS config: max_concurrent_requests is a config-file setting, not a
# CLI flag. Credentials still come from the instance profile; the region is
# passed explicitly on every call because AWS_CONFIG_FILE replaces ~/.aws/config.
CELL_CFG_DIR=$(mktemp -d)
trap 'rm -rf "$CELL_CFG_DIR"' EXIT

i=0
for conc in "${CONCURRENCIES[@]}"; do
  i=$(( i + 1 ))
  name="hydrate-mcr${conc}"
  note="Stage 1.7 cell $i/$TOTAL: full S3->$LEG hydration of both dataset prefixes, aws s3 sync, max_concurrent_requests=$conc. Target wiped pre-cell; the final cell's data is kept and byte-verified. Write cell: cache axis n/a."

  log ""
  log "=== [cell $i/$TOTAL] $name ==="

  # Wipe BEFORE the cell (never after), so the last pass's corpus survives as
  # the leg's dataset. The wipe is outside the timed window deliberately.
  for t in "${TARGETS[@]}"; do
    if [ -d "$DATA_ROOT/$t" ]; then
      log "  wiping $DATA_ROOT/$t (pre-cell; outside the timed window)"
      rm -rf "$DATA_ROOT/$t"
    fi
    mkdir -p "$DATA_ROOT/$t"
  done

  cfg="$CELL_CFG_DIR/awscfg-$conc"
  printf '[default]\ns3 =\n    max_concurrent_requests = %s\n    max_queue_size = 10000\n' "$conc" > "$cfg"

  RECORD_CACHE_STATE="na-write-cell" \
  AWS_CONFIG_FILE="$cfg" \
  "$REPO/scripts/record-run.sh" \
    --run-name "$name" \
    --stage "1.7" \
    --note "$note" \
    -- bash -c "
      set -uo pipefail
      for t in ${TARGETS[*]}; do
        echo \"== aws s3 sync datasets/\$t (max_concurrent_requests=$conc) ==\"
        aws s3 sync --region '$AWS_REGION' --only-show-errors \
          \"s3://$S3_BUCKET/datasets/\$t/\" \"$DATA_ROOT/\$t/\" || exit 1
      done
    " 2>&1 | tee -a "$SWEEP_LOG"
done

# ---- byte-verification of the kept (final) corpus -----------------------------
# Fails loud on ANY mismatch and does NOT write the completion marker — a
# partial hydration caught here poisons every stage that reads the corpus.
log ""
log "=== byte-verifying the kept corpus against the manifests ==="
VERIFY_REPORT="$STATE_DIR/hydration-verification.txt"
FAILED=0
{
  echo "hydration verification — leg=$LEG, $(date -u +%FT%TZ)"
  echo "basis: TCGA per-file md5 + count + size; CAMELYON16 count + per-file size"
  echo "       (CAM16 manifest carries multipart ETags, not md5s; its S3->S3 staging copy was checksummed by S3)"
} > "$VERIFY_REPORT"

# TCGA: count, per-file size, per-file md5 (md5 parallelised; read-only pass).
tcga_local_count=$(find "$DATA_ROOT/tcga-brca" -type f | wc -l)
echo "tcga file count: local=$tcga_local_count manifest=$EXPECTED_TCGA_COUNT" >> "$VERIFY_REPORT"
[ "$tcga_local_count" = "$EXPECTED_TCGA_COUNT" ] || FAILED=1

log "  tcga: checking per-file size + md5 ($EXPECTED_TCGA_COUNT files — this reads the whole corpus once)"
tail -n +2 "$TCGA_MANIFEST" | awk -F'\t' '{print $2"\t"$3"\t"$4}' \
  | xargs -P 8 -n 1 -d '\n' bash -c '
      IFS=$'"'"'\t'"'"' read -r fn md5 size <<< "$0"
      f="'"$DATA_ROOT"'/tcga-brca/$fn"
      if [ ! -f "$f" ]; then echo "MISSING $fn"; exit 0; fi
      actual_size=$(stat -c %s "$f")
      [ "$actual_size" = "$size" ] || { echo "SIZE-MISMATCH $fn local=$actual_size manifest=$size"; exit 0; }
      actual_md5=$(md5sum "$f" | awk "{print \$1}")
      [ "$actual_md5" = "$md5" ] || echo "MD5-MISMATCH $fn local=$actual_md5 manifest=$md5"
    ' > "$STATE_DIR/.hydration-tcga-mismatches" 2>&1
if [ -s "$STATE_DIR/.hydration-tcga-mismatches" ]; then
  FAILED=1
  echo "tcga mismatches:" >> "$VERIFY_REPORT"
  cat "$STATE_DIR/.hydration-tcga-mismatches" >> "$VERIFY_REPORT"
else
  echo "tcga: all $EXPECTED_TCGA_COUNT files present, size + md5 verified" >> "$VERIFY_REPORT"
fi
rm -f "$STATE_DIR/.hydration-tcga-mismatches"

# CAMELYON16: count + per-file size (path = key with the CAMELYON16/ prefix stripped).
cam_local_count=$(find "$DATA_ROOT/camelyon16" -type f | wc -l)
echo "camelyon16 file count: local=$cam_local_count manifest=$EXPECTED_CAM_COUNT" >> "$VERIFY_REPORT"
[ "$cam_local_count" = "$EXPECTED_CAM_COUNT" ] || FAILED=1

tail -n +2 "$CAM_MANIFEST" | awk -F'\t' '$2 != 0 && $1 !~ /\/$/ {print $1"\t"$2}' \
  | while IFS=$'\t' read -r key size; do
      f="$DATA_ROOT/camelyon16/${key#CAMELYON16/}"
      if [ ! -f "$f" ]; then echo "MISSING $key"; continue; fi
      actual=$(stat -c %s "$f")
      [ "$actual" = "$size" ] || echo "SIZE-MISMATCH $key local=$actual manifest=$size"
    done > "$STATE_DIR/.hydration-cam-mismatches"
if [ -s "$STATE_DIR/.hydration-cam-mismatches" ]; then
  FAILED=1
  echo "camelyon16 mismatches:" >> "$VERIFY_REPORT"
  cat "$STATE_DIR/.hydration-cam-mismatches" >> "$VERIFY_REPORT"
else
  echo "camelyon16: all $EXPECTED_CAM_COUNT files present, sizes verified" >> "$VERIFY_REPORT"
fi
rm -f "$STATE_DIR/.hydration-cam-mismatches"

cat "$VERIFY_REPORT" | tee -a "$SWEEP_LOG"

if (( FAILED )); then
  log "FATAL: byte-verification FAILED — the completion marker was NOT written."
  log "       $VERIFY_REPORT holds the mismatch list. Fix and re-run; passes are cheap, a"
  log "       poisoned corpus is not."
  exit 1
fi

date -u +%FT%TZ > "$STATE_DIR/hydration-complete"
log ""
log "=== hydration sweep done — corpus byte-verified; marker written: $STATE_DIR/hydration-complete ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 2 ))"
