#!/usr/bin/env bash
# Stage 6.C concurrent multi-workload sweep driver.
#
# Five tiers per `runs/Stage-6-Feature-Extraction.md` 6.C:
#   Tier 1 (solo baselines): 4 cells — one per workload at the exact concurrent-cell config
#   Tier 2 (pairs):          4 cells — {extract+ingest, extract+mil, mil+viewer, extract+viewer}
#   Tier 3 (triples):        2 cells — {extract+mil+ingest, extract+mil+viewer}
#   Tier 4 (all-four-up):    1 cell  — all four workloads on one namespace
#   Tier 5 (endurance):      1 cell  — all-four-up, 4 hr sustained (ratified
#                            2026-08-21: mirrors 7.5.b's endurance window, so
#                            the two endurance cells are cross-stage comparable
#                            and the chain stays bounded overnight)
#
# Total: 12 cells. Wallclock estimate per cell:
#   solo, pair, triple, all-four = 30 min each (5 ramp + 25 steady)
#   endurance = ~4 hr (5 ramp + 4h steady)
# Total: ~10 hr (dominated by endurance).
#
# Usage:
#   ./sweep-stage6c.sh tier1     # 4 solo baselines
#   ./sweep-stage6c.sh tier2     # pair-wise
#   ./sweep-stage6c.sh tier3     # triple-up
#   ./sweep-stage6c.sh tier4     # all-four-up (THE customer slide)
#   ./sweep-stage6c.sh tier5     # endurance (4 hr)
#   ./sweep-stage6c.sh all       # all five tiers
#   ./sweep-stage6c.sh smoke     # very short single-cell validation
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$REPO/scripts/orchestrate-concurrent-stage6c.sh"
RECORD="$REPO/scripts/record-run.sh"

[ -x "$ORCH" ]   || { echo "missing $ORCH" >&2; exit 1; }
[ -x "$RECORD" ] || { echo "missing record-run.sh" >&2; exit 1; }
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"

# Common cell config
DEFAULT_RAMP="${DEFAULT_RAMP:-300}"
DEFAULT_RUNTIME="${DEFAULT_RUNTIME:-1500}"   # 25 min steady (so cell = ~30 min)
ENDURANCE_RUNTIME="${ENDURANCE_RUNTIME:-14400}"  # 4 hr steady — mirrors 7.5.b's endurance window (ratified 2026-08-21)

FAILED_CELLS=0

run_cell() {
  local workloads="$1"; local ramp="$2"; local runtime="$3"
  local tag; tag=$(echo "$workloads" | tr ',' '+')
  local cell_name="concurrent-${tag}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.C-${cell_name}"

  # If the concurrent extract workload uses UNI2-h (via EXTRACT_MODEL env var),
  # tag the cell as PENDING-APPROVAL — UNI2-h stays internal-only; the tag is
  # what gets filtered before anything is externalised.
  local approval_tag=""
  [ "${EXTRACT_MODEL:-virchow2}" = "uni2-h" ] && approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "
  local note="${approval_tag}Stage 6.C concurrent multi-workload cell on fs=${LEG}: workloads={$workloads} extract_model=${EXTRACT_MODEL:-virchow2} ramp=${ramp}s steady=${runtime}s. WHY: concurrent heterogeneous load on one namespace is where storage architectures diverge, and no single-workload cell surfaces it. Retention is measured against THIS leg's own solo baselines re-measured at the same concurrent config, so the cross-leg comparison is of retention percentages, not absolute rates. Per D15, check the core accounting before attributing any interference to the filesystem rather than the host. Regime: na — the cold/warm axis deliberately does not apply to 6.C (ratified 2026-08-21): the measured quantity is per-workload QoS retention, and solo baselines carry the same declaration as the concurrent tiers because they are the retention denominators measured under the identical construction — labelling the two sides differently would put numerator and denominator in different regimes."

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name"
  echo "  workloads: $workloads"
  echo "  ramp=${ramp}s runtime=${runtime}s"
  echo "=========================================="

  # D-30/D13: one uniform na-* declaration across ALL 6.C tiers (solo included) —
  # see the Regime sentence in the note for why.
  RECORD_CACHE_STATE=na-mixed-concurrent-workloads \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.C \
    --note "$note" \
    -- "$ORCH" --workloads "$workloads" --ramp "$ramp" --runtime "$runtime" \
       --run-dir "$run_dir"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILED_CELLS=$((FAILED_CELLS + 1))
    echo "WARN: cell $cell_name exited rc=$rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"
  fi
}

tier1_solo() {
  echo "=== Tier 1: solo baselines (4 cells) ==="
  run_cell ingest  "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell extract "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell mil     "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell viewer  "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
}

tier2_pairs() {
  echo "=== Tier 2: pair-wise concurrent (4 cells) ==="
  run_cell extract,ingest "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell extract,mil    "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell mil,viewer     "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell extract,viewer "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
}

tier3_triples() {
  echo "=== Tier 3: triple-up (2 cells) ==="
  run_cell extract,mil,ingest "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
  run_cell extract,mil,viewer "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
}

tier4_all_four() {
  echo "=== Tier 4: all-four-up (1 cell — THE customer slide) ==="
  run_cell extract,mil,ingest,viewer "$DEFAULT_RAMP" "$DEFAULT_RUNTIME"
}

tier5_endurance() {
  echo "=== Tier 5: endurance — all-four-up for ~4 hr (1 cell) ==="
  run_cell extract,mil,ingest,viewer "$DEFAULT_RAMP" "$ENDURANCE_RUNTIME"
}

smoke() {
  echo "=== Smoke: extract+ingest 60s steady ==="
  run_cell extract,ingest 30 60
}

all() {
  tier1_solo
  tier2_pairs
  tier3_triples
  tier4_all_four
  tier5_endurance
  echo ""
  echo "=== Stage 6.C sweep done. Aggregate with: $REPO/scripts/aggregate-stage6c-concurrent.py ==="
}

case "${1:-}" in
  smoke) smoke ;;
  tier1) tier1_solo ;;
  tier2) tier2_pairs ;;
  tier3) tier3_triples ;;
  tier4) tier4_all_four ;;
  tier5) tier5_endurance ;;
  all)   all ;;
  *) echo "usage: $0 {smoke|tier1|tier2|tier3|tier4|tier5|all}" >&2; exit 2 ;;
esac

if [ "$FAILED_CELLS" -gt 0 ]; then
  echo "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation)," >&2
  echo "        and this exit tells the chain a hole exists rather than letting the step be marked done." >&2
  exit 1
fi
