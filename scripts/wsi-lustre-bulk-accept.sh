#!/usr/bin/env bash
# wsi-lustre-bulk-accept.sh — bulk-rate transport acceptance for the lustre leg.
#
# WHY THIS EXISTS (2026-09-10, from the 2026-08-21 EFA bulk-write failure)
#   Phase-2 proves the EFA data path with a 100 MiB direct write. The 2026-08-21
#   failure was invisible at that size: sustained 16-job 4 MiB direct writes
#   destabilised the client<->OSS EFA path within ~2-3 minutes, every time, with
#   zero EFA retransmissions on anything smaller. Transport stability at BULK rate
#   is therefore a precondition (D16/L7) that must be proven mechanically, per
#   build, before any measured cell — and, when it fails, the isolation matrix
#   should come out of the same boot rather than a human's afternoon at $48/hr.
#
# WHAT IT DOES
#   Rung 1  as configured        16 jobs x 4 MiB x iodepth 8, O_DIRECT, 120 s, PFL default layout
#   -- PASS --> rung 4 (reads, informational) --> bulk-transport-PASS marker
#   -- FAIL, clean cleanup -->
#   Rung 2  single rail          same, after `lnetctl net del --net efa --if <efa_1>` (skipped on 1 rail)
#            (rail is RESTORED afterwards, always — trap on exit)
#   Rung 3  single OST           same, into a dir with `lfs setstripe -c 1 -i 0` (one OSS)
#   Rung 4  reads                same shape, --rw=read over rung-1's files (RDMA-write direction)
#   --> bulk-transport-FAIL marker with the matrix
#   -- FAIL with fio stuck (D state / survived SIGKILL) --> STOP the ladder (a wedged
#      client invalidates further rungs), FAIL marker says STUCK, banner says reboot.
#
#   Every rung writes: pre/ and post/ snapshots (full EFA hw_counters, lnetctl net/peer
#   -v 4, stats, osc import states), raw/efa-lnet-1hz.tsv (1 Hz counters), raw/fio.json
#   (fio --status-interval=1 dumps), fio-bw-timeseries.tsv (bandwidth vs time — the
#   "slow from t=0 or fast-then-collapse" curve), dmesg-window.txt (kernel log for
#   exactly the window), summary.txt (verdict + reasons + deltas).
#
# VERDICT RULE (per rung)
#   FAIL if any of: fio exit != 0; fio did not exit within runtime+180 s; any
#   ptlrpc_expire_one_request / "Connection to ... was lost" / kefalnd_force_cancel_tx
#   in the window; fio processes stuck after SIGKILL.
#   EFA retrans_timeout_events / retrans_pkts deltas are RECORDED and flagged
#   (PASS_WARN) but do not fail a rung on their own — SRD may retransmit under
#   load; Lustre-visible symptoms are the bar.
#
# MARKERS   runs/.leg-state/lustre/bulk-transport-{PASS,FAIL}
#   If either exists, later boots skip (FORCE=1 to re-run). run-leg.sh should
#   refuse the leg without PASS — refuse-loud, nothing to remember at 3am.
#
# KNOBS (env)  ACCEPT_RUNTIME=120  ACCEPT_NUMJOBS=16  ACCEPT_IODEPTH=8  ACCEPT_BS=4M
#   ACCEPT_FILESIZE=10G  ACCEPT_LADDER=1 (0 = rung 1 only)  ACCEPT_KEEP_FILES=0
#   ACCEPT_WAIT_BOOTSTRAP=1800 (s to wait for /var/lib/wsi-bootstrap.done; 0 = don't)
#   ACCEPT_SETTLE=30  ACCEPT_RECOVER_WAIT=600  ACCEPT_FIO_FORMAT=json (json+ for bins)
#   FORCE=1 re-run despite an existing marker
#
# Usage: sudo scripts/wsi-lustre-bulk-accept.sh      (normally via wsi-lustre-bulk-accept.service)
set -uo pipefail

