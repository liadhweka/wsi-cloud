#!/usr/bin/env bash
# prep-stage1-read-corpora.sh — stage the Stage-1.0 read corpora (1.0b + 1.0d),
# then evict the staging writes from server RAM. Run ONCE per leg, before the
# 1.0b/1.0d sweeps; both drivers refuse to run without its marker.
#
# What it stages (sizes are ENV PARAMETERS, never literals — they derive from
# the provisioned server-side caches, docs/NAMING-AND-VARIABLES.md):
#   seq-corpus.bin                    STAGE1_SEQ_CORPUS_GIB   — the 1.0b shared
#       scan corpus. Must be >= ~2x the larger of the two filesystems'
#       server-side caches: a cyclic sequential scan over a corpus larger than
#       an LRU cache continuously evicts just-ahead data, so sequential
#       re-reads stay cold — the margin is what keeps that true off the
#       borderline.
#   region-<i>.bin  i in [0, STAGE1_RANDR_REGIONS)   each STAGE1_RANDR_REGION_GIB
#       — the 1.0d ONE-TOUCH region pool. Each 1.0d cell reads its own region,
#       every block at most once across the whole sweep, so the cells are cold
#       BY CONSTRUCTION with no cache-behavior assumptions at all. The pool
#       includes reserve regions for the D18 knee/peak repeats (a repeat must
#       read fresh blocks or it measures the first run's cache).
#
# Then ONE EVICTION PASS reads the seq corpus end to end: the staging writes
# leave their tail resident in server RAM, and a >cache scan evicts everything
# else under LRU — without it, the first cells to run would read bytes the
# filesystem absorbed minutes earlier.
#
# The whole prep runs as ONE recorded cell (a real sustained-write +
# sustained-read workload; not a comparison cell). Retained, never unlinked —
# the corpora are capacity inputs (SPINUP-CHECKLIST item 12).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh}"
: "${LEG:?LEG is unset -- source env.sh}"
: "${STAGE1_SEQ_CORPUS_GIB:?STAGE1_SEQ_CORPUS_GIB is unset -- a cache-derived provisioning parameter (docs/NAMING-AND-VARIABLES.md); set it in env.sh}"
: "${STAGE1_RANDR_REGION_GIB:?STAGE1_RANDR_REGION_GIB is unset -- set it in env.sh}"
: "${STAGE1_RANDR_REGIONS:?STAGE1_RANDR_REGIONS is unset -- set it in env.sh}"

CORPUS_DIR="$FS_MOUNT/benchmarks/stage1-read-corpus"
STATE_DIR="$REPO/runs/.leg-state/$LEG"
MARKER="$STATE_DIR/stage1-read-corpus-staged"
mkdir -p "$CORPUS_DIR" "$STATE_DIR"

TOTAL_GIB=$(( STAGE1_SEQ_CORPUS_GIB + STAGE1_RANDR_REGION_GIB * STAGE1_RANDR_REGIONS ))

if [ -f "$MARKER" ]; then
  echo "prep: marker already present ($MARKER) — corpora staged for this leg."
  echo "      To restage (e.g. after a cluster rebuild), remove the marker first;"
  echo "      the corpora themselves are retained deliberately (capacity inputs)."
  exit 0
fi

AVAIL_BYTES=$(df --output=avail -B1 "$FS_MOUNT" | tail -1 | tr -d ' ')
NEED_BYTES=$(( (TOTAL_GIB + TOTAL_GIB / 10) * 1024 * 1024 * 1024 ))
if (( AVAIL_BYTES < NEED_BYTES )); then
  echo "FATAL: $FS_MOUNT has $AVAIL_BYTES B free; corpora need $NEED_BYTES B (sizes + 10%)." >&2
  exit 1
fi

echo "prep: staging seq corpus ${STAGE1_SEQ_CORPUS_GIB} GiB + ${STAGE1_RANDR_REGIONS} x ${STAGE1_RANDR_REGION_GIB} GiB regions = ${TOTAL_GIB} GiB into $CORPUS_DIR"

