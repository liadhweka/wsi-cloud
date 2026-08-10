#!/usr/bin/env bash
# chain-stage1-bcd.sh — run Stage 1.0b → 1.0c → 1.0d back-to-back.
# Each sub-sweep is independent (its own driver, its own sweep log, its own
# run dirs). This wrapper just chains them and writes a top-level log so
# tomorrow's review has a single place to look at progression.
#
# Total estimated wall clock: ~14 hours.
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Checked here, not 14 hours from now: record-run.sh refuses every cell without
# --fs or $LEG, so an unset LEG burns the whole chain's wallclock and records
# nothing. It also scopes the review globs printed at the end — aggregate-sweep.py
# does not pivot on filesystem, so a glob matching both legs would average WEKA
# and Lustre cells into one grid.
: "${LEG:?LEG is unset -- source env.sh}"

LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR"
CHAIN_LOG="$LOG_DIR/$(date -u +%F-%H%M)-chain-stage1-bcd.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$CHAIN_LOG"; }

log "=== Stage 1.0 b/c/d chain starting ==="
log "  1.0b seqr  ~6.5h"
log "  1.0c randw ~3.9h"
log "  1.0d randr ~4h (incl. layout)"
log "  total ~14h"

# 1.0b: sequential read
log ""
log "=========================="
log "=== launching 1.0b seqr ==="
log "=========================="
"$REPO/scripts/sweep-stage1-seqr.sh" 2>&1 | tee -a "$CHAIN_LOG"
RC_B=${PIPESTATUS[0]}
log "1.0b seqr finished, rc=$RC_B"

# 1.0c: random write
log ""
log "==========================="
log "=== launching 1.0c randw ==="
log "==========================="
"$REPO/scripts/sweep-stage1-randw.sh" 2>&1 | tee -a "$CHAIN_LOG"
RC_C=${PIPESTATUS[0]}
log "1.0c randw finished, rc=$RC_C"

# 1.0d: random read
log ""
log "==========================="
log "=== launching 1.0d randr ==="
log "==========================="
"$REPO/scripts/sweep-stage1-randr.sh" 2>&1 | tee -a "$CHAIN_LOG"
RC_D=${PIPESTATUS[0]}
log "1.0d randr finished, rc=$RC_D"

log ""
log "=== chain done ==="
log "  rc: 1.0b=$RC_B  1.0c=$RC_C  1.0d=$RC_D"
log "  review: cat $REPO/runs/INDEX.md | tail -80"
log "  aggregate per stage:"
log "    scripts/aggregate-sweep.py 'runs/*-${LEG}-s1.0b-seqr-*'"
log "    scripts/aggregate-sweep.py 'runs/*-${LEG}-s1.0c-randw-*'"
log "    scripts/aggregate-sweep.py 'runs/*-${LEG}-s1.0d-randr-*'"
