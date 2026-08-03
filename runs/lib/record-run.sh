#!/usr/bin/env bash
# record-run.sh — wrap a benchmark command with full pre/during/post recording.
#
# Usage:
#   record-run.sh --run-name <name> --stage <N> [--note "..."] -- <cmd> [args...]
#
# Captures, all in runs/<utc-timestamp>-<name>/:
#   pre/   cluster + host state snapshot (one-shot)
#   raw/   during-run time series at 1-second resolution
#   post/  state snapshot after run (same set as pre/)
#   metadata.json, cmd.txt, cmd.log, results.json (after parsing)
#
# Each recording source streams to its own file in raw/. The wrapper
# verifies every source produced non-empty data and marks the run OK
# or INCOMPLETE in runs/INDEX.md. Do not trust INCOMPLETE runs.

set -uo pipefail

# ---------- arg parsing ----------
RUN_NAME=""
STAGE=""
NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-name) RUN_NAME="$2"; shift 2 ;;
    --stage)    STAGE="$2";    shift 2 ;;
    --fs)       FS="$2";       shift 2 ;;
    --note)     NOTE="$2";     shift 2 ;;
    --)         shift; break ;;
    -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
    *)          echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$RUN_NAME" ]] && { echo "missing --run-name" >&2; exit 2; }
[[ -z "$STAGE" ]]    && { echo "missing --stage"    >&2; exit 2; }
if [[ -z "${FS:-}" ]]; then
  echo "missing --fs (weka|lustre)" >&2
  echo "  Every run must be attributable to a filesystem, or the head-to-head" >&2
  echo "  comparison cannot be assembled. See runs/STAGES.md D11." >&2
  exit 2
fi
case "$FS" in weka|lustre) ;; *) echo "--fs must be weka|lustre, got '$FS'" >&2; exit 2 ;; esac
# The LABEL must match the MOUNT actually in use. A mismatch here is the one error
# that would silently mis-attribute a whole cell to the wrong filesystem.
if [[ -n "${FS_MOUNT:-}" ]]; then
  case "$FS_MOUNT" in
    *"$FS"*) ;;
    *) echo "FATAL: --fs='$FS' disagrees with FS_MOUNT='$FS_MOUNT'." >&2
       echo "       Refusing to record a run whose label may not match the filesystem." >&2
       exit 2 ;;
  esac
