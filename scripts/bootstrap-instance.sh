#!/usr/bin/env bash
# bootstrap-instance.sh — WEKA-leg client bootstrap (Amazon Linux 2023, ec2-user).
#
# WHAT THIS IS
#   The single, git-tracked copy of instance provisioning. On the WEKA leg it is
#   launched by terraform-aws-weka's clients_custom_data_post_mount wrapper, as
#   root, AFTER /mnt/weka is mounted. It builds the client end-to-end and
#   collapses TEARDOWN-AND-REBUILD's rebuild to: terraform apply -> SSH in ->
#   claude /login.
#
# DESIGN RULES (CLAUDE.md)
#   - Facts land in env.sh from THIS instance's own evidence, never from config
#     intent (D16: FS_TRANSPORT is written only when the client's own state shows
#     DPDK; otherwise it stays blank for the session to investigate).
#   - No `dnf upgrade` EVER: the kernel is a MUST_MATCH contract field (D-17).
#     Patching is a human decision made with the contract in view.
#   - Hydration (S3 -> $FS_MOUNT) is measured cell 1.7 and is NOT done here.
#     Dataset prefetch populates S3 only (see prefetch-datasets-to-s3.sh).
#   - Refuse loudly rather than default quietly; every failure is in the log
#     with a WSI-WARN/WSI-FATAL prefix so `grep WSI- /var/log/wsi-bootstrap.log`
#     is the whole triage.
#
# IDEMPOTENCY: safe to re-run (FORCE=1 bypasses the completion marker).
set -uo pipefail
exec >> /var/log/wsi-bootstrap.log 2>&1

