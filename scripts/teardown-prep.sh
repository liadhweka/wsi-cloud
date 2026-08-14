#!/usr/bin/env bash
# teardown-prep.sh — everything that must happen BEFORE a teardown, in one command.
#
# WHAT THIS IS
#   The doing half of a teardown. It performs the survivable-state work (memory
#   mirror, S3 sync, git commit+push, boot-log archive) and then hands off to
#   teardown-preflight.sh — the existing GO/NO-GO verifier — as the gate. The
#   destruction itself stays human (terraform), by design: this script proves and
#   prints, it never destroys.
#
# USAGE (on the instance, as ec2-user, from anywhere)
#   ~/wsi-cloud/scripts/teardown-prep.sh                 # full prep + full preflight
#   ~/wsi-cloud/scripts/teardown-prep.sh --quick         # pass --quick to preflight
#   ~/wsi-cloud/scripts/teardown-prep.sh --write-contract  # leg-end: write + include
#                                                          # this leg's env contract
#   FORCE=1 ...                                          # override the mid-flight stop
#
# EXIT: 0 = GO (safe to destroy). Non-zero = something would be lost; it says what.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
QUICK=""; WRITE_CONTRACT=0
for a in "$@"; do case "$a" in
  --quick) QUICK="--quick" ;;
  --write-contract) WRITE_CONTRACT=1 ;;
  *) echo "unknown arg: $a (expected --quick / --write-contract)" >&2; exit 1 ;;
esac; done

[ "$(whoami)" != "root" ] || { echo "run as the project user, not root (git identity + memory slug derive from \$HOME)"; exit 1; }
[ -f env.sh ] || { echo "no env.sh — nothing was provisioned here?"; exit 1; }
# shellcheck disable=SC1091
source env.sh

echo "== teardown-prep: leg=${LEG:-unset} bucket=${S3_BUCKET:-unset} $(date -u) =="

# ---- 0. Nothing measured may be mid-flight ------------------------------------
# A running cell interrupted by teardown is unrecorded work — hard stop. The
# resumable background jobs (prefetch, env build, rehydrate) only get a warning.
if pgrep -f 'record-run\.sh|sweep-stage|fio --client|fio --server' >/dev/null 2>&1; then
  if [ "${FORCE:-0}" != "1" ]; then
    echo "NO-GO: a measured run appears to be in flight:"
    pgrep -af 'record-run\.sh|sweep-stage|fio --client|fio --server' | head -5
    echo "Let it finish (or FORCE=1 if you accept losing it)."
    exit 1
  fi
  echo "WARN: mid-flight run overridden by FORCE=1"
fi
pgrep -f 'prefetch-datasets-to-s3|wsi-build-envs' >/dev/null 2>&1 \
  && echo "WARN: prefetch/env-build still running — both are resumable/rebuilt, continuing"

# ---- 1. Optional leg-end contract ---------------------------------------------
if [ "$WRITE_CONTRACT" -eq 1 ]; then
  echo "-- writing env contract for leg=${LEG:?}"
  python3 scripts/env-contract.py write --leg "$LEG" || { echo "contract write FAILED"; exit 1; }
fi

# ---- 2. Memory mirror + full S3 sync ------------------------------------------
# backup.sh = live-memory -> repo mirror, then sync-to-s3.sh --mode full. Its one
# legitimate failure: no live memory exists (no Claude session ever ran here) —
# then the repo's mirror is already the only copy and only the S3 half is owed.
if ./backup.sh; then
  echo "-- backup.sh complete (memories + S3)"
else
  echo "WARN: backup.sh refused (no live memory on this box?) — running the S3 half directly"
  scripts/sync-to-s3.sh --mode full || { echo "S3 sync FAILED — NOT safe to tear down"; exit 1; }
fi

# ---- 3. Commit + push (the step that makes the repo copy durable) ---------------
git add -A
if git diff-index --quiet HEAD --; then
  echo "-- git: nothing new to commit"
else
  git commit -m "Teardown prep: ${LEG:-?} leg, $(hostname), $(date -u +%Y-%m-%dT%H:%MZ)"
fi
git push || { echo "git push FAILED — an unpushed repo dies with this instance. Fix (GitHub key added?) and re-run."; exit 1; }
echo "-- git: pushed ($(git rev-parse --short HEAD))"

# ---- 4. Archive the boot/build logs (post-mortem record after the box is gone) --
for f in /var/log/wsi-bootstrap.log /var/log/wsi-env-build.log /var/log/wsi-prefetch.log /var/log/wsi-rehydrate.log; do
  [ -f "$f" ] && aws s3 cp --only-show-errors "$f" "s3://${S3_BUCKET:?}/bootstrap/logs/" || true
done

# ---- 5. The gate: the existing verifier decides GO / NO-GO ----------------------
echo "-- handing off to teardown-preflight.sh $QUICK"
if scripts/teardown-preflight.sh $QUICK; then
  cat <<'DONE'
== GO — verified safe. From your LAPTOP, in the terraform directory:
     Full teardown : terraform destroy
     Cost pause    : set clients_number = 0 in main.tf, then terraform apply
   (Rebuild later  : clients_number = 1, terraform apply — the bootstrap does the rest.)
DONE
else
  echo "== NO-GO — preflight found something that would be lost. Fix it and re-run."
  exit 1
fi
