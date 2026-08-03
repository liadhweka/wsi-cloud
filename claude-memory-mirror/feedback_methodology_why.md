---
name: methodology-and-why-are-as-load-bearing-as-the-numbers-themselves
description: "Record the WHY behind every methodology choice in every project doc (roadmaps, PRESENTING.md, decision logs, run READMEs, SCRIPT-TRACKER) — not just the WHAT. Numbers without their rationale aren't presentable."
metadata:
  node_type: memory
  type: feedback
---

In every project doc, capture **the reasoning behind a methodology choice, not just the choice** — why
this dataset / sample size / knob value / provisioning basis over the alternative. A stakeholder reading
a result table must be able to evaluate why we measured it that way; numbers without rationale look
arbitrary regardless of how rigorous they were.

This matters more in a competitive comparison than in a single-vendor study: every methodology choice is
a place a skeptical reader will look for bias, so the rationale has to be already on the page. The
fairness basis, the sizing targets, and both deliberate asymmetries are the highest-value WHYs in this
project.

Applies to: per-stage roadmap "why this exists" rows, `PRESENTING.md` (pair every number with its
one-line methodology framing), `SCRIPT-TRACKER` "purpose" fields, decision-log `Why:` lines, run-dir
READMEs. When updating a doc, a methodology choice recorded without its rationale is a bug to fix in the
same edit.

**Not to be confused with pre-baking a story** — the WHY of *how we measure* stays; claims about *what
the numbers will show* never appear. See `[[feedback-results-precede-story]]`.
(Canonical rule text in `CLAUDE.md` → docs cadence / "record the WHY".)
