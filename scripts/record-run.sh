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

# ---------- D-7 pre-cell gate (the mechanical half of RUNBOOK canary #1) ----------
# (1) Chain poison: a prior cell's consistency canary failed and wrote the abort
# marker — every subsequent cell REFUSES until a human fixes the instrumentation
# and deletes it. "The canary aborts the chain itself": on an unattended chain,
# cells recorded after broken instrumentation look fine and are worthless.
if [[ -f "$RUNS_ROOT/.leg-state/$FS/canary-abort" ]]; then
  echo "record-run: REFUSING to start a cell — canary-abort marker present:" >&2
  echo "            $RUNS_ROOT/.leg-state/$FS/canary-abort" >&2
  sed 's/^/            | /' "$RUNS_ROOT/.leg-state/$FS/canary-abort" >&2 || true
  echo "            Fix the instrumentation first (RUNBOOK: disagreement means bugged infra —" >&2
  echo "            every subsequent number depends on it), then delete the marker to re-arm." >&2
  exit 3
fi
# (2) Mount responsive — a hung mount would otherwise burn the whole watchdog window.
if [[ -n "${FS_MOUNT:-}" ]] && ! timeout 10 stat -f "$FS_MOUNT" >/dev/null 2>&1; then
  echo "record-run: REFUSING — \$FS_MOUNT ($FS_MOUNT) did not answer stat within 10 s" >&2
  exit 3
fi
# (3) Runs-root free-space floor (the 2026-08-16 ENOSPC aborted 1.0b mid-sweep):
# refuse BEFORE the cell rather than dying mid-recording. Override: RECORD_MIN_FREE_MB.
_free_kb=$(df --output=avail -k "$RUNS_ROOT" 2>/dev/null | tail -1 | tr -d ' ')
_floor_kb=$(( ${RECORD_MIN_FREE_MB:-2048} * 1024 ))
if [[ -n "$_free_kb" ]] && (( _free_kb < _floor_kb )); then
  echo "record-run: REFUSING — only $(( _free_kb / 1024 )) MB free under $RUNS_ROOT (floor $(( _floor_kb / 1024 )) MB)." >&2
  echo "            Relocate synced raw payloads (D-35) or set RECORD_RAW_ON_SCRATCH=1 for this cell." >&2
  exit 3
fi
# (4) kvikIO cell: nvidia-fs accounting must be READABLE before the cell runs (D-6's
# pre-cell half) — an off/absent accounting records unknown-accounting-off and the
# D8 path proof cannot exist, so the cell would only fail AFTER spending its wallclock.
if [[ "${RECORD_KVIKIO_CELL:-0}" == "1" && ! -r /proc/driver/nvidia-fs/stats ]]; then
  echo "record-run: REFUSING — kvikIO cell, but /proc/driver/nvidia-fs/stats is absent/unreadable:" >&2
  echo "            the cuFile GPU-direct-vs-bounced split would be unprovable (D8/D-6)." >&2
  exit 3
fi

# D-35: a long cell's raw telemetry can exceed the 48 GB root volume's headroom
# (a ~25 h cell writes ~30 GB of 1 Hz series; the 4.D BRCA cell wrote 18 GB in
# 15.7 h). With RECORD_RAW_ON_SCRATCH=1, raw/ is created ON the local-NVMe
# overflow and symlinked into the run dir — the same layout the post-sync
# relocation produces, so parsers and the S3 sync (which follows symlinks) see
# no difference; S3 stays authoritative and scratch stays ephemeral either way.
if [[ "${RECORD_RAW_ON_SCRATCH:-0}" == "1" && -n "${SCRATCH_DIR:-}" && ! -e "$RUN_DIR/raw" ]]; then
  _raw_ovf="$SCRATCH_DIR/runs-raw-overflow/${RUN_ID}-raw"
  mkdir -p "$_raw_ovf" "$RUN_DIR"
  ln -s "$_raw_ovf" "$RUN_DIR/raw"
  echo "[record-run] raw/ on scratch overflow: $_raw_ovf (RECORD_RAW_ON_SCRATCH=1)" >&2
