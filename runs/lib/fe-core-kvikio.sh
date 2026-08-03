#!/usr/bin/env bash
# fe-core-kvikio.sh <label>
# Frontend-core scaling — the ACTUAL pipeline path: kvikIO+GDS N=8 random raw-TIFF
# tile reads across all 8 GPUs (the Stage 4.C peak config that hit 5.48 GB/s),
# fully recorded. Run once per frontend-core count, alongside fe-core-fio.sh.
#
#   ./fe-core-kvikio.sh fe8     # baseline at current cores
#   <colleague adds cores; client restarts>
#   ./fe-core-kvikio.sh fe12 ...
set -uo pipefail
LABEL="${1:?usage: $0 <label, e.g. fe8 = current frontend-core count>}"

REPO=/home/liadhermelin/wsi/rerun_new_TRUERESULTS
RECORD="$REPO/runs/lib/record-run.sh"
MULTI="$REPO/runs/lib/run-multiproc-kvikio.sh"
STAGE="4.C"
RUN_NAME="frontend-core-${LABEL}-kvikio-n8-gds"
GPUS="0,1,2,3,4,5,6,7"; NB=256; NT=16; COMPAT=off
export DATASET="${DATASET:-brca}"

TS=$(date -u +%Y-%m-%d-%H%M%S)
export RECORD_RUN_DIR="$REPO/runs/${TS}-s${STAGE}-${RUN_NAME}"
mkdir -p "$RECORD_RUN_DIR"

NOTE="Frontend-core scaling — PIPELINE path. kvikIO+GDS N=8 (all 8 GPUs) random raw-TIFF tile reads, compat=${COMPAT} (GDS engaged), n_buffer=${NB}, num_threads=${NT}, DATASET=${DATASET}. This is the Stage 4.C peak config (5.48 GB/s reference). LABEL=${LABEL} = current wekafs client FRONTEND core count (confirm live: sudo weka local resources). PRIMARY = aggregate app tiles/sec + GB/s (proc summaries) cross-checked with WEKA-side Read (weka stats) + RDMA rcv."

"$RECORD" --stage "$STAGE" --run-name "$RUN_NAME" --note "$NOTE" -- \
  "$MULTI" 8 "$GPUS" "$COMPAT" "$NB" "$NT" "$RECORD_RUN_DIR"

echo "  Run dir: $RECORD_RUN_DIR"
echo "  (aggregate GB/s printed above by run-multiproc; WEKA-side read: $RECORD_RUN_DIR/raw/weka-stats.csv)"
