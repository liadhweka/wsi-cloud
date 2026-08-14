#!/usr/bin/env bash
# Stage 6.D end-to-end pipeline timing — full TCGA-BRCA.
#
# Sequentially runs the four phases of the modern WSI research pipeline:
#   Phase 1: Stage 3 — CLAM tissue detection (reuses scripts/sweep-stage3-tissue-detection.sh logic
#            at n=64; outputs tile coords to ${FS_MOUNT}/tissue-detection/3.0/.../patches/)
#   Phase 2: Stage 4 prep (optional, kvikio path only) — raw-TIFF conversion (chunked if needed)
#   Phase 3: Stage 6.A — foundation-model feature extraction
#   Phase 4: Stage 6.B.3 — attention-MIL classifier training (one epoch over full extracted features)
#
# Single-number wallclock per backend path. Per-phase breakdown via per-phase-summary.csv
# emitted by this orchestrator.
#
# Two cells:
#   --backend kvikio   : raw-TIFF + kvikIO+GDS path (Stage 4.C/6.A.kvikio winner; chunked
#                        conversion via run-stage6a-tier2-chunked.sh inside)
#   --backend cucim    : cuCIM CPU batched on canonical SVS (no raw-TIFF needed)
#
# Outer record-run.sh wraps the whole pipeline so we capture the filesystem-side
# time-series across all four phases (which source that is differs per leg).
#
# Usage:
#   ./pipeline-end-to-end-stage6d.sh --backend cucim --run-dir <run-dir>
#   ./pipeline-end-to-end-stage6d.sh --backend kvikio --run-dir <run-dir>
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
# The SYSTEM libcufile, matched to the installed kernel nvidia-fs module. Read from
# the environment (docs/NAMING-AND-VARIABLES.md Table 1) — never hardcoded:
# the conda env bundles an older copy, the right path is instance-specific, and a
# path pointing nowhere makes LD_PRELOAD a silent no-op, so the kvikIO cells would
# quietly run on the WRONG libcufile and still report numbers. ⏳ D-10: locate it on
# the real instance and export LIBCUFILE_PRELOAD before running any kvikIO sweep.
: "${LIBCUFILE_PRELOAD:?LIBCUFILE_PRELOAD is unset -- locate the system libcufile matched to the loaded nvidia-fs module and export it (see docs/NAMING-AND-VARIABLES.md Table 1)}"
LIBCUFILE_SYSTEM="$LIBCUFILE_PRELOAD"
[ -f "$LIBCUFILE_SYSTEM" ] || { echo "LIBCUFILE_PRELOAD points at a nonexistent file: $LIBCUFILE_SYSTEM" >&2; exit 1; }
CUFILE_JSON=${CUFILE_ENV_PATH_JSON}

BACKEND=""
RUN_DIR=""
MODEL="${MODEL:-virchow2}"

# GPU set for the extraction phase (Phase 3), read from the environment — never
# baked in, because the right indices are instance-specific.
# ⏳ D-8: 4 GPUs to match the instance (STAGES.md D10); the NUMA/NIC-aware ORDERING
# is still to be re-derived on the real instance. The width is right; the pinning
# order is not. The width is not free to drift either: 6.D composes with the Stage
# 6.A Tier 2 extraction cell, which runs at N=4, so an extraction phase of any other
# width yields an end-to-end number that cannot be composed with 6.A's.
PIPELINE_GPUS="${PIPELINE_GPUS:-0,1,2,3}"
PIPELINE_N_GPUS="${PIPELINE_N_GPUS:-4}"

# ── Guard: every requested GPU index must actually exist ─────────────────────────
# CUDA_VISIBLE_DEVICES silently DROPS indices that do not exist rather than
# erroring, so a stale list does not fail -- Phase 3 just runs on fewer GPUs than
# the cell claims. 6.D's entire output is per-phase wallclock, so a half-width
# extraction phase either dies after model load or reports a wallclock describing a
# configuration nobody chose, while pipeline-summary.json is still written and the
# cell still exits 0. Nothing downstream can see it, so this refuses up front.
_n_gpus_present="$(nvidia-smi -L 2>/dev/null | wc -l)"
if [ "${_n_gpus_present:-0}" -eq 0 ]; then
  echo "FATAL: no GPUs visible (nvidia-smi -L returned nothing) -- 6.D needs them for Phase 3." >&2
  exit 1