MARKER=/var/lib/wsi-bootstrap.done
if [ -f "$MARKER" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "bootstrap: marker present ($MARKER) — already ran. FORCE=1 to re-run."
  exit 0
fi

CONF=/etc/wsi-bootstrap.conf
[ -f "$CONF" ] && . "$CONF"
S3_BUCKET="${S3_BUCKET:-liad-wsi-cloud}"
SSM_PREFIX="${SSM_PREFIX:-/wsi-bench}"
DATASET_PREFETCH="${DATASET_PREFETCH:-none}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
# Concurrent legs (D6): the wrapper's conf says which leg this box is. Absent = weka
# (Leg-A back-compat). On lustre the wrapper also delivers the FSx facts from
# terraform — never retyped by anyone.
LEG="${LEG:-weka}"
FSX_ID="${FSX_ID:-}"; FSX_DNS_NAME="${FSX_DNS_NAME:-}"; FSX_MOUNT_NAME="${FSX_MOUNT_NAME:-}"

U=ec2-user
UH=/home/$U
REPO=$UH/wsi-cloud
SCRATCH=/data/local-nvme
# Historical name; holds the filesystem-under-test mount on EITHER leg.
WEKA_MNT=/mnt/weka
[ "$LEG" = "lustre" ] && WEKA_MNT=/mnt/lustre
warn()  { echo "WSI-WARN: $*"; }
fatal() { echo "WSI-FATAL: $*"; }
step()  { printf '\n===== %s ===== (%s)\n' "$*" "$(date -u +%H:%M:%S)"; }
as_u()  { runuser -u $U -- "$@"; }

step "0. facts"
TOK=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
imds() { curl -sf -H "X-aws-ec2-metadata-token: $TOK" "http://169.254.169.254/latest/meta-data/$1"; }
REGION=$(imds placement/region); AZ=$(imds placement/availability-zone)
INSTANCE_ID=$(imds instance-id);  AMI_ID=$(imds ami-id); ITYPE=$(imds instance-type)
HOSTN=$(hostname)
echo "region=$REGION az=$AZ instance=$INSTANCE_ID ami=$AMI_ID type=$ITYPE host=$HOSTN kernel=$(uname -r)"
grep -q "Amazon Linux 2023" /etc/os-release || warn "not AL2023 — this script targets AL2023; proceeding anyway"

step "1. base packages (no dnf upgrade — D-17)"
dnf install -y git tmux jq unzip rsync tar wget numactl mdadm fio pciutils python3-pip \
  sysstat tree \
  gcc make automake autoconf \
  kernel-devel-"$(uname -r)" kernel-headers-"$(uname -r)" kernel-modules-extra \
  || warn "some base packages failed — check the dnf output above"
# GNU parallel (4 pipeline call sites) — may not be packaged for AL2023.
if ! command -v parallel >/dev/null; then
  dnf install -y parallel \
    || ( cd /tmp && wget -q https://ftp.gnu.org/gnu/parallel/parallel-latest.tar.bz2 \
         && tar -xjf parallel-latest.tar.bz2 && cd parallel-*/ \
         && ./configure >/dev/null && make -s install && cd /tmp && rm -rf parallel-* ) \
    || warn "GNU parallel unavailable — scripts invoking it will fail (see SCRIPT-TRACKER)"
fi
dnf install -y nodejs22 nodejs22-npm || dnf install -y nodejs20 nodejs20-npm || dnf install -y nodejs npm \
  || warn "no Node.js — Claude Code npm fallback unavailable"
command -v node >/dev/null || { for n in /usr/bin/node-22 /usr/bin/node-20; do [ -x "$n" ] && ln -sf "$n" /usr/bin/node; done; }
command -v npm  >/dev/null || { for n in /usr/bin/npm-22 /usr/bin/npm-20;   do [ -x "$n" ] && ln -sf "$n" /usr/bin/npm;  done; }
echo "node=$(node --version 2>/dev/null || echo none) npm=$(npm --version 2>/dev/null || echo none)"

# fpart/fpsync (Stage 1.1 / 6.C ingest). Best-effort: not packaged for AL2023.
if ! command -v fpsync >/dev/null; then
  ( cd /tmp && rm -rf fpart && git clone -q --depth 1 https://github.com/martymac/fpart.git \
    && cd fpart && autoreconf -i >/dev/null 2>&1 && ./configure >/dev/null && make -s && make -s install ) \
    || warn "fpsync build failed — Stage 1.1/6.C ingest cells need it (install fpart by hand and retry)"
fi
echo "fpsync=$(command -v fpsync || echo MISSING)"

step "2. NVIDIA driver / CUDA / GDS (AL2023 NVIDIA repo)"
# Rebuild pinning: if a Leg-A contract exists in S3, try to install the SAME driver
# branch it recorded; a silent driver drift would violate MUST_MATCH.
# Two contract roles (D6, concurrent legs): the PIN REFERENCE is always Leg A's
# contract — Leg A defines every MUST_MATCH value, both legs pin to it. The
# REBUILD-MERGE contract is THIS leg's own — recovering a leg's env fields from
# the OTHER leg's contract would write weka facts into a lustre env.sh.
PINREF=/tmp/env-contract-leg-weka.json
PIN_DRIVER=""
if aws s3 cp "s3://$S3_BUCKET/env-contracts/env-contract-leg-weka.json" "$PINREF" 2>/dev/null; then
  PIN_DRIVER=$(python3 -c "import json;c=json.load(open('$PINREF'));print(c.get('driver_version') or '')" 2>/dev/null)
fi
CONTRACT=/tmp/env-contract-leg-$LEG.json
REBUILD=0
if aws s3 cp "s3://$S3_BUCKET/env-contracts/env-contract-leg-$LEG.json" "$CONTRACT" 2>/dev/null; then
  REBUILD=1; echo "own-leg contract found in S3 -> REBUILD mode"
fi
dnf install -y nvidia-release || warn "nvidia-release install failed — no AL2023 NVIDIA repo"
if [ -n "$PIN_DRIVER" ]; then
  dnf install -y "nvidia-driver-$PIN_DRIVER*" \
    || { warn "pinned driver $PIN_DRIVER unavailable — installing latest (POSSIBLE MUST_MATCH DRIFT)"; \
         touch /var/lib/wsi-DRIVER-DRIFT-CHECK-ME; dnf install -y nvidia-driver; }
else
  dnf install -y nvidia-driver || warn "nvidia-driver install failed"
fi
# System toolkit tracks the envs' CUDA major (they pin cuda-version=12.*): a NEWER
# system libcufile preloaded over cuCIM's bundled one segfaults (standing constraint),
# and gdscheck must come from the line the kvikIO cells actually preload.
dnf install -y cuda-toolkit-12-9 || dnf install -y cuda-toolkit || warn "CUDA toolkit install failed"
dnf install -y nvidia-fs || dnf install -y nvidia-gds || warn "nvidia-fs/GDS not installed — kvikIO cells run compat-only until resolved by hand"
systemctl enable --now nvidia-persistenced 2>/dev/null || true
# nvidia-fs I/O counters default OFF, and a kvikIO cell run that way records a
# GPU-direct-vs-bounced byte split that is present and entirely zero — read as
# "no GPU-direct traffic" instead of "accounting was off", corrupting the D8
# determination. Enable before first use and persist across module reloads.
printf 'options nvidia_fs rw_stats_enabled=1 peer_stats_enabled=1\n' > /etc/modprobe.d/nvidia-fs-stats.conf
modprobe nvidia 2>/dev/null; modprobe nvidia_fs 2>/dev/null || true
for _p in rw_stats_enabled peer_stats_enabled; do
  echo 1 > "/sys/module/nvidia_fs/parameters/$_p" 2>/dev/null || warn "could not enable nvidia_fs $_p — cuFile path accounting will read all-zero"
done
if nvidia-smi >/dev/null 2>&1; then
  DRIVER_V=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
  echo "GPU OK: driver=$DRIVER_V  gpus=$(nvidia-smi -L | wc -l)"
else
  fatal "nvidia-smi failed — GPU stack NOT working; must be resolved before any GPU cell"
fi
ls -d /usr/local/cuda* 2>/dev/null || warn "no /usr/local/cuda — check cuda-toolkit install"

step "3. local NVMe scratch -> $SCRATCH"
if mountpoint -q "$SCRATCH"; then
  echo "scratch already mounted"
else
  # Instance-store disks only: unmounted, no fs, no partitions. Never touches root.
  CAND=()
  for d in /dev/nvme*n1; do
    [ -b "$d" ] || continue
    lsblk -no MOUNTPOINT,FSTYPE "$d" | grep -q '[^[:space:]]' && continue
    [ "$(lsblk -no TYPE "$d" | wc -l)" -gt 1 ] && continue   # has partitions
    CAND+=("$d")
  done
  echo "candidate scratch disks: ${CAND[*]:-none}"
  if [ "${#CAND[@]}" -ge 2 ]; then
    mdadm --create /dev/md/wsi-scratch --level=0 --raid-devices="${#CAND[@]}" "${CAND[@]}" --force --run \
      && mkfs.xfs -f /dev/md/wsi-scratch && DEV=/dev/md/wsi-scratch \
      && mdadm --detail --scan >> /etc/mdadm.conf || DEV=""
  elif [ "${#CAND[@]}" -eq 1 ]; then
    mkfs.xfs -f "${CAND[0]}" && DEV="${CAND[0]}" || DEV=""
  else
    DEV=""
  fi
  if [ -n "${DEV:-}" ]; then
    if mkdir -p "$SCRATCH" && mount "$DEV" "$SCRATCH"; then
      # only a MOUNTED scratch earns an fstab entry — the old && … || chain
      # appended one even when the mount itself failed
      grep -q "$SCRATCH" /etc/fstab || echo "$DEV $SCRATCH xfs defaults,noatime,nofail 0 0" >> /etc/fstab
    else
      warn "scratch mount of $DEV at $SCRATCH FAILED — fstab not touched; env builds will land on the root disk"
    fi
  else
    fatal "no scratch device prepared — CONDA_ROOT/CONDA_ENVS_DIR live on $SCRATCH; env builds skipped"
  fi
fi
mkdir -p "$SCRATCH" && chown $U:$U "$SCRATCH" && df -h "$SCRATCH" || true

step "4. filesystem-under-test ownership"
if [ "$LEG" = "lustre" ]; then
  # The lustre mount is a GATED, session-driven step (prompt: EFA config + lnetctl
  # gate + human approvals; later the baked phase-2). Phase 1 only prepares the
  # mount point; ownership is set post-mount.
  mkdir -p "$WEKA_MNT"
  echo "lustre leg: $WEKA_MNT prepared; mount deferred to the gated walk / phase-2"
else
  mountpoint -q "$WEKA_MNT" || fatal "$WEKA_MNT not mounted — post_mount ordering violated?"
  chown $U:$U "$WEKA_MNT" 2>/dev/null || warn "could not chown $WEKA_MNT"
fi

step "5.0 WEKA cluster login (admin password from Secrets Manager)"
if [ "$LEG" = "lustre" ]; then
  echo "lustre leg: no cluster login (managed service)"
else
# Cluster-level queries (weka status / weka cluster ...) need `weka user login`;
# the local ones (weka local *) and the DPDK evidence below do not. The module
# stores the generated admin password in Secrets Manager as
# weka/<prefix>-<cluster>/weka-password-<suffix> (the suffix regenerates per cluster).
# We log in as BOTH root (this script's queries) and ec2-user (so no human ever
# runs `weka user login` on this box again). On any failure the cluster facts
# below simply stay blank/pending in env.sh — nothing else breaks.
LB_HOST=$(findmnt -n -o SOURCE "$WEKA_MNT" 2>/dev/null | cut -d/ -f1)
CLUSTER_HINT=$(echo "$LB_HOST" | sed 's/^internal-//; s/-lb-[0-9]*\..*$//')
sm_fetch() { # sm_fetch SECRET_ID -> prints the password (handles raw or JSON SecretString)
  local raw
  raw=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" \
          --query SecretString --output text 2>/dev/null) || return 1
  case "$raw" in
    \{*) printf '%s' "$raw" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('password') or d.get('value') or '')" ;;
    *)   printf '%s' "$raw" ;;
  esac
}
sm_discover() { # find weka/<cluster>/weka-password-* by name (suffix regenerates on rebuilds)
  aws secretsmanager list-secrets --region "$REGION" \
      --query "SecretList[].Name" --output text 2>/dev/null \
    | tr '\t' '\n' | grep -F "$CLUSTER_HINT" | grep -i password | head -1
}
SECRET_ID="${WEKA_PASSWORD_SECRET_ID:-}"
WEKA_PASS=""
[ -n "$SECRET_ID" ] && WEKA_PASS=$(sm_fetch "$SECRET_ID")
if [ -z "$WEKA_PASS" ] && [ -n "$CLUSTER_HINT" ]; then
  [ -n "$SECRET_ID" ] && warn "configured secret id did not resolve (suffix regenerated on a rebuild?) — trying name discovery"
  SECRET_ID=$(sm_discover)
  [ -n "$SECRET_ID" ] && { echo "discovered secret: $SECRET_ID (hint: $CLUSTER_HINT)"; WEKA_PASS=$(sm_fetch "$SECRET_ID"); }
