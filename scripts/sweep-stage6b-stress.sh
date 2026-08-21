#!/usr/bin/env bash
# Stage 6.B.2 file-IO stress sweep driver.
#
# Three sub-tiers per `docs/Stage-6-Feature-Extraction.md` 6.B.2. The grid was
# FIXED AT SUBSTAGE ENTRY (ratified 2026-08-21) against the measured 6.A Tier-2
# file-size distribution (features-6a fingerprint: median 55-66 MB, p10 14-17,
# max 200-240) — 50 MB is the measured-median tier; 5/200 MB bracket the range.
#
#   B.2.a — Saturation sweep (the main customer-quotable curve)
#     corpus = N=10K × sz=50MB × {FP32, FP16}   (~500 GB each — cache-served)
#     concurrency ∈ {16, 64, 256}
#     pattern ∈ {random, batched-shuffled, sequential}
#     dtype ∈ {fp32, fp16}
#     = 3 conc × 3 pattern × 2 dtype = 18 cells
#
#   B.2.b — Production scale (the genuinely COLD headline cells)
#     corpus = N=66,000 × sz=50MB × FP32 = 3.3 TB ≈ 3.0 TiB — the ratified
#     corpus definition (Stage-6 register): past the 2304 GiB
#     client+larger-server-cache floor with ~30% margin, identical on both legs
#     concurrency ∈ {64, 128, 256}, pattern = random
#     = 3 cells
#
#   B.2.c — File-size sensitivity (conc=64, random, fp32; ~500 GB TOTAL per
#     size tier, so N varies inversely with size and every tier stays in ONE
#     cache regime — fixed-N would cross the cold floor mid-tier and confound
#     the size axis with the cache regime)
#     corpus ∈ {N=100K×5MB, N=50K×10MB, N=2.5K×200MB}
#     = 3 cells; the 50 MB point of the curve IS B.2.a's (fp32, n=64, random)
#     cell — identical corpus and config, so it is read, not re-run
#
# Total: 24 cells (18 + 3 + 3). Per cell: 5 min ramp + 10 min steady.
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
FAILED_CELLS=0

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

  # D-30/D13: per-cell regime from the ratified corpus-vs-cache arithmetic
  # (Stage-6 register + cold-cache section, 2026-08-16): a corpus exceeding
  # client RAM (768 GiB) + the LARGER of the two server-side caches (WEKA
  # backends 1536 GiB vs FSx ~768 GiB at 28,800 GiB) = 2304 GiB is cold by
  # construction; anything smaller is server-cache-servable and is labelled and
  # reported as CACHE-SERVED (RUNBOOK pre-cell canary rule), never as cold
  # storage throughput. The threshold is one fixed value on both legs — the
  # identical-corpus-definition rule — so the label derives from the corpus
  # NAME, never from per-leg state. The reader's client-side discard still runs
  # on every cell (uniform client-cold entry; achieved recorded in
  # file-io-summary.json) — the label reflects the server side, which no client
  # action clears.
  local n_files size_mb corpus_gib cache_state regime_note
  n_files=$(sed -n 's/^syn.*-N\([0-9]\+\)-.*$/\1/p' <<<"$corpus_name")
  size_mb=$(sed -n 's/^syn.*-sz\([0-9]\+\)MB-.*$/\1/p' <<<"$corpus_name")
  if [ -z "$n_files" ] || [ -z "$size_mb" ]; then
    echo "[ERR] cannot derive corpus size from name '$corpus_name' — refusing to run an unlabelable cell (D13/D21)" >&2
    return 2
  fi
  corpus_gib=$(( n_files * size_mb / 1024 ))
  if (( corpus_gib > 2304 )); then
    cache_state=cold
    regime_note="Regime: cold by construction — corpus ${corpus_gib} GiB exceeds client RAM + the larger server-side cache (2304 GiB floor, Stage-6 register); client page cache additionally discarded at cell start, achieved recorded in file-io-summary.json."
  else
    cache_state=warm
    regime_note="Regime: warm (cache-served) — corpus ${corpus_gib} GiB sits under the 2304 GiB cold floor (Stage-6 register), so server-side residency can serve the steady-state window regardless of the client-side discard at entry; reported as cache-served, never as cold storage throughput."
  fi

  local note="Stage 6.B.2 cell on fs=${LEG}: corpus=${corpus_name} pattern=${pattern} n_processes=${n_processes} ramp=${ramp}s steady=${runtime}s. WHY: the small-file/metadata substage — structurally NOT bandwidth-bound, so it stays discriminating even under a client-capped ceiling, and it exercises whichever metadata architecture this leg's filesystem uses. Per-file-load latency CSV is the PRIMARY headline source. Cache state recorded as achieved, not asserted (D13). ${regime_note}"

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name"
  echo "  corpus=$corpus_dir n=$n_processes pattern=$pattern ramp=${ramp}s steady=${runtime}s"
  echo "=========================================="

  RECORD_CACHE_STATE="$cache_state" \
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
  (( rc != 0 )) && FAILED_CELLS=$(( FAILED_CELLS + 1 ))
  return "$rc"
}

