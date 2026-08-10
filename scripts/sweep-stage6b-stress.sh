#!/usr/bin/env bash
# Stage 6.B.2 file-IO stress sweep driver.
#
# Three sub-tiers per `runs/Stage-6-Feature-Extraction.md` 6.B.2:
#
#   B.2.a — Saturation sweep (the main customer-quotable curve)
#     corpus = N=10K × sz=50MB × {FP32, FP16}
#     concurrency ∈ {16, 64, 256}
#     pattern ∈ {random, batched-shuffled, sequential}
#     dtype ∈ {fp32, fp16}
#     = 3 conc × 3 pattern × 2 dtype = 18 cells
#
#   B.2.b — Production scale (100K-file headline cell)
#     corpus = N=100K × sz=50MB × FP32
#     concurrency ∈ {64, 128, 256}
#     pattern = random
#     dtype = fp32
#     = 3 cells
#
#   B.2.c — File-size sensitivity (fixed corpus=30K, conc=64, vary file size)
#     corpus = N=30K × sz ∈ {5, 10, 50, 200} MB × FP32
#     concurrency = 64
#     pattern = random
#     dtype = fp32
#     = 4 cells
#
# Total: 25 cells (18 + 3 + 4). Per cell: 5 min ramp + 10 min steady.
# Total sweep wallclock: ~6 hr.
#
# Required env (set below): CONDA_PREFIX; no LD_PRELOAD needed (no kvikIO/GDS in 6.B).
#
# Usage:
#   ./sweep-stage6b-stress.sh prep              # generate the standard synthetic corpora (one-shot, ~1 hr)
#   ./sweep-stage6b-stress.sh smoke             # single-cell validation (small corpus, short runtime)
#   ./sweep-stage6b-stress.sh b2a               # B.2.a saturation (18 cells)
#   ./sweep-stage6b-stress.sh b2b               # B.2.b production scale (3 cells)
#   ./sweep-stage6b-stress.sh b2c               # B.2.c file-size sensitivity (4 cells)
#   ./sweep-stage6b-stress.sh all               # b2a + b2b + b2c (25 cells)
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
READER="$REPO/scripts/read-feature-files-stage6b.py"
GENERATOR="$REPO/scripts/generate-synthetic-features-stage6b.py"
RECORD="$REPO/scripts/record-run.sh"

[ -x "$PY" ] || { echo "missing python $PY" >&2; exit 1; }
[ -f "$READER" ] || { echo "missing reader $READER" >&2; exit 1; }
[ -f "$GENERATOR" ] || { echo "missing generator $GENERATOR" >&2; exit 1; }
[ -x "$RECORD" ] || { echo "missing record-run.sh $RECORD" >&2; exit 1; }

CORPUS_BASE=${FS_MOUNT}/features-6.B-synthetic

export CONDA_PREFIX="$CONDA_ENV"
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8

# Run a single 6.B.2 stress cell.
#   args: corpus_name, n_processes, pattern, runtime, ramp
# Cell name: stress-<corpus_name>-n<N>-<pattern>
run_cell() {
  local corpus_name="$1"; shift
  local n_processes="$1"; shift
  local pattern="$1"; shift
  local runtime="${1:-600}"; shift || true
  local ramp="${1:-300}"; shift || true

  local corpus_dir="$CORPUS_BASE/$corpus_name"
  [ -d "$corpus_dir" ] || { echo "missing corpus $corpus_dir (run 'prep' first)" >&2; return 2; }

  local cell_name="stress-${corpus_name}-n${n_processes}-${pattern}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.B.2-${cell_name}"

  local note="Stage 6.B.2 cell on fs=${LEG}: corpus=${corpus_name} pattern=${pattern} n_processes=${n_processes} ramp=${ramp}s steady=${runtime}s. WHY: the small-file/metadata substage — structurally NOT bandwidth-bound, so it stays discriminating even under a client-capped ceiling, and it exercises whichever metadata architecture this leg's filesystem uses. Per-file-load latency CSV is the PRIMARY headline source. Cache state recorded as achieved, not asserted (D13)."

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name"
  echo "  corpus=$corpus_dir n=$n_processes pattern=$pattern ramp=${ramp}s steady=${runtime}s"
  echo "=========================================="

  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.B.2 \
    --note "$note" \
    -- "$PY" "$READER" \
       --corpus-dir "$corpus_dir" \
       --pattern "$pattern" \
       --n-processes "$n_processes" \
       --runtime "$runtime" --ramp "$ramp" \
       --latency-csv "$run_dir/per-file-latencies.csv" \
       --summary-json "$run_dir/file-io-summary.json"

  local rc=$?
  echo "[$cell_name] record-run.sh exited rc=$rc"
  return "$rc"
}

