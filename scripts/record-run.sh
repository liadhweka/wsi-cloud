#!/usr/bin/env bash
# record-run.sh — wrap a benchmark command with full pre/during/post recording.
#
# Usage:
#   record-run.sh --fs <weka|lustre> --run-name <name> --stage <N> [--note "..."] -- <cmd> [args...]
#
# --fs is REQUIRED, but may be supplied by the environment instead of the flag:
# if omitted it falls back to $LEG (set by env.sh, exported by
# run-leg.sh). With neither set the wrapper REFUSES — an unlabelled cell cannot
# be attributed to a filesystem, so the head-to-head cannot be assembled.
#
# Captures, all in runs/<utc-timestamp>-<fs>-s<stage>-<name>/:
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
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$RUN_NAME" ]] && { echo "missing --run-name" >&2; exit 2; }

# Repeat index (D18): REP=2 / REP=3 re-runs of a headline cell get their own run
# dirs, distinguishable by name and groupable by the metadata field below —
# aggregation reports median + spread for a config with multiple reps.
[[ -n "${REP:-}" ]] && RUN_NAME="${RUN_NAME}-rep${REP}"
[[ -z "$STAGE" ]]    && { echo "missing --stage"    >&2; exit 2; }
# The sweep drivers take no ENVIRONMENT arguments — several do take a positional
# target (see run-leg.sh's plan comment) — so none of them pass --fs; they inherit
# $LEG from the sourced env.sh / from run-leg.sh's
# `export LEG`. Falling back to $LEG is NOT a convenience default: it is explicit
# configuration, and with neither the flag nor LEG set we still refuse.
if [[ -z "${FS:-}" ]]; then
  FS="${LEG:-}"
fi
if [[ -z "$FS" ]]; then
  echo "missing --fs (weka|lustre), and \$LEG is unset" >&2
  echo "  Every run must be attributable to a filesystem, or the head-to-head" >&2
  echo "  comparison cannot be assembled. See docs/STAGES.md D11." >&2
  echo "  Fix: source env.sh (which sets LEG), or pass --fs." >&2
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
# jq builds metadata.json's command/note fields, and at cleanup the wallclock +
# cost_inputs block. Without it the heredoc below interpolates EMPTY strings and
# writes syntactically invalid JSON ("command": ,) for every cell of the leg, while
# the cost inputs — which thesis §4 says cannot be reconstructed after the fact —
# are dropped with no error at all. Refuse here rather than corrupt output at the end.
command -v jq >/dev/null 2>&1 || {
  echo "FATAL: jq is not installed — metadata.json and the cost inputs cannot be written." >&2
  echo "       Install it before running any cell (the bootstrap installs it; dnf install jq if missing)." >&2
  exit 2
}

CMD=("$@")

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ lives beside runs/, so the runs root is ../runs — NOT "..", which would
# scatter run dirs into the repo root without erroring.
RUNS_ROOT="$(cd "$SCRIPT_DIR/../runs" && pwd)"
REPO_ROOT="$(cd "$RUNS_ROOT/.." && pwd)"
# If the caller pre-computed the run-dir (e.g., to pass paths into the wrapped
# command's args before invoking us), respect it via $RECORD_RUN_DIR. Otherwise
# we pick our own timestamp. Avoids a race where caller and wrapper each call
# `date` and disagree by a second — which leaves the wrapped command writing
# into a run dir the wrapper never created.
if [[ -n "${RECORD_RUN_DIR:-}" ]]; then
  RUN_DIR="$RECORD_RUN_DIR"
  TS=$(basename "$RUN_DIR" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || date -u +%Y-%m-%d-%H%M%S)
else
  TS=$(date -u +%Y-%m-%d-%H%M%S)
  # Run dir name: <UTC-timestamp>-<fs>-s<stage>-<run-name>. The fs segment is
  # load-bearing, not cosmetic: sync-to-s3.sh and teardown-preflight.sh both
  # glob runs/*-$LEG-s*/, so a dir without it is never backed up and the
  # teardown gate does not notice. The stage prefix makes the stage visible in
  # `ls runs/` without reading metadata.
  RUN_DIR="$RUNS_ROOT/${TS}-${FS}-s${STAGE}-${RUN_NAME}"
fi
# Everything that NAMES this run — INDEX.md's entry and 0_README.md's heading —
# uses this, never a name rebuilt from ${TS}-${FS}-s${STAGE}-${RUN_NAME}. The
# rebuilt form is only correct when we chose the dir ourselves: a caller-supplied
# RECORD_RUN_DIR may legitimately use a different shape — sweep-stage7-clinical.sh
# names its dirs -s7- while passing --stage 7.1/7.3/7.4/7.6 — and the index would
# then point at a directory that does not exist on disk.
RUN_ID="$(basename "$RUN_DIR")"

