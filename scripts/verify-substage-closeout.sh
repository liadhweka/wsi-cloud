#!/usr/bin/env bash
# verify-substage-closeout.sh <substage>|--all-completed — the mechanical
# substage-closeout gate (born 2026-08-17, after the Stage-3 results block was
# missed by hand: the docs called the closeout non-negotiable and it still got
# skipped, which is the project's own lesson that prose discipline is not a
# mechanism — "a trigger must be mechanical").
#
# For one completed substage it asserts, each with a named failure:
#   1. every matching run dir's INDEX row says OK (forensically renamed
#      -FAILED-* dirs are excluded — they are history, not subjects)
#   2. the substage's aggregate summary CSV exists and is NEWER than the newest
#      matching run dir (a stale aggregate is a silent lie)
#   3. the stage roadmap carries a "**Leg <leg> results" row INSIDE that
#      substage's section — the numbers-into-the-roadmap cadence, checked
#      mechanically (the convention: every completed substage's table carries
#      a row starting "**Leg A results" / "**Leg B results")
#   4. the post-cell consistency canary runs on every cell; NO_DATA anywhere is
#      fatal (a dead Primary source), non-PASS judgements are counted + printed
#   5. every cell's raw telemetry is verifiably in S3 (size-checked dry-run
#      shows nothing pending)
#
# Chains call this after a step completes; a substage is NOT done until this
# exits 0. Exit codes: 0 clean, 1 assertion failed, 2 usage/unknown substage.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
: "${LEG:?LEG is unset -- source env.sh}"
: "${S3_BUCKET:?S3_BUCKET is unset -- source env.sh}"

# substage | run-dir glob-mid | summary CSV ("-" = none required: prep/infra) |
# roadmap file ("-" = none) | roadmap section header prefix
TABLE="
1.0a|s1.0a-|runs/s1.0a-seqw-summary.csv|docs/Stage-1-Ingest.md|### 1.0a
1.0b|s1.0b-|runs/s1.0b-seqr-summary.csv|docs/Stage-1-Ingest.md|### 1.0b
1.0c|s1.0c-|runs/s1.0c-randw-summary.csv|docs/Stage-1-Ingest.md|### 1.0c
1.0d|s1.0d-|runs/s1.0d-randr-summary.csv|docs/Stage-1-Ingest.md|### 1.0d
1.0r|s1.0-read-corpus-prep|-|-|-
1.5|s1.5-|runs/s1.5-fpsync-summary.csv|docs/Stage-1-Ingest.md|### 1.5
1.6|s1.6-|runs/s1.6-mixed-summary.csv|docs/Stage-1-Ingest.md|### 1.6
1.7|s1.7-|runs/s1.7-hydrate-summary.csv|docs/Stage-1-Ingest.md|### 1.7
2.0|s2.0-|runs/s2.0-properties-summary.csv|docs/Stage-2-Cataloging.md|### 2.0
3.0|s3.0-|runs/s3.0-tissue-summary.csv|docs/Stage-3-Tissue-Detection.md|### 3.0
4.A|s4.A-|runs/s4.A-patches-summary.csv|docs/Stage-4-Patching.md|### 4.A
4.B|s4.B-|runs/s4.B-tilesread-summary.csv|docs/Stage-4-Patching.md|### 4.B
4.C|s4.C-|runs/s4.C-kvikio-summary.csv|docs/Stage-4-Patching.md|### 4.C
4.D|s4.D-|-|docs/Stage-4-Patching.md|### 4.D
5|s5.|runs/s5.A-training-summary.csv|docs/Stage-5-Training.md|### 5.A
6.A|s6.A-*brca50|runs/s6.A-extract-summary.csv|docs/Stage-6-Feature-Extraction.md|#### 6.A Tier 1
6.A.3|s6.A-*cam16|runs/s6.A-extract-summary.csv|docs/Stage-6-Feature-Extraction.md|#### 6.A Tier 3
6.A.2|s6.A-*brca_full|runs/s6.A-extract-summary.csv|docs/Stage-6-Feature-Extraction.md|#### 6.A Tier 2
6.B.3|s6.B.3-|runs/s6.B-mil-summary.csv|docs/Stage-6-Feature-Extraction.md|#### 6.B.3
6.B.2|s6.B.2-|runs/s6.B-stress-summary.csv|docs/Stage-6-Feature-Extraction.md|#### 6.B.2
6.C|s6.C-|runs/s6.C-concurrent-summary.csv|docs/Stage-6-Feature-Extraction.md|### 6.C
7|s7|runs/s7-clinical-summary.csv|docs/Stage-7-Clinical-Inference-Deployment.md|### 7.1
"

lookup() { echo "$TABLE" | grep -v '^\s*$' | awk -F'|' -v s="$1" '$1==s'; }

