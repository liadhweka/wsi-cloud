#!/usr/bin/env bash
# prove-recording.sh — the throwaway Stage-0 recording proof (D-20), scripted.
#
# Runs one real fio cell end to end through record-run.sh and asserts, each
# with its own named non-zero exit:
#   10  the cell ran and record-run.sh returned 0
#   11  the INDEX.md row for this cell says OK
#   12  the leg's core streams exist with data (defence in depth on top of the
#       wrapper's own required-list verdict, which INDEX OK already encodes)
#   13  results.json carries a non-zero client-summed filesystem-side rate
#       (weka_stats_client — the pattern-#1 series; a present-but-zero series
#       means the client filter matched nothing and the cell measured nothing)
#   14  the run's raw/ telemetry is verifiably in S3 (every local file listed)
#   15  the generic aggregator emits a summary row for the cell
#
# Loud SKIPs, not silent gaps: the two canary assertions (pre-cell exclusivity
# canary as a mechanical check, post-cell cross-source consistency canary) do
# not exist yet — they land with D-7 and D-5 — and this script must gain them
# then. Until it does it says so on every run, because a proof that silently
# proves less than the checklist promises is how one of five checks gets skipped.
#
# Runs on every rebuild BEFORE wallclock is spent. Costs ~1 min and one ~15 s
# fio cell (a real Stage-0 run dir; never deleted, like every run dir).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh}"
: "${LEG:?LEG is unset -- source env.sh}"
: "${S3_BUCKET:?S3_BUCKET is unset -- source env.sh}"

fail() { echo "PROVE-RECORDING FAILED (exit $1): $2" >&2; exit "$1"; }
note() { echo "prove-recording: $*"; }

SCRATCH="$FS_MOUNT/benchmarks/fio-scratch"
mkdir -p "$SCRATCH"

# The name matters: aggregate-sweep.py parses -bs<X>-jobs<N>$ from the dir name,
# so this proof cell doubles as the aggregator-row assertion's input.
NAME="proof-bs1m-jobs4"
TS=$(date -u +%Y-%m-%d-%H%M%S)
export RECORD_RUN_DIR="$REPO/runs/${TS}-${LEG}-s0-${NAME}"

note "running the proof cell: $RECORD_RUN_DIR"
RECORD_CACHE_STATE="na-write-cell" "$REPO/scripts/record-run.sh" \
  --run-name "$NAME" --stage 0 \
  --note "D-20 recording proof: one real fio cell to prove the recording loop, the S3 sync, the INDEX verdict and the aggregator row on this build, before wallclock is spent." \
  -- fio --name=proof --directory="$SCRATCH" --rw=readwrite --rwmixread=50 \
     --bs=1M --size=512M --numjobs=4 --iodepth=4 --ioengine=libaio --direct=1 \
     --runtime=15 --time_based --group_reporting --unlink=1 --output-format=json+ \
  || fail 10 "record-run.sh returned non-zero for the proof cell"

RUN_ID=$(basename "$RECORD_RUN_DIR")

# 11 — INDEX verdict
grep -F "\`${RUN_ID}\`" "$REPO/runs/INDEX.md" | grep -q ', OK)' \
  || fail 11 "INDEX.md row for $RUN_ID is missing or not OK (the wrapper's required-stream verdict failed)"
note "OK  INDEX.md row says OK"

# 12 — core streams exist with data
for f in weka-stats.csv nvidia-smi.csv netdev-counters.csv sar-cpu.csv; do
  [ -s "$RECORD_RUN_DIR/raw/$f" ] && [ "$(wc -l < "$RECORD_RUN_DIR/raw/$f")" -ge 2 ] \
    || fail 12 "core stream raw/$f missing or under 2 lines"
done
note "OK  core streams present with data"

# 13 — client-summed filesystem-side rate is present and non-zero
python3 - "$RECORD_RUN_DIR/results.json" <<'EOF' || fail 13 "weka_stats_client absent, or its client-summed Read+Write rates are zero"
import json, sys
d = json.load(open(sys.argv[1]))
c = d["sources"].get("weka_stats_client") or {}
if not c.get("present"):
    sys.exit(1)
m = c.get("metrics") or {}
rw = (m.get("Read_client_sum") or {}).get("max", 0) + (m.get("Write_client_sum") or {}).get("max", 0)
sys.exit(0 if rw > 0 else 1)
EOF
note "OK  client-summed filesystem-side rate non-zero"

# 14 — every local raw/ file is in S3 after a run-mode sync
"$REPO/scripts/sync-to-s3.sh" --mode run --run-dir "$RECORD_RUN_DIR" >/dev/null \
  || fail 14 "sync-to-s3.sh --mode run failed"
S3_LIST=$(aws s3 ls --recursive "s3://$S3_BUCKET/runs/$LEG/$RUN_ID/raw/" | awk '{print $NF}')
while IFS= read -r f; do
  rel=${f#"$RECORD_RUN_DIR/"}
  echo "$S3_LIST" | grep -qF "$RUN_ID/$rel" \
    || fail 14 "raw file not found in S3 after sync: $rel"
done < <(find "$RECORD_RUN_DIR/raw" -type f ! -path '*/.pids/*')
note "OK  raw telemetry verified in S3 ($(echo "$S3_LIST" | wc -l) objects)"

# 15 — the generic aggregator emits a row for the cell
python3 "$REPO/scripts/aggregate-sweep.py" "$REPO/runs/*-${LEG}-s0-${NAME}" >/dev/null 2>&1 \
  || fail 15 "aggregate-sweep.py did not emit a summary for the proof cell"
SUMMARY="$REPO/runs/s0-proof-summary.csv"
[ -s "$SUMMARY" ] && grep -q "$RUN_ID" "$SUMMARY" \
  || fail 15 "aggregator summary missing the proof cell's row"
note "OK  aggregator emitted the cell's row ($SUMMARY)"

echo
note "SKIP (pending D-7): pre-cell exclusivity/health canary is not mechanical yet — add its assertion here when it lands"
note "SKIP (pending D-5): post-cell cross-source consistency canary does not exist yet — add its assertion here when it lands"
note "SKIP (pending D-4 helper): the fs-pivoted aggregation column is not built yet — assert it here when the shared helper lands"
echo
note "ALL AVAILABLE ASSERTIONS PASSED — recording infrastructure proven on this build."
