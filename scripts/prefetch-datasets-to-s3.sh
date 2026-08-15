#!/usr/bin/env bash
# prefetch-datasets-to-s3.sh — populate s3://$S3_BUCKET/datasets/ from public sources.
#
# WHAT THIS IS AND IS NOT
#   This fills the DURABLE store (S3) from GDC and the CAMELYON open-data bucket.
#   It is NOT hydration: S3 -> $FS_MOUNT is measured cell 1.7 and runs through
#   record-run.sh. This script never touches the filesystem under test.
#
# USAGE (normally launched in the background by bootstrap-instance.sh):
#   ./scripts/prefetch-datasets-to-s3.sh pilot     # small subsets (~a few slides)
#   ./scripts/prefetch-datasets-to-s3.sh full      # full manifests — hundreds of GB
#
# Idempotent: objects already in S3 (matching size) are skipped, so re-running
# after an interruption resumes rather than restarts.
set -uo pipefail

MODE="${1:-pilot}"
CONF=/etc/wsi-bootstrap.conf
[ -f "$CONF" ] && . "$CONF"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET unset — source /etc/wsi-bootstrap.conf or export it}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="$REPO/scripts/manifests"
STAGE="${PREFETCH_STAGE_DIR:-/data/local-nvme/prefetch-stage}"
PAR="${PREFETCH_PARALLEL:-4}"

case "$MODE" in
  none)  echo "prefetch: mode=none — nothing to do"; exit 0 ;;
  pilot) TCGA_MANIFEST="$MANIFESTS/tcga-brca-pilot.tsv"
         CAM_MANIFEST="$MANIFESTS/camelyon16-stage4a-subset.tsv" ;;
  full)  TCGA_MANIFEST="$MANIFESTS/tcga-brca-full.tsv"
         CAM_MANIFEST="$MANIFESTS/camelyon16-full.tsv" ;;
  *) echo "prefetch: unknown mode '$MODE' (none|pilot|full)" >&2; exit 1 ;;
esac

# The fast-exit is scoped to the DATASET sections: the model mirror further down
# is cheap when already synced and must still run on every fresh instance.
SKIP_DATASETS=0
if [ "${FORCE:-0}" != "1" ] && aws s3api head-object --bucket "$S3_BUCKET" --key "datasets/.prefetch-complete-$MODE" >/dev/null 2>&1; then
  echo "prefetch: $MODE datasets already complete (marker in S3) — skipping dataset sections (FORCE=1 to re-scan)"
  SKIP_DATASETS=1
fi

s3_has() { # s3_has KEY SIZE -> 0 if object exists with the same size
  local sz
  sz=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$1" --query ContentLength --output text 2>/dev/null) || return 1
  [ "$sz" = "$2" ]
}

if [ "$SKIP_DATASETS" -eq 0 ]; then   # ---- dataset sections (skipped when marker present)
# Staging dir is only needed by the dataset sections; the model half syncs
# straight between S3 and $HOME and must work on a scratch-less box.
mkdir -p "$STAGE" || { echo "prefetch: cannot create staging dir $STAGE (scratch not mounted?) — dataset sections cannot run" >&2; exit 1; }
# ---- TCGA via the GDC data API (open-access diagnostic slides; no token) --------
fetch_tcga_one() { # id filename md5 size
  local id="$1" fn="$2" md5="$3" size="$4" key local_f
  key="datasets/tcga-brca/$fn"; local_f="$STAGE/$fn"
  if s3_has "$key" "$size"; then echo "skip  $fn (already in S3)"; return 0; fi
  echo "fetch $fn ($size bytes)"
  curl -fsSL --retry 5 --retry-delay 10 -o "$local_f" "https://api.gdc.cancer.gov/data/$id" || { echo "FAIL  $fn (download)"; rm -f "$local_f"; return 1; }
  local got; got=$(md5sum "$local_f" | awk '{print $1}')
  if [ "$got" != "$md5" ]; then echo "FAIL  $fn (md5 $got != $md5)"; rm -f "$local_f"; return 1; fi
  aws s3 cp --only-show-errors "$local_f" "s3://$S3_BUCKET/$key" || { echo "FAIL  $fn (s3 cp)"; rm -f "$local_f"; return 1; }
  rm -f "$local_f"; echo "done  $fn"
}
export -f fetch_tcga_one s3_has
export S3_BUCKET STAGE

