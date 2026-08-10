#!/usr/bin/env bash
# backup.sh — mirror this project's Claude memories into the git repo so every
# commit carries them to GitHub. The memories are the one piece of load-bearing
# project state that lives OUTSIDE the repo (in ~/.claude/.../memory/); this puts
# a tracked copy inside it for disaster recovery.
#
# This matters more here than on a workstation: the cloud instance is EPHEMERAL
# and is rebuilt between the WEKA and Lustre legs. Only git, this mirror, and S3
# survive a teardown — Claude's conversation context does not.
#
# Run it right before committing:
#     ./backup.sh && git add . && git commit && git push
#
# Mechanism: `rsync -a --delete` makes claude-memory-mirror/ an EXACT mirror of
# the live memory dir — new files copied, changed files updated, and files
# deleted from the source are removed from the mirror (the same per-file
# add/modify/delete set git then stages). The mirror is generated output; never
# hand-edit it — edit the live memory and re-run this.
#
# Restore after a teardown / rebuild (discover the slug rather than typing it,
# since it is derived from the repo path):
#     SLUG=$(printf '%s' "$PWD" | sed 's#^/#-#; s#/#-#g')   # derived from the repo path
#     mkdir -p ~/.claude/projects/$SLUG/memory
#     rsync -a claude-memory-mirror/ ~/.claude/projects/$SLUG/memory/
#
# ONE-TIME EXCEPTION — the very first bootstrap. The memories were authored
# directly INTO claude-memory-mirror/ before any session ran in this repo, so at
# that point the mirror is the source of truth and there is no live dir to copy
# from. Do NOT run this script then: RESTORE first (above), and the normal
# live->mirror direction applies from then on. The guard below refuses that case
# rather than emptying the mirror.
set -euo pipefail

cd "$(dirname "$0")"                 # = the repo root (this script lives there)

# The memory dir name is the repo path with '/' -> '-'. Discover it rather than
# hardcoding, so the script still works if the repo is cloned to another path.
SLUG="$(pwd | sed 's#^/#-#; s#/#-#g')"
SRC="$HOME/.claude/projects/$SLUG/memory/"
DST="claude-memory-mirror/"

# Fail loud if the source is missing or empty — otherwise `rsync --delete` would
# happily empty the mirror, silently turning the "backup" into nothing.
if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo "backup.sh: memory dir missing or empty: $SRC" >&2
  echo "backup.sh: refusing to mirror (that would delete the existing backup)" >&2
  echo "backup.sh: if this is a fresh machine, RESTORE first (see header), don't back up." >&2
  exit 1
fi

mkdir -p "$DST"
rsync -a --delete "$SRC" "$DST"
echo "backup.sh: mirrored $(find "$DST" -type f | wc -l | tr -d ' ') memory files ($(du -sh "$DST" | cut -f1)) -> $DST"

# ---- Second half: push everything teardown-critical to S3 ---------------------
# git covers all the small text; S3 covers the heavy write-once telemetry and the
# datasets. Delegated to scripts/sync-to-s3.sh, which implements the two distinct
# sync semantics (mirror-with-delete vs archive-never-delete) — see its header.
#
# Degrades gracefully: if S3_BUCKET isn't set we've still done the memory mirror,
# which is all that's needed on a machine with no bucket (e.g. the initial
# bootstrap). But say so loudly rather than exiting 0 as if fully backed up.
if [ -z "${S3_BUCKET:-}" ]; then
  echo "backup.sh: S3_BUCKET not set — memory mirror done, S3 sync SKIPPED." >&2
  echo "backup.sh: that is correct pre-cloud; in the cloud it means telemetry is NOT backed up." >&2
  exit 0
fi

echo "backup.sh: syncing to s3://$S3_BUCKET/ (leg: ${LEG:-unset}) ..."
"$(dirname "${BASH_SOURCE[0]}")/scripts/sync-to-s3.sh" --mode full "$@"
echo "backup.sh: memory mirror + S3 sync both complete."
