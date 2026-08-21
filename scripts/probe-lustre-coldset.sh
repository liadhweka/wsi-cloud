#!/usr/bin/env bash
# probe-lustre-coldset.sh — the D13/D-4 lustre cold-mechanism demonstration cell.
#
# THE QUESTION (ratified 2026-08-21): what must a clearing-based "cold" cell on
# the lustre client actually clear? The page-cache drop (vm.drop_caches=3) is
# leg-neutral; the lustre client ADDITIONALLY holds DLM locks (ldlm) whose
# validity can keep data/attributes servable client-side. The ratified cold set
# is drop_caches=3 + `lctl set_param ldlm.namespaces.*.lru_size=clear`, both
# acknowledged per cell. This cell is the measured evidence behind that call:
# it times a fixed re-read and a fixed re-stat under three regimes and records
# the server-RPC/byte deltas, so "the ldlm flush is load-bearing / belt-and-
# braces" is a number, not an argument.
#
#   regime A: no clearing            -> client-served baseline
#   regime B: drop_caches=3 only     -> what the leg-neutral step alone forces
#   regime C: drop_caches=3 + ldlm   -> the ratified lustre cold set
#
# Evidence per phase: wallclock, osc read_bytes delta (data actually re-fetched
# from the servers), and the mdc md_stats total-RPC delta summed across MDTs
# (metadata RPCs actually issued). B-vs-C is the demonstration.
#
# Stage-0 DIAGNOSTIC, never quote as a rate. Run through record-run.sh:
#   RECORD_CACHE_STATE=na-cold-mechanism-demo record-run.sh \
#     --run-name coldset-ldlm-demo --stage 0 -- scripts/probe-lustre-coldset.sh
#
# Requires: LEG=lustre, FS_MOUNT, a readable data file (a fio-canary-calib
# fixture by default), sudo -n for sysctl/lctl.
set -euo pipefail

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh}"
: "${LEG:?LEG is unset -- source env.sh}"
[ "$LEG" = "lustre" ] || { echo "FATAL: lustre-only demonstration (LEG=$LEG)"; exit 2; }

DATA_FILE="${COLDSET_DATA_FILE:-$FS_MOUNT/benchmarks/fio-canary-calib/calib.0}"
READ_MB=2048
META_DIR="$FS_MOUNT/benchmarks/coldset-demo-meta"
N_FILES=2000
[ -r "$DATA_FILE" ] || { echo "FATAL: data file missing: $DATA_FILE (run calibration first)"; exit 2; }

mdc_rpcs() { # total mdc RPC samples across all MDTs
  sudo -n lctl get_param -n mdc.*.md_stats 2>/dev/null | python3 -c '
import sys
tot = 0
for line in sys.stdin:
    p = line.split()
    if len(p) >= 3 and p[2] == "samples":
        tot += int(p[1])
print(tot)'
}
osc_read_bytes() { # total bytes read from OSTs, summed across OSCs
  sudo -n lctl get_param -n osc.*.stats 2>/dev/null | python3 -c '
import sys
tot = 0
for line in sys.stdin:
    p = line.split()
    if p and p[0] == "read_bytes" and len(p) >= 7:
        tot += int(p[6])
print(tot)'
}

drop_pc() { sync; sudo -n sysctl vm.drop_caches=3 >/dev/null; echo "  ack: vm.drop_caches=3 rc=$?"; }
ldlm_clear() { sudo -n lctl set_param -n ldlm.namespaces.*.lru_size=clear >/dev/null; echo "  ack: ldlm lru_size=clear rc=$?"; }

read_pass() { # buffered read of the head of DATA_FILE; prints seconds
  local t0 t1
  t0=$(date +%s.%N)
  dd if="$DATA_FILE" of=/dev/null bs=1M count=$READ_MB status=none
  t1=$(date +%s.%N)
  python3 -c "print(f'{$t1-$t0:.2f}')"
}
stat_pass() { # stat every file in META_DIR; prints seconds
  local t0 t1
  t0=$(date +%s.%N)
  find "$META_DIR" -type f -exec stat -c '%s' {} + > /dev/null
  t1=$(date +%s.%N)
  python3 -c "print(f'{$t1-$t0:.2f}')"
}

phase() { # phase <label> <kind: read|stat>
  local label="$1" kind="$2" m0 m1 o0 o1 secs
  m0=$(mdc_rpcs); o0=$(osc_read_bytes)
  if [ "$kind" = read ]; then secs=$(read_pass); else secs=$(stat_pass); fi
  m1=$(mdc_rpcs); o1=$(osc_read_bytes)
  echo "RESULT phase=$label kind=$kind wallclock_s=$secs mdc_rpc_delta=$((m1-m0)) osc_read_bytes_delta=$((o1-o0))"
}

echo "=== lustre cold-mechanism demonstration (D13/D-4; ratified set: drop_caches=3 + ldlm lru clear) ==="
echo "data file: $DATA_FILE (first ${READ_MB} MiB, buffered reads)"
echo "meta dir:  $META_DIR ($N_FILES files)"

echo "--- setup: create $N_FILES files, warm everything once"
rm -rf "$META_DIR"; mkdir -p "$META_DIR"
( cd "$META_DIR" && python3 -c "
for i in range($N_FILES):
    open(f'f{i:05d}', 'w').close()" )
phase warmup-read  read
phase warmup-stat  stat

echo "--- regime A: no clearing (client-served baseline)"
phase A-read read
phase A-stat stat

echo "--- regime B: drop_caches=3 only (the leg-neutral step alone)"
drop_pc
phase B-read read
drop_pc
phase B-stat stat

echo "--- re-warm before C so B and C start from the same warm state"
phase rewarm-read read
phase rewarm-stat stat

echo "--- regime C: drop_caches=3 + ldlm lru_size=clear (the ratified lustre cold set)"
drop_pc; ldlm_clear
phase C-read read
drop_pc; ldlm_clear
phase C-stat stat

rm -rf "$META_DIR"
echo "=== done. Read the RESULT lines: C-vs-B mdc_rpc_delta and osc_read_bytes_delta are the evidence."
