#!/usr/bin/env bash
# rerun-cell.sh <run-dir> <rep> — the D18 repeat runner: re-invoke a recorded
# cell's EXACT command as REP=<rep>, with the original run name, stage, cache
# declaration, and note (annotated), so record-run.sh suffixes -rep<N> and the
# aggregators group the reps into median + spread.
#
# WHY a script: the knee / pinned-peak cells are per-leg DISCOVERIES, so the
# repeats cannot be pre-wired into run-leg.sh — and hand-retyping a cell's
# command is exactly the transcription risk the recorded cmd/metadata exist to
# remove. The command, name, stage and declared regime all come from the
# original run dir's metadata.json, never from a human retype.
#
# CAVEAT (D18/D13): a repeat must not measure its first run's cache. Write
# cells and scan-corpus reads are history-independent by construction; a 1.0d
# one-touch repeat is NOT — it must claim a fresh reserve region via the
# driver's ledger, which this generic runner cannot do. It REFUSES 1.0d cells.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR=$1; REP=$2
[[ "$REP" == "2" || "$REP" == "3" ]] || { echo "rep must be 2 or 3 (rep 1 is the original cell)" >&2; exit 2; }
META="$RUN_DIR/metadata.json"
[[ -f "$META" ]] || { echo "no metadata.json under $RUN_DIR" >&2; exit 2; }

STAGE=$(jq -r .stage "$META")
NAME=$(jq -r .run_name "$META")
CACHE=$(jq -r '.cache_state // empty' "$META")
NOTE=$(jq -r '.note // ""' "$META")
if [[ "$STAGE" == "1.0d" ]]; then
  echo "REFUSING: a 1.0d one-touch repeat must claim a fresh reserve region via the driver's" >&2
  echo "ledger (runs/.leg-state/\$LEG/randr-region-claims) or it measures its first run's cache." >&2
  exit 2
fi
mapfile -t CMD < <(jq -r '.command[]' "$META")
(( ${#CMD[@]} > 0 )) || { echo "empty command in $META" >&2; exit 2; }

# A recorded command may carry output paths that point INTO the original run
# dir (e.g. 4.C's --summary-json / --latency-csv). Re-running it verbatim makes
# the repeat OVERWRITE the original cell's outputs (bit the 4.C reps,
# 2026-08-18) — so pre-compute the repeat's run dir, hand it to the wrapper via
# RECORD_RUN_DIR (pattern #4), and rewrite every token that references the
# original dir to point at the repeat's own.
ORIG_ABS="$(cd "$RUN_DIR" && pwd)"
NEW_DIR="$REPO/runs/$(date -u +%Y-%m-%d-%H%M%S)-${LEG:?LEG is unset -- source env.sh}-s${STAGE}-${NAME}-rep${REP}"
CMD=("${CMD[@]//$ORIG_ABS/$NEW_DIR}")
mkdir -p "$NEW_DIR"

echo "rerun-cell: $NAME (stage $STAGE) as REP=$REP -> $NEW_DIR"
REP="$REP" RECORD_CACHE_STATE="${CACHE:-}" RECORD_RUN_DIR="$NEW_DIR" \
"$REPO/scripts/record-run.sh" \
  --stage "$STAGE" --run-name "$NAME" \
  --note "$NOTE [D18 REP=$REP re-invocation of $(basename "$RUN_DIR") — same command, same env; original-run-dir paths rewritten into this rep's dir; reps group to median + spread]" \
  -- "${CMD[@]}"
