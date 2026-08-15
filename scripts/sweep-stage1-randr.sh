#!/usr/bin/env bash
# sweep-stage1-randr.sh — Stage 1.0d random-read IOPS fio sweep, COLD BY
# CONSTRUCTION via ONE-TOUCH regions (D13 route 1; design ratified 2026-08-15,
# Stage-1-Ingest.md).
#
# Grid: bs ∈ {4K, 16K, 64K} × jobs ∈ {1, 2, 4, 8, 16, 32, 64} = 21 cells,
# plus one WARM REFERENCE cell = 22.
#
# WHY one-touch regions and not a shared corpus: under steady-state LRU,
# uniform random reads over a corpus C with server cache S are served from
# cache at ≈ S/C — and the two legs' caches differ, so a shared corpus makes
# the hit rates ASYMMETRIC across legs: the exact cache-size artifact D13
# exists to prevent. Instead each cell reads its OWN pre-staged region, every
# block at most once across the whole sweep (fio's default random map within
# per-job disjoint slices), so no read can be served by a previous read — cold
# with NO cache-behavior assumptions, identically on both legs.
#
# Mechanics that keep the construction true:
#   - Regions pre-staged by prep-stage1-read-corpora.sh (never laid out in the
#     timed window), staging-write warmth flushed by its eviction pass.
#   - Cells stop at min(region one-touch complete, --runtime=600) — never
#     time_based, which would re-read touched blocks.
#   - Region-to-cell mapping is the cell's position in the FIXED DE-ORDERED
#     sequence committed below — identical on both legs.
#   - D18 REPEATS (REP=2/3 of the knee/pinned-peak cells) claim a fresh RESERVE
#     region via the claims ledger — a repeat re-reading its first run's region
#     would measure that run's cache, not the storage.
#   - The WARM REFERENCE cell (route 2, inverted: the grid's default is cold)
#     re-reads the LAST grid cell's just-touched region — deliberately the most
#     cache-resident bytes available. Its contrast against that cell is the
#     measured evidence the one-touch construction rests on.
#
# Run with:  scripts/sweep-stage1-randr.sh   (after prep-stage1-read-corpora.sh)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh}"
: "${STAGE1_RANDR_REGION_GIB:?STAGE1_RANDR_REGION_GIB is unset -- set it in env.sh (cache-derived provisioning parameter)}"
: "${STAGE1_RANDR_REGIONS:?STAGE1_RANDR_REGIONS is unset -- set it in env.sh}"

CORPUS_DIR="$FS_MOUNT/benchmarks/stage1-read-corpus"
STATE_DIR="$REPO/runs/.leg-state/$LEG"
MARKER="$STATE_DIR/stage1-read-corpus-staged"
CLAIMS="$STATE_DIR/randr-region-claims"
LOG_DIR=$REPO/runs/sweep-logs
mkdir -p "$LOG_DIR"
SWEEP_LOG="$LOG_DIR/$(date -u +%F-%H%M)-$LEG-stage1-randr.log"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$SWEEP_LOG"; }

[ -f "$MARKER" ] || { log "FATAL: staging marker missing ($MARKER) — run prep-stage1-read-corpora.sh first."; exit 2; }
staged_region_gib=$(awk -F= '/^randr_region_gib=/{print $2}' "$MARKER")
staged_regions=$(awk -F= '/^randr_regions=/{print $2}' "$MARKER")
[ "$staged_region_gib" = "$STAGE1_RANDR_REGION_GIB" ] && [ "$staged_regions" = "$STAGE1_RANDR_REGIONS" ] \
  || { log "FATAL: staged regions (${staged_regions} x ${staged_region_gib} GiB) disagree with env (${STAGE1_RANDR_REGIONS} x ${STAGE1_RANDR_REGION_GIB} GiB) — restage or fix env.sh."; exit 2; }

# Fixed de-ordered sequence: 3 passes over a de-ordered jobs list, block size
# rotated per pass — every (bs, jobs) pair exactly once, neither axis ascends.
JOBS_SEQ=(16 1 64 4 32 2 8)
BS_ALL=(16k 4k 64k)
GRID_CELLS=21
RESERVE_BASE=$GRID_CELLS   # regions [21, STAGE1_RANDR_REGIONS) are the D18 repeat reserve
TOTAL=22

(( STAGE1_RANDR_REGIONS > GRID_CELLS )) \
  || { log "FATAL: STAGE1_RANDR_REGIONS=$STAGE1_RANDR_REGIONS leaves no reserve regions past the $GRID_CELLS grid cells (D18 repeats need fresh regions)."; exit 2; }

# A D18 repeat must read FRESH blocks: claim the first unclaimed reserve region.
claim_reserve_region() { # claim_reserve_region <cell-name> -> echoes region index
  local cell="$1" r
  touch "$CLAIMS"
  for (( r=RESERVE_BASE; r<STAGE1_RANDR_REGIONS; r++ )); do
    if ! grep -q "^region=$r " "$CLAIMS"; then
      echo "region=$r cell=$cell rep=${REP:-?} claimed=$(date -u +%FT%TZ)" >> "$CLAIMS"
      echo "$r"
      return 0
    fi
  done
  return 1
}