prep() {
  echo "=== Stage 6.B.1 — Generate standard synthetic corpus suite ==="
  echo "Corpora: {10K×50MB×fp32, 10K×50MB×fp16, 66K×50MB×fp32 (3.0 TiB cold), 100K×5MB, 50K×10MB, 2.5K×200MB}"
  echo "Total disk: ~5.8 TB (~5.3 TiB) — confirm free capacity first."

  local cell_name="generate-synthetic-corpora-standard"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s6.B.1-${cell_name}"

  RECORD_CACHE_STATE=na-write-cell \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.B.1 \
    --note "Stage 6.B.1 prep: generate the standard synthetic corpus suite for 6.B.2/B.3. WHY: corpus generation is itself a real recordable write workload against $FS_MOUNT — a sustained-write data point worth capturing per CLAUDE.md recording philosophy. Corpus sizing is the ratified Stage-6 register decision (production-scale corpus past the 2304 GiB cold floor; one identical definition on both legs); the per-(N_files, file_size, dtype) grid is fixed at substage entry against the measured 6.A Tier-2 file-size distribution." \
    -- "$PY" "$GENERATOR" \
       --standard-suite \
       --output-base "$CORPUS_BASE" \
       --n-workers 32 \
       --summary-json "$run_dir/generation-summary.json"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
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

  RECORD_CACHE_STATE=warm \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage 6.B.2 \
    --note "Stage 6.B.2 smoke cell — validates reader + recording infra end-to-end. Regime: warm (cache-served) — the smoke corpus is far under the 2304 GiB cold floor; steady-state cache-served by construction. Diagnostic only, never quote." \
    -- "$PY" "$READER" \
       --corpus-dir "$smoke_dir" \
       --pattern random \
       --n-processes 4 \
       --runtime 60 --ramp 30 \
       --latency-csv "$run_dir/per-file-latencies.csv" \
       --summary-json "$run_dir/file-io-summary.json"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
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
  echo "=== Stage 6.B.2.b — Production scale, cold corpus (3 cells) ==="
  local corpus="syn-N66000-sz50MB-fp32"
  for n in 64 128 256; do
    run_cell "$corpus" "$n" random 600 300 || echo "  (cell failed; continuing)"
  done
}

b2c_file_size() {
  echo "=== Stage 6.B.2.c — File-size sensitivity (3 cells; the 50MB point is B.2.a's fp32/n64/random cell) ==="
  for pair in "5:100000" "10:50000" "200:2500"; do
    local sz="${pair%%:*}" count="${pair##*:}"
    local corpus="syn-N${count}-sz${sz}MB-fp32"
    run_cell "$corpus" 64 random 600 300 || echo "  (cell failed; continuing)"
  done
}

all() {
  echo "=== Stage 6.B.2 sweep: b2a + b2b + b2c (24 cells) ==="
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

if (( FAILED_CELLS > 0 )); then
  echo "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation)," >&2
  echo "        and this exit tells the chain a hole exists rather than letting the step be marked done." >&2
  exit 1
fi
