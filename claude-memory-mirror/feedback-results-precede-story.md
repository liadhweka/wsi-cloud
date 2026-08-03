---
name: feedback-results-precede-story
description: "Never pre-bake a narrative. Docs carry the WHY of each methodology choice but say nothing about what the numbers will show; interpretation sections stay marked [STORY PENDING RESULTS] until results exist. Whatever the benchmark produces is what gets reported, including losses."
metadata:
  node_type: memory
  type: feedback
---

**The customer story follows the results, never the reverse.** No document in this project may contain a
predicted outcome, an expected magnitude, a designated "headline" stage, or a narrative built before the
measurement exists.

**Why:** the user was explicit — inventing a story before there are numbers inverts the logic of
benchmarking, and the only reason a prior effort's docs had a story pre-written was that its benchmark
had already run once. This project is a genuine fresh start, so a pre-baked story would be pure
contamination: it biases which cells get scrutinized, and it makes a contradicting result feel like a
failure rather than a finding.

**How to apply — the distinction that matters:**
- **KEEP the WHY-we-measure-it-this-way.** Methodology rationale — why this magnification, this cohort,
  this block size, this concurrency range, this fairness basis. That is not a story; it is what makes a
  number evaluable, and it is separately mandated (`[[feedback_methodology_why]]`).
- **DELETE the WHAT-it-will-show.** Predictions ("expect ~3×"), rank-ordering of stages by importance,
  "the headline storage stage," pre-assigned outcome buckets, and any inherited conclusion.
- Interpretation sections exist but stay marked **`[STORY PENDING RESULTS]`** until the results land.
  `PRESENTING.md` is a methodology-and-what-we-will-measure script until then, not a narrative.
- **Report losses.** Provisioning Lustre at maximum raises the chance some cells go against WEKA; that is
  the accepted trade, because a weakness found here is one a customer does not find later.

Related: `[[feedback_methodology_why]]`, `[[feedback_presenting_md_role]]`,
`[[feedback-each-leg-is-half-an-unfinished-comparison]]`, `[[weka-vs-lustre-cloud-project]]`.
