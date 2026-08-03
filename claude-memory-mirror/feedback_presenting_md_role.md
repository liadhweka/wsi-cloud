---
name: presenting-md-is-a-boss-presentable-summary-script-not-an-index-doc
description: "PRESENTING.md is a comprehensive, self-contained presentation script (per stage: WSI context, what, WHY, the question it answers, numbers, caveats, pointers) — NOT an index. Until results exist it is a methodology script with [STORY PENDING RESULTS] markers. Update in place."
metadata:
  node_type: memory
  type: feedback
---

`PRESENTING.md` is the **presentable script** — what the user reads before presenting to stakeholders.
Per stage it carries: WSI context, what we did, **WHY**, the question the stage answers, the numbers, the
caveats, and pointers to deeper artifacts. The bar: someone who's never seen the project can present any
covered stage from it alone.

**Until results exist it is a methodology-and-what-we-will-measure script, not a narrative.** Every
interpretation section is present but marked **`[STORY PENDING RESULTS]`**, and every number is
`[PENDING]`. It must contain no predicted outcome and no pre-assigned "headline" stage — see
`[[feedback-results-precede-story]]`. When results land, the interpretation fills in **from the numbers**.

- It is NOT an index/pointer doc, NOT an audit trail of past mistakes, NOT a duplicate of the per-stage
  roadmaps (those are more granular, for engineering/audit).
- **Update the affected section in place** when a finding lands or is corrected — don't preserve the
  obsolete version (history lives in git + roadmap decision logs). Bump the TL;DR/status/date stamp if
  the project narrative shifts.
- **Scope every claim to its leg.** A Leg-A section presents WEKA numbers as half an unfinished
  comparison; the decisive head-to-head only appears in the synthesis after Leg B
  (`[[feedback-each-leg-is-half-an-unfinished-comparison]]`).
- **State both deliberate asymmetries wherever results appear** — the provisioning basis (Lustre at
  maximum vs WEKA at a realistic production config) and the GPU-direct transport difference. A reader
  asks "what was the other side running?" first; the answer must already be on the page.

(Canonical rule text in `CLAUDE.md` → docs cadence.)