CONF=/etc/wsi-bootstrap.conf
MNT=/mnt/lustre
U=ec2-user
UH=/home/$U
REPO=$UH/wsi-cloud
STATE=$REPO/runs/.leg-state/lustre
RUNTIME=${ACCEPT_RUNTIME:-120}
NUMJOBS=${ACCEPT_NUMJOBS:-16}
IODEPTH=${ACCEPT_IODEPTH:-8}
BS=${ACCEPT_BS:-4M}
FILESIZE=${ACCEPT_FILESIZE:-10G}
LADDER=${ACCEPT_LADDER:-1}
KEEP_FILES=${ACCEPT_KEEP_FILES:-0}
WAIT_BOOTSTRAP=${ACCEPT_WAIT_BOOTSTRAP:-1800}
SETTLE=${ACCEPT_SETTLE:-30}
RECOVER_WAIT=${ACCEPT_RECOVER_WAIT:-600}
FIO_FORMAT=${ACCEPT_FIO_FORMAT:-json}
FORCE=${FORCE:-0}
OVERRUN_GRACE=180   # fio may block past --runtime; this is how long we wait before killing

log()  { echo "[bulk-accept $(date -u +%H:%M:%S)] $*"; }
warn() { echo "WSI-WARN: $*"; }
die()  { echo "WSI-FATAL: $*" >&2; exit 2; }

# ── preconditions ─────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$CONF" ] && . "$CONF"
[ "${LEG:-}" = "lustre" ] || die "LEG='${LEG:-}' — lustre-only"
for c in fio lctl lfs lnetctl python3; do command -v "$c" >/dev/null || die "missing command: $c"; done
mkdir -p "$STATE"

if [ "$FORCE" != "1" ]; then
  for m in PASS FAIL; do
    if [ -f "$STATE/bulk-transport-$m" ]; then
      log "verdict already on record: bulk-transport-$m — not re-running (FORCE=1 to override)"
      cat "$STATE/bulk-transport-$m"
      exit 0
    fi
  done
fi

if ! systemctl is-active --quiet wsi-lustre-phase2.service; then
  log "wsi-lustre-phase2.service is not active — fs unmounted by design (D16); nothing to accept. Exiting 0."
  exit 0
fi
mountpoint -q "$MNT" || die "$MNT not mounted although phase-2 is active — inconsistent; refusing"

if [ "$WAIT_BOOTSTRAP" -gt 0 ] && [ ! -f /var/lib/wsi-bootstrap.done ]; then
  log "waiting up to ${WAIT_BOOTSTRAP}s for bootstrap to finish (so dnf/NVIDIA installs do not share the window)..."
  t0=$(date +%s)
  while [ ! -f /var/lib/wsi-bootstrap.done ] && [ $(( $(date +%s) - t0 )) -lt "$WAIT_BOOTSTRAP" ]; do sleep 10; done
  [ -f /var/lib/wsi-bootstrap.done ] || warn "bootstrap marker never appeared — proceeding anyway"
fi
log "settling ${SETTLE}s"; sleep "$SETTLE"

