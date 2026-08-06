#!/usr/bin/env bash
# restore-memories.sh — put the tracked memory mirror back into Claude's live memory dir.
#
# WHY THIS IS A SCRIPT AND NOT FOUR LINES IN A CHECKLIST
#   It runs on EVERY instance build — at least twice (once per leg), more if there is a
#   cost pause — and its failure mode is silent: `rsync` into the wrong directory
#   succeeds. A fresh Claude session then starts with no memories and no error, and
#   proceeds to redo settled decisions. The manual version also asked the operator to
#   eyeball "expect ~20 files", which is exactly the kind of check people skip.
#
#   So this script derives the slug rather than trusting a typed one, refuses on an
#   empty or missing mirror, and VERIFIES the result rather than assuming it.
#
# DIRECTION — this restores INTO the live dir; ../backup.sh mirrors OUT of it:
#     mirror (in git)  --restore-memories.sh-->  ~/.claude/projects/<slug>/memory/
#     mirror (in git)  <----- backup.sh -------  ~/.claude/projects/<slug>/memory/
#   Running them in the wrong order on a fresh machine is how you lose the mirror,
#   which is why backup.sh refuses when the live dir is empty. Restore first.
#
# USAGE
#   ./cloud-setup/restore-memories.sh            # restore, then verify
#   ./cloud-setup/restore-memories.sh --check    # verify only, change nothing
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="$REPO/claude-memory-mirror"
# The live memory dir name is the repo path with '/' -> '-'. Derive it; never type it.
SLUG="$(printf '%s' "$REPO" | sed 's#^/#-#; s#/#-#g')"
LIVE="$HOME/.claude/projects/$SLUG/memory"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

die() { echo "restore-memories.sh: $*" >&2; exit 1; }

echo "repo   : $REPO"
echo "slug   : $SLUG"
echo "mirror : $MIRROR"
echo "live   : $LIVE"

# ---- refuse rather than produce an empty memory dir -----------------------------
[ -d "$MIRROR" ] || die "mirror directory not found: $MIRROR"
n_mirror=$(find "$MIRROR" -maxdepth 1 -name '*.md' | wc -l)
[ "$n_mirror" -gt 0 ] || die "mirror holds no .md files — refusing to 'restore' nothing"
[ -f "$MIRROR/MEMORY.md" ] || die "mirror has no MEMORY.md — it is the index every session reads first"

if [ "$CHECK_ONLY" -eq 0 ]; then
  mkdir -p "$LIVE" || die "could not create $LIVE"
  rsync -a "$MIRROR/" "$LIVE/" || die "rsync failed"
  echo "restored $n_mirror file(s)"
fi

# ---- verify, do not assume ------------------------------------------------------
[ -d "$LIVE" ] || die "live memory dir does not exist: $LIVE"
n_live=$(find "$LIVE" -maxdepth 1 -name '*.md' | wc -l)
[ -f "$LIVE/MEMORY.md" ] || die "MEMORY.md is missing from $LIVE"

if ! diff -rq "$MIRROR" "$LIVE" >/dev/null 2>&1; then
  echo "restore-memories.sh: live dir DIFFERS from the mirror:" >&2
  diff -rq "$MIRROR" "$LIVE" 2>&1 | head -10 | sed 's/^/    /' >&2
  # Extra files in the live dir are normal once sessions have run and written new
  # memories — that is the live dir being ahead, not a failed restore. Missing or
  # differing files are not normal.
  missing=$(diff -rq "$MIRROR" "$LIVE" 2>&1 | grep -c "Only in $MIRROR" || true)
  differing=$(diff -rq "$MIRROR" "$LIVE" 2>&1 | grep -c '^Files .* differ$' || true)
  if [ "$missing" -gt 0 ] || [ "$differing" -gt 0 ]; then
    die "$missing file(s) missing and $differing differing — the restore did NOT succeed"
  fi
  echo "  (only extra files in the live dir — that is the live dir being ahead of the"
  echo "   mirror, which is normal after a session has written new memories. Run"
  echo "   ./backup.sh to fold them back in before the next commit.)"
fi

echo "OK — $n_live memory file(s) live, MEMORY.md present, mirror reproduced."
echo "A fresh Claude session in $REPO will now load them."