fi
IFS=',' read -ra _req_gpus <<< "$PIPELINE_GPUS"
for _g in "${_req_gpus[@]}"; do
  if ! [[ "$_g" =~ ^[0-9]+$ ]] || [ "$_g" -ge "$_n_gpus_present" ]; then
    echo "FATAL: PIPELINE_GPUS='$PIPELINE_GPUS' names GPU index '$_g', but this instance has" >&2
    echo "       $_n_gpus_present GPU(s) (valid indices 0..$((_n_gpus_present - 1)))." >&2
    echo "       CUDA_VISIBLE_DEVICES would silently drop it and the extraction phase would run" >&2
    echo "       on fewer GPUs than this pipeline's wallclock claims. Re-derive the GPU list for" >&2
    echo "       THIS instance (deferred item D-8) and export PIPELINE_GPUS." >&2
    exit 1
  fi
done
if [ "${#_req_gpus[@]}" -ne "$PIPELINE_N_GPUS" ]; then
  echo "FATAL: PIPELINE_GPUS lists ${#_req_gpus[@]} GPU(s) but PIPELINE_N_GPUS=$PIPELINE_N_GPUS." >&2
  echo "       These must agree, or the extractor's world size will not match its device list." >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$BACKEND" ] && { echo "missing --backend" >&2; exit 2; }
[ -z "$RUN_DIR" ] && { echo "missing --run-dir" >&2; exit 2; }
mkdir -p "$RUN_DIR"
PHASE_CSV="$RUN_DIR/per-phase-summary.csv"
echo "phase,t_start_s,t_end_s,wallclock_s,status,notes" > "$PHASE_CSV"

EMBED_DIM=1280
[ "$MODEL" = "uni2-h" ] && EMBED_DIM=1536
[ "$MODEL" = "gigapath" ] && EMBED_DIM=1536

# UNI2-h conditional-use tag — 2026-05-19 plan: HF access granted, Mahmood Lab
# publication permission pending. Per-cell metadata note marks the run dir clearly.
PENDING_APPROVAL_TAG=""
[ "$MODEL" = "uni2-h" ] && PENDING_APPROVAL_TAG="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "

FEATURES_OUT="${FS_MOUNT}/features/6.A/${MODEL}/6d-pipeline-${BACKEND}"
mkdir -p "$FEATURES_OUT"

T_ORCH=$(date +%s.%N)
log() { echo "[6.D-$(date -u +%FT%TZ)] $*"; }