prep() {
  echo "=== Stage 6.B.1 — Generate standard synthetic corpus suite ==="
  echo "Corpora: {10K×50MB×fp32, 10K×50MB×fp16, 100K×50MB×fp32, 30K×{5,10,50,200}MB×fp32}"
  echo "Total disk: ~13.75 TB; ~1.5 hr generation time. (200 MB tier restored 2026-05-25.)"

  local cell_name="generate-synthetic-corpora-standard"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.B.1-${cell_name}"

  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.B.1 \
    --note "Stage 6.B.1 prep: generate the standard synthetic corpus suite for 6.B.2/B.3. WHY: corpus generation is itself a real recordable write workload against $FS_MOUNT — a sustained-write data point worth capturing per CLAUDE.md recording philosophy. ⏳ Corpus size is open item 5b: it must exceed the client page cache PLUS the larger of the two filesystems' server-side caches, using ONE identical definition on both legs." \
    -- "$PY" "$GENERATOR" \
       --standard-suite \
       --output-base "$CORPUS_BASE" \
       --n-workers 32 \
       --summary-json "$run_dir/generation-summary.json"
}

smoke() {
  echo "=== Stage 6.B.2 smoke: small corpus + short runtime ==="
  # Quick validation: generate 100 files at 10 MB FP32, sweep n=4 random, ramp=30s runtime=60s
  local smoke_corpus="syn-smoke-N100-sz10MB-fp32"
  local smoke_dir="$CORPUS_BASE/$smoke_corpus"
  if [ ! -d "$smoke_dir" ] || [ "$(ls "$smoke_dir"/*.pt 2>/dev/null | wc -l)" -lt 100 ]; then
    echo "[smoke] generating small corpus first"
    "$PY" "$GENERATOR" --count 100 --file-size-mb 10 --dtype fp32 \
      --output-base "$CORPUS_BASE" --n-workers 8 2>&1 | tail -3
    # Rename generated dir to our smoke name
    if [ -d "$CORPUS_BASE/syn-N100-sz10MB-fp32" ]; then
      mv "$CORPUS_BASE/syn-N100-sz10MB-fp32" "$smoke_dir" 2>/dev/null || true
    fi
  fi

  local cell_name="stress-smoke-${smoke_corpus}-n4-random"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.B.2-${cell_name}"

  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.B.2 \
    --note "Stage 6.B.2 smoke cell — validates reader + recording infra end-to-end." \
    -- "$PY" "$READER" \
       --corpus-dir "$smoke_dir" \
       --pattern random \
       --n-processes 4 \
       --runtime 60 --ramp 30 \
       --latency-csv "$run_dir/per-file-latencies.csv" \
       --summary-json "$run_dir/file-io-summary.json"
}

b2a_saturation() {
  echo "=== Stage 6.B.2.a — Saturation sweep (18 cells) ==="
  # corpus = N=10K × sz=50MB × {fp32, fp16}
  # conc ∈ {16, 64, 256} × pattern ∈ {random, batched-shuffled, sequential}
  for dtype in fp32 fp16; do
    local corpus="syn-N10000-sz50MB-${dtype}"
    for n in 16 64 256; do
      for pat in random batched-shuffled sequential; do
        run_cell "$corpus" "$n" "$pat" 600 300 || echo "  (cell failed; continuing)"
      done
    done
  done
}

b2b_production() {
  echo "=== Stage 6.B.2.b — Production scale (3 cells) ==="
  local corpus="syn-N100000-sz50MB-fp32"
  for n in 64 128 256; do
    run_cell "$corpus" "$n" random 600 300 || echo "  (cell failed; continuing)"
  done
}

b2c_file_size() {
  echo "=== Stage 6.B.2.c — File-size sensitivity (4 cells; 200 MB tier added 2026-05-25) ==="
  for sz in 5 10 50 200; do
    local corpus="syn-N30000-sz${sz}MB-fp32"
    run_cell "$corpus" 64 random 600 300 || echo "  (cell failed; continuing)"
  done
}

all() {
  echo "=== Stage 6.B.2 sweep: b2a + b2b + b2c (25 cells) ==="
  b2a_saturation
  b2b_production
  b2c_file_size
  echo ""
  echo "=== Stage 6.B.2 sweep done. Aggregate with: $REPO/scripts/aggregate-stage6b.py ==="
}

case "${1:-}" in
  prep)   prep ;;
  smoke)  smoke ;;
  b2a)    b2a_saturation ;;
  b2b)    b2b_production ;;
  b2c)    b2c_file_size ;;
  all)    all ;;
  *)
    echo "usage: $0 {prep|smoke|b2a|b2b|b2c|all}" >&2
    exit 2
    ;;
esac