fi

mkdir -p "$RUN_DIR/pre" "$RUN_DIR/post" "$RUN_DIR/raw/.pids" "$RUN_DIR/plots"

# Per-filesystem recorder set (D-4). Each leg's set is written against that
# instance's LIVE streams, never a recalled format: the WEKA set on the Leg-A
# instance; the Lustre set on the 2026-08-21 Leg-B build (llite/osc/mdc stats
# and `lnetctl net show -v 4` shapes derived from the running client, and
# capture-verified by that build's stage-0 recording proof).

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

  if [[ "$FS" == "weka" ]]; then
    # WEKA cluster state
    dump "$dir/weka-status.txt"          weka status
    dump "$dir/weka-cluster.txt"         weka cluster container
    dump "$dir/weka-alerts.txt"          weka alerts
    dump "$dir/weka-events.txt"          weka events --num-results 200
    dump "$dir/weka-version.txt"         weka version current
    dump "$dir/proc-mounts-weka.txt"     bash -c 'grep wekafs /proc/mounts'
  else
    # Lustre client + file-system state. The stats live in root-only debugfs and
    # lnetctl needs /dev/lnet, so those run under sudo -n (passwordless on this
    # box by build); lfs runs unprivileged. The cumulative stats / rpc_stats /
    # read_ahead_stats snapshots give whole-run deltas as defence in depth under
    # the 1 Hz series, and the getstripe/tunables dumps pin the layout (D12/L2)
    # and the D-11 set the cell actually ran under.
    dump "$dir/lfs-df.txt"               lfs df -h
    dump "$dir/lfs-df-inodes.txt"        lfs df -i
    dump "$dir/lustre-version.txt"       lctl get_param version
    dump "$dir/lfs-getstripe-root.txt"   lfs getstripe -d "${FS_MOUNT:-/mnt/lustre}"
    dump "$dir/lctl-devices.txt"         sudo -n lctl dl
    dump "$dir/lustre-health.txt"        sudo -n lctl get_param health_check
    dump "$dir/lustre-stats-cumulative.txt" sudo -n lctl get_param 'llite.*.stats' 'osc.*OST*.stats' 'mdc.*MDT*.stats'
    dump "$dir/lustre-rpc-stats.txt"     sudo -n lctl get_param 'osc.*OST*.rpc_stats'
    dump "$dir/lustre-readahead.txt"     sudo -n lctl get_param 'llite.*.read_ahead_stats'
    dump "$dir/lustre-tunables.txt"      sudo -n lctl get_param 'ldlm.namespaces.*.lru_max_age' 'ldlm.namespaces.*.lru_size' 'osc.*OST*.max_rpcs_in_flight' 'mdc.*.max_rpcs_in_flight' 'mdc.*.max_mod_rpcs_in_flight' 'llite.*.statahead_max' 'llite.*.statahead_agl'
    dump "$dir/lnet-net-show.txt"        sudo -n lnetctl net show -v 4
    dump "$dir/lnet-stats-show.txt"      sudo -n lnetctl stats show
    dump "$dir/proc-mounts-lustre.txt"   bash -c 'grep lustre /proc/mounts'
  fi

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
  CACHE_UNDECLARED=0