# Per-job slice of the seq corpus (8 parallel writers into one file).
SEQ_JOBS=8
SEQ_SLICE_GIB=$(( STAGE1_SEQ_CORPUS_GIB / SEQ_JOBS ))

RECORD_CACHE_STATE="na-write-cell" "$REPO/scripts/record-run.sh" \
  --run-name "read-corpus-prep" \
  --stage 1.0 \
  --note "Stage-1.0 read-corpora staging (not a comparison cell; a real sustained-write + sustained-read workload). Phase 1: seq-corpus.bin ${STAGE1_SEQ_CORPUS_GIB} GiB (8 parallel writers). Phase 2: ${STAGE1_RANDR_REGIONS} one-touch regions x ${STAGE1_RANDR_REGION_GIB} GiB for 1.0d. Phase 3: eviction pass — full sequential read of the seq corpus, so the staging writes' tail leaves server RAM before any cell runs. Sizes are env parameters derived from the provisioned server-side caches (D13)." \
  -- bash -c "
    set -euo pipefail
    echo '== phase 1: seq corpus =='
    fio --name=stage-seq --filename='$CORPUS_DIR/seq-corpus.bin' \
        --rw=write --bs=1M --ioengine=libaio --iodepth=4 --direct=1 \
        --numjobs=$SEQ_JOBS --offset_increment=${SEQ_SLICE_GIB}G --size=${SEQ_SLICE_GIB}G \
        --group_reporting --output-format=json+ --status-interval=1
    echo '== phase 2: randr one-touch regions =='
    fio --name=stage-regions --directory='$CORPUS_DIR' \
        --filename_format='region-\$jobnum.bin' \
        --rw=write --bs=1M --ioengine=libaio --iodepth=4 --direct=1 \
        --numjobs=$STAGE1_RANDR_REGIONS --size=${STAGE1_RANDR_REGION_GIB}G \
        --group_reporting --output-format=json+ --status-interval=1
    echo '== phase 3: eviction pass (full seq-corpus read) =='
    fio --name=evict --filename='$CORPUS_DIR/seq-corpus.bin' \
        --rw=read --bs=1M --ioengine=libaio --iodepth=4 --direct=1 \
        --numjobs=$SEQ_JOBS --offset_increment=${SEQ_SLICE_GIB}G --size=${SEQ_SLICE_GIB}G \
        --group_reporting --output-format=json+ --status-interval=1
  "
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "FATAL: staging failed (rc=$RC) — marker NOT written; fix and re-run." >&2
  exit "$RC"
fi

# Verify the files exist at full size before writing the marker.
FAIL=0
seq_bytes=$(stat -c %s "$CORPUS_DIR/seq-corpus.bin" 2>/dev/null || echo 0)
(( seq_bytes >= STAGE1_SEQ_CORPUS_GIB * 1024 * 1024 * 1024 )) || { echo "FATAL: seq-corpus.bin short ($seq_bytes B)" >&2; FAIL=1; }
for (( r=0; r<STAGE1_RANDR_REGIONS; r++ )); do
  b=$(stat -c %s "$CORPUS_DIR/region-$r.bin" 2>/dev/null || echo 0)
  (( b >= STAGE1_RANDR_REGION_GIB * 1024 * 1024 * 1024 )) || { echo "FATAL: region-$r.bin short ($b B)" >&2; FAIL=1; }
done
(( FAIL == 0 )) || exit 1

{
  echo "staged_utc=$(date -u +%FT%TZ)"
  echo "seq_corpus_gib=$STAGE1_SEQ_CORPUS_GIB"
  echo "randr_region_gib=$STAGE1_RANDR_REGION_GIB"
  echo "randr_regions=$STAGE1_RANDR_REGIONS"
  echo "corpus_dir=$CORPUS_DIR"
} > "$MARKER"
echo "prep: done — corpora staged, evicted, and verified; marker: $MARKER"
