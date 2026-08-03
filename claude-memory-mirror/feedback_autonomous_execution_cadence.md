---
name: autonomous-execution-cadence
description: "Once a roadmap is aligned, keep working through tasks without pausing — except for four triggers. No routine progress pings."
metadata:
  node_type: memory
  type: feedback
---

After a roadmap + methodology are aligned, **default to working straight through the next task** (long
sweeps are background work; auto-notification on completion is enough). Don't re-ask permission for
already-agreed steps; no "still running, X cells done" pings.

**The only four pause triggers:** (1) open decisions / un-pre-decided methodology forks; (2) actual
issues to debug; (3) soft issues that may reshape FUTURE-step methodology (flag in the post-step summary;
don't block subsequent agreed work); (4) anything else needing user attention (surprising results,
external steps the user must take, sudo or destructive ops). Otherwise proceed.

**Cloud addition:** unattended overnight chains are the normal mode, so a pause trigger that fires at
3am must be *mechanical*, not conversational — the consistency canary aborts the chain itself rather
than waiting to be noticed. Report what aborted and why in the next summary; don't ping while it runs.

(Canonical text in `CLAUDE.md` → "how we work together".)