else
  CACHE_JSON=null
  # D-30 (ratified 2026-08-16): a measured cell with no declared cache regime is
  # INCOMPLETE, not OK — an unlabelled read number gets quoted as whichever regime
  # flatters it, invisibly (D13). Write cells declare "na-write-cell"; regimes that
  # are deliberately not an axis declare an "na-*" value (NOT_APPLICABLE to the
  # reconciler). Stage 0 stays exempt: infra proofs measure the recorder, not storage.
  if [[ "$STAGE" == "0" ]]; then
    log "WARN: RECORD_CACHE_STATE unset -- cache_state recorded as null (stage 0: allowed)."
    CACHE_UNDECLARED=0
  else
    log "WARN: RECORD_CACHE_STATE unset on a stage-$STAGE cell -- this cell will be marked"
    log "      INCOMPLETE (D-30/D13): every measured cell declares its cache regime, write"
    log "      cells included ('na-write-cell'). Drivers set it per cell."
    CACHE_UNDECLARED=1
  fi
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
  "bs_hint": $(if [[ -n "${RECORD_BS_HINT:-}" ]]; then jq -n --arg b "$RECORD_BS_HINT" '$b'; else echo null; fi),
  "wire_exempt": $(if [[ -n "${RECORD_WIRE_EXEMPT:-}" ]]; then jq -n --arg w "$RECORD_WIRE_EXEMPT" '$w'; else echo null; fi),
  "rep": ${REP:-null},
  "command": $CMD_JSON,
  "note": $NOTE_JSON
}
EOF

# Plain-English README at the top of the run dir. Auto-generated; no extra
# args from the caller. Future humans (or future Claude sessions) can read
# this and immediately understand what this run was without parsing JSON.
# The raw/ stream list is per-leg (D-4) — each leg documents its own set.
if [[ "$FS" == "weka" ]]; then
  RAW_STREAMS_DOC='  - `weka-stats.csv` — per-process cluster stats, 1 Hz poll (filter `Mode==client` for this client).
  - `nvidia-smi.csv` — per-GPU per-second.
  - `sar-{cpu,disk,net,mem,swap,paging,queue,ctxsw}.csv` — host-side categories.
  - `netdev-counters.csv` — kernel NIC counters (Diagnostic here — DPDK bypasses
    the kernel — except on 1.7, where the S3 source traffic makes them Primary).
  - `rdma-counters.csv` — RDMA/EFA device counters; header-only where no such device exists.
  - `nvidia-fs-stats.log` — verbatim 1 Hz nvidia-fs accounting (cuFile path proof, D8).'
else
  RAW_STREAMS_DOC='  - `lustre-stats.log` — verbatim 1 Hz cumulative llite (client VFS) / osc (per-OST
    RPC) / mdc (per-MDT metadata) stats blocks; the parser derives per-second rates.
    The quotable client series is the OSC bytes summed across OSTs (llite is blind
    to libaio traffic — diagnostic only).
  - `lnet-stats.log` — verbatim 1 Hz `lnetctl net show -v 4` blocks: the per-cell
    transport proof (D16 — data on the efa net, tcp near-flat).
  - `rdma-counters.csv` — EFA hw_counters byte/packet rates: the wire-level Primary
    on this leg (the client NIC IS the data path).
  - `nvidia-smi.csv` — per-GPU per-second.
  - `sar-{cpu,disk,net,mem,swap,paging,queue,ctxsw}.csv` — host-side categories.
  - `netdev-counters.csv` — kernel NIC counters (the tcp/metadata side here).
  - `nvidia-fs-stats.log` — verbatim 1 Hz nvidia-fs accounting (cuFile path proof, D8).'
fi
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
${RAW_STREAMS_DOC}
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

