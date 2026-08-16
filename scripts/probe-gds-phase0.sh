#!/usr/bin/env bash
# probe-gds-phase0.sh — the D8 Phase-0 determination: three recorded Stage-0
# cells that settle the WEKA-GDS question empirically before the GPU-direct
# matrix is committed (PROJECT-THESIS.md 5.2, STAGES.md D8).
#
#   A  kvikio compat OFF + cufile allow_compat_mode=true   cuFile engaged; its
#      own accounting says GDS vs bounced under the standing config
#   B  kvikio compat OFF + cufile allow_compat_mode=false  strict: true GDS
#      works, or the cuFile layer refuses — either answer is the determination
#   C  kvikio compat ON                                    kvikio's POSIX path;
#      never enters cuFile — proves the three-layer distinction (nvidia-fs must
#      stay at zero here)
#
# gdscheck -p output is captured inside each cell's cmd.log. The test file is
# 1 GiB of urandom prepped before any cell (content irrelevant; zeros risk
# hitting a compression/sparse fast path). Reads are backend-RAM-resident by
# construction — the PATH is the question, not the rate (na-path-determination).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh}"
: "${LEG:?LEG is unset -- source env.sh}"
: "${LIBCUFILE_PRELOAD:?LIBCUFILE_PRELOAD is unset -- the bootstrap exports it; a kvikIO cell without it silently runs the bundled conda-env libcufile}"
: "${CUFILE_ENV_PATH_JSON:?CUFILE_ENV_PATH_JSON is unset -- source env.sh}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
: "${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENVS_DIR/$CONDA_ENV_MAIN/bin/python"
RECORD="$REPO/scripts/record-run.sh"
PROBE="$REPO/scripts/probe-gds-phase0.py"

TESTDIR="$FS_MOUNT/benchmarks/gds-phase0"
TESTFILE="$TESTDIR/testfile.bin"
mkdir -p "$TESTDIR"
if [ ! -s "$TESTFILE" ] || [ "$(stat -c %s "$TESTFILE")" -lt $((1024*1024*1024)) ]; then
  echo "prepping 1 GiB urandom test file at $TESTFILE"
  dd if=/dev/urandom of="$TESTFILE" bs=4M count=256 status=none
fi

# The strict config: allow_compat_mode=false, so cuFile may NOT bounce — the
# hard half of the determination. Generated beside the standing compat config.
STRICT_JSON="$(dirname "$CUFILE_ENV_PATH_JSON")/cufile-strict-nogds-probe.json"
[ -f "$STRICT_JSON" ] || printf '{\n  "properties": { "allow_compat_mode": false }\n}\n' > "$STRICT_JSON"

GDSCHECK=$(ls /usr/local/cuda*/gds/tools/gdscheck 2>/dev/null | sort -V | tail -1)
[ -n "$GDSCHECK" ] || { echo "gdscheck not found under /usr/local/cuda*/gds/tools — the determination needs it" >&2; exit 1; }

FAILED=0
cell() { # cell <name> <kvikio_compat ON|OFF> <cufile_json> <note-extra>
  local name=$1 kmode=$2 cjson=$3 extra=$4
  local ts run_dir
  ts=$(date -u +%Y-%m-%d-%H%M%S)
  run_dir="$REPO/runs/${ts}-${LEG}-s0-${name}"
  # if ! ...: keeps set -e from aborting the driver on a failed cell — every
  # cell is attempted and the driver fails loud at the end (the same
  # attempt-all-then-exit-nonzero pattern the sweep drivers use).
  if ! RECORD_RUN_DIR="$run_dir" \
       RECORD_KVIKIO_CELL=1 \
       RECORD_CACHE_STATE="na-path-determination" \
       "$RECORD" --stage 0 --run-name "$name" \
         --note "D8 Phase-0 GDS determination cell: $extra. Modes FORCED, never AUTO (three-layer path accounting); gdscheck -p captured in cmd.log; verdict = the recorded path_accounting split, not any config flag. Reads are backend-RAM-resident by construction — the PATH is the question, not the rate." \
         -- env LD_PRELOAD="$LIBCUFILE_PRELOAD" \
                CUFILE_ENV_PATH_JSON="$cjson" \
                KVIKIO_COMPAT_MODE="$kmode" \
                CUDA_VISIBLE_DEVICES=0 \
                PYTHONPATH="$REPO/scripts" \
           bash -c "\"$GDSCHECK\" -p; \"$PY\" \"$REPO/scripts/probe-gds-phase0.py\" \
                    --file \"$TESTFILE\" --kvikio-compat \"${kmode,,}\" \
                    --summary-json \"$run_dir/gds-phase0-summary.json\""; then
    FAILED=$((FAILED+1)); echo "WARN: cell $name failed"
  fi
}

cell "d8gds-kvoff-cufilecompat" OFF "$CUFILE_ENV_PATH_JSON" \
  "A: kvikio compat OFF + cufile allow_compat_mode=true (the standing config) — cuFile engaged, bounce permitted"
cell "d8gds-kvoff-strictgds"    OFF "$STRICT_JSON" \
  "B: kvikio compat OFF + cufile allow_compat_mode=false — strict GDS; a cuFile refusal here IS the no-GDS answer"
cell "d8gds-kvon-posix"         ON  "$CUFILE_ENV_PATH_JSON" \
  "C: kvikio compat ON — kvikio's own POSIX path, never enters cuFile; nvidia-fs must stay zero (posix-by-construction)"

if (( FAILED > 0 )); then
  echo "probe-gds-phase0: $FAILED cell(s) could not determine — fix and re-run" >&2
  exit 1
fi
echo "probe-gds-phase0: all three determination cells recorded — read the path_accounting splits"
