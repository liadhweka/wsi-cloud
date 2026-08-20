#!/usr/bin/env bash
# push-safe.sh — commit-and-push for TWO autonomous committers (D6, concurrent legs).
#
# Plain `git push` loses races against the other leg's session. This pulls with
# rebase (autostash tolerates a dirty tree), pushes, and retries the pair up to
# five times. Union-merge attributes (.gitattributes) make the append-only
# artifacts (INDEX.md, summary CSVs) merge themselves; a REAL conflict — both
# legs editing the same prose — aborts loudly, because that is an ownership
# violation to report, not to auto-resolve (CLAUDE.md, "Concurrent legs").
set -uo pipefail
for i in 1 2 3 4 5; do
  git pull --rebase --autostash || { echo "push-safe: REBASE CONFLICT — ownership violation or stale tree; resolve by hand, do not force" >&2; exit 2; }
  git push && exit 0
  echo "push-safe: push lost a race (attempt $i/5); retrying"
  sleep $((i * 2))
done
echo "push-safe: FAILED after 5 attempts" >&2; exit 1