fi
WEKA_AUTH=0
if [ -n "$WEKA_PASS" ]; then
  # Not echoed, not traced (this script does not run under set -x). The value is
  # briefly visible in argv, same as the documented manual login on this box.
  if weka user login admin "$WEKA_PASS" >/dev/null 2>&1; then
    WEKA_AUTH=1
    as_u env HOME=$UH weka user login admin "$WEKA_PASS" >/dev/null 2>&1 \
      && echo "weka login OK (root + $U)" \
      || { warn "weka login OK as root but FAILED for $U"; }
  else
    warn "weka user login failed with the retrieved secret ($SECRET_ID)"
  fi
else
  warn "no WEKA password retrievable (id + discovery both failed: IAM GetSecretValue/ListSecrets? KMS?) — cluster facts stay pending; log in manually and re-run with FORCE=1, or record them into env.sh by hand"
fi
unset WEKA_PASS

fi

step "5. WEKA facts (evidence, not intent — D16)"
if [ "$LEG" = "lustre" ]; then
  # Lustre facts phase 1 can honestly state: the fs identity from terraform via the
  # conf. Transport evidence (lnetctl showing efa) is POST-MOUNT — FS_TRANSPORT
  # stays blank, and run-leg's D16 gate keeps refusing until phase-2/the walk
  # writes the evidenced value. Blank-and-refused beats guessed-and-plausible.
  FS_NAME="${FSX_MOUNT_NAME:-}"; EC=""; CAP=""; CAP_TIB=""; BACKENDS=""; CLIENT_CORES=""
  BOUND_NICS=0; FS_TRANSPORT=""
  echo "lustre leg: fs_name=$FS_NAME (from terraform conf); FS_TRANSPORT pending phase-2 lnetctl evidence (D16)"