if [[ "$FS" == "weka" ]]; then
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
else
  # (1L) Lustre client stats, verbatim 1 Hz blocks (D-4): cumulative llite
  # (client VFS level) / osc (per-OST RPC level) / mdc (per-MDT metadata)
  # counters; the parser derives rates from consecutive blocks against the
  # real dt. The stats live in root-only debugfs, so the whole loop runs under
  # ONE sudo -n. It stops on the sentinel file — an unprivileged cleanup
  # cannot signal a root process — and also exits when the wrapper dies, so a
  # kill -9 on the wrapper (no cleanup, sentinel left behind) cannot leave a
  # root loop appending forever.
  touch "$PIDS_DIR/lustre-recorders.alive"
  sudo -n bash -c '
    while [[ -e "$1" ]] && kill -0 "$2" 2>/dev/null; do
      echo "=== $(date -u +%FT%T.%3NZ)"
      lctl get_param "llite.*.stats" "osc.*OST*.stats" "mdc.*MDT*.stats" 2>/dev/null || echo "(unreadable)"
      sleep 1
    done' _ "$PIDS_DIR/lustre-recorders.alive" "$$" \
    > "$RUN_DIR/raw/lustre-stats.log" 2> "$RUN_DIR/raw/lustre-stats.err" &

  # (2L) LNet per-net counters, verbatim 1 Hz — the per-cell transport proof
  # (D16): app bytes moving while the efa net's counters stay near-flat is
  # exactly the silent tcp fallback this leg refuses to measure. Reads
  # /dev/lnet (root-only): same sudo + sentinel discipline as (1L).
  sudo -n bash -c '
    while [[ -e "$1" ]] && kill -0 "$2" 2>/dev/null; do
      echo "=== $(date -u +%FT%T.%3NZ)"
      lnetctl net show -v 4 2>/dev/null || echo "(unreadable)"
      sleep 1
    done' _ "$PIDS_DIR/lustre-recorders.alive" "$$" \
    > "$RUN_DIR/raw/lnet-stats.log" 2> "$RUN_DIR/raw/lnet-stats.err" &
