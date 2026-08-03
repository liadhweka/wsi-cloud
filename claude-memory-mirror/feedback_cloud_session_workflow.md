---
name: cloud-session-workflow-tmux-and-ephemerality
description: "Work inside `tmux new -A -s wsi` on the cloud instance (the ssh-disconnect net); still tee long output; don't propose nohup/disown. The instance is ephemeral — anything that matters lives in git, in the memory mirror, or in S3, never only on the box."
metadata:
  node_type: memory
  type: feedback
---

All work on the cloud instance (including Claude Code itself) runs inside **`tmux new -A -s wsi`**, so
Bash-tool commands survive ssh disconnects. Assume you're already in it — don't prefix commands with the
tmux invocation. If the user reports a fresh shell, suggest reattaching with `tmux new -A -s wsi`.

- Long runs: tmux is the disconnect net, **but still tee to a dated log** (survives even if tmux dies).
  Don't suggest `nohup`/`disown` — they have tmux.
- Overnight chains are the normal mode here, which makes the tee'd log the primary forensic record of
  what happened while nobody was watching.

**Ephemerality is the defining constraint of this environment.** A cloud instance is not a workstation:
it is rebuilt between legs and can be lost at any time, taking local NVMe, both filesystem mounts, and
the entire Claude conversation with it. **Claude's context does not survive** — only the repo, the
memories, and S3 do. That is exactly why the doc and memory discipline is as heavy as it is: a fresh
session reads the memories plus the docs and continues without the user re-explaining anything.

So: persist state to disk continuously, sync raw telemetry to S3 *during* runs rather than at the end,
and treat the teardown & rebuild checklist (`cloud-setup/TEARDOWN-AND-REBUILD.md`, gated by `runs/lib/teardown-preflight.sh`) as mandatory, not advisory.

**`backup.sh` is the single durability entry point** — memories → mirror, then S3 sync, with two
deliberately different semantics (mirror-with-delete for docs/memories where git is the real backup;
add-and-update-never-delete for raw telemetry and datasets, so reclaiming local disk can't destroy the
only copy). Canonical rule text and the git-vs-S3 authority split are in `CLAUDE.md` → Recording →
Durability & backup.

⚠ **The S3 half exists (`runs/lib/sync-to-s3.sh`) but is UNVERIFIED against a real bucket** — run the
7-step first-run procedure in its header before trusting it. Formerly not built at all; — only the memory-mirror half exists. It needs the real
bucket name, region, and instance-profile role, so it is the **cloud session's job**, alongside the
`record-run.sh` during-run sync. Don't assume a run's telemetry is durable until that exists and has been
verified once.

Related: `[[feedback_git_commit_cadence]]`, `[[feedback_accuracy_safety_dependability]]`.