# ---------- Phase 1: tissue detection ----------
PHASE_T0=$(date +%s.%N)
log "Phase 1: CLAM tissue detection (Stage 3 path)"
# Stage 3 outputs already exist at ${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches
# for our pipeline purposes; if not, this re-runs CLAM. Idempotent.
TISSUE_DIR="${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches"
N_EXIST=$(ls "$TISSUE_DIR"/*.h5 2>/dev/null | wc -l)
if [ "$N_EXIST" -ge 1131 ]; then
  log "Phase 1: skipping — Stage 3 output already present ($N_EXIST .h5 files)"
  PHASE_STATUS="SKIP-EXISTS"
else
  log "Phase 1: re-running CLAM tissue detection on full BRCA n=64"
  # Invoke Stage 3's existing driver (idempotent — only re-runs missing slides)
  bash "$REPO/scripts/sweep-stage3-tissue-detection.sh" tcga-brca 64 \
       >> "$RUN_DIR/phase1-tissue-detection.log" 2>&1 || true
  N_EXIST=$(ls "$TISSUE_DIR"/*.h5 2>/dev/null | wc -l)
  PHASE_STATUS="OK"
fi
PHASE_T1=$(date +%s.%N)
PHASE_WALL=$(awk "BEGIN{print $PHASE_T1 - $PHASE_T0}")
printf "tissue_detection,%s,%s,%s,%s,%s\n" "$PHASE_T0" "$PHASE_T1" "$PHASE_WALL" "$PHASE_STATUS" \
  "n_slides_with_coords=$N_EXIST" >> "$PHASE_CSV"
log "Phase 1: $PHASE_STATUS in ${PHASE_WALL}s"

# ---------- Phase 2: raw-TIFF conversion (kvikio path only) ----------
# kvikio path needs full BRCA raw-TIFF; we handle via the chunked orchestrator,
# which combines convert + extract into one phase. So for kvikio we'll just
# invoke the chunked orchestrator in Phase 3 and skip explicit "Phase 2".
# For cucim path, no Phase 2 needed.

# ---------- Phase 3: foundation-model feature extraction ----------
PHASE_T0=$(date +%s.%N)
log "Phase 3: $MODEL feature extraction via $BACKEND backend"
EXTRACT_LOG="$RUN_DIR/phase3-extract.log"
EXTRACT_SUMMARY="$RUN_DIR/phase3-extract-summary.json"
EXTRACT_STATUS="OK"
MANIFEST="$REPO/scripts/manifests/tcga-brca-full40x-stage4a-format.tsv"

if [ "$BACKEND" = "kvikio" ]; then
  # Chunked orchestrator handles convert + extract internally.
  # The device list goes ONLY through --gpu-csv: the orchestrator re-exports it as
  # CUDA_VISIBLE_DEVICES around the extractor, and CUDA_VISIBLE_DEVICES NESTS —
  # setting it here as well would make the inner list index into the already-
  # restricted set, so any non-identity list silently loses ranks. The conversion
  # step the orchestrator runs first is CPU-only, so nothing else here needs it.
  # No comment may end these continued lines: a `#` swallows the trailing backslash,
  # truncating the command to whatever preceded it — bash -n still passes, the
  # orchestrator runs argument-starved, and the leftover flags execute as a bogus
  # command whose failure is what sets EXTRACT_STATUS.
  LD_PRELOAD="$LIBCUFILE_SYSTEM" \
  CUFILE_ENV_PATH_JSON="$CUFILE_JSON" \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  bash "$REPO/scripts/run-stage6a-tier2-chunked.sh" \
    --model "$MODEL" --n-gpus "$PIPELINE_N_GPUS" --gpu-csv "$PIPELINE_GPUS" \
    --output-dir "$FEATURES_OUT" \
    --extraction-steps-csv "$RUN_DIR/phase3-extraction-steps.csv" \
    --per-slide-csv "$RUN_DIR/phase3-per-slide.csv" \
    --summary-json "$EXTRACT_SUMMARY" \
    --per-chunk-summary "$RUN_DIR/phase3-per-chunk-summary.csv" \
    --chunk-size 200 \
    >> "$EXTRACT_LOG" 2>&1 || EXTRACT_STATUS="FAIL"
elif [ "$BACKEND" = "cucim" ]; then
  # Direct cucim path against canonical SVS. No nesting here — this is the only
  # place CUDA_VISIBLE_DEVICES is applied, and the extractor's ranks index into the
  # visible set, so --world-size must equal the number of indices it names.
  CUDA_VISIBLE_DEVICES="$PIPELINE_GPUS" \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  "$PY" "$REPO/scripts/extract-features-foundation-stage6.py" \
    --backend cucim_batched_cpu --world-size "$PIPELINE_N_GPUS" --model "$MODEL" \
    --svs-dir ${FS_MOUNT}/data/tcga-brca \
    --coords-dir ${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches \
    --manifest "$MANIFEST" \
    --output-dir "$FEATURES_OUT" \
    --batch-size 256 \
    --extraction-steps-csv "$RUN_DIR/phase3-extraction-steps.csv" \
    --per-slide-csv "$RUN_DIR/phase3-per-slide.csv" \
    --summary-json "$EXTRACT_SUMMARY" \
    >> "$EXTRACT_LOG" 2>&1 || EXTRACT_STATUS="FAIL"
else
  echo "unknown --backend $BACKEND" >&2; exit 2
fi
N_PT=$(ls "$FEATURES_OUT"/*.pt 2>/dev/null | wc -l)
PHASE_T1=$(date +%s.%N)
PHASE_WALL=$(awk "BEGIN{print $PHASE_T1 - $PHASE_T0}")
printf "extract,%s,%s,%s,%s,%s\n" "$PHASE_T0" "$PHASE_T1" "$PHASE_WALL" "$EXTRACT_STATUS" \
  "backend=$BACKEND model=$MODEL n_features_pt=$N_PT" >> "$PHASE_CSV"
log "Phase 3: $EXTRACT_STATUS in ${PHASE_WALL}s; $N_PT .pt files produced"

# ---------- Phase 4: MIL classifier training (one epoch over features) ----------
PHASE_T0=$(date +%s.%N)
log "Phase 4: attention-MIL classifier training (single epoch over $N_PT features)"
# Compute single-epoch runtime: canonical CLAM MIL is bs=1 (one slide per step),
# so ~N_PT steps/epoch; ~10 s/step is a generous upper bound for the time budget.
EPOCH_STEPS=$((N_PT + 10))
EPOCH_RUNTIME=$((EPOCH_STEPS * 10))  # rough s upper bound
MIL_LOG="$RUN_DIR/phase4-mil-train.log"
MIL_SUMMARY="$RUN_DIR/phase4-mil-summary.json"
MIL_STATUS="OK"

if [ "$N_PT" -lt 10 ]; then
  log "Phase 4: SKIP — too few features ($N_PT)"
  MIL_STATUS="SKIP-NO-FEATURES"
else
  CUDA_VISIBLE_DEVICES=0 \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  "$PY" "$REPO/scripts/train-mil-stage6b.py" \
    --features-dir "$FEATURES_OUT" \
    --embedding-dim "$EMBED_DIM" \
    --num-workers 4 \
    --ramp 60 --runtime "$EPOCH_RUNTIME" \
    --training-steps-csv "$RUN_DIR/phase4-training-steps.csv" \
    --summary-json "$MIL_SUMMARY" \
    --gpu 0 \
    >> "$MIL_LOG" 2>&1 || MIL_STATUS="FAIL"
fi
PHASE_T1=$(date +%s.%N)
PHASE_WALL=$(awk "BEGIN{print $PHASE_T1 - $PHASE_T0}")
printf "mil_train,%s,%s,%s,%s,%s\n" "$PHASE_T0" "$PHASE_T1" "$PHASE_WALL" "$MIL_STATUS" \
  "bs=1 nw=4" >> "$PHASE_CSV"
log "Phase 4: $MIL_STATUS in ${PHASE_WALL}s"

# ---------- Final summary ----------
T_END=$(date +%s.%N)
TOTAL_WALL=$(awk "BEGIN{print $T_END - $T_ORCH}")
"$PY" -c "
import csv, json
phases = []
with open('$PHASE_CSV') as f:
    for r in csv.DictReader(f):
        phases.append(r)
summary = {
    'backend': '$BACKEND',
    'model': '$MODEL',
    'embedding_dim': $EMBED_DIM,
    'pipeline_end_to_end_wallclock_s': $TOTAL_WALL,
    'phases': phases,
    'n_features_pt_produced': $N_PT,
    'per_phase_summary_csv': '$PHASE_CSV',
}
with open('$RUN_DIR/pipeline-summary.json', 'w') as f:
    json.dump(summary, f, indent=2)
print('=== pipeline summary ===')
print(json.dumps(summary, indent=2))
"
log "DONE. End-to-end wallclock: ${TOTAL_WALL}s ($(awk "BEGIN{print $TOTAL_WALL / 60}") min)"
