# Task prompt — align every document to the project thesis

You are Claude Code on the build machine, working in **`~/weka-vs-lustre-cloud`**. This repository has just
been through a structural rebuild: the thesis was rewritten, `CLAUDE.md` was rewritten, the memory set was cut
from 20 files to 2, the tree was restructured, and the scripts were re-pathed. **The documents were not
touched.** They still describe an older framing, an older metric structure, and a directory layout that no
longer exists.

**Your job: make every document true to `PROJECT-THESIS.md`.** Nothing has been measured, so this is a
rewriting task, not an analysis one.

**This prompt is one-shot, and deleting it is the last step** — see the end.

---

## Read first, completely

1. **`PROJECT-THESIS.md`** — the source of truth. Every edit is judged against it.
2. **`CLAUDE.md`** — how we work. Especially **"Write lean"**, which governs the largest part of this job.
3. `MEMORY.md` and the two memories it indexes.

---

## What has already been done — do not redo

- **`PROJECT-THESIS.md` and `CLAUDE.md`** are rewritten and current.
- **The tree was restructured** — see "The layout" below.
- **The scripts were re-pathed and verified**: repo roots, runs roots, `runs/lib` → `scripts`. Do not touch
  `scripts/`.
- **The five prompts in `prompts/` had their paths fixed** — every path they cite currently resolves. Their
  *content* has not been audited; see below, it is yours.
- **Memory is 2 files.** Nine conventions were folded into `CLAUDE.md` and two framing rules into the thesis.
- **`AUDIT-REPORT.md` and `AUDIT-PROMPT.md` were deleted** as history — git holds them.

## Scope

**In scope — 22 files:** everything in `docs/` **except `SCRIPT-TRACKER.md`**, everything in
`docs/cloud-setup/`, **everything in `prompts/`**, plus `README.md` and `.gitignore`.

The provisioning docs and the prompts matter *more* here than in an on-prem project, not less: the instance is
destroyed and rebuilt between legs, so those files are executed repeatedly, by a session with no memory of the
last time. A vague instruction there costs a rebuild.

**Out of scope, deliberately:**
- **`docs/SCRIPT-TRACKER.md`** — it is the register for deferred script work (`D-4`…`D-24`) and belongs to
  whoever does that work. Editing it now would describe scripts that are about to change.
- **`scripts/`, `PROJECT-THESIS.md`, `CLAUDE.md`.**
- **Any claim about how an individual script works.** Per-script mechanics live in `SCRIPT-TRACKER.md`. If a
  roadmap asserts a script's interface, describe the *step* and leave the mechanics out.
- **Inventing results.** Nothing has been measured. No document may gain a number.

---

## The layout

```
docs/               methodology — STAGES, the 7 stage roadmaps, RUNBOOK, FILESYSTEM-MAP,
                    NAMING-AND-VARIABLES, SCRIPT-TRACKER (not yours)
docs/cloud-setup/   procedure for a lifecycle event — NEW-CLOUD-SETUP, TEARDOWN-AND-REBUILD,
                    SPINUP-CHECKLIST, WORKFLOW
prompts/            the five paste-to-Claude prompts
scripts/            the library + manifests/ + env-specs/
runs/               INDEX.md and run directories, nothing else
env.example.sh      at the repo root (was cloud-setup/env.example.sh)
```

---

## The work

### 1. ⚠ The client-capped claim — delete the prediction, KEEP the sizing rule

**Measured target: `4 files`, 6 hits.** This one needs a hand, not a find-and-replace, because the same phrase
is doing two different jobs:

**(a) The prediction — DELETE.** *"Bandwidth is expected to be client-capped for both sides at ~25 GB/s; a tie
on pure bandwidth cells reflects the instance, not either filesystem."* This is a **predicted outcome** in a
project whose first framing rule forbids them, and it is very likely wrong: Lustre carries a
per-client-per-file-server bandwidth cap that EFA exists to escape, so its achievable single-client bandwidth
depends on server count and striping and may not approach line rate at all. Predicting a tie pre-decides the
most contested axis in the comparison.

**(b) The sizing rule — KEEP.** *"Provision both filesystems above what the client can drive, so neither is
the constraint."* This is sound, and it is **why** the FSx capacity floor and the WEKA backend-count floor
exist. A filesystem provisioned below the client's capability measures its own sizing rather than its
architecture. Thesis §5.1 carries the corrected wording — follow it.

