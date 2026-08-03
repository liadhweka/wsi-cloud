---
name: methodology-revisability
description: "The per-stage roadmap is the planning source-of-truth, NOT a frozen contract. Before each tier/substage, reassess against accumulated findings and revise proactively. \"Locked\" decisions are alignment markers, revisable when new info lands. Goal = the best benchmark, not roadmap adherence."
metadata:
  node_type: memory
  type: feedback
---

Roadmaps are captured at stage start when little is measured. **Before kicking off any tier/substage/cell,
reassess it against everything measured since** — "has new info changed what 'best' looks like here?" If
yes, revise even against the roadmap, and surface it proactively (before committing wallclock), not after
the user asks. The goal is THE BEST BENCHMARK.

Triggers to reassess: about to start a tier planned >24h ago; a prior result touches a future step's
methodology (different optimal N, sample size, threshold); about to commit substantial wallclock to
params chosen before relevant data existed; a roadmap estimate proved materially off.

**Two cloud-specific triggers:** (1) the **pre-committed instance revisit** — if Leg A's synthetic ceiling
pins at line rate across block sizes *and* the `num_workers` sweep saturates on CPU cores rather than
storage, the instance is measuring itself, so move up before Leg B; (2) **anything learned in Leg A that
changes what Leg B should measure** — Leg B's plan is provisional until Leg A's results exist, and
improving it is the point, not a deviation.

NOT a license to scope-creep or skip warranted cells. On revising: surface as a decision, then update the
roadmap in place + a decision-log entry; if a cell already ran under the old methodology, preserve it
(`-prior-to-<rev>` suffix) and redo. (Canonical text in `CLAUDE.md`.)
