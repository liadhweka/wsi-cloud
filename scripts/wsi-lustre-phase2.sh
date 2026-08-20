#!/usr/bin/env bash
# wsi-lustre-phase2.sh — the BAKED lustre mount automation. NOT YET BAKED.
#
# This file's content comes from the first gated walk of
# prompts/prompt-lustre-cluster-cloud.md (EFA client config + lnetctl gate +
# mount, human-approved throughout). That walk IS the validation; its transcript
# gets baked here so every rebuild after the first is hands-off (D6/D16/D-17).
#
# Baked shape (each ⛔ = WSI-FATAL, filesystem left UNMOUNTED, banner explains):
#   1. Preflight: FSX_* facts in /etc/wsi-bootstrap.conf; fs AVAILABLE.
#   2. EFA userspace per the walk's exact packages/commands (⛔ fi_info lacks efa).
#   3. Lustre client install, pinned to the walk's package+kernel pair (⛔ kernel
#      mismatch — D-17).
#   4. Reboot handling across the walk-determined points (systemd oneshot re-arm).
#   5. FSx EFA client config → `lnetctl net show` ⛔ HARD GATE: efa present, else
#      NO MOUNT, NO FALLBACK — a TCP waiver is a human decision (D16).
#   6. Mount → chown → fstab → FS_TRANSPORT=efa evidence line (quoting lnetctl)
#      → env.sh update → motd update.
set -uo pipefail
echo "WSI-FATAL: phase-2 is not baked yet — run the gated walk (prompts/prompt-lustre-cluster-cloud.md);" >&2
echo "           its validated transcript becomes this script's content. Refusing to guess a mount." >&2
exit 2
