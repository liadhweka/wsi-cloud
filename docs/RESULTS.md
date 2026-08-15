# RESULTS — the cross-stage synthesis

**This document holds findings and what they mean.** It is the one place the WEKA-vs-Lustre story is told
across stages, and it is the repository's deliverable in prose form.

**It is written after results exist.** Nothing has been measured yet, so what follows is the contract this
document is written under — not an outline waiting to be filled. An empty section reserved for a finding that
does not exist is a placeholder, and placeholders rot.

---

## The rule that keeps this document honest

**Numbers live in exactly one place.** Per-cell results belong in the stage roadmap, beside the methodology
that produced them. This file quotes only a **headline figure with a pointer to the cell it came from**, and
**never reproduces a per-cell table.**

*Why:* two copies of a number drift, and the stale one is invisible — it looks exactly like the current one.
A pointer cannot go stale in that way; at worst it dangles, which is visible.

## What each finding must carry

- **The number, and the cell it came from** — stage, substage, and the run-dir name.
- **Both filesystems, or an explicit statement that only one leg has run.** A single leg's numbers are half an
  unfinished comparison (`../PROJECT-THESIS.md` §10). Present them as strong but incomplete, leave explicit
  room for the other leg, and say that the consolidated comparison is built later. This is not a licence to
  soften the numbers — record them plainly; it is the *claim* that stays scoped.
- **Both asymmetries, stated on the page** (`../PROJECT-THESIS.md` §5). A reader's first question is what the
  other side was running; the answer must already be there.
- **The cost to complete, in both recorded bases** — infra-only and all-in, each named where quoted, with
  the software input's asymmetry stated per **D7** (FSx software-inclusive; WEKA at the dated public
  Marketplace rate) — alongside the throughput or latency figure it belongs to. It is the figure the buyer
  actually faces, and the only place the provisioning asymmetry stops being a caveat and becomes arithmetic.
  Which basis leads the writeup is a writing-time choice made with both present. **Headline costs come from
  the publication-time reprice** (`../PROJECT-THESIS.md` §4; `../prompts/prompt-reprice-at-publication.md`):
  one fresh dated snapshot applied to both legs' recorded wallclocks, with the as-run prices retained per
  cell as provenance.
- **Which axis was decisive, as a finding.** No metric was designated primary in advance, so what turned out
  to discriminate between the two architectures is itself a result worth stating.
- **The caveats that change how the number is read** — cache state achieved, the I/O path proven, whether the
  cell was client-bound, and which sources were quoted.

## What must never appear here

- A figure quoted from a source the filesystem in use bypasses (`../PROJECT-THESIS.md` §7).
- A predicted outcome, an expected magnitude, or a narrative written before the measurement exists.
- A Leg-A result presented as though the comparison were finished — which will be tempting the moment Leg A
  produces good numbers.
- A UNI2-h number in anything that leaves the building, until the Mahmood Lab approval lands.

## Shape

One section per stage, in stage order, each in the same shape: what the stage asked, what the head-to-head
showed, the cost to complete, and the caveats. A consistent shape is what keeps the synthesis compressible as
it grows, and it makes a missing piece visible rather than merely absent.

**Losses get reported.** Provisioning Lustre at maximum raises the chance of them, and a weakness found here
is one a customer does not find later.
