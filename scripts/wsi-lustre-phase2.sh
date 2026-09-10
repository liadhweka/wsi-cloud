#!/usr/bin/env bash
# wsi-lustre-phase2.sh — the BAKED lustre mount automation.
#
# BAKED FROM THE 2026-08 GATED WALK (runs/2026-08-20-lustre-efa-walk-transcript.md,
# human-approved throughout) and PROVEN FROM SCRATCH on the 2026-08-21 rebuild:
# unattended per-boot run, D16 gate passed, counter-proof +100/100MiB, no human step.
#
# What the walk established, which this script encodes (sources fetched 2026-08-20):
#   - AL2023 ships the Lustre kernel modules IN-KERNEL (staging/lustrefsx), including
#     kefalnd (Amazon's EFA LNet driver) and efa.ko — so the client install is the
#     USERSPACE-ONLY `dnf install lustre-client` from the base repo: no FSx repo, no
#     kmod, no kernel change, no reboot. D-17's kernel risk is dissolved by
#     construction, and stage 3 asserts that stays true.
#   - No EFA userspace installer is needed: the kernel Lustre data path uses kefalnd,
#     not libfabric. AWS's own installer gates on `modinfo efa` >= 2.12.1 and skips
#     when the in-kernel driver satisfies it (docs.aws.amazon.com/fsx/latest/
#     LustreGuide/configure-efa-clients.html).
#   - The EFA LNet configuration is AWS's official bundle, VENDORED at
#     scripts/vendor/configure-efa-fsx-lustre-client/ (sha-pinned; see VENDORED.md).
#     Its systemd oneshot re-arms the config on every boot.
#   - The mount device string stays `@tcp:/<mountname>` even on an EFA-enabled file
#     system — that is the MGS NID; LNet discovery + the UDSP rule route data over
#     EFA. A config flag is not proof of behaviour, so stage 6 PROVES the transport
#     with LNet byte counters around a direct-I/O dd, and only then writes
#     FS_TRANSPORT=efa.
#   - Client tuning (D-11, ratified 2026-08-20): AWS's documented set for a
#     >64-vCPU / >64-GiB client (docs .../performance-tips.html). lctl set_param does
#     not survive reboot, so stage 6 installs wsi-lustre-tuning.service.
#   NOTE (D8, checked 2026-08-20): no GDS driver/config work belongs here — GDS on
#   FSx requires a P5/P6-class client and this project's client is g6e, so the compat
#   cufile.json from phase 1 is the END state. Per-cell path accounting verifies; a
#   contradicting split is a finding to surface, not wiring to add.
#
# Stages (each ⛔ = WSI-FATAL, filesystem left UNMOUNTED, banner explains):
#   1 preflight   FSX facts + fs spec asserted + EFA hardware (count must match
#                 terraform's second_efa_type) + DNS + port 988
#   2 efa-kernel  in-kernel efa.ko >= 2.12.1 and kefalnd present  (⛔ = AMI/kernel drift)
#   3 client      dnf install lustre-client; ⛔ if the kernel changed (D-17);
#                 provenance logged; ⛔ if lustre modules are already loaded
#                 before the AWS configurator (its libcfs CPT options would not apply)
#   4 re-arm      vendored AWS setup.sh --tcp-name <IMDS-derived primary if> →
#                 EFA LNet config now + systemd oneshot at boot
#   5 HARD GATE   `lnetctl net show` must list an efa net, up (⛔ NO MOUNT, NO
#                 FALLBACK — a TCP mount is a human decision in writing, D16)
#   6 mount       mount → boot snapshot (lnetctl/EFA hw_counters/osc params/layout)
#                 → counter-proof of EFA data path incl. EFA retrans bracket
#                 (⛔ unmount on failure) → chown → fstab → tuning + persistence
#                 unit → env.sh → motd
#   (7 is NOT here: bulk-rate transport acceptance is scripts/wsi-lustre-bulk-accept.sh,
#    armed by bootstrap as wsi-lustre-bulk-accept.service, After= this unit.)
#
# Revision 2026-09-10 (post EFA bulk-write failure, dossier 2026-08-21):
#   - Install provenance is now STATED, not assumed: AWS's install-fsx-lustre-client.sh
#     v1.0 (read 2026-09-10) on AL2023 is `dnf install -y lustre-client` plus an EFA
#     gate (check_efa_version >= 2.12.1) that PASSES on this kernel's efa.ko and
#     therefore SKIPS the aws-efa-installer. Stage 3 is that documented path in
#     effect, and logs modinfo/rpm so the journal proves it.
#   - Stage 4 pins --tcp-name from IMDS local-ipv4 instead of trusting `hostname -I`
#     ordering (matters if second_efa_type=efa adds a second netdev).
#   - Stage 6 writes a per-boot snapshot dir under runs/ with everything the
#     failure analysis found missing (lnetctl -v 4, peer show, stats, global, full
#     EFA hw_counters, osc max_pages_per_rpc/import, at_*/timeout, stripe layout).
#
# Usage: sudo scripts/wsi-lustre-phase2.sh [--dry-run]
#   --dry-run prints every mutating command it would run and mutates nothing.
# Idempotent: safe to re-run on a box where any stage already holds.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/configure-efa-fsx-lustre-client"
ENV_SH="$REPO_ROOT/env.sh"
CONF=/etc/wsi-bootstrap.conf
MNT=/mnt/lustre
U=ec2-user
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

