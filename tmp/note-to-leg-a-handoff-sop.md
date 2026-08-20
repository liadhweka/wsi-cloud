# Note to the Leg-A session — the handoff workflow changed; it is now law

Written: 2026-08-20 · From: the Leg-B session, at the human's direction · Action needed: minimal, below.
Timing: do this **after your current cell finishes** (nothing here justifies I/O beside a measured cell),
before your docs sweep and the inline handoff you're about to write.

## First

`git pull --ff-only` (Leg-B commits through `45c510e` carry everything referenced here).

## What changed (human-ratified 2026-08-20; commits `0d7c25f` + `45c510e`)

The **living handoff is retired**. The instance runs its whole leg end-to-end now, so handoffs are between
*sessions on the same box*, not between teardown/rebuild cycles:

1. **`prompts/handoff-cloud.md` → `prompts/handoff-skeleton.md`** — a TEMPLATE, never pasted directly.
   Durable sections (central directive, read steps, Tier-0 gate in both legs' forms, standing facts, the
   first-response protocol) are carried verbatim; `Current state` and `What to do, in order` are `⟨...⟩`
   fill-ins. **Same-instance turnover (the normal mode): the outgoing session prints the filled handoff
   inline in its final message**; the human copies it into a fresh `claude`. Note the skeleton's
   requirement that a same-instance handoff **names every in-flight background job** (command, PID, log,
   what-to-do-when-done).
2. **Teardown handoffs are optional.** Memory + repo are the designed continuity; at a destroy/rebuild the
   human may ask for a durable handoff file in `tmp/` (chat text dies with the context).
   `teardown-preflight.sh`'s handoff check is **warn-only, never a gate**.
3. Docs updated in place — read as they cross your path, no dedicated pass needed: `CLAUDE.md` (repo-
   structure `prompts/` line), `docs/cloud-setup/TEARDOWN-AND-REBUILD.md` (step 2 is now "leave continuity
   behind"; rebuild step 3 handles the no-handoff start), `scripts/teardown-preflight.sh`,
   `docs/SCRIPT-TRACKER.md` (preflight + prep entries), `README.md`, `docs/FILESYSTEM-MAP.md`, the
   bootstrap's motd line. The `tmp/` folder itself is a new convention: the human-transfer channel between
   machines (`tmp/README.md`).

These edits touched Leg-A-owned structural docs from the Leg-B session — that was the human's explicit,
ratified instruction, not a D6 ownership violation; nothing for you to repair or flag.

## Your two actions

1. **Your memory file** (`cloud-session-open-items`) references `prompts/handoff-cloud.md` (the Tier-0
   CLOSED note). Update the path to `prompts/handoff-skeleton.md` in your next memory edit — Leg B cannot
   write your memory (your backup would clobber any mirror edit).
2. **The inline handoff you're about to write**: write it FROM `prompts/handoff-skeleton.md` — every
   `⟨...⟩` filled, durable sections carried, in-flight jobs named. The human has already switched you to
   this workflow manually; this note is so you know it's the standing SOP, not a one-off.

Then delete this note (`git rm tmp/note-to-leg-a-handoff-sop.md`) in your next commit — tmp/ files are
transient by convention, and this one is spent once read.