log "=== Stage 1.0d randr sweep starting (leg=$LEG) ==="
log "  region pool: $STAGE1_RANDR_REGIONS x ${STAGE1_RANDR_REGION_GIB} GiB one-touch regions at $CORPUS_DIR"
log "  grid: $GRID_CELLS cells (fixed de-ordered sequence) + 1 warm reference = $TOTAL"
log "  consolidated log: $SWEEP_LOG"

i=0
FAILED_CELLS=0
LAST_REGION=0
run_randr_cell() { # run_randr_cell <bs> <jobs> <region-idx> <cellindex> <cache-state> <extra-note>
  local bs="$1" jobs="$2" region="$3" idx="$4" cstate="$5" extra="$6"
  local slice_gib=$(( STAGE1_RANDR_REGION_GIB / jobs ))
  (( slice_gib >= 1 )) || { log "FATAL: region ${STAGE1_RANDR_REGION_GIB} GiB / $jobs jobs < 1 GiB per job"; exit 2; }
  local region_file="$CORPUS_DIR/region-${region}.bin"
  [ -f "$region_file" ] || { log "FATAL: $region_file missing — restage the region pool."; exit 2; }
  local name="randr-bs${bs}-jobs${jobs}"
  [ "$cstate" = "warm" ] && name="randr-warmref-bs${bs}-jobs${jobs}"
  local note="Stage 1.0d cell $((idx+1))/$TOTAL: random read IOPS, bs=$bs jobs=$jobs iodepth=8 libaio --direct=1, region-${region}.bin (${STAGE1_RANDR_REGION_GIB} GiB; per-job disjoint ${slice_gib} GiB slices, fio random map on => each block at most once). ${extra} Fixed de-ordered cell order; stops at min(one-touch complete, 600s). Server-side residual recorded, not asserted."

  log ""
  log "=== [cell $((idx+1))/$TOTAL] $name (region $region, $cstate) ==="
  RECORD_CACHE_STATE="$cstate" "$REPO/scripts/record-run.sh" \
    --run-name "$name" --stage "1.0d" --note "$note" \
    -- fio \
      --name="$name" \
      --filename="$region_file" \
      --rw=randread --bs="$bs" \
      --numjobs="$jobs" --iodepth=8 --ioengine=libaio --direct=1 \
      --offset_increment="${slice_gib}G" --size="${slice_gib}G" \
      --runtime=600 --ramp_time=60 \
      --group_reporting --output-format=json+ --status-interval=1 \
    2>&1 | tee -a "$SWEEP_LOG"
  local rc=${PIPESTATUS[0]}
  (( rc != 0 )) && { FAILED_CELLS=$(( FAILED_CELLS + 1 )); log "  WARN: cell rc=$rc — INCOMPLETE; sweep continues (fails loud at the end)"; }
}

for p in 0 1 2; do
  for q in 0 1 2 3 4 5 6; do
    bs="${BS_ALL[$(( (p + q) % 3 ))]}"
    jobs="${JOBS_SEQ[$q]}"
    region=$i
    # A D18 repeat of this cell reads a FRESH reserve region, never its first
    # run's region — the ledger records which repeat consumed which region.
    if [ -n "${REP:-}" ]; then
      region=$(claim_reserve_region "randr-bs${bs}-jobs${jobs}") \
        || { log "FATAL: reserve regions exhausted — restage with a larger STAGE1_RANDR_REGIONS."; exit 2; }
      log "  REP=$REP: claimed reserve region $region (ledger: $CLAIMS)"
    fi
    run_randr_cell "$bs" "$jobs" "$region" "$i" cold \
      "COLD BY CONSTRUCTION (one-touch: no block of this region has been read before, staging warmth evicted by the prep's flush pass)."
    LAST_REGION=$region
    i=$(( i + 1 ))
  done
done

# Warm reference cell (route 2, inverted): re-read the LAST grid cell's
# just-touched region — deliberately the most server-cache-resident bytes
# available — at a fixed mid config. Its delta against the grid is the
# measured evidence the one-touch construction rests on, and it doubles as the
# server-cache-served random-read rate.
run_randr_cell 4k 16 "$LAST_REGION" "$i" warm \
  "WARM REFERENCE (D13 route 2, inverted — the grid's default regime is cold): deliberate re-read of the last grid cell's just-touched region."

log ""
log "=== sweep done ==="
log "review: cat runs/INDEX.md | tail -$(( TOTAL + 5 ))"
if (( FAILED_CELLS > 0 )); then
  log "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation),"
  log "        and this exit tells the chain a hole exists rather than letting the step be marked done."
  exit 1
fi