**Deleting (b) along with (a) would destroy the provisioning rationale.** Read each hit before touching it.

### 2. The metric structure changed — no metric is primary

Thesis §4. The docs currently headline throughput per stage. **Nothing is designated primary now**, because
choosing the decisive axis in advance would be a prediction. Every cell reports the full set — throughput,
ops/sec, latency and percentiles, metadata rates, concurrency scaling, wallclock — and **which axis turns out
decisive is a result.**

**Cost is measured on every cell and `cost to complete = (instance $/hr + filesystem $/hr) × wallclock` is
calculated per cell and per leg.** This is new, it applies to every stage roadmap, and it is the figure that
turns the provisioning asymmetry from a caveat into arithmetic. Prices are fetched and date-stamped, never
recalled.

### 3. Delete every `[STORY PENDING RESULTS]` marker

**Measured target: `9 files`, 42 hits.** Under the leanness rule a placeholder rots and must be remembered;
**an interpretation section that doesn't exist yet can't go stale.** Delete the markers and the empty
scaffolding they sit in. When results land, the section gets written then.

### 4. Delete every change log. Convert every decision log to a register.

**Measured target: `8 files`** — the seven stage roadmaps plus `STAGES.md`, which also carries **4 change-log
rows** and **16 `D`-entries**.

- **Change logs: delete outright.** Git is the audit trail.
- **Decision logs → decision registers.** One entry per **live** decision, stating what we do and **why it is
  right on its own terms** — never as a contrast with what it replaced, never dated. Drop every entry whose
  decision is superseded or no longer applies under this thesis.
- Two things that look like history and **stay**: a **standing constraint** (*"don't use X; it does Y"*), and a
  **data-validity note** attached to affected cells.

### 5. The instance is decided — drop the "subject to change" tagging

**Measured target: `6 files`, 8 hits.** `g6e.24xlarge` is confirmed. Remove the hedging, and remove any
pointer to the open-decisions memory that used to index those references — **that memory was deleted**, since
a hand-maintained index of every doc mentioning a value is a grep maintained by hand.

The instance's **pre-committed revisit trigger still stands** and belongs in the `STAGES.md` register: if
Leg A's synthetic ceiling pins at line rate across block sizes *and* the concurrency sweep saturates on CPU
rather than storage, the instance is measuring itself — move up before Leg B.

### 6. Fix the layout references

- **`runs/lib` → `scripts/`** — `6 files`, 19 hits.
- **bare `cloud-setup/`** — `9 files`, 55 hits. It resolves to `docs/cloud-setup/`, `prompts/`, `scripts/` or
  the repo root depending on the file; check each.
- **`runs/STAGES.md` / `runs/README.md` / `runs/Stage-`** — `5 files`, 14 hits. These are now `docs/STAGES.md`,
  `docs/RUNBOOK.md`, `docs/Stage-*.md`.
- **`.gitignore`** must match the new tree.
- One dangling **`AUDIT-REPORT`** reference remains, inside a change log you are deleting anyway.

### 7. The prompts and the handoff cadence — you may restructure

The five prompts in `prompts/` and the lifecycle docs in `docs/cloud-setup/` describe **how the work is handed
between the human and Claude**. That cadence was designed incrementally, and you have explicit licence to
**consolidate, split, merge or re-sequence it** where that makes the work simpler or less error-prone. This is
not a licence to redesign the benchmark — only how it is driven.

**A named candidate, not a decision.** `prompts/handoff-cloud.md` is currently one state-independent prompt
that detects whether it is a first build or a rebuild and then routes through a table of "on a rebuild, do X
instead of Y". Two separate prompts — one first-build, one rebuild — would each be simpler and would remove the
routing step. **The counter-argument is duplication:** the two would share most of their content, and two files
that must be kept in step are how instructions drift apart. Weigh it and decide; either answer is fine if the
reasoning is recorded.

**Criteria for a good change here:**
- **Fewer places a session can take the wrong branch**, and fewer things the human must remember to say.
- **No duplicated procedure.** If two prompts would share a block, either factor it out or keep one prompt.
  A drifted copy is worse than a longer file.
- **Each prompt stays self-contained and re-runnable on every rebuild** — that is the whole design.
- **Every hard gate survives**: the transport gate, the blocker gate, the pre-flight GO/NO-GO, and the
  human-only steps (commit and push, destroying anything).