# ── facts ─────────────────────────────────────────────────────────────────────
EFA_DEVS=()
for i in /sys/class/infiniband/*; do
  [ -e "$i/device/driver" ] || continue
  [ "$(basename "$(realpath "$i/device/driver")")" = "efa" ] && EFA_DEVS+=("$(basename "$i")")
done
mapfile -t EFA_DEVS < <(printf '%s\n' "${EFA_DEVS[@]}" | sort)
[ "${#EFA_DEVS[@]}" -ge 1 ] || die "no EFA devices"
RAILS=${#EFA_DEVS[@]}
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $(curl -sfX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 600')" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo unknown)

RUN_ID=$(date -u +%Y-%m-%d-%H%M%S)
RUN_DIR=$REPO/runs/$RUN_ID-lustre-bulk-accept
FS_DIR=$MNT/benchmarks/bulk-accept/$RUN_ID
mkdir -p "$RUN_DIR" "$FS_DIR"
{
  echo "run_id: $RUN_ID"; echo "instance: $INSTANCE_ID"; echo "kernel: $(uname -r)"
  echo "efa_devs: ${EFA_DEVS[*]} (rails=$RAILS, terraform expected=${EFA_RAILS_EXPECTED:-?}, second_efa_type=${SECOND_EFA_TYPE:-?})"
  echo "efa.ko: $(modinfo efa | awk '/^version:/{print $2}') $(modinfo -n efa)"
  echo "lustre-client: $(rpm -q lustre-client 2>/dev/null)"
  echo "shape: rw=write numjobs=$NUMJOBS iodepth=$IODEPTH bs=$BS size=$FILESIZE runtime=${RUNTIME}s direct=1 libaio"
  echo "mount: $(findmnt -n -o SOURCE,OPTIONS "$MNT")"
} > "$RUN_DIR/run-facts.txt"
log "run dir: $RUN_DIR"; cat "$RUN_DIR/run-facts.txt"

# ── telemetry helpers ─────────────────────────────────────────────────────────
ctr() { cat "/sys/class/infiniband/$1/ports/1/hw_counters/$2" 2>/dev/null || echo 0; }
ctr_sum() { local s=0; for d in "${EFA_DEVS[@]}"; do s=$(( s + $(ctr "$d" "$1") )); done; echo "$s"; }
snapshot() { # snapshot <dir>
  local d=$1; mkdir -p "$d"
  for dev in "${EFA_DEVS[@]}"; do
    for f in /sys/class/infiniband/"$dev"/ports/1/hw_counters/*; do [ -r "$f" ] && echo "$dev $(basename "$f") $(cat "$f")"; done
  done > "$d/efa-hw-counters.txt"
  lnetctl net show -v 4  > "$d/lnetctl-net-show-v4.txt"  2>&1
  lnetctl peer show -v 4 > "$d/lnetctl-peer-show-v4.txt" 2>&1
  lnetctl stats show     > "$d/lnetctl-stats.txt"        2>&1
  lctl get_param osc.*.import > "$d/osc-import.txt" 2>&1
  lctl get_param osc.*.rpc_stats > "$d/osc-rpc_stats.txt" 2>&1
  lfs df -h "$MNT" > "$d/lfs-df.txt" 2>&1
  date -u +%Y-%m-%dT%H:%M:%SZ > "$d/timestamp.txt"
}
SAMPLER_PID=""
sampler_start() { # 1 Hz: EFA counters per device + LNet message counters
  local out=$1
  {
    printf 'epoch'
    for d in "${EFA_DEVS[@]}"; do for c in retrans_pkts retrans_timeout_events tx_bytes rx_bytes rdma_read_resp_bytes rdma_write_bytes rx_drops; do printf '\t%s.%s' "$d" "$c"; done; done
    printf '\tlnet.send_count\tlnet.recv_count\tlnet.drop_count\n'
  } > "$out"
  (
    while :; do
      line=$(date +%s)
      for d in "${EFA_DEVS[@]}"; do for c in retrans_pkts retrans_timeout_events tx_bytes rx_bytes rdma_read_resp_bytes rdma_write_bytes rx_drops; do line+=$'\t'$(ctr "$d" "$c"); done; done
      st=$(lnetctl stats show 2>/dev/null)
      for k in send_count recv_count drop_count; do line+=$'\t'$(echo "$st" | awk -v k="$k:" '$1==k{print $2; exit}'); done
      echo "$line" >> "$out"
      sleep 1
    done
  ) &
  SAMPLER_PID=$!
}
sampler_stop() { [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""; }

imports_all_full() { local s; s=$(lctl get_param -n osc.*.import 2>/dev/null | awk '$1=="state:"{print $2}'); [ -n "$s" ] && ! echo "$s" | grep -qv '^FULL$'; }
wait_recovery() { # wait for osc imports FULL and EFA retrans counters quiet
  local t0; t0=$(date +%s)
  log "recovery: waiting for all osc imports FULL (<=${RECOVER_WAIT}s)"
  while ! imports_all_full && [ $(( $(date +%s) - t0 )) -lt "$RECOVER_WAIT" ]; do sleep 5; done
  imports_all_full && log "recovery: imports FULL after $(( $(date +%s) - t0 ))s" || warn "recovery: imports NOT all FULL after ${RECOVER_WAIT}s: $(lctl get_param -n osc.*.import 2>/dev/null | awk '$1=="state:"{print $2}' | sort | uniq -c | tr '\n' ' ')"
  local prev cur; prev=$(ctr_sum retrans_timeout_events); cur=$prev
  while [ $(( $(date +%s) - t0 )) -lt "$RECOVER_WAIT" ]; do
    sleep 10; cur=$(ctr_sum retrans_timeout_events)
    [ "$cur" = "$prev" ] && break
    prev=$cur
  done
  log "recovery: retrans_timeout_events quiet at $cur"
}

fio_parse() { # fio_parse <fio.json> <timeseries.tsv> -> prints "agg_bw_MBps io_GiB fio_error"
  python3 - "$1" "$2" <<'PY'
import json, sys
src, ts = sys.argv[1], sys.argv[2]
docs = []
try:
    buf = open(src).read()
except Exception:
    print("? ? ?"); sys.exit(0)
dec = json.JSONDecoder(); i = 0
while i < len(buf):
    while i < len(buf) and buf[i].isspace(): i += 1
    if i >= len(buf): break
    try:
        obj, j = dec.raw_decode(buf, i); docs.append(obj); i = j
    except Exception:
        break   # truncated tail (fio killed mid-dump)
with open(ts, "w") as f:
    f.write("elapsed_ms\twrite_bw_KiBps\tread_bw_KiBps\twrite_iops\tread_iops\twrite_io_bytes\tread_io_bytes\n")
    for d in docs:
        try:
            j = d["jobs"][0]
            f.write("%d\t%d\t%d\t%.1f\t%.1f\t%d\t%d\n" % (j.get("job_runtime", 0), j["write"]["bw"], j["read"]["bw"],
                    j["write"]["iops"], j["read"]["iops"], j["write"]["io_bytes"], j["read"]["io_bytes"]))
        except Exception:
            pass
if not docs:
    print("? ? ?"); sys.exit(0)
j = docs[-1]["jobs"][0]
bw = (j["write"]["bw_bytes"] + j["read"]["bw_bytes"]) / 1e6
io = (j["write"]["io_bytes"] + j["read"]["io_bytes"]) / 2**30
print("%.0f %.1f %s" % (bw, io, j.get("error", "?")))
PY
}

# ── the probe ─────────────────────────────────────────────────────────────────
# run_probe <label> <rw> <target_dir> <size>   -> returns 0 PASS, 1 FAIL, 2 STUCK
# Writes $RUN_DIR/rung-<label>/ ; sets PROBE_VERDICT, PROBE_REASONS, PROBE_LINE.
run_probe() {
  local label=$1 rw=$2 target=$3 size=$4
  local dir="$RUN_DIR/rung-$label"; mkdir -p "$dir/raw" "$dir/pre" "$dir/post"
  local pidfile="$dir/raw/fio.pgid" rcfile="$dir/raw/fio.rc"
  local -a reasons=()
  log "===== rung $label: rw=$rw target=$target size=$size ====="
  snapshot "$dir/pre"
  local start_epoch; start_epoch=$(date +%s)
  local -A rt_b rp_b
  for d in "${EFA_DEVS[@]}"; do rt_b[$d]=$(ctr "$d" retrans_timeout_events); rp_b[$d]=$(ctr "$d" retrans_pkts); done
  sampler_start "$dir/raw/efa-lnet-1hz.tsv"

  local -a cmd=(fio --name="wsi-accept-$label" --directory="$target" --filename_format='accept.$jobnum'
                --size="$size" --numjobs="$NUMJOBS" --ioengine=libaio --direct=1 --iodepth="$IODEPTH"
                --rw="$rw" --bs="$BS" --runtime="$RUNTIME" --time_based --group_reporting
                --output-format="$FIO_FORMAT" --status-interval=1 --eta=never --output="$dir/raw/fio.json")
  printf '%q ' "${cmd[@]}" > "$dir/fio-cmdline.txt"; echo >> "$dir/fio-cmdline.txt"
  rm -f "$pidfile" "$rcfile"
  # Own session + process group so the whole tree can be killed as a unit; the
  # inner bash records its PID (== PGID) and fio's exit code to files, because
  # $! is not reliable across setsid's fork-or-exec behaviour.
  setsid bash -c 'echo $$ > "$1"; rcf=$2; shift 2; "$@" 2>"${rcf%.rc}.stderr"; echo $? > "$rcf"' _ "$pidfile" "$rcfile" "${cmd[@]}" &
  sleep 2
  local pgid; pgid=$(cat "$pidfile" 2>/dev/null || echo "")
  [ -n "$pgid" ] || { warn "fio wrapper did not report a PGID"; pgid=$!; }
  log "fio started (pgid $pgid); deadline ${RUNTIME}s + ${OVERRUN_GRACE}s"

  local deadline=$(( start_epoch + RUNTIME + OVERRUN_GRACE )) overran=0 killed=0
  while kill -0 "$pgid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      overran=1; reasons+=("fio did not exit within runtime+${OVERRUN_GRACE}s (the 2026-08-21 signature)")
      log "deadline passed — SIGTERM then SIGKILL to process group $pgid"
      kill -TERM -- "-$pgid" 2>/dev/null; sleep 30
      kill -KILL -- "-$pgid" 2>/dev/null; killed=1; sleep 5
      break
    fi
    sleep 2
  done
  local end_epoch; end_epoch=$(date +%s)
  sampler_stop
  local fio_rc; fio_rc=$(cat "$rcfile" 2>/dev/null || echo "killed")
  [ "$fio_rc" = "0" ] || [ "$overran" -eq 1 ] || reasons+=("fio exit code $fio_rc")

  # stragglers / D state (the occurrence-1 rep3 signature: workers surviving SIGKILL)
  local stuck=0
  if [ "$killed" -eq 1 ]; then sleep 60; fi
  local strag; strag=$(pgrep -f -- "--name=wsi-accept-$label" 2>/dev/null || true)
  if [ -n "$strag" ]; then
    local st; st=$(ps -o pid=,stat=,wchan= -p "$(echo "$strag" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null)
    echo "$st" > "$dir/stragglers.txt"
    if echo "$st" | awk '{print $2}' | grep -q '^D'; then stuck=1; reasons+=("fio workers in D state after SIGKILL: $(echo "$st" | tr '\n' ';')"); else reasons+=("fio processes still present after kill (not D): $(echo "$st" | tr '\n' ';')"); fi
  fi

  snapshot "$dir/post"
  journalctl -k --since="@$start_epoch" --no-pager -o short-iso > "$dir/dmesg-window.txt" 2>&1
  local n_exp n_lost n_rest n_cancel n_efa
  n_exp=$(grep -c 'ptlrpc_expire_one_request' "$dir/dmesg-window.txt"); n_lost=$(grep -c 'was lost' "$dir/dmesg-window.txt")
  n_rest=$(grep -c 'Connection restored' "$dir/dmesg-window.txt"); n_cancel=$(grep -c 'kefalnd_force_cancel_tx' "$dir/dmesg-window.txt")
  n_efa=$(grep -ci 'efa' "$dir/dmesg-window.txt")
  [ "$n_exp" -eq 0 ]    || reasons+=("$n_exp ptlrpc RPC expirations")
  [ "$n_lost" -eq 0 ]   || reasons+=("$n_lost OST connection-lost events ($n_rest restored)")
  [ "$n_cancel" -eq 0 ] || reasons+=("$n_cancel kefalnd TX cancellations (+ any 'Skipped N similar')")

  local delta_txt="" any_rt=0
  for d in "${EFA_DEVS[@]}"; do
    local drt=$(( $(ctr "$d" retrans_timeout_events) - ${rt_b[$d]} )) drp=$(( $(ctr "$d" retrans_pkts) - ${rp_b[$d]} ))
    delta_txt+="$d retrans_timeout_events +$drt retrans_pkts +$drp; "
    [ "$drt" -gt 0 ] && any_rt=1
  done
  read -r agg_bw io_gib fio_err <<<"$(fio_parse "$dir/raw/fio.json" "$dir/fio-bw-timeseries.tsv")"

  local verdict
  if [ "$stuck" -eq 1 ]; then verdict=STUCK
  elif [ "${#reasons[@]}" -gt 0 ]; then verdict=FAIL
  elif [ "$any_rt" -eq 1 ]; then verdict=PASS_WARN
  else verdict=PASS; fi
  {
    echo "rung: $label"; echo "verdict: $verdict"
    echo "shape: rw=$rw numjobs=$NUMJOBS iodepth=$IODEPTH bs=$BS size=$size runtime=${RUNTIME}s target=$target"
    echo "rails in lnet at start: $(grep -c 'nid: .*@efa' "$dir/pre/lnetctl-net-show-v4.txt")"
    echo "window: $(date -u -d @"$start_epoch" +%H:%M:%SZ) .. $(date -u -d @"$end_epoch" +%H:%M:%SZ) (wall $(( end_epoch - start_epoch ))s)"
    echo "fio: exit=$fio_rc overran=$overran aggregate_bw=${agg_bw}MB/s io=${io_gib}GiB fio_error=$fio_err"
    echo "efa deltas: $delta_txt"
    echo "dmesg window: expirations=$n_exp lost=$n_lost restored=$n_rest kefalnd_cancels=$n_cancel efa-mentions=$n_efa"
    echo "reasons:"; for r in "${reasons[@]}"; do echo "  - $r"; done
    [ "${#reasons[@]}" -eq 0 ] && echo "  (none)"
    echo "layout: $(lfs getstripe -d "$target" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
  } | tee "$dir/summary.txt"
  PROBE_LINE="| $label | $rw | $verdict | ${agg_bw} MB/s | ${io_gib} GiB | $n_exp / $n_lost / $n_cancel | $delta_txt |"
  case $verdict in PASS|PASS_WARN) return 0;; STUCK) return 2;; *) return 1;; esac
}

# ── rail helpers (rung 2) ─────────────────────────────────────────────────────
RAIL_DELETED=""; RAIL_CPT=""; RAIL_PC=""
rail_info() { # rail_info <dev> -> "cpt pc" from lnetctl net show -v 4
  python3 - "$1" <<'PY'
import re, subprocess, sys
dev = sys.argv[1]
out = subprocess.run(["lnetctl", "net", "show", "-v", "4", "--net", "efa"], capture_output=True, text=True).stdout
block = None; found = None
for line in out.splitlines():
    s = line.strip()
    if s.startswith("- nid:"):
        if block is not None and block.get("if") == dev: found = block; break
        block = {}; continue
    if block is None: continue
    m = re.match(r'^\d+:\s*(\S+)$', s)
    if m: block["if"] = m.group(1)
    m = re.match(r'^CPT:\s*"?\[?([^\]"]*)\]?"?$', s)
    if m: block["cpt"] = m.group(1).strip()
    m = re.match(r'^peer_credits:\s*(\d+)$', s)
    if m: block["pc"] = m.group(1)
if found is None and block is not None and block.get("if") == dev: found = block
if found: print(found.get("cpt", ""), found.get("pc", ""))
PY
}
rail_restore() {
  [ -n "$RAIL_DELETED" ] || return 0
  log "restoring rail $RAIL_DELETED (peer_credits ${RAIL_PC:-32}${RAIL_CPT:+, cpt $RAIL_CPT})"
  local -a add=(lnetctl net add --net efa --if "$RAIL_DELETED" --peer-credits "${RAIL_PC:-32}")
  [[ "$RAIL_CPT" =~ ^[0-9]+$ ]] && add+=(--cpt "$RAIL_CPT")   # multi-CPT ("0,1") == unbound == default
  if "${add[@]}"; then RAIL_DELETED=""; else warn "rail restore FAILED — box is single-rail; fix by hand: ${add[*]}"; fi
}
trap 'rail_restore' EXIT

# ── the ladder ────────────────────────────────────────────────────────────────
declare -a MATRIX=()
FINAL=""; STOP_REASON=""
read_rung() { # rung 4: reads over rung-1's files, sized to what actually got written. Sets READ_RC.
  local minb nfiles rsize
  minb=$(stat -c %s "$FS_DIR"/r1/accept.* 2>/dev/null | sort -n | head -1)
  nfiles=$(find "$FS_DIR/r1" -maxdepth 1 -name 'accept.*' 2>/dev/null | wc -l)
  READ_RC=3
  if [ "${nfiles:-0}" -ge "$NUMJOBS" ] && [ "${minb:-0}" -ge $((1<<30)) ]; then
    rsize=$(( minb / (4<<20) * (4<<20) ))
    run_probe 4-reads read "$FS_DIR/r1" "$rsize"; READ_RC=$?
    MATRIX+=("$PROBE_LINE")
    [ "$READ_RC" -eq 2 ] && STOP_REASON="rung 4 left fio workers in D state — reboot required"
  else
    MATRIX+=("| 4-reads | read | SKIPPED (rung-1 files too small/few: n=${nfiles:-0} min=${minb:-0}B) | | | | |")
  fi
}

mkdir -p "$FS_DIR/r1"
run_probe 1-as-configured write "$FS_DIR/r1" "$FILESIZE"; rc=$?
MATRIX+=("$PROBE_LINE")
if [ $rc -eq 0 ]; then
  # writes hold; the leg also needs the read direction (RDMA-write path, never exercised on 2026-08-21)
  wait_recovery
  read_rung
  case $READ_RC in
    0|3) FINAL=PASS;;
    2)   FINAL=FAIL;;
    *)   FINAL=FAIL; STOP_REASON="bulk WRITES were clean but bulk READS failed (rung 4) — the read direction needs the same investigation";;
  esac
elif [ $rc -eq 2 ]; then
  FINAL=FAIL; STOP_REASON="rung 1 left fio workers in D state — ladder STOPPED; this box needs a reboot before anything else"
elif [ "$LADDER" != "1" ]; then
  FINAL=FAIL; STOP_REASON="rung 1 failed; ACCEPT_LADDER=0 so no isolation rungs were run"
else
  FINAL=FAIL
  wait_recovery
  # rung 2: single rail
  if [ "$RAILS" -ge 2 ]; then
    RAIL_DELETED=${EFA_DEVS[$((RAILS-1))]}
    read -r RAIL_CPT RAIL_PC <<<"$(rail_info "$RAIL_DELETED")"
    log "rung 2: deleting rail $RAIL_DELETED from LNet (was cpt='${RAIL_CPT:-all}' peer_credits='${RAIL_PC:-?}')"
    if lnetctl net del --net efa --if "$RAIL_DELETED"; then
      wait_recovery
      mkdir -p "$FS_DIR/r2"
      run_probe 2-single-rail write "$FS_DIR/r2" "$FILESIZE"; rc=$?
      MATRIX+=("$PROBE_LINE")
      rail_restore
      [ $rc -eq 2 ] && STOP_REASON="rung 2 left fio workers in D state — ladder STOPPED; reboot required"
    else
      warn "lnetctl net del $RAIL_DELETED failed — rung 2 skipped"; RAIL_DELETED=""
      MATRIX+=("| 2-single-rail | write | SKIPPED (net del failed) | | | | |")
    fi
  else
    MATRIX+=("| 2-single-rail | write | SKIPPED (1 rail) | | | | |")
  fi
  # rung 3: single OST (one OSS) on the as-configured topology
  if [ -z "$STOP_REASON" ]; then
    wait_recovery
    mkdir -p "$FS_DIR/r3"
    if lfs setstripe -c 1 -i 0 "$FS_DIR/r3"; then
      run_probe 3-single-ost write "$FS_DIR/r3" "$FILESIZE"; rc=$?
      MATRIX+=("$PROBE_LINE")
      [ $rc -eq 2 ] && STOP_REASON="rung 3 left fio workers in D state — ladder STOPPED; reboot required"
    else
      warn "lfs setstripe failed — rung 3 skipped"; MATRIX+=("| 3-single-ost | write | SKIPPED (setstripe failed) | | | | |")
    fi
  fi
  # rung 4: reads over whatever rung 1 managed to write
  if [ -z "$STOP_REASON" ]; then
    wait_recovery
    read_rung
  fi
fi
rail_restore; trap - EXIT

# ── verdict, markers, cleanup ─────────────────────────────────────────────────
{
  echo "# Bulk-transport acceptance — $RUN_ID"
  echo; echo "**FINAL: $FINAL**  instance $INSTANCE_ID  rails=$RAILS  efa.ko $(modinfo efa | awk '/^version:/{print $2}')  $(rpm -q lustre-client 2>/dev/null)"
  [ -n "$STOP_REASON" ] && { echo; echo "**STOP:** $STOP_REASON"; }
  echo; echo "| rung | rw | verdict | agg bw | io | expire / lost / cancel | EFA deltas |"; echo "|---|---|---|---|---|---|---|"
  for l in "${MATRIX[@]}"; do echo "$l"; done
  echo; echo "Per-rung detail: rung-*/summary.txt, fio-bw-timeseries.tsv, dmesg-window.txt, pre/ post/, raw/."
  echo; echo "Reading the matrix:"
  echo "- 1 PASS: transport holds at bulk rate on this build. Proceed. (If 2026-08-21 failed on the same config, the delta is the instance/host/fabric, not the client — say so in the AWS case.)"
  echo "- 1 FAIL, 2 PASS: the second rail / CPT path is implicated. Rebuild with -var second_efa_type=efa (or none) and re-accept; give AWS the exact A/B."
  echo "- 1 FAIL, 2 FAIL, 3 PASS: needs fan-out across OSSes to trigger — points at client-side multi-peer LNet/kefalnd behaviour or aggregate egress, not one OSS."
  echo "- 1 FAIL, 2 FAIL, 3 FAIL: reproduces with one rail into one OSS — client-topology-agnostic; hand AWS the matrix and the fio time series."
  echo "- Any STUCK: reboot before anything else; the box is not trustworthy for further rungs."
} | tee "$RUN_DIR/verdict.md"