if [ -f "$TCGA_MANIFEST" ]; then
  echo "== TCGA: $TCGA_MANIFEST -> s3://$S3_BUCKET/datasets/tcga-brca/ =="
  tail -n +2 "$TCGA_MANIFEST" | awk -F'\t' '{print $1"\t"$2"\t"$3"\t"$4}' \
    | xargs -P "$PAR" -n 1 -d '\n' bash -c 'IFS=$'"'"'\t'"'"' read -r i f m s <<< "$0"; fetch_tcga_one "$i" "$f" "$m" "$s"'
else
  echo "prefetch: TCGA manifest not found: $TCGA_MANIFEST (skipping)"
fi

# ---- CAMELYON16 from the AWS Open Data bucket (streams through the instance) ----
fetch_cam_one() { # key size
  local key="$1" size="$2" dest
  dest="datasets/camelyon16/${key#CAMELYON16/}"
  if s3_has "$dest" "$size"; then echo "skip  $key"; return 0; fi
  echo "copy  $key"
  aws s3 cp --only-show-errors "s3://camelyon-dataset/$key" "s3://$S3_BUCKET/$dest" || echo "FAIL  $key"
}
export -f fetch_cam_one

if [ -f "$CAM_MANIFEST" ]; then
  echo "== CAMELYON16: $CAM_MANIFEST -> s3://$S3_BUCKET/datasets/camelyon16/ =="
  tail -n +2 "$CAM_MANIFEST" | awk -F'\t' '$2 != 0 && $1 !~ /\/$/ {print $1"\t"$2}' \
    | xargs -P "$PAR" -n 1 -d '\n' bash -c 'IFS=$'"'"'\t'"'"' read -r k s <<< "$0"; fetch_cam_one "$k" "$s"'
else
  echo "prefetch: CAMELYON manifest not found: $CAM_MANIFEST (skipping)"
fi

date -u > "$STAGE/.last-prefetch-$MODE"
aws s3 cp --only-show-errors "$STAGE/.last-prefetch-$MODE" "s3://$S3_BUCKET/datasets/.prefetch-complete-$MODE" || true
fi   # ---- end dataset sections

# ---- Foundation models (stage 6/7) — timm loads by hub id, so the artifact is
# ---- the HF hub CACHE; S3 mirrors it so rebuilds never re-hit huggingface.co.
HF_MODELS=("paige-ai/Virchow2" "MahmoodLab/UNI2-h" "prov-gigapath/prov-gigapath")
HUB_CACHE="$HOME/.cache/huggingface/hub"
mkdir -p "$HUB_CACHE"
aws s3 sync --only-show-errors "s3://$S3_BUCKET/models/hub-cache/" "$HUB_CACHE/" || true
HF_BIN="$HOME/.local/bin/hf"
if [ -x "$HF_BIN" ]; then
  for m in "${HF_MODELS[@]}"; do
    "$HF_BIN" download "$m" >/dev/null 2>&1 && echo "model ok    $m" \
      || echo "model FAIL  $m (gated repo without a valid HF token?)"
  done
  # --no-follow-symlinks: the hub cache stores each model once in blobs/ with
  # snapshots/ symlinking into it; following the links uploads every model twice.
  # Restores stay whole: sync-down brings blobs/ + refs/, and `hf download` above
  # rebuilds the snapshot links from existing blobs without re-downloading.
  aws s3 sync --only-show-errors --no-follow-symlinks "$HUB_CACHE/" "s3://$S3_BUCKET/models/hub-cache/" || true
else
  echo "prefetch: hf CLI missing — model prefetch skipped"
fi

echo "prefetch: $MODE pass complete"