mkdir -p "$RUN_DIR/pre" "$RUN_DIR/post" "$RUN_DIR/raw/.pids" "$RUN_DIR/plots"

# Per-filesystem recorder set (D-4). The WEKA set below is written against this
# instance's live streams. The Lustre set must be written against the live
# /proc/fs/lustre and `lctl get_param` streams on the provisioned Leg-B cluster —
# never from a recalled format — so until that build exists, recording a lustre
# cell would produce a run with a hole where that leg's Primary sources belong,
# which the INCOMPLETE flag would catch only after the wallclock is spent.
# Refuse up front instead.
if [[ "$FS" == "lustre" ]]; then
  echo "FATAL: the Lustre recorder adapter is not built (SCRIPT-TRACKER D-4, Lustre half)." >&2
  echo "       Build it on the Leg-B instance against the live stats streams, then" >&2
  echo "       extend the per-leg recorder set and required-stream list here." >&2
  exit 2
fi

# Kernel netdevs, discovered not named ("capture every device, let analysis pick
# the active ones"). On the WEKA leg these are Diagnostic — DPDK owns the data
# NICs, which are invisible to the kernel — EXCEPT on 1.7, whose S3 source
# traffic rides the kernel TCP stack and makes them Primary on both legs
# (Stage-1 roadmap). On the Lustre leg they are the data path itself.
NETDEVS=$(for n in /sys/class/net/*; do b=$(basename "$n"); [[ "$b" == lo ]] && continue; echo "$b"; done | tr '\n' ' ')

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

  # Kernel netdev cumulative counters (snapshot only — also polled during the run)
  for iface in $NETDEVS; do
    if [[ -d "/sys/class/net/$iface/statistics" ]]; then
      {
        echo "interface=$iface"
        echo "timestamp=$(date -u +%FT%TZ)"
        for stat in /sys/class/net/$iface/statistics/*; do
          echo "$(basename "$stat")=$(cat "$stat")"
        done
      } > "$dir/netdev-counters-$iface.txt"
    fi
  done

  # cuFile / GDS state — the per-cell I/O-path provenance (D8, D-6): the loaded
  # nvidia-fs accounting verbatim, its enable switches, and the cuFile config the
  # cell would run under. A config flag is not proof of behaviour, but WHICH
  # config and WHETHER the counters were on must be on record per cell.
  dump "$dir/nvidia-fs-stats.txt"      cat /proc/driver/nvidia-fs/stats
  dump "$dir/nvidia-fs-params.txt"     bash -c 'grep -H . /sys/module/nvidia_fs/parameters/* 2>/dev/null'
  [[ -n "${CUFILE_ENV_PATH_JSON:-}" && -f "${CUFILE_ENV_PATH_JSON:-}" ]] && \
    dump "$dir/cufile-config.json"     cat "$CUFILE_ENV_PATH_JSON"
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

# ---------- core accounting + declared cache regime (D15 / D13 destinations) ----------
# Same contract as the cost inputs at cleanup: read from documented variables
# (docs/NAMING-AND-VARIABLES.md), recorded as null and warned about when unset --
# never guessed. The storage client's reserved-core set is a per-filesystem,
# per-instance MEASURED input (WEKA reserves cores for its DPDK data path; the
# Lustre client reserves none -- set 'none' there, which records []). Aggregators
# REFUSE a run whose cores_reserved is null, because an application-CPU mean over
# an unknown exclusion set is a polluted number that looks correct.
CORES_TOTAL=$(nproc)
if [[ -n "${FS_CLIENT_RESERVED_CORES:-}" ]]; then
  if [[ "$FS_CLIENT_RESERVED_CORES" == "none" ]]; then
    RESERVED_JSON="[]"
    CORES_AVAIL=$CORES_TOTAL
  else
    # Expand "a-b,c,d" into a JSON int list.
    RESERVED_JSON=$(awk -v s="$FS_CLIENT_RESERVED_CORES" 'BEGIN{
      n = split(s, parts, ","); out = "";
      for (i = 1; i <= n; i++) { p = parts[i];
        if (split(p, ab, "-") == 2) { for (j = ab[1]+0; j <= ab[2]+0; j++) out = out (out=="" ? "" : ",") j }
        else out = out (out=="" ? "" : ",") p+0 }
      print "[" out "]" }')
    RESERVED_N=$(jq 'length' <<<"$RESERVED_JSON")
    CORES_AVAIL=$(( CORES_TOTAL - RESERVED_N ))
  fi
else
  log "WARN: FS_CLIENT_RESERVED_CORES unset -- cores_reserved recorded as null, and CPU"
  log "      aggregation will REFUSE this run. The set is a per-filesystem measured input"
  log "      (D15): set it in env.sh from the client's own report ('none' on a leg that"
  log "      reserves none)."
  RESERVED_JSON=null
  CORES_AVAIL=null
fi
if [[ -n "${RECORD_CACHE_STATE:-}" ]]; then
  CACHE_JSON=$(jq -n --arg c "$RECORD_CACHE_STATE" '$c')
else
  log "WARN: RECORD_CACHE_STATE unset -- cache_state recorded as null. Read cells must"
  log "      declare their cache regime (D13); drivers set it per cell."
  CACHE_JSON=null
fi

cat > "$RUN_DIR/metadata.json" <<EOF
{
  "run_name": "$RUN_NAME",
  "stage": "$STAGE",
  "fs": "$FS",
  "fs_mount": "${FS_MOUNT:-unset}",
  "fs_transport": $(if [[ -n "${FS_TRANSPORT:-}" ]]; then jq -n --arg t "$FS_TRANSPORT" '$t'; else echo null; fi),
  "timestamp_utc": "$META_TS",
  "hostname": "$HN",
  "user": "${USER:-unknown}",
  "kernel": "$KR",
  "cores_total": $CORES_TOTAL,
  "cores_reserved": $RESERVED_JSON,
  "cores_available": $CORES_AVAIL,
  "cache_state": $CACHE_JSON,
  "rep": ${REP:-null},
  "command": $CMD_JSON,
  "note": $NOTE_JSON
}
EOF

# Plain-English README at the top of the run dir. Auto-generated; no extra
# args from the caller. Future humans (or future Claude sessions) can read
# this and immediately understand what this run was without parsing JSON.
cat > "$RUN_DIR/0_README.md" <<EOF
# ${RUN_ID}

**Filesystem:** ${FS} (mounted at ${FS_MOUNT:-unset})
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
- \`raw/\` — during-run time series at 1-second resolution. The recorder set is
  per-filesystem (\`docs/RUNBOOK.md\` holds each leg's Primary-vs-Diagnostic
  table). On this leg:
  - \`weka-stats.csv\` — per-process cluster stats, 1 Hz poll (filter \`Mode==client\` for this client).
  - \`nvidia-smi.csv\` — per-GPU per-second.
  - \`sar-{cpu,disk,net,mem,swap,paging,queue,ctxsw}.csv\` — host-side categories.
  - \`netdev-counters.csv\` — kernel NIC counters (Diagnostic here — DPDK bypasses
    the kernel — except on 1.7, where the S3 source traffic makes them Primary).
  - \`rdma-counters.csv\` — RDMA/EFA device counters; header-only where no such device exists.
  - \`nvidia-fs-stats.log\` — verbatim 1 Hz nvidia-fs accounting (cuFile path proof, D8).
- \`post/\` — same snapshot taken after the run, for delta computation.
- \`results.json\` — parsed aggregates. Re-runnable any time via \`scripts/parse-results.py <this-dir>\`.

## Project context

This run is part of the WEKA-vs-Lustre WSI storage comparison on AWS.
- \`CLAUDE.md\` — project rules (docs citation, memory hygiene, recording philosophy).
- \`${REPO_ROOT}/docs/STAGES.md\` — the \`--stage\` code map, the per-leg plan, and the cross-stage decision register.
- \`${REPO_ROOT}/docs/RUNBOOK.md\` — operational runbook (how to run, how to re-parse, how to recover from failures).
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

# (4) Kernel netdev counters from /sys/class/net/<iface>/statistics/, all
# non-lo interfaces. On the WEKA leg this is control-plane only — DPDK owns the
# data NICs, invisible here — EXCEPT on 1.7, where the S3 source traffic rides
# the kernel stack and this stream is Primary on both legs. On the Lustre leg
# it is the data path (ENA) or its control plane (EFA), per the RUNBOOK table.
{
  echo "timestamp,interface,tx_bytes,rx_bytes,tx_packets,rx_packets,tx_dropped,rx_dropped,tx_errors,rx_errors"
  while true; do
    ts=$(date -u +%FT%T.%3NZ)
    for iface in $NETDEVS; do
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
} > "$RUN_DIR/raw/netdev-counters.csv" 2> "$RUN_DIR/raw/netdev-counters.err" &
echo $! > "$PIDS_DIR/netdev-counters.pid"

# (5) RDMA-device counters from /sys/class/infiniband/<dev>/ports/1/. Absent on
# the WEKA-on-AWS leg (header-only file, not in its required list); present on
# an EFA-attached instance, where EFA exposes an ibdev whose byte counters live
# under hw_counters/ rather than the IB-spec counters/ (which count 4-byte
# words). Both shapes captured — every device, analysis picks the active ones.
IB_DEVICES=$(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')
{
  echo "timestamp,ibdev,source,xmit_bytes,rcv_bytes,xmit_packets,rcv_packets"
  while true; do
    ts=$(date -u +%FT%T.%3NZ)
    for ibdev in $IB_DEVICES; do
      cbase=/sys/class/infiniband/$ibdev/ports/1/counters
      hbase=/sys/class/infiniband/$ibdev/ports/1/hw_counters
      if [[ -d "$cbase" ]]; then
        xd=$(cat $cbase/port_xmit_data 2>/dev/null || echo 0)
        rd=$(cat $cbase/port_rcv_data 2>/dev/null || echo 0)
        printf "%s,%s,counters,%d,%d,%s,%s\n" \
          "$ts" "$ibdev" $(( xd * 4 )) $(( rd * 4 )) \
          "$(cat $cbase/port_xmit_packets 2>/dev/null || echo 0)" \
          "$(cat $cbase/port_rcv_packets 2>/dev/null || echo 0)"
      fi
      if [[ -d "$hbase" ]]; then
        printf "%s,%s,hw_counters,%s,%s,%s,%s\n" \
          "$ts" "$ibdev" \
          "$(cat $hbase/tx_bytes 2>/dev/null || echo 0)" \
          "$(cat $hbase/rx_bytes 2>/dev/null || echo 0)" \
          "$(cat $hbase/tx_pkts 2>/dev/null || echo 0)" \
          "$(cat $hbase/rx_pkts 2>/dev/null || echo 0)"
      fi
    done
    sleep 1
  done
} > "$RUN_DIR/raw/rdma-counters.csv" 2> "$RUN_DIR/raw/rdma-counters.err" &
echo $! > "$PIDS_DIR/rdma-counters.pid"

# (6) nvidia-fs accounting, verbatim, 1 Hz — the kernel half of cuFile path
# accounting (D8, D-6). Captured as timestamped raw blocks rather than parsed
# fields: the stats format is version-stamped, and the enabled-under-load field
# set is exactly what D-6 must be written against, so the record keeps the raw
# truth and parsing follows it. Cheap on every cell; REQUIRED on kvikIO cells
# once D-6 wires the requirement.
{
  while true; do
    echo "=== $(date -u +%FT%T.%3NZ)"
    cat /proc/driver/nvidia-fs/stats 2>/dev/null || echo "(unreadable)"
    sleep 1
  done
} > "$RUN_DIR/raw/nvidia-fs-stats.log" 2> "$RUN_DIR/raw/nvidia-fs-stats.err" &
echo $! > "$PIDS_DIR/nvidia-fs-stats.pid"

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

  # Verify recordings produced data — against THIS leg's required-stream list
  # (D-4): the INCOMPLETE rule demands the leg's own Primary streams, not the
  # other leg's. rdma-counters.csv is deliberately NOT required on the WEKA-on-AWS
  # leg (no RDMA devices exist; the file is header-only) but is still captured so
  # an EFA-attached instance records it without a code change. The Lustre list is
  # built with that leg's adapter (the lustre guard above refuses until then).
  case "$FS" in
    weka)   REQUIRED_STREAMS="weka-stats.csv nvidia-smi.csv netdev-counters.csv \
             sar-cpu.csv sar-disk.csv sar-net.csv sar-mem.csv sar-swap.csv sar-paging.csv" ;;
    lustre) REQUIRED_STREAMS="" ;;  # unreachable today: the lustre guard refuses at start (D-4)
  esac
  log "verifying recordings (required set for fs=$FS)..."
  INCOMPLETE=0
  for f in $REQUIRED_STREAMS; do
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

  # ---------- wallclock + cost inputs into metadata.json ----------
  # Two cost figures per cell and per leg (PROJECT-THESIS.md section 4, D7):
  #   infra-only = (instance + filesystem $/hr) x measured wallclock
  #   all-in     = (instance + filesystem + software $/hr) x measured wallclock
  # The wallclock is measured here; the prices are NOT. They are read from documented
  # variables, because prices are FETCHED from current vendor pricing and stamped
  # with the date checked -- never recalled, and never baked into a script. A
  # stale price silently rewrites the conclusion, and an undated one cannot be
  # audited, so an absent price is recorded as null and warned about rather than
  # guessed. A cell with null prices is a cell whose cost cannot be computed --
  # visible, and fixable by re-running nothing but the arithmetic.
  # jq is preflighted at the top, so the only way to get here without a wallclock is
  # an interrupt before the benchmark returned. Say so out loud: a metadata.json with
  # no cost_inputs block is otherwise indistinguishable from one written before the
  # block existed, and neither the wallclock nor the prices can be recovered once the
  # instance is gone.
  if [[ -n "${WALLCLOCK_S:-}" ]]; then
    if [[ -z "${INSTANCE_USD_PER_HR:-}" || -z "${FS_USD_PER_HR:-}" || -z "${SOFTWARE_USD_PER_HR:-}" || -z "${PRICE_CHECKED_UTC:-}" ]]; then
      log "  WARN: cost inputs incomplete (INSTANCE_USD_PER_HR / FS_USD_PER_HR / SOFTWARE_USD_PER_HR /"
      log "        PRICE_CHECKED_UTC). Cost-to-complete cannot be computed for this cell. Set them in"
      log "        env.sh from CURRENT vendor pricing, with the date you checked -- do not recall a price."
      log "        SOFTWARE_USD_PER_HR: the WEKA leg uses the public AWS Marketplace rate; the Lustre leg"
      log "        sets 0 (the FSx service rate is software-inclusive)."
    fi
    jq \
      --argjson wall "$WALLCLOCK_S" \
      --arg startts "$START_TS" --arg endts "$END_TS" \
      --arg inst "${INSTANCE_USD_PER_HR:-}" \
      --arg fsp  "${FS_USD_PER_HR:-}" \
      --arg soft "${SOFTWARE_USD_PER_HR:-}" \
      --arg when "${PRICE_CHECKED_UTC:-}" \
      '. + {
         wallclock_s: $wall,
         started_utc: $startts,
         ended_utc: $endts,
         cost_inputs: {
           instance_usd_per_hr:   (if $inst == "" then null else ($inst | tonumber? // $inst) end),
           filesystem_usd_per_hr: (if $fsp  == "" then null else ($fsp  | tonumber? // $fsp)  end),
           software_usd_per_hr:   (if $soft == "" then null else ($soft | tonumber? // $soft) end),
           price_checked_utc:     (if $when == "" then null else $when end),
           basis: "infra-only = instance+filesystem; all-in = instance+filesystem+software. Both computed per cell (D7). The Lustre software rate is 0 because the FSx service rate is software-inclusive; the WEKA software rate is the public AWS Marketplace rate, dated like every price."
         }
       }' "$RUN_DIR/metadata.json" > "$RUN_DIR/metadata.json.tmp" \
      && mv "$RUN_DIR/metadata.json.tmp" "$RUN_DIR/metadata.json" \
      || log "  WARN: could not add wallclock/cost inputs to metadata.json"
  else
    log "  WARN: no measured wallclock (interrupted before the benchmark returned) —"
    log "        wallclock and cost_inputs were NOT added to metadata.json for this cell."
  fi

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
  # The entry must name the run dir EXACTLY, fs segment included — INDEX.md is the
  # run history, and an entry that omits the filesystem loses the one dimension
  # the whole comparison pivots on. $RUN_ID is the dir's real basename, so this
  # stays true for any caller-supplied RECORD_RUN_DIR.
  echo "- \`${RUN_ID}\` (fs $FS, stage $STAGE, $START_TS, rc=$RC, $STATUS) — ${ESC_NOTE}" \
    >> "$RUNS_ROOT/INDEX.md"

  log "done: $RUN_DIR"
  log "status: $STATUS (rc=$RC)"
}
trap cleanup EXIT INT TERM

# ---------- run the benchmark ----------
log "running: ${CMD[*]}"
START_TS=$(date -u +%FT%TZ)
START_EPOCH=$(date -u +%s)
echo "$START_TS" > "$RUN_DIR/raw/.run_start"

# Run the benchmark with stdout+stderr tee'd to cmd.log.
# We allow non-zero exit codes to flow through to RC without aborting the wrapper.
"${CMD[@]}" > "$RUN_DIR/cmd.log" 2>&1
RC=$?

END_TS=$(date -u +%FT%TZ)
END_EPOCH=$(date -u +%s)
echo "$END_TS" > "$RUN_DIR/raw/.run_end"
WALLCLOCK_S=$(( END_EPOCH - START_EPOCH ))
echo "$WALLCLOCK_S" > "$RUN_DIR/raw/.run_wallclock_s"
log "command exited rc=$RC after ${WALLCLOCK_S}s"

# Trap fires on EXIT — handles recorder shutdown, conversion, snapshot, verify, parse, INDEX update
exit $RC
