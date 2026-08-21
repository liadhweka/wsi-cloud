# Amend the Leg-A handoff prompt (2026-08-21)

Please amend the handoff prompt you just produced to include the following:

**Before starting any stage work, close two past-due deferred items (SCRIPT-TRACKER table):**

1. **D-30 blocks 6.B mechanically.** `sweep-stage6b-mil.sh`, `sweep-stage6b-stress.sh`,
   `sweep-stage6c.sh`, `sweep-stage7-clinical.sh` set no `RECORD_CACHE_STATE` (verified: zero
   occurrences in all four). The wrapper refuses undeclared stage≥1 cells, so 6.B's first cell
   goes INCOMPLETE and the chain aborts. Set each cell's regime from its roadmap's
   cache-discipline row **before launching 6.B**; surface any stage whose roadmap defines none.
   (6.A Tier 2 closed out CLEAN, so its chunked-orchestrator regime call was evidently made —
   record it on D-30's row if it isn't there yet.)

2. **D-24's window is open.** `runs/.leg-state/weka/fingerprints/` holds no `features-6a`
   although 6.A is fully done. The rule is build-right-after-6.A, against 6.A's REAL output,
   before 6.B.3/7.3 consume the features. Do it first.

**Standing for the whole session:** the deferred table was audited and cleaned on 2026-08-21 —
every remaining row names its own gate, closed rows are deleted (a resolution index keeps their
ids resolvable), and the preamble states the working rule: **whoever touches a row's scope does
the row, in the same edit, and updates the row in that edit. Close as many as you can.** Likely
in Leg A's path: **D-34** (10 Hz short-cell polling — all recorders are still 1 Hz; due before
any stage-2 / sub-second high-concurrency cell; no recorded data affected so far), **D-25**
(6.C's impossible 4-GPU partition — a methodology call to settle before 6.C), **D-33** (stage-7
grid structurally empty; its RDMA column also reads a hardcoded `mlx5_0` that exists on neither
leg), **D-7** (canary-abort/watchdog — every unattended chain), **D-8** (GPU/NUMA map, still
annotated per-cell as underived).

*Spent once its content is in the handoff — delete this file then.*
