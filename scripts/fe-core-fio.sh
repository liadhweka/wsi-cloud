#!/usr/bin/env bash
# fe-core-fio.sh <label>
# ONE fully-recorded fio random-read cell at a FIXED block size. A single-cell spot
# check for varying one client-side knob while holding the cell byte-identical.
#
#   ./fe-core-fio.sh <label>        # <label> names the client config under test
#   ./fe-core-fio.sh <label>-again  # repeat the first label at the end = drift control
#
# The ONLY thing that may change between runs is the knob the label names; the fio
# config is identical every time, sized to keep the client well driven so that a
# flat point means a real cap rather than an under-driven client. direct=1 bypasses
# the page cache, so each cell reads cold from the filesystem.
#
# NOTE: varying the *storage client's* reserved core count is a WEKA-leg-only axis —
# the Lustre client reserves none (D15). Do not read a cross-leg comparison out of a
# label sequence.
#
# ⚠ Not the Phase-0 ceiling capture. This runs ONE block size, and every downstream
# "% of ceiling" must divide by the *block-size-matched* Stage 1.0a-d cell
# (sweep-stage1-{seqw,seqr,randw,randr}.sh sweep 5 block sizes × 7 concurrencies).
set -uo pipefail
LABEL="${1:?usage: $0 <label, e.g. fe8 = current frontend-core count>}"

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
RECORD="$REPO/scripts/record-run.sh"
SCRATCH=${FS_MOUNT}/fio-fe-scratch
STAGE="4.C"
RUN_NAME="clientcfg-${LABEL}-randr-bs64k"
NJOBS=64; IODEPTH=16; BS=64k; SIZE=2G    # 128 GB working set, direct=1

mkdir -p "$SCRATCH"

# One-time scratch layout (unrecorded) so every measured run is pure random-read
# over the SAME reused files.
if [ ! -e "$SCRATCH/randr.0.0" ]; then
  echo "[prep] one-time scratch layout (~128 GB, unrecorded; a few minutes)..."
  fio --name=randr --directory="$SCRATCH" --rw=randread --bs="$BS" \
      --size="$SIZE" --numjobs="$NJOBS" --create_only=1 >/dev/null
fi

TS=$(date -u +%Y-%m-%d-%H%M%S)
export RECORD_RUN_DIR="$REPO/runs/${TS}-${LEG}-s${STAGE}-${RUN_NAME}"
mkdir -p "$RECORD_RUN_DIR"

NOTE="Single-cell fio spot check on fs=${LEG}: randread bs=${BS} numjobs=${NJOBS} iodepth=${IODEPTH} direct=1 on ${SCRATCH} (reused files, so this is a pure read cell). LABEL=${LABEL} = the client configuration being varied across successive runs; record what it means in this note when you use it. Identical config at every label -> a throughput-vs-knob curve. PRIMARY = this leg's filesystem-side source per docs/RUNBOOK.md's per-leg source table (never quote a bypassed source); fio app-level is the cross-check. NOT a %-of-ceiling denominator: one block size only — those come from the block-size-matched Stage 1.0 cells."

"$RECORD" --stage "$STAGE" --run-name "$RUN_NAME" --note "$NOTE" -- \
  fio --name=randr --directory="$SCRATCH" --rw=randread --bs="$BS" \
      --direct=1 --ioengine=libaio --iodepth="$IODEPTH" --numjobs="$NJOBS" \
      --size="$SIZE" --time_based --runtime=60 --ramp_time=10 \
      --group_reporting --output-format=json --output="$RECORD_RUN_DIR/fio.json"

python3 - "$RECORD_RUN_DIR/fio.json" <<'PY' 2>/dev/null || true
import json,sys
r=json.load(open(sys.argv[1]))["jobs"][0]["read"]
gbs=r["bw_bytes"]/1e9; gibs=r["bw_bytes"]/2**30
p99=r["clat_ns"]["percentile"]["99.000000"]/1e3
print(f"\n  fio app-level: {gbs:.2f} GB/s  ({gibs:.2f} GiB/s)  {r['iops']:.0f} IOPS  p99 {p99:.0f} us")
PY
echo "  Run dir: $RECORD_RUN_DIR"
echo "  The primary number is the filesystem-side read for THIS leg — see"
echo "  docs/RUNBOOK.md § What gets recorded for which source that is."
