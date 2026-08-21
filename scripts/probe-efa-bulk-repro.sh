#!/usr/bin/env bash
# probe-efa-bulk-repro.sh — the 2026-08-21 EFA bulk-write incident reproduce probe.
#
# THE QUESTION. Sustained bulk writes (16 jobs x 4M direct) destabilized the
# EFA data path on this client (~16:05-16:45Z): efalnd TX cancellations on both
# devices, ptlrpc bulk timeouts, OST reconnect flaps, ~2,850 SRD retransmission
# timeout events — while the FSx servers sat at <=1% network / <=5% disk
# utilization. Short transfers were unaffected. This probe answers, after a
# reboot: does sustained bulk write STILL destabilize the transport?
#
# WHAT IT DOES. One recorded stage-0 diagnostic cell (never quote a rate) in
# the exact incident shape but short (120 s), bracketed by EFA hw_counter and
# dmesg snapshots. PASS/FAIL is mechanical:
#   FAIL if: retrans_timeout_events moved across the cell, OR new efalnd
#            cancel-TX / ptlrpc-timeout / connection-lost lines appeared,
#            OR fio exited non-zero.
#   PASS otherwise.
# FAIL means STOP stands: surface to the human -> AWS support case (the
# evidence bundle lives in the runs/2026-08-21-1*-FAILED-efa-* dirs). PASS
# means escalate to one full 300 s probe (PROBE_RUNTIME=300), and only a PASS
# there clears calibration to relaunch.
#
# Usage:  scripts/probe-efa-bulk-repro.sh          (120 s)
#         PROBE_RUNTIME=300 scripts/probe-efa-bulk-repro.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh}"
: "${LEG:?LEG is unset -- source env.sh}"
[ "$LEG" = "lustre" ] || { echo "FATAL: lustre-only probe (LEG=$LEG)"; exit 2; }

RUNTIME=${PROBE_RUNTIME:-120}
SCRATCH="$FS_MOUNT/benchmarks/fio-canary-calib"
mkdir -p "$SCRATCH"

efa_snapshot() { # efa_snapshot <outfile>
  for c in /sys/class/infiniband/efa_*/ports/1/hw_counters/*; do
    printf '%s/%s=%s\n' "$(echo "$c" | cut -d/ -f5)" "$(basename "$c")" "$(cat "$c")"
  done > "$1"
}
counter_total() { # counter_total <snapshot-file> <counter-name>
  awk -F= -v k="$2" '$1 ~ k {s+=$2} END{print s+0}' "$1"
}

PRE_EFA=$(mktemp); POST_EFA=$(mktemp)
PRE_DMESG_LINES=$(sudo -n dmesg | grep -cE 'kefalnd_force_cancel_tx|ptlrpc_expire_one_request|Connection to krvlrbev' || true)
efa_snapshot "$PRE_EFA"

echo "=== EFA bulk-write reproduce probe: ${RUNTIME}s of the incident shape (16j x 4M direct writes) ==="
RECORD_CACHE_STATE="na-write-cell" RECORD_TIMEOUT_S=$(( RUNTIME * 2 + 300 )) \
"$REPO/scripts/record-run.sh" \
  --stage 0 --run-name "efa-bulk-repro-${RUNTIME}s" \
  --note "EFA bulk-write incident reproduce probe (${RUNTIME}s, 16j x 4M direct — the incident shape). DIAGNOSTIC, never quote a rate: the subject is transport stability, evidenced by the EFA retrans counters and dmesg across the cell. Incident evidence: runs/2026-08-21-1*-FAILED-efa-*." \
  -- fio --name="efa-bulk-repro" --directory="$SCRATCH" --filename_format='calib.$jobnum' \
     --size=10G --numjobs=16 --ioengine=libaio --direct=1 --iodepth=8 \
     --rw=write --bs=4M --runtime="$RUNTIME" --time_based \
     --group_reporting --output-format=json+ --status-interval=1
FIO_RC=$?

efa_snapshot "$POST_EFA"
POST_DMESG_LINES=$(sudo -n dmesg | grep -cE 'kefalnd_force_cancel_tx|ptlrpc_expire_one_request|Connection to krvlrbev' || true)

RETRANS_TO_DELTA=$(( $(counter_total "$POST_EFA" retrans_timeout_events) - $(counter_total "$PRE_EFA" retrans_timeout_events) ))
RETRANS_PKT_DELTA=$(( $(counter_total "$POST_EFA" retrans_pkts) - $(counter_total "$PRE_EFA" retrans_pkts) ))
DMESG_DELTA=$(( POST_DMESG_LINES - PRE_DMESG_LINES ))
rm -f "$PRE_EFA" "$POST_EFA"

echo "=== probe verdict inputs: fio_rc=$FIO_RC retrans_timeout_events_delta=$RETRANS_TO_DELTA retrans_pkts_delta=$RETRANS_PKT_DELTA new_lustre_error_lines=$DMESG_DELTA"
if (( FIO_RC != 0 || RETRANS_TO_DELTA > 0 || DMESG_DELTA > 0 )); then
  echo "=== VERDICT: FAIL — the instability REPRODUCES after reboot. STOP stands: surface to the"
  echo "    human; AWS support case with the incident evidence. Do not calibrate, do not run-leg."
  exit 1
fi
echo "=== VERDICT: PASS — no retrans timeouts, no new lustre/lnet errors, fio clean at ${RUNTIME}s."
if (( RUNTIME < 300 )); then
  echo "    Next: PROBE_RUNTIME=300 $0   (only a full-length PASS clears calibration to relaunch)"
fi