warn()  { echo "WSI-WARN: $*"; }
step()  { printf '\n===== phase2 %s ===== (%s)\n' "$*" "$(date -u +%H:%M:%S)"; }
fatal() { # every fatal leaves the fs unmounted and says why that is the safe state
  echo "WSI-FATAL: $*" >&2
  echo "WSI-FATAL: $MNT left UNMOUNTED deliberately — a wrong or unproven-transport mount" >&2
  echo "           produces plausible numbers for a configuration this project refuses to" >&2
  echo "           measure (D16). Fix the cause or take it to the human; never mount around it." >&2
  exit 2
}
run() { # run <cmd...> — honor --dry-run for every mutating command
  if [ "$DRY" -eq 1 ]; then echo "DRY-RUN would run: $*"; else "$@"; fi
}
IMDS_TOK=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
imds() { curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOK" "http://169.254.169.254/latest/meta-data/$1"; }
py_set() { # py_set KEY VALUE — overwrite an existing export line, else insert before --check
  [ "$DRY" -eq 1 ] && { echo "DRY-RUN would py_set $1=\"$2\" in $ENV_SH"; return 0; }
  python3 - "$ENV_SH" "$1" "$2" <<'PY'
import sys,re
p,k,v=sys.argv[1:4]
lines=open(p).read().splitlines(True)
pat=re.compile(r'^(\s*)export '+re.escape(k)+r'=')
done=False
for i,l in enumerate(lines):
    if pat.match(l):
        lines[i]=re.sub(r'^(\s*export '+re.escape(k)+r'=)"[^"]*"', r'\1"'+v+'"', l)
        done=True; break
if not done:
    for i,l in enumerate(lines):
        if l.startswith('if [ "${1:-}" = "--check" ]'):
            lines.insert(i,f'export {k}="{v}"\n'); done=True; break
open(p,'w').write(''.join(lines))
sys.exit(0 if done else 1)
PY
}

[ "$(id -u)" -eq 0 ] || fatal "must run as root (sudo)"
[ -f "$CONF" ] || fatal "$CONF missing — terraform user-data did not deliver the FSx facts"
# shellcheck disable=SC1090
source "$CONF"
[ "${LEG:-}" = "lustre" ] || fatal "LEG='${LEG:-}' in $CONF — this script is lustre-only and must never run on Leg A"
for v in FSX_ID FSX_DNS_NAME FSX_MOUNT_NAME; do
  [ -n "${!v:-}" ] || fatal "$v empty in $CONF — never retype FSx identity by hand; fix terraform"
done

step "1. preflight: file-system spec + EFA hardware + reachability"
SPEC=$(aws fsx describe-file-systems --file-system-ids "$FSX_ID" --region "${AWS_REGION:-ap-northeast-2}" \
  --query 'FileSystems[0].[Lifecycle,LustreConfiguration.DeploymentType,LustreConfiguration.PerUnitStorageThroughput,LustreConfiguration.EfaEnabled,StorageCapacity,LustreConfiguration.MetadataConfiguration.Mode,LustreConfiguration.MetadataConfiguration.Iops,LustreConfiguration.MountName]' \
  --output text 2>&1) || fatal "describe-file-systems failed for $FSX_ID: $SPEC"
read -r LC DT PUT EFA CAP MDMODE MDIOPS MNAME <<<"$SPEC"
echo "fs: $FSX_ID lifecycle=$LC type=$DT put=$PUT efa=$EFA cap=${CAP}GiB metadata=$MDMODE/$MDIOPS mount=$MNAME"
# The spec below IS the ratified experiment (thesis/D7); a wrong filesystem measured
# correctly is still the wrong experiment. Metadata IOPS is recorded, not asserted at
# a number — the placeholder may be raised as a ratified provisioning event.
[ "$LC" = "AVAILABLE" ]        || fatal "file system not AVAILABLE (got $LC)"
[ "$DT" = "PERSISTENT_2" ]     || fatal "deployment type $DT != PERSISTENT_2 (D7 fairness basis)"
[ "$PUT" = "1000" ]            || fatal "per-unit throughput $PUT != 1000 MB/s/TiB (D7: the top SSD tier)"
[ "$EFA" = "True" ]            || fatal "EfaEnabled=$EFA — the fs was not created EFA-enabled"
[ "$CAP" = "28800" ]           || fatal "capacity ${CAP}GiB != ratified 28800 GiB"
[ "$MDMODE" = "USER_PROVISIONED" ] || fatal "metadata mode $MDMODE != USER_PROVISIONED (D7)"
[ "$MNAME" = "$FSX_MOUNT_NAME" ]   || fatal "live mount name $MNAME != conf $FSX_MOUNT_NAME"
EFA_DEVS=()
for i in /sys/class/infiniband/*; do
  [ -e "$i/device/driver" ] || continue
  [ "$(basename "$(realpath "$i/device/driver")")" = "efa" ] && EFA_DEVS+=("$(basename "$i")")
done
[ "${#EFA_DEVS[@]}" -ge 1 ] || fatal "no EFA device under /sys/class/infiniband — the instance was launched without an EFA interface (terraform: interface_type=efa); no client config can fix that"
echo "EFA device(s): ${EFA_DEVS[*]}"
# Terraform's second_efa_type is delivered via the conf (2026-09-10). A mismatch
# means EC2 did not wire what was asked — the ratified topology is not what is
# running, and every number would be measured against the wrong ceiling.
if [ -n "${EFA_RAILS_EXPECTED:-}" ]; then
  [ "${#EFA_DEVS[@]}" -eq "$EFA_RAILS_EXPECTED" ] \
    || fatal "EFA device count ${#EFA_DEVS[@]} != EFA_RAILS_EXPECTED=$EFA_RAILS_EXPECTED (terraform second_efa_type=${SECOND_EFA_TYPE:-?}) — EC2 did not deliver the ratified rail count; no client config can fix that"
  echo "rail count matches terraform (second_efa_type=${SECOND_EFA_TYPE:-?} -> $EFA_RAILS_EXPECTED)"
  for d in "${EFA_DEVS[@]}"; do
    echo "  $d numa_node=$(cat "/sys/class/infiniband/$d/device/numa_node" 2>/dev/null || echo ?) pci=$(basename "$(readlink -f "/sys/class/infiniband/$d/device")" 2>/dev/null)"
  done
fi
getent hosts "$FSX_DNS_NAME" >/dev/null || fatal "DNS not resolving for $FSX_DNS_NAME"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$FSX_DNS_NAME/988" \
  || fatal "port 988 unreachable — security-group/subnet problem, not a client problem"

step "2. in-kernel EFA driver gate (AWS minimum 2.12.1)"
EFA_VER=$(modinfo efa 2>/dev/null | awk '/^version:/ {print $2}' | sed 's/[^0-9.]//g')
[ -n "$EFA_VER" ] || fatal "efa kernel module absent — AMI/kernel drift (D-17 tripwire); the walk's AMI shipped it in-kernel"
[ "$(printf '%s\n' "2.12.1" "$EFA_VER" | sort -V | head -1)" = "2.12.1" ] \
  || fatal "efa.ko $EFA_VER < 2.12.1 (AWS's own minimum) — AMI/kernel drift (D-17)"
echo "efa.ko $EFA_VER OK (in-kernel; no userspace EFA installer needed for the kernel Lustre path)"

step "3. lustre client (userspace only; kernel must not move — D-17)"
KERNEL_BEFORE=$(uname -r)
if rpm -q lustre-client >/dev/null 2>&1; then
  echo "already installed: $(rpm -q lustre-client)"
else
  run dnf install -y lustre-client || fatal "dnf install lustre-client failed"
fi
[ "$(uname -r)" = "$KERNEL_BEFORE" ] || fatal "kernel changed during install ($KERNEL_BEFORE -> $(uname -r)) — D-17 violation; stop and re-baseline decision is the human's"
if [ "$DRY" -eq 0 ]; then
  rpm -q lustre-client
  modinfo kefalnd >/dev/null 2>&1 || fatal "kefalnd absent for $(uname -r) — this Lustre client cannot do EFA (AWS's own support gate); D-17/AMI drift"
  LFS_VER=$(lfs --version 2>/dev/null | awk '{print $2}')
  [ "$(printf '%s\n' "2.15" "$LFS_VER" | sort -V | head -1)" = "2.15" ] || fatal "lfs $LFS_VER < 2.15 (metadata-IOPS client requirement)"
  echo "kernel unchanged; kefalnd present; lfs $LFS_VER"
  # Provenance into the journal (2026-09-10). This is what a support engineer will
  # check first; state it before they do.
  echo "provenance: kernel=$(uname -r)"
  echo "provenance: $(rpm -q lustre-client) tag=$(rpm -q --qf '%{RELEASE}' lustre-client 2>/dev/null)"
  echo "provenance: efa.ko version=$(modinfo efa | awk '/^version:/{print $2}') file=$(modinfo -n efa)"
  echo "provenance: kefalnd version=$(modinfo kefalnd | awk '/^version:/{print $2}') file=$(modinfo -n kefalnd)"
  echo "provenance: AWS install-fsx-lustre-client.sh v1.0 on AL2023 == 'dnf install -y lustre-client' + efa gate (check_efa_version >= 2.12.1) that passes on this efa.ko and skips the aws-efa-installer. This stage IS that documented path in effect."
fi

# Guard (2026-09-10): the AWS configurator writes libcfs cpu_npartitions/cpu_pattern
# to modprobe.conf and THEN modprobes lnet. If libcfs/lnet are already resident
# before it runs, those options silently do not apply and the CPT layout is wrong
# with no error anywhere. On reboots the configurator runs first (unit After=),
# so resident modules are expected then — the guard applies only when it has not.
if [ "$DRY" -eq 0 ]; then
  if systemctl is-failed --quiet configure-efa-fsx-lustre-client.service 2>/dev/null; then
    fatal "configure-efa-fsx-lustre-client.service FAILED this boot — journalctl -u configure-efa-fsx-lustre-client.service; do NOT hand-configure around it"
  elif ! systemctl is-active --quiet configure-efa-fsx-lustre-client.service 2>/dev/null; then
    if lsmod | grep -qE '^(libcfs|lnet) '; then
      fatal "libcfs/lnet already loaded before the AWS configurator ran ($(lsmod | awk '/^(libcfs|lnet|kefalnd|ksocklnd|lustre) /{printf "%s ",$1}')) — its libcfs CPT options would NOT apply. Find what loaded them (journalctl -b, /etc/modules-load.d); never configure around it"
    fi
  fi
fi

step "4. EFA LNet config + boot re-arm (vendored AWS bundle)"
[ -x "$VENDOR_DIR/setup.sh" ] || fatal "vendored bundle missing at $VENDOR_DIR (see VENDORED.md)"
# --tcp-name pinned from IMDS (2026-09-10): the configurator's default is "the
# first UP interface in `hostname -I`", which is an ordering accident once a
# second netdev exists (second_efa_type=efa). setup.sh bakes the value into the
# boot oneshot's ExecStart, so it is deterministic on every boot too.
PRIMARY_IP=$(imds local-ipv4) || fatal "IMDS local-ipv4 unavailable — cannot pin the LNet tcp interface"
TCP_IF=$(ip -br -4 addr | awk -v ip="$PRIMARY_IP" '$3 ~ "^"ip"/" {print $1; exit}')
[ -n "$TCP_IF" ] || fatal "no interface carries IMDS local-ipv4 $PRIMARY_IP (ip -br -4 addr: $(ip -br -4 addr | tr '\n' ';'))"
echo "LNet tcp interface pinned: $TCP_IF ($PRIMARY_IP)"
if systemctl is-enabled --quiet configure-efa-fsx-lustre-client.service 2>/dev/null \
   && lnetctl net show 2>/dev/null | grep -q 'net type: efa'; then
  echo "already configured and armed (service enabled, efa net present) — skipping setup.sh"
  grep -q -- "--tcp-name $TCP_IF" /etc/systemd/system/configure-efa-fsx-lustre-client.service 2>/dev/null \
    || warn "armed unit does not carry --tcp-name $TCP_IF (older setup.sh invocation) — re-run setup.sh by hand to pin it, or accept hostname -I auto-detect"
else
  ( cd "$VENDOR_DIR" && run ./setup.sh --tcp-name "$TCP_IF" ) || fatal "AWS configure-efa setup.sh failed — read its output above; do NOT hand-configure around it"
fi

step "5. HARD GATE (D16): lnetctl must evidence an efa net"
if [ "$DRY" -eq 1 ]; then
  echo "DRY-RUN: would require 'lnetctl net show' to list an efa net, status up"
else
  NETSHOW=$(lnetctl net show 2>&1) || fatal "lnetctl net show failed: $NETSHOW"
  echo "$NETSHOW"
  echo "$NETSHOW" | grep -q 'net type: efa' \
    || fatal "NO efa net after configuration — TCP-only. NOT mounting. A TCP mount works, looks fine, and silently forfeits the fairness basis (D16); mounting over TCP is a human decision, in writing."
  echo "$NETSHOW" | sed -n '/net type: efa/,/interfaces/p' | grep -q 'status: up' \
    || fatal "efa net present but not up — fix before any mount"
  FSX_IP=$(getent hosts "$FSX_DNS_NAME" | awk '{print $1}')
  lnetctl ping "$FSX_IP@tcp" >/dev/null 2>&1 || fatal "lnetctl ping $FSX_IP@tcp failed — MGS unreachable at LNet level"
  echo "GATE PASSED: efa net up; MGS $FSX_IP answers"
fi

step "6. mount + transport proof + tuning + env + motd"
run mkdir -p "$MNT"
if mountpoint -q "$MNT"; then
  echo "already mounted: $(findmnt -n "$MNT")"
else
  # @tcp in the device string is CORRECT for an EFA-enabled fs: it is the MGS NID;
  # discovery + UDSP route data over efa. The counters below are the proof.
  run mount -t lustre -o relatime,flock "$FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME" "$MNT" \
    || fatal "mount failed"
fi
if [ "$DRY" -eq 0 ]; then
  # Per-boot snapshot (2026-09-10): everything the 2026-08-21 failure analysis
  # found missing from the evidence, captured before and after the proof write so
  # every later probe has an exact same-boot baseline. Small text -> git; runs/
  # convention.
  SNAP_DIR="$REPO_ROOT/runs/$(date -u +%Y-%m-%d-%H%M%S)-lustre-phase2-boot-snapshot"
  snapshot() { # snapshot <tag>
    local d="$SNAP_DIR/$1"; mkdir -p "$d"
    lnetctl net show -v 4      > "$d/lnetctl-net-show-v4.txt"   2>&1
    lnetctl peer show -v 4     > "$d/lnetctl-peer-show-v4.txt"  2>&1
    lnetctl stats show         > "$d/lnetctl-stats.txt"         2>&1
    lnetctl global show        > "$d/lnetctl-global.txt"        2>&1
    lnetctl udsp show          > "$d/lnetctl-udsp.txt"          2>&1
    for dev in "${EFA_DEVS[@]}"; do
      for f in /sys/class/infiniband/"$dev"/ports/1/hw_counters/*; do
        [ -r "$f" ] && echo "$dev $(basename "$f") $(cat "$f")"
      done
    done > "$d/efa-hw-counters.txt" 2>/dev/null
    lctl get_param osc.*.max_pages_per_rpc osc.*.max_rpcs_in_flight osc.*.import > "$d/osc-params-import.txt" 2>&1
    lctl get_param timeout at_min at_max at_history > "$d/ptlrpc-timeouts.txt" 2>&1
    lctl get_param lnet.lnet_transaction_timeout lnet.lnet_retry_count lnet.lnet_health_sensitivity > "$d/lnet-timeouts.txt" 2>&1
    { echo "kernel: $(uname -r)"; rpm -q lustre-client; echo; modinfo efa; echo; modinfo kefalnd; } > "$d/provenance.txt" 2>&1
    cat /etc/modprobe.d/modprobe.conf > "$d/modprobe.conf" 2>/dev/null
    cat /etc/systemd/system/configure-efa-fsx-lustre-client.service > "$d/configure-efa.service" 2>/dev/null
    lfs getstripe -d "$MNT"    > "$d/lfs-getstripe-root.txt"     2>&1
    lfs df -h "$MNT"           > "$d/lfs-df.txt"                 2>&1
    ip -br addr                > "$d/ip-br-addr.txt"             2>&1
    ethtool -S "$TCP_IF" 2>/dev/null | grep -iE 'allowance|drop|err' > "$d/ethtool-$TCP_IF-allowance.txt" 2>&1
  }
  efa_sends() { lnetctl net show -v 4 2>/dev/null | sed -n '/net type: efa/,/net type:/p' | awk '/send_count:/{s+=$2} END{print s+0}'; }
  efa_ctr_sum() { # efa_ctr_sum <counter> — summed over all EFA devices
    local s=0 v; for dev in "${EFA_DEVS[@]}"; do v=$(cat "/sys/class/infiniband/$dev/ports/1/hw_counters/$1" 2>/dev/null || echo 0); s=$((s + v)); done; echo "$s"
  }
  snapshot pre-proof
  B=$(efa_sends); RT_B=$(efa_ctr_sum retrans_timeout_events); RP_B=$(efa_ctr_sum retrans_pkts)
  dd if=/dev/zero of="$MNT/.wsi-phase2-transport-probe" bs=1M count=100 oflag=direct status=none \
    || { umount "$MNT"; fatal "direct-I/O probe write failed"; }
  A=$(efa_sends); RT_A=$(efa_ctr_sum retrans_timeout_events); RP_A=$(efa_ctr_sum retrans_pkts)
  rm -f "$MNT/.wsi-phase2-transport-probe"
  snapshot post-proof
  chown -R "$U:$U" "$SNAP_DIR" 2>/dev/null || true
  DELTA=$((A - B))
  echo "transport proof: efa send_count +$DELTA across a 100MiB direct write (expect ~100, one RPC per MiB)"
  echo "transport proof: EFA retrans bracket across the same write: retrans_timeout_events +$((RT_A - RT_B)), retrans_pkts +$((RP_A - RP_B)) (expect 0/0; the 2026-08-21 box showed exactly 0 on small transfers)"
  echo "boot snapshot: $SNAP_DIR/{pre-proof,post-proof}"
  [ $((RT_A - RT_B)) -eq 0 ] || warn "EFA retransmission timeouts moved during a 100 MiB write — the small-transfer path is NOT clean on this boot (it was on 2026-08-21). Recorded, not fatal; the bulk-accept ladder will tell the rest."
  if [ "$DELTA" -lt 50 ]; then
    umount "$MNT"
    fatal "data moved but efa counters barely did (+$DELTA) — the mount is passing data over tcp despite the efa net. UNMOUNTED. This is exactly the silent failure D16 exists for."
  fi
fi
run chown "$U:$U" "$MNT"
[ "$DRY" -eq 0 ] && runuser -u "$U" -- mkdir -p "$MNT/data"
FSTAB_LINE="$FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME $MNT lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=configure-efa-fsx-lustre-client.service,x-systemd.after=configure-efa-fsx-lustre-client.service 0 0"
if grep -q "$FSX_MOUNT_NAME" /etc/fstab; then
  echo "fstab entry already present"
else
  if [ "$DRY" -eq 1 ]; then echo "DRY-RUN would append to /etc/fstab: $FSTAB_LINE"; else
    echo "$FSTAB_LINE" >> /etc/fstab && systemctl daemon-reload
  fi
fi

# D-11 client tuning (ratified 2026-08-20; AWS performance-tips for >64 vCPU / >64 GiB).
# The two modprobe options (ksocklnd credits, ptlrpcd_per_cpt_max) are written by the
# AWS configure script in stage 4. lctl values do not survive reboot -> systemd unit.
TUNE_CMDS=(
  "lctl set_param ldlm.namespaces.*.lru_max_age=600000"
  "lctl set_param ldlm.namespaces.*.lru_size=$((100 * $(nproc)))"
  "lctl set_param osc.*OST*.max_rpcs_in_flight=32"
  "lctl set_param mdc.*.max_rpcs_in_flight=64"
  "lctl set_param mdc.*.max_mod_rpcs_in_flight=50"
  "lctl set_param llite.*.statahead_max=512"
  "lctl set_param llite.*.statahead_agl=1"
  "lctl set_param llite.*.statahead_xattr=1"
)
for c in "${TUNE_CMDS[@]}"; do
  if [ "$DRY" -eq 1 ]; then echo "DRY-RUN would run: $c"; else
    $c >/dev/null 2>&1 || warn "tuning failed (recorded, not fatal): $c"
  fi
done
TUNING_UNIT=/etc/systemd/system/wsi-lustre-tuning.service
if [ "$DRY" -eq 1 ]; then echo "DRY-RUN would install+enable $TUNING_UNIT"; else
  {
    echo "[Unit]"
    echo "Description=WSI Lustre client tuning (D-11, AWS performance-tips; lctl values do not survive reboot)"
    echo "RequiresMountsFor=$MNT"
    echo "After=configure-efa-fsx-lustre-client.service"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "RemainAfterExit=yes"
    for c in "${TUNE_CMDS[@]}"; do echo "ExecStart=/usr/sbin/$c"; done
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "$TUNING_UNIT"
  systemctl daemon-reload && systemctl enable wsi-lustre-tuning.service >/dev/null 2>&1
fi

# env.sh: facts from evidence, never from intent. FS_TRANSPORT only after the counter proof.
if [ -f "$ENV_SH" ]; then
  py_set FS_TRANSPORT "efa"
  py_set FSX_TIER "PERSISTENT_2-1000"
  py_set FSX_CAPACITY_TIB "$(python3 -c "print($CAP/1024)")"
  py_set FSX_METADATA_IOPS "$MDIOPS"
  py_set FSX_EFA_ENABLED "true"
  if [ "$DRY" -eq 0 ]; then
    STRIPE=$(runuser -u "$U" -- lfs getstripe -d "$MNT" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
    [ -n "$STRIPE" ] && py_set LUSTRE_STRIPE_LAYOUT "$STRIPE" || warn "lfs getstripe -d returned nothing — LUSTRE_STRIPE_LAYOUT not written (D12 needs it)"
    chown "$U:$U" "$ENV_SH"
  fi
else
  warn "$ENV_SH not found — env values not written (bootstrap creates it; ordering?)"
fi

if [ "$DRY" -eq 0 ] && [ -f /etc/motd.d/50-wsi ]; then
  # flip the bootstrap's not-mounted triage block (3 lines) to the mounted state
  sed -i 's|.*Lustre NOT mounted.*|  3. Lustre is MOUNTED with evidenced EFA (phase-2). Paste the TEMP/ handoff the last session wrote.|' /etc/motd.d/50-wsi
  sed -i '/journalctl -u wsi-lustre-phase2.service; manual fallback:/d;/docs\/cloud-setup\/LUSTRE-PROVISIONING.md/d' /etc/motd.d/50-wsi
fi

step "DONE"
echo "phase-2 complete: $MNT mounted, transport=efa (counter-proven at 100 MiB), tuning applied+armed,"
echo "fstab+systemd re-arm in place, env.sh updated. Cost/ceiling values and the environment"
echo "contract remain SESSION work (human-ratified numbers; env-contract.py write --leg lustre)."
echo "NOT yet proven: transport at SUSTAINED BULK rate. That is wsi-lustre-bulk-accept.service"
echo "(After= this unit; runs once after bootstrap). No runs/.leg-state/lustre/bulk-transport-PASS"
echo "means the leg is not runnable — the 2026-08-21 failure was invisible below bulk rate."
