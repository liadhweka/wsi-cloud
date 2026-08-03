---
name: one-git-commit-push-per-stage-not-per-substage
description: "User commits + pushes once per stage (at closeout), not per substage/cell/doc. Don't commit autonomously or pressure to commit; the user pushes. Also: the user creates the GitHub remote."
metadata:
  node_type: memory
  type: feedback
---

Git cadence: **one commit + push per stage, at closeout** — not per substage, cell, or doc update. **The
user commits and pushes**; do not do it autonomously.

- **The user also creates the GitHub remote** for this repo. Don't add a remote or push on their behalf.
- After substage work, summarise uncommitted/untracked changes in the report but **don't suggest
  committing yet**.
- At stage closeout, flag "ready for stage commit" as part of the checklist.
- A large mid-stage `git status` diff is normal, not a signal to commit.
- **Before any commit, `./backup.sh`** — it mirrors live Claude memories into `claude-memory-mirror/` so
  the commit carries them. If memories changed, remind the user.
  > ⚠ **One exception — the initial bootstrap commit.** The memories were authored **directly into**
  > `claude-memory-mirror/` before any session had run in this repo, so at that point the **mirror is the
  > source of truth** and there is no live directory to copy from. **Do not tell the user to run
  > `backup.sh` before that first commit** — it would be backing up from a directory that doesn't exist.
  > (The script's guard refuses and exits 1 rather than emptying the mirror, so nothing breaks — but the
  > instruction is still wrong.) Once `NEW-CLOUD-SETUP.md` § 4.3 restores the mirror into the live memory
  > directory, the normal live→mirror direction resumes and this rule applies unconditionally.

**Cloud addition:** git push is also a **teardown prerequisite**. The repo is the only thing that
survives an instance rebuild, so the full teardown order is: handoff prompt → `./backup.sh` →
**environment contract written** → verified S3 sync → `git commit && git push` → pre-flight GO.
The contract comes **before** the commit and the sync because it is both a git-tracked file and an S3
object — writing it last would leave it in neither, and the pre-flight checks for it in both.
See `cloud-setup/TEARDOWN-AND-REBUILD.md` (and `runs/lib/teardown-preflight.sh`, which gates it).
