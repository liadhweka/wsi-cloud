#!/usr/bin/env bash
# fe-core-fio.sh <label>
# Frontend-core scaling experiment. Runs the SAME fio random-read at whatever the
# wekafs client's current frontend-core count is, fully recorded (weka stats +
# RDMA + fio app-level). Run once per core count -> throughput-vs-cores curve.
#
#   ./fe-core-fio.sh fe8      # baseline at current cores
#   <colleague adds cores; client container restarts>
#   ./fe-core-fio.sh fe12
#   ./fe-core-fio.sh fe16 ...
#   ./fe-core-fio.sh fe8b     # re-run baseline at the end = drift control
#
# The ONLY thing that changes between runs is the frontend-core count. Same fio
# config every time, sized to saturate a high core count so a flat point means a
# real cap (not an under-driven client). direct=1 = cold (no page cache).
set -uo pipefail
LABEL="${1:?usage: $0 <label, e.g. fe8 = current frontend-core count>}"

# Repo root derived from this script's own location (runs/lib -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source cloud-setup/env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
RECORD="$REPO/runs/lib/record-run.sh"
SCRATCH=${FS_MOUNT}/fio-fe-scratch
STAGE="4.C"
RUN_NAME="frontend-core-${LABEL}-randr-bs64k"
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
export RECORD_RUN_DIR="$REPO/runs/${TS}-s${STAGE}-${RUN_NAME}"
mkdir -p "$RECORD_RUN_DIR"

NOTE="Frontend-core scaling. fio randread bs=${BS} numjobs=${NJOBS} iodepth=${IODEPTH} direct=1 on ${SCRATCH} (reused files). LABEL=${LABEL} = current wekafs client FRONTEND core count (confirm live: sudo weka local resources). Same config at every core count -> throughput-vs-cores curve. PRIMARY metric = WEKA-side Read (weka stats) + RDMA rcv; fio app-level is the cross-check."

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
echo "  WEKA-side read (the primary number): $RECORD_RUN_DIR/raw/weka-stats.csv"