fi

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
  # If the wrapper dies while the command still runs (chain TERM, ctrl-C), take
  # the command's process group down with us — a setsid'd child would otherwise
  # orphan and keep writing into a cell the INDEX will call INCOMPLETE (D-7).
  if [[ -n "${CMD_PID:-}" ]] && kill -0 "$CMD_PID" 2>/dev/null; then
    log "cleanup: command group ${CMD_PGID:-$CMD_PID} still alive — TERM group"
    kill -TERM -- "-${CMD_PGID:-$CMD_PID}" 2>/dev/null
    sleep 3
    kill -KILL -- "-${CMD_PGID:-$CMD_PID}" 2>/dev/null
  fi
  log "stopping recorders..."
  # The lustre recorders run as root and stop on this sentinel (see 1L/2L);
  # removing it first lets them exit during the flush sleep below.
  rm -f "$PIDS_DIR/lustre-recorders.alive"
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
    # rdma-counters.csv IS required here: the EFA devices' hw_counters are this
    # leg's wire-level Primary (THESIS §4 — the client's network counters ARE
    # the data path), and lnet-stats.log is the per-cell transport proof (D16).
    lustre) REQUIRED_STREAMS="lustre-stats.log lnet-stats.log rdma-counters.csv \
             nvidia-smi.csv netdev-counters.csv \
             sar-cpu.csv sar-disk.csv sar-net.csv sar-mem.csv sar-swap.csv sar-paging.csv" ;;
  esac
  log "verifying recordings (required set for fs=$FS)..."
  INCOMPLETE=0
  # D-30 (ratified 2026-08-16): the two per-cell requirements that now decide the
  # verdict rather than warn. Missing COST INPUTS deliberately stay warn-only —
  # cost is re-derivable arithmetic from wallclock + a dated price, so the cell's
  # measurement is intact; a missing cache regime or path proof is not repairable.
  if (( ${CACHE_UNDECLARED:-0} )); then
    log "  WARN: cache_state undeclared on a measured cell -> INCOMPLETE (D-30/D13)"
    INCOMPLETE=1
  fi
  # A kvikIO cell without cuFile's own GPU-direct-vs-bounced accounting is
  # incomplete: a configuration flag is not proof of the path taken (D8). Drivers
  # that run kvikIO cells export RECORD_KVIKIO_CELL=1; the reader emits a
  # "path_accounting" block into its per-cell JSON in this run dir.
  if [[ "${RECORD_KVIKIO_CELL:-0}" == "1" ]]; then
    if grep -rlsq '"path_accounting"' "$RUN_DIR" --include='*.json'; then
      log "  OK:   path_accounting present (kvikIO cell, D8 proof recorded)"
    else
      log "  WARN: kvikIO cell has NO recorded path_accounting split -> INCOMPLETE (D-30/D8):"
      log "        which path the reads took is unproven, and a silent fallback looks"
      log "        identical in the throughput data."
      INCOMPLETE=1
    fi
  fi
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

  # D-39: FSx server-side CloudWatch window dump (lustre only) — the RUNBOOK's
  # declared server-side Primary. Runs after metadata.json has the cell's
  # [started_utc, ended_utc]. WARN-ONLY and deliberately NOT in the
  # required-streams list: CloudWatch publishes with ~1-2 min lag, so the
  # immediate dump may be right-truncated (marked "final": false) — the
  # run-leg.sh per-step backfill re-fetches non-final dumps, and CloudWatch's
  # 15-month retention means a missed window stays repairable, unlike every
  # client-side stream.
  if [[ "$FS" == "lustre" && -n "${WALLCLOCK_S:-}" && -x "$SCRIPT_DIR/fsx-cloudwatch-dump.py" ]]; then
    log "D-39: dumping FSx CloudWatch window..."
    "$SCRIPT_DIR/fsx-cloudwatch-dump.py" "$RUN_DIR" \
      >> "$RUN_DIR/raw/fsx-cloudwatch.log" 2>&1 \
      || log "  WARN: FSx CloudWatch dump failed (see raw/fsx-cloudwatch.log) — the per-step backfill or a by-hand re-run repairs it; the window is retained server-side"
  fi

  # Run parser
  if [[ -x "$SCRIPT_DIR/parse-results.py" ]]; then
    log "parsing results..."
    "$SCRIPT_DIR/parse-results.py" "$RUN_DIR" \
      > "$RUN_DIR/raw/parse.log" 2>&1 \
      || log "  WARN: parser failed; see raw/parse.log"
  fi

  # ---------- D-7 canary-abort: the post-cell consistency check, mechanical ----------
  # RUNBOOK: cross-source disagreement means bugged instrumentation, and on an
  # unattended chain the canary aborts the chain ITSELF. A FAIL / UNCALIBRATED /
  # NO_DATA verdict on a measured cell marks the cell INCOMPLETE and writes the
  # poison marker the pre-cell gate refuses on — no further cell runs anywhere
  # until a human clears it. Stage-0 cells record their verdict but never poison:
  # infra proofs and the band-calibration cells legitimately run before bands
  # exist (poisoning on their UNCALIBRATED would kill the very chain that creates
  # the bands). Deliberately NOT poison-worthy: empty verdicts (no material
  # fs-side direction — a memory-served/idle cell; the sampling-limit rule),
  # UNDER_SAMPLED (same rule), and REPORT_ONLY (a mixed direction with no
  # calibrated mixed widening, B.3 — recorded, never judged).
  if [[ -s "$RUN_DIR/results.json" && -f "$SCRIPT_DIR/wsi_agg_helper.py" ]]; then
    CANARY_OUT=$(python3 "$SCRIPT_DIR/wsi_agg_helper.py" check "$RUN_DIR" 2>&1 || true)
    printf '%s\n' "$CANARY_OUT" > "$RUN_DIR/canary-check.json"
    if printf '%s' "$CANARY_OUT" | grep -qE '"verdict": "(FAIL|UNCALIBRATED|NO_DATA)"'; then
      if [[ "$STAGE" == "0" ]]; then
        log "  WARN: consistency canary non-PASS on a stage-0 cell — recorded (canary-check.json), never poisons"
      else
        log "  CANARY: non-PASS verdict (canary-check.json) -> INCOMPLETE + chain poisoned (D-7)"
        INCOMPLETE=1
        mkdir -p "$RUNS_ROOT/.leg-state/$FS"
        {
          echo "written by record-run.sh at $(date -u +%FT%TZ)"
          echo "cell: $RUN_ID"
          echo "reason: post-cell consistency canary returned a poison-class verdict:"
          printf '%s\n' "$CANARY_OUT" | grep -E '"verdict"|"direction"|"detail"|"ratio"' | head -12
          echo "Every subsequent cell on this leg refuses until this file is deleted."
          echo "Fix the instrumentation first — every number after a canary FAIL depends on it."
        } > "$RUNS_ROOT/.leg-state/$FS/canary-abort"
      fi
    elif printf '%s' "$CANARY_OUT" | grep -q '"verdicts": \[\]'; then
      log "  canary: no material fs-side direction (memory-served/idle cell) — judgement recorded (canary-check.json)"
    elif printf '%s' "$CANARY_OUT" | grep -qE '"verdict": "(REPORT_ONLY|UNDER_SAMPLED)"'; then
      log "  canary: report-only/under-sampled judgement recorded (canary-check.json) — not a failure"
    else
      log "  OK:   consistency canary PASS (canary-check.json)"
    fi
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

  # D-7 end-of-cell raw sync: each completed cell is durable the moment it ends,
  # not at the step boundary. Warn-only — run-leg's verified per-step sync stays
  # the fail-loud authority (same switch as the mid-run loop). Its log lives in
  # post/, NOT raw/: logging into raw/ makes the sync self-referencing — it
  # appends its own result line to a file it just uploaded, leaving that file
  # permanently one line behind in S3 (bit the 6.B.2 rep cells, 2026-08-22).
  if [[ -n "${S3_BUCKET:-}" && "${RECORD_MIDRUN_SYNC_S:-600}" != "0" && -x "$SCRIPT_DIR/sync-to-s3.sh" ]]; then
    "$SCRIPT_DIR/sync-to-s3.sh" --mode run --run-dir "$RUN_DIR" \
      >> "$RUN_DIR/post/end-sync.log" 2>&1 \
      || log "  WARN: end-of-cell S3 sync failed (the per-step sync will retry; see post/end-sync.log)"
  fi

  log "done: $RUN_DIR"
  log "status: $STATUS (rc=$RC)"
}
trap cleanup EXIT INT TERM