**If you change the cadence, two things must change with it:** `docs/cloud-setup/WORKFLOW.md`, which is the
router naming each prompt and when to paste it, and `docs/cloud-setup/NEW-CLOUD-SETUP.md`, whose Parts are
built around the handoff points. A cadence change that leaves either stale is worse than no change at all.

### 8. Replace `PRESENTING.md` with `docs/RESULTS.md`

`PRESENTING.md` was deleted — 439 lines of presentation script for results that do not exist. `3 files` still
reference it.

**Create `docs/RESULTS.md`** per its contract in `CLAUDE.md`: the cross-stage synthesis of findings and their
story; **numbers live in exactly one place** — per-cell results stay in the stage roadmap beside the
methodology that produced them, and RESULTS.md quotes only headline figures **with a pointer to the cell**; a
consistent per-stage shape; written **after** results exist.

**Right now it should be close to empty.** A skeleton, not scaffolding.

### 9. Carry the thesis's hard gates into the roadmaps

Each of these already exists in the thesis; the roadmaps must not contradict them.

- **The transport gate** — WEKA on DPDK, Lustre on EFA. A fallback transport is a **stop**, not a caveat
  (thesis §5.2), and `run-leg.sh` refuses to start a leg without it.
- **The GPU-direct matrix** runs both cuFile modes on both filesystems, designed on the expectation that the
  WEKA leg runs in compat mode, with **a single Phase-0 cell confirming that empirically** before the matrix is
  committed. The I/O path is proven per cell; a configuration flag is never proof of behaviour.
- **Cold-versus-warm is enforced**, cache state recorded as achieved, and any corpus that must exceed cache is
  sized against **both** filesystems' caches so one identical corpus definition serves both legs.
- **Per-filesystem telemetry primaries invert** between legs (thesis §7) — don't restate the table, point at it.

---

## How to handle what isn't known yet

**Do not write a placeholder.** `CLAUDE.md` forbids them: they rot and get forgotten, which is exactly what the
42 `[STORY PENDING RESULTS]` markers demonstrate.

**State the rule that governs the unknown instead.** Thesis §5.1 is the model — rather than a blank for the
provisioned configuration, it says both sides are sized above what the client can drive *and that the
configuration is recorded alongside every result*. That sentence is permanently true and needs no maintenance.

---

## Rules

- **Read a document fully before editing it.** These are long and interconnected.
- **Lean is not a licence to delete rationale.** Every *why* that changes what someone does stays — and in a
  competitive comparison the *why* is what a skeptical reader checks for bias, so it is load-bearing. Cut
  verbiage, staleness and duplication, not explanation. The test both ways: **does removing this change what
  anyone does?**
- **Surface conflicts, don't average them.** If a roadmap contradicts the thesis, the thesis wins — say so in
  your report rather than blending them.
- **Fail loud.** If you cannot tell what a section was trying to say, flag it rather than guessing.
- **Don't commit.** The user commits.

## Report back

1. **Per document:** what changed, and roughly how much shrank.
2. **A verification table** for the measured targets above — each should be zero within your scope (exclude
   `docs/SCRIPT-TRACKER.md`). Show the commands.
3. **The client-capped hits one by one**, with your delete-or-keep call and the reason. This is the item most
   likely to be got wrong, so it gets its own section.
4. **Decisions dropped from the registers**, and why each no longer applies.
5. **Anything in the thesis that a document made you doubt.** The thesis was rewritten before these roadmaps
   were re-read; if a stage cannot be run the way it describes, that is a finding, not something to paper over.
6. **Anything you left for whoever owns `SCRIPT-TRACKER.md`**, especially places where a roadmap needed to
   describe a script's behaviour.

---

## Last step — delete this prompt

**`rm prompts/audit-docs.md`, as the final action of the task.**

*Why:* the other five prompts in `prompts/` are **re-runnable on every rebuild** — that is their design, and it
is why they earn a permanent place. **This one is not.** It describes a single transition, and its measured
targets ("`9 files`, 42 hits") are only true *before* it runs. The moment you finish, every count in it is
wrong and every instruction describes work already done.

Leaving it behind would put a document in `prompts/` that **reads like a live instruction and isn't** — which
is the precise failure this whole pass exists to remove, and it would sit in the one directory where a future
session goes looking for things to execute. `CLAUDE.md`: *a document that must be updated to stay correct will
eventually be wrong.* This one cannot be updated to stay correct; it can only be finished.

Git holds it. This repository already deleted its previous audit report and audit brief on exactly this
reasoning.