else
FS_NAME=$(findmnt -n -o SOURCE "$WEKA_MNT" 2>/dev/null | awk -F/ '{print $NF}')
WSTAT=$(weka status 2>/dev/null || true)
EC=$(echo "$WSTAT"     | sed -n 's/.*protection: \([0-9]\++[0-9]\+\).*/\1/p' | head -1)
# `weka status` reports TiB; the env variable is WEKA_CAPACITY_TB, so convert —
# the 2026-08 rebuild wrote the TiB number under the TB name and the ~10% unit
# error would have flowed into the contract and every capacity computation.
CAP_TIB=$(echo "$WSTAT" | sed -n 's/.*drive storage: \([0-9.]\+\) TiB total.*/\1/p' | head -1)
CAP=$([ -n "$CAP_TIB" ] && awk -v t="$CAP_TIB" 'BEGIN{printf "%.2f", t*1.099511627776}')
read -r BACKENDS CLIENT_CORES <<< "$(weka cluster container -J 2>/dev/null | python3 -c "
import json,sys
try:
    rows=json.load(sys.stdin); hosts=set(); cores=''
    for r in rows:
        name=(r.get('container') or r.get('container_name') or '')
        hn=r.get('hostname','')
        if name=='client' and '$HOSTN'.startswith(hn.split('.')[0]): cores=str(r.get('cores',''))
        elif name!='client': hosts.add(hn)
    print(len(hosts), cores or '')
except Exception: print('','')" 2>/dev/null)"
[ "$WEKA_AUTH" -eq 0 ] && [ -z "${BACKENDS:-}" ] && warn "cluster facts unavailable without weka login — EC/capacity/backends left pending"
# Local fallback for cores (no cluster auth needed): count FRONTEND rows in the
# local resources table. Strict regex — zero matches means leave it blank.
if [ -z "${CLIENT_CORES:-}" ]; then
  CC=$(weka local resources 2>/dev/null | grep -cE '^[0-9]+[[:space:]]+FRONTEND')
  [ "${CC:-0}" -gt 0 ] && CLIENT_CORES=$CC
