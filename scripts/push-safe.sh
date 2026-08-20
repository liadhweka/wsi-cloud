#!/usr/bin/env bash
# push-safe.sh — pull-rebase-and-push for TWO autonomous committers (D6,
# concurrent legs). Committing stays with the caller's own cadence.
#
# Plain `git push` loses races against the other leg's session. This pulls with
# rebase (autostash tolerates a dirty tree), pushes, and retries the pair up to
# five times. Union-merge attributes (.gitattributes) make the append-only
# artifacts merge themselves; a REAL conflict — both legs editing the same
# prose — aborts loudly, because that is an ownership violation to report, not
# to auto-resolve (CLAUDE.md, "Concurrent legs").
#
# Two failure modes are cleaned up rather than left armed, because the callers
# are unattended chains:
#   - a failed rebase is ABORTED before exiting, so the tree is never left in
#     rebase state for the next backup/aggregator to trip over;
#   - a conflicted autostash pop strands dirty work (e.g. a mid-step INDEX.md
#     append) in the stash — git keeps it and prints a warning nothing reads.
#     Detected by stash-count growth; loud non-zero exit so it is recovered,
#     not discovered.
set -uo pipefail
stash_before=$(git stash list | wc -l)
for i in 1 2 3 4 5; do
  if ! git pull --rebase --autostash; then
    git rebase --abort 2>/dev/null
    echo "push-safe: REBASE CONFLICT — ownership violation or stale tree; rebase aborted, tree restored; resolve by hand, do not force" >&2
    exit 2
  fi
  if [ "$(git stash list | wc -l)" -gt "$stash_before" ]; then
    echo "push-safe: autostash pop CONFLICTED — local dirty work is sitting in the stash (git stash list)." >&2
    echo "           Recover it (git stash pop) before anything appends to the affected files, or rows are lost." >&2
    exit 3
  fi
  git push && exit 0
  echo "push-safe: push lost a race (attempt $i/5); retrying"
  sleep $((i * 2))
done
echo "push-safe: FAILED after 5 attempts" >&2; exit 1