check_one() {
  local sub=$1 row mid csv doc hdr fail=0
  row=$(lookup "$sub") || true
  [ -n "$row" ] || { echo "closeout: unknown substage '$sub' — extend the table when a new substage lands" >&2; return 2; }
  IFS='|' read -r _ mid csv doc hdr <<< "$row"
  echo "── closeout: $sub (leg=$LEG) ──"

  # collect run dirs (exclude forensically renamed)
  local dirs=() d
  # $mid is deliberately UNQUOTED: per-tier rows carry their own wildcard
  # (e.g. "s6.A-*brca50"), which a quoted expansion would make literal.
  for d in runs/*-"$LEG"-$mid*/; do
    d=${d%/}; [ -d "$d" ] || continue
    [[ "$d" == *FAILED* ]] && continue
    dirs+=("$d")
  done
  if [ ${#dirs[@]} -eq 0 ]; then echo "  FAIL: no run dirs match runs/*-$LEG-$mid*"; return 1; fi
  echo "  cells: ${#dirs[@]}"

  # 1. INDEX verdicts
  local not_ok=0
  for d in "${dirs[@]}"; do
    grep -qF "\`$(basename "$d")\` (fs $LEG" runs/INDEX.md || { echo "  FAIL: $(basename "$d") has no INDEX row"; not_ok=1; continue; }
    grep -F "\`$(basename "$d")\`" runs/INDEX.md | grep -q ' OK)' || { echo "  FAIL: $(basename "$d") is not OK in INDEX"; not_ok=1; }
  done
  [ $not_ok -eq 0 ] && echo "  OK:   every cell OK in INDEX" || fail=1

  # 2. aggregate CSV exists + fresher than the newest cell
  # Summary CSVs are PER-LEG files (D6, concurrent legs — two rewriting
  # aggregators must never share a write target). The table stays leg-neutral;
  # the suffix is applied mechanically here.
  [ "$csv" != "-" ] && csv="${csv%.csv}-$LEG.csv"
  if [ "$csv" != "-" ]; then
    if [ ! -s "$csv" ]; then echo "  FAIL: aggregate $csv missing/empty — run the aggregator"; fail=1
    else
      local newest; newest=$(ls -td "${dirs[@]}" | head -1)
      if [ "$csv" -ot "$newest/results.json" ]; then
        echo "  FAIL: aggregate $csv is OLDER than $(basename "$newest") — re-run the aggregator"; fail=1
      else echo "  OK:   aggregate $csv present and fresh"; fi
    fi
  fi

  # 3. roadmap results row inside the substage's section
  if [ "$doc" != "-" ]; then
    if awk -v hdr="$hdr" -v leg="$LEG" '
        index($0, hdr)==1 {insec=1; next}
        insec && /^#{3,4} / {exit}
        insec && $0 ~ ("\\*\\*Leg .* results") {found=1; exit}
        END {exit !found}' "$doc"; then
      echo "  OK:   roadmap results row present in $doc ($hdr)"
    else
      echo "  FAIL: no '**Leg <X> results' row in $doc under '$hdr' — numbers-into-the-roadmap is the cadence"; fail=1
    fi
  fi

  # 4. consistency canary per cell (NO_DATA fatal; judgements counted)
  local judged=0 nodata=0
  for d in "${dirs[@]}"; do
    local out
    if out=$(python3 scripts/wsi_agg_helper.py check "$d" 2>&1); then continue; fi
    if echo "$out" | grep -q '"verdict": "NO_DATA"'; then
      echo "  FAIL: NO_DATA canary on $(basename "$d") — dead Primary source"; nodata=1
    else judged=$((judged+1)); fi
  done
  [ $nodata -eq 0 ] && echo "  OK:   canary — no dead sources ($judged recorded judgement(s))" || fail=1

  # 5. raw telemetry verifiably in S3
  local unsynced=0
  for d in "${dirs[@]}"; do
    local pending
    pending=$(aws s3 sync "$d/raw" "s3://$S3_BUCKET/runs/$LEG/$(basename "$d")/raw" --size-only --dryrun 2>/dev/null | head -1)
    [ -n "$pending" ] && { echo "  FAIL: $(basename "$d") raw not fully in S3"; unsynced=1; }
  done
  [ $unsynced -eq 0 ] && echo "  OK:   raw telemetry verified in S3 for every cell" || fail=1

  if [ $fail -eq 0 ]; then echo "  CLOSEOUT CLEAN: $sub"; else echo "  CLOSEOUT FAILED: $sub" >&2; fi
  return $fail
}

if [ "${1:-}" = "--all-completed" ]; then
  rc=0
  for sub in $(echo "$TABLE" | grep -v '^\s*$' | cut -d'|' -f1); do
    mid=$(lookup "$sub" | cut -d'|' -f2)
    ls -d runs/*-"$LEG"-"$mid"*/ >/dev/null 2>&1 || continue   # substage not run yet
    check_one "$sub" || rc=1
    echo
  done
  exit $rc
fi
[ -n "${1:-}" ] || { echo "usage: verify-substage-closeout.sh <substage>|--all-completed" >&2; exit 2; }
check_one "$1"