{
  echo "verdict: $FINAL"; echo "run: $RUN_DIR"; echo "instance: $INSTANCE_ID"; echo "at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$STOP_REASON" ] && echo "stop: $STOP_REASON"
  for l in "${MATRIX[@]}"; do echo "$l"; done
} > "$STATE/bulk-transport-$FINAL"
rm -f "$STATE/bulk-transport-$([ "$FINAL" = PASS ] && echo FAIL || echo PASS)"

if [ "$KEEP_FILES" != "1" ] && [ -z "$STOP_REASON" ]; then
  timeout 600 rm -rf "$FS_DIR" 2>/dev/null || warn "test-file cleanup timed out/failed — $FS_DIR left on the fs"
else
  log "test files kept at $FS_DIR"
fi
chown -R "$U:$U" "$RUN_DIR" "$STATE" 2>/dev/null || true

if [ -f /etc/motd.d/50-wsi ]; then
  sed -i '/bulk-transport verdict:/d' /etc/motd.d/50-wsi
  echo "  bulk-transport verdict: $FINAL ($RUN_ID) — $RUN_DIR/verdict.md${STOP_REASON:+  ** $STOP_REASON **}" >> /etc/motd.d/50-wsi
fi
log "FINAL: $FINAL — marker $STATE/bulk-transport-$FINAL; matrix in $RUN_DIR/verdict.md"
[ "$FINAL" = PASS ] && exit 0 || exit 1