fi
[[ $# -eq 0 ]]       && { echo "missing command after --" >&2; exit 2; }

CMD=("$@")

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# If the caller pre-computed the run-dir (e.g., to pass paths into the wrapped
# command's args before invoking us), respect it via $RECORD_RUN_DIR. Otherwise
# we pick our own timestamp. Avoids a race where caller and wrapper each call
# `date` and disagree by a second — diagnosed 2026-05-21 after Stage 6.A
# Tier 2 GigaPath cuCIM cell failed with the extractor writing CSVs to a
# nonexistent dir (run_cell precomputed 154713, record-run picked 154714).
if [[ -n "${RECORD_RUN_DIR:-}" ]]; then
  RUN_DIR="$RECORD_RUN_DIR"
  TS=$(basename "$RUN_DIR" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || date -u +%Y-%m-%d-%H%M%S)
else
  TS=$(date -u +%Y-%m-%d-%H%M%S)
  # Run dir name: <UTC-timestamp>-s<stage>-<run-name>. Stage prefix makes the
  # stage immediately visible in `ls runs/` without needing to read metadata.
  RUN_DIR="$RUNS_ROOT/${TS}-${FS}-s${STAGE}-${RUN_NAME}"
fi

mkdir -p "$RUN_DIR/pre" "$RUN_DIR/post" "$RUN_DIR/raw/.pids" "$RUN_DIR/plots"

# IB netdevs for the IPoIB control-plane capture (the wekafs DATA plane is
# native RDMA, captured separately across ALL /sys/class/infiniband devices
# below). Discover the UP IB netdevs dynamically so the client's actual NIC
# binding is always captured — this was hardcoded to ibp97s0f0/f1, which are
# NOT this client's data NICs after the 2026-07 reinstall (data flows on
# ibp12s0/ibp18s0 = mlx5_0/1). Dynamic discovery also auto-adapts if the client
# is later rebound to more NICs.
IB_NETDEVS=$(for n in /sys/class/net/ib*; do [[ -e "$n" ]] || continue; [[ "$(cat "$n/operstate" 2>/dev/null)" == up ]] && basename "$n"; done | tr '\n' ' ')
[[ -z "$IB_NETDEVS" ]] && IB_NETDEVS="ibp12s0 ibp18s0"

# ---------- helpers ----------
log() { echo "[record-run $(date -u +%FT%TZ)] $*" >&2; }

# Run a command; capture stdout+stderr to file; never abort wrapper on failure.
dump() {
  local out="$1"; shift
  if "$@" > "$out" 2>&1; then
    :
  else
    echo "(failed: $?)" >> "$out"
  fi
}

snapshot() {
  local dir="$1"

  # WEKA cluster state
  dump "$dir/weka-status.txt"          weka status
  dump "$dir/weka-cluster.txt"         weka cluster container
  dump "$dir/weka-alerts.txt"          weka alerts
  dump "$dir/weka-events.txt"          weka events --num-results 200
  dump "$dir/weka-version.txt"         weka version current

  # Host state
  dump "$dir/nvidia-smi-q.txt"         nvidia-smi -q
  dump "$dir/nvidia-smi-topo.txt"      nvidia-smi topo -m
  dump "$dir/df.txt"                   df -hT
  dump "$dir/mount.txt"                mount
  dump "$dir/lsblk.txt"                lsblk -O
  dump "$dir/lsmod.txt"                lsmod
  dump "$dir/uname.txt"                uname -a
  dump "$dir/lscpu.txt"                lscpu
  dump "$dir/free.txt"                 free -h
  dump "$dir/proc-mounts-weka.txt"     bash -c 'grep wekafs /proc/mounts'
  dump "$dir/fio-version.txt"          fio --version
  dump "$dir/python-version.txt"       python3 --version

  # IB cumulative counters (snapshot only — we also poll during the run)
  for iface in $IB_NETDEVS; do
    if [[ -d "/sys/class/net/$iface/statistics" ]]; then
      {
        echo "interface=$iface"
        echo "timestamp=$(date -u +%FT%TZ)"
        for stat in /sys/class/net/$iface/statistics/*; do
          echo "$(basename "$stat")=$(cat "$stat")"
        done
      } > "$dir/ib-counters-$iface.txt"
    fi
  done
}

# ---------- pre-run snapshot ----------
log "pre-run snapshot to $RUN_DIR/pre/"
snapshot "$RUN_DIR/pre"

# ---------- write metadata.json + cmd.txt ----------
{
  printf '%q ' "${CMD[@]}"
  echo
} > "$RUN_DIR/cmd.txt"

CMD_JSON=$(printf '%s\n' "${CMD[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
NOTE_JSON=$(printf '%s' "$NOTE" | jq -R -s -c '.')
META_TS=$(date -u +%FT%TZ)
HN=$(hostname)
KR=$(uname -r)
cat > "$RUN_DIR/metadata.json" <<EOF
{
  "run_name": "$RUN_NAME",
  "stage": "$STAGE",
  "fs": "$FS",
  "fs_mount": "${FS_MOUNT:-unset}",
  "timestamp_utc": "$META_TS",
  "hostname": "$HN",
  "user": "${USER:-unknown}",
  "kernel": "$KR",
  "command": $CMD_JSON,
  "note": $NOTE_JSON
}
EOF

# Plain-English README at the top of the run dir. Auto-generated; no extra
# args from the caller. Future humans (or future Claude sessions) can read
# this and immediately understand what this run was without parsing JSON.
cat > "$RUN_DIR/0_README.md" <<EOF
# ${TS}-s${STAGE}-${RUN_NAME}

**Stage:** ${STAGE}  ·  **Started (UTC):** ${META_TS}
**Hostname:** ${HN}  ·  **User:** ${USER:-unknown}  ·  **Kernel:** ${KR}

## What was tested

Exact command:

\`\`\`
$(printf '%q ' "${CMD[@]}")
\`\`\`

## Why this run exists

${NOTE:-(no note provided)}

## What's in this directory

- \`metadata.json\` — structured metadata (programmatic).
- \`cmd.txt\` / \`cmd.log\` — exact command and tee'd stdout+stderr from the benchmark.
- \`pre/\` — cluster + host state snapshot before the run.
- \`raw/\` — during-run time series at 1-second resolution:
  - \`weka-stats.csv\` — WEKA per-process per-second stats.
  - \`rdma-counters.csv\` — actual RDMA traffic per IB device (the wekafs data path).
  - \`ipoib-counters.csv\` — IPoIB control plane (sanity check, NOT the data path).
  - \`nvidia-smi.csv\` — per-GPU per-second (8 GPUs × ~1Hz).
  - \`sar-{cpu,disk,net,mem,swap,paging,queue,ctxsw}.csv\` — host-side categories.
- \`post/\` — same snapshot taken after the run, for delta computation.
- \`results.json\` — parsed aggregates. Re-runnable any time via \`runs/lib/parse-results.py <this-dir>\`.

## Project context

This run is part of the WEKA WSI benchmarking project.
- \`CLAUDE.md\` — project rules (docs citation, memory hygiene, recording philosophy).
- \`${REPO}/runs/STAGES.md\` — stage breakdown (1.0 = synthetic upper bound, 1.1 = TCGA pilot, etc.).
- \`${REPO}/runs/README.md\` — operational runbook (how to run, how to re-parse, how to recover from failures).
EOF

# ---------- start recorders ----------
log "starting recorders in $RUN_DIR/raw/"
PIDS_DIR="$RUN_DIR/raw/.pids"

# (1) WEKA stats realtime — `--format csv` returns ONE snapshot of all
# processes per invocation, NOT a stream. Poll once per second and prepend
# our own timestamp so we get a real time series.
WEKA_COLS="node,hostname,role,mode,writeps,writebps,wlatency,readps,readbps,rlatency,ops,cpu,l6recv,l6send,upload,download,rdmarecv,rdmasend"
{
  HEADER_PRINTED=0
  while true; do
    out=$(weka stats realtime --format csv --raw-units --UTC --output "$WEKA_COLS" 2>/dev/null)
    if [[ -z "$out" ]]; then sleep 1; continue; fi
    if (( HEADER_PRINTED == 0 )); then
      printf "timestamp,%s\n" "$(echo "$out" | head -1)"
      HEADER_PRINTED=1
    fi
    ts=$(date -u +%FT%T.%3NZ)
    echo "$out" | tail -n +2 | sed "s|^|${ts},|"
    sleep 1
  done
} > "$RUN_DIR/raw/weka-stats.csv" 2> "$RUN_DIR/raw/weka-stats.err" &
echo $! > "$PIDS_DIR/weka-stats.pid"

# (2) sar binary — CPU per-core, disk, net per-iface, mem, swap, paging.
# Note: -A is a display-mode flag that conflicts with -o; recording mode collects
# the full metric set by default. Use -A at conversion time (sadf -- -A) instead.
LANG=C sar -o "$RUN_DIR/raw/sar.bin" 1 \
  > /dev/null 2> "$RUN_DIR/raw/sar.err" &
echo $! > "$PIDS_DIR/sar.pid"

# (3) nvidia-smi per-GPU per-second
nvidia-smi --query-gpu=index,timestamp,utilization.gpu,utilization.memory,memory.used,memory.free,power.draw,temperature.gpu,clocks.current.graphics,clocks.current.memory,pcie.link.gen.current,pcie.link.width.current \
  --format=csv -lms 1000 \
  > "$RUN_DIR/raw/nvidia-smi.csv" 2> "$RUN_DIR/raw/nvidia-smi.err" &
echo $! > "$PIDS_DIR/nvidia-smi.pid"

# (4) IPoIB counters from /sys/class/net/<iface>/statistics/.
# Important: these reflect the IPoIB layer ONLY — wekafs uses native RDMA
# which bypasses this path. Kept as a link/control-plane sanity check.
{
  echo "timestamp,interface,tx_bytes,rx_bytes,tx_packets,rx_packets,tx_dropped,rx_dropped,tx_errors,rx_errors"
  while true; do
    ts=$(date -u +%FT%T.%3NZ)
    for iface in $IB_NETDEVS; do
      base=/sys/class/net/$iface/statistics
      if [[ -d "$base" ]]; then
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
          "$ts" "$iface" \
          "$(cat $base/tx_bytes 2>/dev/null || echo 0)" \
          "$(cat $base/rx_bytes 2>/dev/null || echo 0)" \
          "$(cat $base/tx_packets 2>/dev/null || echo 0)" \
          "$(cat $base/rx_packets 2>/dev/null || echo 0)" \
          "$(cat $base/tx_dropped 2>/dev/null || echo 0)" \
          "$(cat $base/rx_dropped 2>/dev/null || echo 0)" \
          "$(cat $base/tx_errors 2>/dev/null || echo 0)" \
          "$(cat $base/rx_errors 2>/dev/null || echo 0)"
      fi
    done
    sleep 1
  done
} > "$RUN_DIR/raw/ipoib-counters.csv" 2> "$RUN_DIR/raw/ipoib-counters.err" &
echo $! > "$PIDS_DIR/ipoib-counters.pid"

# (5) RDMA counters from /sys/class/infiniband/<ibdev>/ports/1/counters/.
# THIS is the data plane wekafs actually uses. port_xmit_data and
# port_rcv_data are in 4-byte words per the IB spec (multiplied by 4 here
# for bytes). Poll ALL infiniband devices: wekafs's DPDK process binds to
# physical devices that don't necessarily match the kernel netdev's symlink to
# mlx5_X, so we never assume which device carries data — we capture them all and
# let analysis pick the active ones (verified empirically; post-2026-07 the
# a100 client's data flows on mlx5_0 / mlx5_1 = ibp12s0 / ibp18s0).
IB_DEVICES=$(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')
{
  echo "timestamp,ibdev,xmit_bytes,rcv_bytes,xmit_packets,rcv_packets,xmit_wait,xmit_discards"
  while true; do
    ts=$(date -u +%FT%T.%3NZ)
    for ibdev in $IB_DEVICES; do
      base=/sys/class/infiniband/$ibdev/ports/1/counters
      if [[ -d "$base" ]]; then
        xd=$(cat $base/port_xmit_data 2>/dev/null || echo 0)
        rd=$(cat $base/port_rcv_data 2>/dev/null || echo 0)
        xp=$(cat $base/port_xmit_packets 2>/dev/null || echo 0)
        rp=$(cat $base/port_rcv_packets 2>/dev/null || echo 0)
        xw=$(cat $base/port_xmit_wait 2>/dev/null || echo 0)
        xdis=$(cat $base/port_xmit_discards 2>/dev/null || echo 0)
        printf "%s,%s,%d,%d,%s,%s,%s,%s\n" \
          "$ts" "$ibdev" \
          $(( xd * 4 )) $(( rd * 4 )) \
          "$xp" "$rp" "$xw" "$xdis"
      fi
    done
    sleep 1
  done
} > "$RUN_DIR/raw/rdma-counters.csv" 2> "$RUN_DIR/raw/rdma-counters.err" &
echo $! > "$PIDS_DIR/rdma-counters.pid"

# Brief settle so the first sample lands before the benchmark starts
sleep 2

# ---------- cleanup trap ----------
RC=999
# Fallback so cleanup()'s INDEX append stays set -u-safe if the script is interrupted
# before the real START_TS assignment (which happens after the trap is installed below).
START_TS="(pre-start)"
cleanup() {
  log "stopping recorders..."
  for pidfile in "$PIDS_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid=$(cat "$pidfile" 2>/dev/null || echo "")
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  # Allow flush
  sleep 2

  for pidfile in "$PIDS_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid=$(cat "$pidfile" 2>/dev/null || echo "")
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  # Convert sar binary to per-category CSVs.
  # Single sar.csv with -A is multi-section (each category has its own header
  # row), which breaks naive CSV parsers. Per-category outputs are clean.
  if [[ -s "$RUN_DIR/raw/sar.bin" ]]; then
    while IFS=':' read -r name flags; do
      sadf -d "$RUN_DIR/raw/sar.bin" -- $flags \
        > "$RUN_DIR/raw/sar-$name.csv" \
        2>> "$RUN_DIR/raw/sar-convert.err" || true
    done <<EOF
cpu:-u ALL -P ALL
disk:-d
net:-n DEV
mem:-r
swap:-W
paging:-B
queue:-q
ctxsw:-w
EOF
  fi

  # Post-run snapshot (same set as pre/)
  log "post-run snapshot to $RUN_DIR/post/"
  snapshot "$RUN_DIR/post"

  # Verify recordings produced data
  log "verifying recordings..."
  INCOMPLETE=0
  for f in weka-stats.csv nvidia-smi.csv ipoib-counters.csv rdma-counters.csv \
           sar-cpu.csv sar-disk.csv sar-net.csv sar-mem.csv sar-swap.csv sar-paging.csv; do
    path="$RUN_DIR/raw/$f"
    if [[ ! -s "$path" ]]; then
      log "  WARN: $f is missing or empty"
      INCOMPLETE=1
    else
      n=$(wc -l < "$path")
      if (( n < 2 )); then
        log "  WARN: $f has only $n line(s)"
        INCOMPLETE=1
      else
        log "  OK:   $f ($n lines)"
      fi
    fi
  done

  # Run parser
  if [[ -x "$SCRIPT_DIR/parse-results.py" ]]; then
    log "parsing results..."
    "$SCRIPT_DIR/parse-results.py" "$RUN_DIR" \
      > "$RUN_DIR/raw/parse.log" 2>&1 \
      || log "  WARN: parser failed; see raw/parse.log"
  fi

  # Append to INDEX.md
  STATUS=$( (( RC == 0 && INCOMPLETE == 0 )) && echo "OK" || echo "INCOMPLETE" )
  ESC_NOTE=$(printf '%s' "$NOTE" | head -c 200 | tr '\n' ' ')
  echo "- \`${TS}-s${STAGE}-${RUN_NAME}\` (stage $STAGE, $START_TS, rc=$RC, $STATUS) — ${ESC_NOTE}" \
    >> "$RUNS_ROOT/INDEX.md"

  log "done: $RUN_DIR"
  log "status: $STATUS (rc=$RC)"
}
trap cleanup EXIT INT TERM

# ---------- run the benchmark ----------
log "running: ${CMD[*]}"
START_TS=$(date -u +%FT%TZ)
echo "$START_TS" > "$RUN_DIR/raw/.run_start"

# Run the benchmark with stdout+stderr tee'd to cmd.log.
# We allow non-zero exit codes to flow through to RC without aborting the wrapper.
"${CMD[@]}" > "$RUN_DIR/cmd.log" 2>&1
RC=$?

END_TS=$(date -u +%FT%TZ)
echo "$END_TS" > "$RUN_DIR/raw/.run_end"
log "command exited rc=$RC"

# Trap fires on EXIT — handles recorder shutdown, conversion, snapshot, verify, parse, INDEX update
exit $RC
