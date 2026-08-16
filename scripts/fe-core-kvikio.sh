#!/usr/bin/env bash
# fe-core-kvikio.sh <label>
# ONE fully-recorded kvikIO/cuFile cell on the pipeline path: random raw-TIFF tile
# reads across the instance's GPUs. A single-cell spot check, not a sweep — for a
# quick recorded reference point, and for varying one client-side knob while
# holding the cell identical.
#
#   ./fe-core-kvikio.sh <label>          # <label> names the client config under test
#
# The label is free text and goes into the run name, so successive runs form a
# curve over whatever you varied. NOTE: varying the *storage client's* reserved
# core count is a WEKA-leg-only axis — the Lustre client reserves none (D15). Do
# not read a cross-leg comparison out of a label sequence.
#
# ⚠ Not the Phase-0 ceiling capture. "% of ceiling" denominators must come from the
# block-size-matched Stage 1.0a-d cells (sweep-stage1-{seqw,seqr,randw,randr}.sh);
# this helper runs one fixed configuration.
# ⏳ D-6: cuFile GPU-direct-vs-bounced byte accounting is mandatory per kvikIO cell
# and is not recorded yet, so a cell from here is incomplete until that lands.
set -uo pipefail
LABEL="${1:?usage: $0 <label, e.g. fe8 = current frontend-core count>}"

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
RECORD="$REPO/scripts/record-run.sh"
MULTI="$REPO/scripts/run-multiproc-kvikio.sh"
STAGE="4.C"
# ⏳ D-8: 4 GPUs to match the instance (STAGES.md D10); the NUMA/NIC-aware ordering
# is still to be re-derived on the real instance.
NGPU=4; GPUS="0,1,2,3"
NB=256; NT=16
# compat=off REQUESTS the GPU-direct path; it does not prove one was taken. Whether
# true GDS is achievable here is an empirical, per-filesystem question (D8).
COMPAT=off
RUN_NAME="clientcfg-${LABEL}-kvikio-n${NGPU}-compat${COMPAT}"
export DATASET="${DATASET:-brca}"

TS=$(date -u +%Y-%m-%d-%H%M%S)
export RECORD_RUN_DIR="$REPO/runs/${TS}-${LEG}-s${STAGE}-${RUN_NAME}"
mkdir -p "$RECORD_RUN_DIR"

NOTE="Single-cell kvikIO/cuFile spot check on fs=${LEG}, PIPELINE path: random raw-TIFF tile reads, N=${NGPU} processes on GPUs ${GPUS}, compat_mode=${COMPAT} (REQUESTED, not proven — path accounting per D-6 settles which path ran), n_buffer=${NB}, num_threads=${NT}, DATASET=${DATASET}. LABEL=${LABEL} = the client configuration being varied across successive runs; record what it means in this note when you use it. PRIMARY = aggregate app tiles/sec + GB/s from the per-process summaries, cross-checked against this leg's filesystem-side primary per docs/RUNBOOK.md's source table (which differs per leg — never quote a bypassed source). NOT a % -of-ceiling denominator: those come from the block-size-matched Stage 1.0 cells."

# RECORD_KVIKIO_CELL: record-run refuses to stamp a kvikIO cell OK without the
# recorded path_accounting split (D-30/D8). na-*: this helper is a diagnostic
# spot check that manages no cache regime — NOT_APPLICABLE to the reconciler.
RECORD_KVIKIO_CELL=1 \
RECORD_CACHE_STATE="na-diagnostic-spot-check" \
"$RECORD" --stage "$STAGE" --run-name "$RUN_NAME" --note "$NOTE" -- \
  "$MULTI" "$NGPU" "$GPUS" "$COMPAT" "$NB" "$NT" "$RECORD_RUN_DIR"

echo "  Run dir: $RECORD_RUN_DIR"
echo "  (aggregate GB/s printed above by run-multiproc; the filesystem-side primary for"
echo "   this leg is listed in docs/RUNBOOK.md § What gets recorded)"