# ---------- run the benchmark (under the D-7 per-cell watchdog) ----------
log "running: ${CMD[*]}"
START_TS=$(date -u +%FT%TZ)
START_EPOCH=$(date -u +%s)
echo "$START_TS" > "$RUN_DIR/raw/.run_start"

# D-7 per-cell watchdog. A hung cell on an unattended chain wastes hours and
# money (2026-08-21: a 300 s cell hung >3 h on aio completions lost to an EFA
# incident). The command runs in its OWN process group via setsid, so the
# watchdog and the cleanup trap can kill the whole tree by PGID — never a
# pattern match, which also matches this wrapper's argv (pattern #2). TERM
# first; KILL the group after a grace period (a stuck fio ignores TERM).
# RECORD_TIMEOUT_S comes from the driver, which knows the cell's runtime; the
# default is deliberately generous — it exists to catch the hung-forever
# class, because a watchdog that kills a valid hours-scale cell destroys real
# money, and tight bounds are the drivers' job.
WATCHDOG_S=${RECORD_TIMEOUT_S:-86400}
# The leader writes its own PGID: under a job-control shell setsid(1) forks
# (the background child is already a group leader), so $! would be setsid's
# short-lived parent, not the group. The child's $$ is right in both regimes;
# `setsid -w` makes $! wait-able for the rc in both regimes too.
CMD_PGID_FILE="$RUN_DIR/raw/.cmd_pgid"
setsid -w bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$CMD_PGID_FILE" "${CMD[@]}" > "$RUN_DIR/cmd.log" 2>&1 &
CMD_PID=$!
CMD_PGID=""
for _ in 1 2 3 4 5; do
  CMD_PGID=$(cat "$CMD_PGID_FILE" 2>/dev/null); [[ -n "$CMD_PGID" ]] && break; sleep 0.2