fi
# DPDK evidence: ENA functions on PCI that the kernel no longer drives (bound to
# weka/DPDK), plus hugepages actually allocated.
ENA_TOTAL=$(lspci 2>/dev/null | grep -ci 'Elastic Network Adapter' || echo 0)
ENA_KERNEL=$(ip -br link 2>/dev/null | grep -vc '^lo' || echo 0)
BOUND_NICS=$(( ENA_TOTAL - ENA_KERNEL )); [ "$BOUND_NICS" -lt 0 ] && BOUND_NICS=0
HUGE=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
FS_TRANSPORT=""
if [ "$BOUND_NICS" -ge 1 ] && [ "${HUGE:-0}" -gt 0 ]; then FS_TRANSPORT="dpdk"; fi
echo "fs_name=$FS_NAME ec=$EC cap_tb=$CAP (=${CAP_TIB:-?} TiB) backends=$BACKENDS client_cores=$CLIENT_CORES bound_nics=$BOUND_NICS hugepages=$HUGE -> FS_TRANSPORT='${FS_TRANSPORT:-<blank: no evidence>}'"

fi

step "6. env.sh (rebuild-aware)"
ENV_SH=$REPO/env.sh
if [ ! -f "$ENV_SH" ]; then cp "$REPO/env.example.sh" "$ENV_SH"; fi
py_set() { # py_set KEY VALUE — overwrite an existing export line, else insert before --check
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
    if not done: lines.append(f'export {k}="{v}"\n')
open(p,'w').writelines(lines)
PY
}
if [ $REBUILD -eq 1 ]; then
  # Contract merge runs FIRST; this instance's freshly-derived evidence is applied
  # AFTER it and therefore wins where both exist. A mid-leg rebuild can deliberately
  # change the cluster (the 2026-08 backend switch did), so live cluster facts must
  # beat the torn-down cluster's recorded ones — while everything only the contract
  # knows (prices, corpus sizes, reserved cores) still recovers from it.
  # --for-leg weka: this bootstrap builds only the WEKA leg, so a rebuild here is
  # same-leg by definition — the leg-specific fields must emit LIVE or the merge
  # (which consumes only live export lines) drops them, as the 2026-08 rebuild did.
  python3 "$REPO/scripts/env-contract.py" env --file "$CONTRACT" --for-leg "$LEG" 2>/dev/null | \
  while IFS= read -r line; do
    case "$line" in export\ *=\"*\")
      k=${line#export }; k=${k%%=*}; v=${line#*\"}; v=${v%\"*}
      py_set "$k" "$v" ;;
    esac
  done
fi
py_set AWS_REGION "$REGION";            py_set S3_BUCKET "$S3_BUCKET"
py_set LEG "$LEG";                      py_set FS_MOUNT "$WEKA_MNT"
if [ "$LEG" = "lustre" ]; then
  [ -n "$FS_NAME" ]        && py_set FS_NAME "$FS_NAME"
  [ -n "$FSX_ID" ]         && py_set FSX_ID "$FSX_ID"
  [ -n "$FSX_DNS_NAME" ]   && py_set FSX_DNS_NAME "$FSX_DNS_NAME"
  [ -n "$FSX_MOUNT_NAME" ] && py_set FSX_MOUNT_NAME "$FSX_MOUNT_NAME"
  # D15: the Lustre client reserves no cores — set 'none' explicitly at build
  # time, because unset means UNKNOWN and every CPU aggregator refuses it. True
  # regardless of the mount walk (a client-stack property, not a mount fact).
  py_set FS_CLIENT_RESERVED_CORES "none"
fi
[ -n "$EC" ]           && py_set WEKA_EC_SCHEME "$EC"
[ -n "$CAP" ]          && py_set WEKA_CAPACITY_TB "$CAP"
[ -n "$BACKENDS" ]     && py_set WEKA_BACKEND_COUNT "$BACKENDS"
[ -n "$CLIENT_CORES" ] && py_set WEKA_CLIENT_CORES "$CLIENT_CORES"
[ "$BOUND_NICS" -ge 1 ] && py_set WEKA_CLIENT_NICS "$BOUND_NICS"
[ -n "$FS_TRANSPORT" ] && py_set FS_TRANSPORT "$FS_TRANSPORT"
chown $U:$U "$ENV_SH"

step "6.5 cuFile/GDS wiring (D-10 mechanical half)"
# weka leg: ENA, no RDMA — kvikIO cells run libcufile in COMPAT mode by design
# (D8 runs the kvikIO path on both legs); gdscheck reporting GDS unsupported is a
# recorded fact, not a failure. lustre leg: compat is ALSO the expected END state,
# not just the pre-walk default — AWS documents GDS on FSx as requiring a
# P5/P5e/P5en/P6-B200 client and this project's client is g6e (STAGES.md D8,
# checked 2026-08-20). No GDS wiring is expected at the walk/phase-2; only a
# per-cell path split contradicting the docs would reopen it. Per-cell GPU-direct-vs-bounced accounting
# (D-6) remains the proof of path either way; tuning judgment stays with the
# benchmark session (D-10).
CUFILE_DIR=$UH/cufile-config
mkdir -p "$CUFILE_DIR"
if [ ! -f "$CUFILE_DIR/cufile.json" ]; then
  cat > "$CUFILE_DIR/cufile.json" <<'CUF'
{
  "properties": { "allow_compat_mode": true }
}
CUF
fi
chown -R $U:$U "$CUFILE_DIR"
LIBCUFILE=$(ls -1 /usr/local/cuda*/targets/*/lib/libcufile.so.* 2>/dev/null | grep -E 'so\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
if [ -n "$LIBCUFILE" ]; then
  py_set LIBCUFILE_PRELOAD "$LIBCUFILE"
  echo "LIBCUFILE_PRELOAD=$LIBCUFILE"
else
  warn "no versioned libcufile found under /usr/local/cuda* — kvikIO drivers will refuse to start until resolved by hand"
fi
GDSCHECK=$(ls /usr/local/cuda*/gds/tools/gdscheck 2>/dev/null | sort -V | tail -1)
if [ -n "$GDSCHECK" ]; then
  echo "-- gdscheck -p verdict (expected: GDS unsupported on this leg):"
  "$GDSCHECK" -p 2>&1 || true
else
  warn "gdscheck not found — CUDA toolkit gds tools missing?"
fi

# --check runs HERE, after 6.5, so the boot log shows the finished env.sh
# (LIBCUFILE_PRELOAD and cufile.json included) rather than second-old pendings.
as_u bash "$ENV_SH" --check || warn "env.sh --check reported missing items (expected pre-env-build; see above)"
if [ $REBUILD -eq 1 ]; then
  ( cd "$REPO" && as_u python3 scripts/env-contract.py verify --against "$CONTRACT" --leg weka ) \
    || { warn "CONTRACT VERIFY FAILED — held-constant drift on this rebuild"; touch /var/lib/wsi-CONTRACT-VIOLATION-CHECK-ME; }
fi

step "7. Claude Code"
# Personal defaults (model/effort/TUI) so first launch needs no /config walkthrough.
# Verbatim copy of the working laptop config; project rules ride in via the repo's
# own .claude/settings.json and override where they overlap. /login stays human.
if [ ! -f "$UH/.claude/settings.json" ]; then
  as_u mkdir -p "$UH/.claude"
  cat > "$UH/.claude/settings.json" <<'CCFG'
{
  "permissions": {
    "defaultMode": "auto"
  },
  "worktree": {
    "baseRef": "fresh"
  },
  "workflowKeywordTriggerEnabled": false,
  "effortLevel": "xhigh",
  "promptSuggestionEnabled": false,
  "awaySummaryEnabled": false,
  "tui": "fullscreen",
  "theme": "auto",
  "autoCompactEnabled": false,
  "switchModelsOnFlag": false,
  "fileCheckpointingEnabled": false,
  "statusLine": {
    "type": "command",
    "command": "jq -r '\"[\\(.model.display_name)|\\(.effort.level // \"-\")] ctx \\(.context_window.used_percentage // 0)%\" + (if (.rate_limits.five_hour.used_percentage // 0) > 75 then \" ⚠ 5-hr RATE LIMIT ABOVE 75%\" else \"\" end) + (if (.rate_limits.seven_day.used_percentage // 0) > 75 then \" ⚠ 7-day RATE LIMIT ABOVE 75%\" else \"\" end)'"
  },
  "model": "claude-fable-5[1m]"
}
CCFG
  chown $U:$U "$UH/.claude/settings.json"
fi
as_u bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' || true
if ! as_u bash -lc 'command -v claude || test -x ~/.local/bin/claude'; then
  npm install -g @anthropic-ai/claude-code || warn "Claude Code install failed (native + npm)"
fi
echo "claude=$(as_u bash -lc 'claude --version 2>/dev/null || ~/.local/bin/claude --version 2>/dev/null' || echo MISSING)"

step "8. Miniforge + benchmark envs (background)"
CONDA_ROOT=$SCRATCH/miniforge
CONDA_ENVS=$SCRATCH/conda-envs
if mountpoint -q "$SCRATCH"; then
  if [ ! -x "$CONDA_ROOT/bin/mamba" ]; then
    as_u bash -c "wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O /tmp/miniforge.sh && bash /tmp/miniforge.sh -b -p $CONDA_ROOT && rm -f /tmp/miniforge.sh" \
      || fatal "miniforge install failed"
  fi
  as_u "$CONDA_ROOT/bin/conda" init bash >/dev/null 2>&1 || true
  as_u mkdir -p "$CONDA_ENVS"
  cat > /usr/local/bin/wsi-build-envs.sh <<EOS
#!/usr/bin/env bash
# Rebuilds the pinned benchmark envs from scripts/env-specs (scratch dies with the
# instance, so this runs on every build). The pins are TWO files per env — the conda
# explicit file (conda layer) plus the PyPI-form lines of the pip freeze (pip layer;
# conda explicit files cannot carry pip packages). Do not "update" either.
set -x
for e in wsi-cucim-2604 wsi-cucim; do
  spec=$REPO/scripts/env-specs/\$e.conda-explicit.txt
  [ -f "\$spec" ] || { echo "WSI-WARN: no spec for \$e"; continue; }
  [ -x "$CONDA_ENVS/\$e/bin/python" ] && { echo "\$e already built"; continue; }
  $CONDA_ROOT/bin/mamba create -y -p "$CONDA_ENVS/\$e" --file "\$spec" \
    || { echo "WSI-WARN: env \$e build FAILED — see scripts/env-specs/env-create-history.txt for the manual recipe"; continue; }
  # The pip layer: conda explicit files carry only conda packages, so the genuinely
  # pip-installed pins (PyPI-form `name==ver` lines; conda-provided ones appear as
  # `@ file://` and are skipped) come from the freeze. --no-deps because the freeze
  # is a complete closure — letting pip resolve would fight the conda layer.
  # Stage 3's preflight imports cv2/matplotlib/openslide from this layer and
  # refuses without them.
  req=$REPO/scripts/env-specs/\$e.pip-freeze.txt
  if [ -f "\$req" ] && grep -E '^[A-Za-z0-9_.-]+==[0-9]' "\$req" > "/tmp/wsi-pip-\$e.txt" && [ -s "/tmp/wsi-pip-\$e.txt" ]; then
    "$CONDA_ENVS/\$e/bin/pip" install --no-deps -q -r "/tmp/wsi-pip-\$e.txt" \
      || echo "WSI-WARN: pip layer for \$e FAILED — stage preflights that import from it will refuse"
  fi
  # Smoke test the way the sweep drivers invoke it: CONDA_PREFIX set, bare exec.
  mods="torch,cucim,cv2"; [ "\$e" = "wsi-cucim-2604" ] && mods="torch,cucim,kvikio,cv2"
  if CONDA_PREFIX="$CONDA_ENVS/\$e" "$CONDA_ENVS/\$e/bin/python" -c "import \$mods; assert torch.cuda.is_available(); print('\$e smoke OK:', torch.__version__, torch.cuda.device_count(), 'GPUs')" \
       > "$CONDA_ENVS/\$e/.wsi-smoke.log" 2>&1; then
    touch "$CONDA_ENVS/\$e/.wsi-smoke-ok"; cat "$CONDA_ENVS/\$e/.wsi-smoke.log"
  else
    echo "WSI-WARN: env \$e smoke test FAILED — see $CONDA_ENVS/\$e/.wsi-smoke.log"
  fi
done
echo "env builds finished \$(date -u)"
EOS
  chmod +x /usr/local/bin/wsi-build-envs.sh
  nohup runuser -u $U -- /usr/local/bin/wsi-build-envs.sh > /var/log/wsi-env-build.log 2>&1 &
  echo "env builds launched in background -> /var/log/wsi-env-build.log"
else
  warn "scratch absent — skipping miniforge/env builds"
fi

step "9. CLAM (Stage 3 tissue detector)"
[ -d "$UH/wsi-tools/CLAM/.git" ] || as_u git clone -q https://github.com/mahmoodlab/CLAM "$UH/wsi-tools/CLAM" \
  || warn "CLAM clone failed"

step "10. Hugging Face token (SSM SecureString $SSM_PREFIX/hf-token)"
HF_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/hf-token" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)
if [ -n "$HF_TOKEN" ] && [ "$HF_TOKEN" != "None" ]; then
  as_u mkdir -p "$UH/.cache/huggingface"
  printf '%s' "$HF_TOKEN" > "$UH/.cache/huggingface/token"
  chown $U:$U "$UH/.cache/huggingface/token"; chmod 600 "$UH/.cache/huggingface/token"
  echo "HF token installed to ~/.cache/huggingface/token"
else
  warn "no HF token from SSM ($SSM_PREFIX/hf-token) — gated models (UNI2-h etc.) blocked until 'hf auth login' is run manually, or add ssm:GetParameter to the client role"
fi
unset HF_TOKEN
as_u python3 -m pip install --user -q "huggingface_hub[cli]" || warn "huggingface_hub install failed — model prefetch will skip HF downloads"

step "11. GitHub identity + push key"
[ -n "$GIT_USER_NAME" ]  && as_u git config --global user.name  "$GIT_USER_NAME"
[ -n "$GIT_USER_EMAIL" ] && as_u git config --global user.email "$GIT_USER_EMAIL"
if [ ! -f "$UH/.ssh/id_ed25519" ]; then
  # Preferred: the FIXED deploy key from SSM ($SSM_PREFIX/github-deploy-key,
  # SecureString), registered ONCE in GitHub (repo Settings -> Deploy keys, with
  # write access) — so rebuilds need no GitHub step at all. Falls back to a
  # per-instance key whose pubkey must be added by hand.
  DEPLOY_KEY=$(aws ssm get-parameter --region "$REGION" --name "$SSM_PREFIX/github-deploy-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)
  if printf '%s' "$DEPLOY_KEY" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
    as_u mkdir -p "$UH/.ssh"
    printf '%s\n' "$DEPLOY_KEY" > "$UH/.ssh/id_ed25519"
    chown $U:$U "$UH/.ssh/id_ed25519"; chmod 600 "$UH/.ssh/id_ed25519"
    ssh-keygen -y -f "$UH/.ssh/id_ed25519" > "$UH/.ssh/id_ed25519.pub"
    chown $U:$U "$UH/.ssh/id_ed25519.pub"
    echo "GitHub push key: fixed deploy key installed from SSM — no GitHub step needed"
  else
    as_u ssh-keygen -q -t ed25519 -N "" -C "wsi-client-$INSTANCE_ID" -f "$UH/.ssh/id_ed25519"
    echo "GitHub push key: SSM key absent — per-instance key generated; ADD IT at the repo's Deploy keys (write access):"
  fi
  unset DEPLOY_KEY
fi
as_u bash -c "ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null; sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts"
as_u git -C "$REPO" remote set-url --push origin git@github.com:liadhweka/wsi-cloud.git
cp "$UH/.ssh/id_ed25519.pub" "$UH/GITHUB-DEPLOY-KEY.pub"; chown $U:$U "$UH/GITHUB-DEPLOY-KEY.pub"
cat "$UH/.ssh/id_ed25519.pub"

step "12. Claude memories"
( cd "$REPO" && as_u env HOME=$UH ./scripts/restore-memories.sh ) || warn "memory restore failed — sessions will start blank"

step "13. dataset prefetch -> S3 (mode=$DATASET_PREFETCH; NOT hydration/cell 1.7)"
if [ "$DATASET_PREFETCH" != "none" ] && [ -f "$REPO/scripts/prefetch-datasets-to-s3.sh" ]; then
  nohup runuser -u $U -- bash "$REPO/scripts/prefetch-datasets-to-s3.sh" "$DATASET_PREFETCH" > /var/log/wsi-prefetch.log 2>&1 &
  echo "prefetch launched -> /var/log/wsi-prefetch.log"
else
  echo "prefetch skipped"
fi

step "13.5 conditional re-hydration (unmeasured; only when 1.7 is on record but data is gone)"
# Cell 1.7 (S3 -> filesystem hydration) is a MEASURED cell; this step never
# replaces it. It fires only when this leg's hydrate driver has recorded
# completion (runs/.leg-state/$LEG/hydration-complete — written by the D-13
# driver) and the data is absent, i.e. a mid-leg cluster rebuild lost the
# filesystem contents after the measurement already happened.
if [ -f "$REPO/runs/.leg-state/$LEG/hydration-complete" ] && [ ! -d "$WEKA_MNT/data/tcga-brca" ]; then
  echo "1.7 recorded complete but data absent -> re-hydrating UNMEASURED in background"
  nohup runuser -u $U -- aws s3 sync "s3://$S3_BUCKET/datasets/tcga-brca/"  "$WEKA_MNT/data/tcga-brca/"  --only-show-errors > /var/log/wsi-rehydrate.log 2>&1 &
  nohup runuser -u $U -- aws s3 sync "s3://$S3_BUCKET/datasets/camelyon16/" "$WEKA_MNT/data/camelyon16/" --only-show-errors >> /var/log/wsi-rehydrate.log 2>&1 &
fi

step "SUMMARY"
mkdir -p /etc/motd.d 2>/dev/null || true
{
  echo "wsi-cloud client bootstrapped $(date -u). Remaining HUMAN steps:"
  echo "  1. Verify GitHub push works: ssh -T git@github.com  (the SSM deploy key installs automatically;"
  echo "     only if that fails: add ~/GITHUB-DEPLOY-KEY.pub as a repo deploy key with write access)"
  echo "  2. tmux; cd ~/wsi-cloud; claude  ->  /login"
  if [ "$LEG" = "lustre" ] && ! mountpoint -q "$WEKA_MNT"; then
    echo "  3. Paste prompts/prompt-lustre-cluster-cloud.md FIRST (gated EFA + mount walk);"
    echo "     the Leg-B handoff comes after the walk"
  else
    echo "  3. Paste prompts/handoff-cloud.md (the living handoff)"
  fi
  echo "Logs: /var/log/wsi-bootstrap.log, wsi-env-build.log, wsi-prefetch.log"
  echo "Triage: grep WSI- /var/log/wsi-bootstrap.log"
} | tee /etc/motd.d/50-wsi 2>/dev/null || true
grep -c 'WSI-WARN' /var/log/wsi-bootstrap.log | xargs -I{} echo "warnings this run: {}"
grep -c 'WSI-FATAL' /var/log/wsi-bootstrap.log | xargs -I{} echo "fatals this run: {}"
touch "$MARKER"
echo "=== bootstrap complete $(date -u) ==="
