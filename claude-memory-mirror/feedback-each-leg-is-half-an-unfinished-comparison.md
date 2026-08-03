---
name: feedback-each-leg-is-half-an-unfinished-comparison
description: "Frame every Leg-A (WEKA) result as a strong-but-incomplete half of the WEKA-vs-Lustre comparison; the decisive narrative is the head-to-head synthesis built after Leg B. Never imply a single leg's numbers are the final word."
metadata:
  node_type: memory
  type: feedback
---

This project runs in two sequential legs — **Leg A: WEKA**, then **Leg B: FSx for Lustre** — followed by
the synthesis. A single leg's numbers mean little in a vacuum; their entire force is the apples-to-apples
comparison against the other leg.

**Why:** the decisive question is "WEKA vs Lustre," which only exists once both halves are measured. A
Leg-A document that implies finality oversells the result and leaves no room for the comparison that
actually lands the point — and it invites exactly the reading we can least afford, that a WEKA number is
being presented as a win before anything was compared.

**How to apply:** in every doc (per-stage roadmaps, `PRESENTING.md`, and all Leg-B docs), present
single-leg findings as strong-but-incomplete, explicitly leave room for the other leg, and state that the
consolidated head-to-head is built later. Holds during and after Leg B — after Leg B, the framing becomes
"the synthesis is the result; the per-leg numbers are its inputs."

This is *not* a licence to soften findings. Record the numbers plainly; it is the **claim** that stays
scoped, not the data.

Related: `[[feedback-results-precede-story]]`, `[[feedback_presenting_md_role]]`,
`[[weka-vs-lustre-cloud-project]]`.
