---
name: complete-implied-work
description: "Interpret instructions completely — do the requisite surrounding work (state cleanup, doc/memory updates, forensic preservation) via the 7-point checklist, not just the literal verb. Not a license to scope-creep; don't leave the system half-clean."
metadata:
  node_type: memory
  type: feedback
---

Before declaring an instruction done, ask "what's the FULL scope this implies?" and do the requisite
surrounding work — not just the literal verb. Switching state A→B means cleaning A's residue, not just
installing B. NOT a license to wildly extrapolate, but don't leave a half-clean state (stale files,
inconsistent docs, leftover processes).

**7-point checklist:** (1) literal ask; (2) state cleanup (stale files/dirs/processes/intermediates from
the prior state); (3) doc consistency (audit the docs cadence, update every triggered doc in place);
(4) methodology consistency (decision-log + change-log entries); (5) memory consistency; (6) forensic
preservation (rename replaced artifacts `-PRIOR-TO-<rev>` / `-FAILED-<reason>`, don't delete); (7) verify
the new state is actually clean.

**Highest-value application in this project:** when an assumed environment value firms up, use the index
in `[[weka-vs-lustre-cloud-open-decisions]]` to update *every* reference in one pass — a half-updated
assumption is exactly the kind of stale state this rule exists to prevent.

When unsure if something's requisite vs scope-creep, surface a quick "I'll also do X — ok?".
(Canonical text in `CLAUDE.md`.)