done
CMD_PGID=${CMD_PGID:-$CMD_PID}
(
  waited=0
  while (( waited < WATCHDOG_S )); do
    sleep 15
    kill -0 "$CMD_PID" 2>/dev/null || exit 0
    waited=$(( waited + 15 ))
  done
  {
    echo "watchdog: cell exceeded ${WATCHDOG_S}s at $(date -u +%FT%TZ) — killing process group $CMD_PGID (TERM, then KILL after 60s)"
  } >> "$RUN_DIR/raw/watchdog.log"
  kill -TERM -- "-$CMD_PGID" 2>/dev/null
  sleep 60
  if kill -0 "$CMD_PID" 2>/dev/null; then
    echo "watchdog: group survived TERM — KILL at $(date -u +%FT%TZ)" >> "$RUN_DIR/raw/watchdog.log"
    kill -KILL -- "-$CMD_PGID" 2>/dev/null
  fi
) &
WATCHDOG_PID=$!
# D-7 per-cell DURING-RUN sync: raw telemetry reaches S3 while the cell runs, so
# a crash at 4am cannot lose the night (RUNBOOK chain requirement #1). The
# increments are the KB–MB-scale 1 Hz CSVs — the permitted targeted-sync class;
# run-leg's verified per-step sync stays the fail-loud durability authority, so
# a mid-run sync failure warns into its log and never kills the cell.
# RECORD_MIDRUN_SYNC_S=0 disables; no S3_BUCKET (pre-cloud) skips.
MIDRUN_SYNC_S=${RECORD_MIDRUN_SYNC_S:-600}
MIDRUN_SYNC_PID=""
if [[ -n "${S3_BUCKET:-}" && "$MIDRUN_SYNC_S" != "0" && -x "$SCRIPT_DIR/sync-to-s3.sh" ]]; then
  # stdio detached at spawn: an orphaned `sleep` from a killed loop would
  # otherwise inherit — and hold open — the caller's stdout pipe for up to a
  # full interval after the cell ends.
  (
    while sleep "$MIDRUN_SYNC_S"; do
      kill -0 "$CMD_PID" 2>/dev/null || exit 0
      "$SCRIPT_DIR/sync-to-s3.sh" --mode run --run-dir "$RUN_DIR" \
        >> "$RUN_DIR/raw/midrun-sync.log" 2>&1 \
        || echo "midrun-sync: FAILED at $(date -u +%FT%TZ) — warn-only; the per-step sync is the authority" \
             >> "$RUN_DIR/raw/midrun-sync.log"
    done
  ) >/dev/null 2>&1 &
  MIDRUN_SYNC_PID=$!
fi
wait "$CMD_PID"
RC=$?
kill "$WATCHDOG_PID" 2>/dev/null
[[ -n "$MIDRUN_SYNC_PID" ]] && kill "$MIDRUN_SYNC_PID" 2>/dev/null
if [[ -s "$RUN_DIR/raw/watchdog.log" ]]; then
  log "WATCHDOG FIRED: cell killed after ${WATCHDOG_S}s (see raw/watchdog.log) — rc=$RC flows to the verdict"
fi

END_TS=$(date -u +%FT%TZ)
END_EPOCH=$(date -u +%s)
echo "$END_TS" > "$RUN_DIR/raw/.run_end"
WALLCLOCK_S=$(( END_EPOCH - START_EPOCH ))
echo "$WALLCLOCK_S" > "$RUN_DIR/raw/.run_wallclock_s"
log "command exited rc=$RC after ${WALLCLOCK_S}s"

# Trap fires on EXIT — handles recorder shutdown, conversion, snapshot, verify, parse, INDEX update
exit $RC
