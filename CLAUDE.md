# Project Instructions: WEKA vs Lustre — WSI storage comparison on AWS

You run this competitive storage benchmark on the project's AWS GPU instance at my direction — executing the
pipeline and providing technical insight and decision support, especially on the storage side. It runs as two
sequential legs — **Leg A: WEKA**, then **Leg B: FSx for Lustre** — followed by the head-to-head synthesis.

**`PROJECT-THESIS.md` is the source of truth for _what we measure and why_. This file is _how we work_.**
Where the two overlap, the thesis owns the methodology and this file points at it — never restates it, because
two copies of a rule drift.

## Rules

The eleven rules govern how you work here. Read them every session. They are not aspirational. **If a rule and
a request conflict, surface the conflict — don't silently override either one.**

**1 — Think before coding.** No silent assumptions. State what you're assuming, surface tradeoffs, ask before
guessing, push back when something simpler would do.

**2 — Simplicity first.** Minimum code that solves the problem. No speculative features, no abstractions for
single-use code. If a senior engineer would call it overcomplicated, simplify.

**3 — Surgical changes.** Touch only what you must. Don't "improve" adjacent code, comments or formatting.
Don't refactor what isn't broken. Match existing style.

**4 — Goal-driven execution.** Define success criteria, then loop until verified. I state what success looks
like; you choose the steps and iterate until the criteria demonstrably hold.

**5 — Use the model only for judgment calls.** Classification, drafting, summarization, extraction from
unstructured text — yes. Routing, retries, status-code handling, deterministic transforms — no. Parsing,
transforms, hashing and queries are always plain code.

**6 — Surface conflicts, don't average them.** If two patterns contradict, pick one (the more recent, more
tested), explain why, and flag the other for cleanup. "Average" code that half-satisfies both is the worst
outcome.

**7 — Read before you write.** Read the file, its caller, and any shared utility before adding to it. If you
don't understand why something is structured the way it is, ask. *"Looks orthogonal to me"* is the most
dangerous phrase in this codebase.

**8 — Tests verify intent, not just behaviour.** A test must encode **why** the behaviour matters. Here that
means: a sweep's recording check asserts that the filesystem-side and wire-level numbers track the app-level
rate **at the consistency relation derived for that filesystem**, and that **the I/O path a cell actually took
matches what it claims** — not merely that every cell produced a `results.json`.

**9 — Checkpoint after every significant step.** Summarize what was done, what's verified, what's left. Never
continue from a state you can't describe back to me.

**10 — Match the codebase's conventions**, even where you'd choose differently. Conformance beats taste. If a
convention is genuinely harmful, surface it — don't fork it silently.

**11 — Fail loud.** If you can't be sure something worked, say so. "Backed up to S3" is wrong if the sync
errored on three files and you didn't say so. Default to surfacing uncertainty, not hiding it.

## Write lean

**Write what is true and durable.**

- No alternatives that were considered and dropped. No history. No state-of-things-today.
- **No placeholders for unknowns** — state the rule that governs the unknown instead.
- No value that drifts (versions, capacities, counts, paths) in a document about *method*; cite the rule, not
  the number.
- **A document that must be updated to stay correct will eventually be wrong.**

**This is not a licence to delete rationale.** Every *why* that changes what someone does stays. Lean means no
sentence that doesn't earn its place — not no explanation. The test, in both directions: **does removing this
change what anyone does?**

### No change logs. No date stamps. Decisions are a register, not a log.

**Git is the audit trail.** It records what changed, when, and in what order — automatically and correctly. A
change log maintained by hand inside a document is a worse copy of that, and one more thing that must be
updated to stay true. Delete them.

**Keep a decision _register_, not a decision _log_:** one entry per **live** decision, stating the decision and
why it is right **on its own terms** — never as a contrast with what it replaced. When a decision changes,
**overwrite the entry.** A superseded decision plus an explanation of why it was wrong helps nobody and rots
immediately; the reader needs to know what we do now and why that is sound.

Two things look like history but are not, and they stay:

- **A standing constraint** — *"don't use X; it does Y"* is forward-looking instruction that stops a future
  session re-proposing X. Write it as a constraint, not as a record of when we learned it.
- **A data-validity note** — if cells ran under a methodology that later changed, cells from before and after
  are not comparable. That fact attaches to the **affected cells**, not to a log.

**Preserve data, overwrite prose.** Benchmark data is irreplaceable and costs hours and real money; documents
are in git.

## Documentation — non-negotiable

Accuracy beats speed: **reference official docs, not training data**, before giving any command, flag, API
call, mount option, tuning parameter, price or config. These change between versions, and cloud specs and
prices change without notice.

- **AWS** → `docs.aws.amazon.com` (EC2 specs, FSx for Lustre performance/tiers/limits, EFA, S3, IAM, quotas).
  **WEKA** → `docs.weka.io`. **Lustre** → `doc.lustre.org` plus AWS's FSx guide for the managed specifics.
  **NVIDIA** → GDS / cuFile / nvidia-fs. **WSI toolkits** → OpenSlide, cuCIM + kvikIO (`docs.rapids.ai`),
  tifffile, large_image, MONAI, CLAM, Trident, Slideflow, QuPath. **Datasets** → TCGA (GDC), CAMELYON16/17
  (and the AWS Open Data registry), PANDA, BRACS, GTEx, PCam.
- Cite the page used. **If docs and training data disagree, the docs win — say so.** If something is
  undocumented, say that; don't fabricate flags. Check the installed version first (`pip show`, `--version`).
- **Never quote a cloud spec, cap, quota or price from memory** — fetch it, and stamp any price with the date
  it was checked.
- **Fetching official docs is standing-approved — never ask first.** Still ask before: a fetch that downloads a
  large asset, a service I've named off-limits, anything that sends project data in the request, or any
  non-WebFetch outbound channel — external output is ask-first like any state-mutating action.

## How we work together

**Priorities, in order: accuracy → safety → dependability → exhaustive recording → speed.**

**Plan first, then execute.** For real methodology decisions (what to benchmark, how to provision, what to
measure, dataset/tool/model) — surface options and tradeoffs and let me ratify; **the methodology calls are
mine.** Once agreed, execute without re-asking. Read-only checks (`weka status`, `lfs df`, `nvidia-smi`, `df`,
`ls`) just run. Surface decisions as a **plain-text numbered list with a recommendation each** — not the
AskUserQuestion picker, which forces one click per decision and blocks discussion.

**Safety.** Verify before mutating state you haven't checked this session. State the reason and ask before any
`sudo`, mount, format, package install or destructive operation — and say what would be lost first.

**Dependability defaults:** tee long output to a dated log; checkpoint anything over ~10 minutes; keep scripts
idempotent; pin versions that affect numbers.

**Don't ask for ratification of the obvious.** If a standing rule in this file already decides something —
or the answer is one no senior engineer would debate — decide and proceed, noting it. A stale "ask me first"
note in a tracker or doc does not outrank a standing rule here; that is a rule-6 conflict to resolve toward
the rule, not a reason to block. Reserve asks for genuine judgment calls.

**Pause only for these four triggers:** (1) open decisions or un-pre-decided methodology forks; (2) actual
issues to debug; (3) soft issues that may reshape *future*-step methodology (flag in the summary, don't block
agreed work); (4) anything else needing my attention — surprising results, external steps I must take, sudo or
destructive operations. Otherwise proceed; long sweeps are background work, with no routine "still running"
pings. **Wait on background work via its completion notification, never by blocking polls** — the
notification fires the moment the process exits, so polling both burns attention and can lag the finish.

**Unattended overnight chains are the normal mode**, which makes the tee'd log the primary forensic record of
what happened while nobody was watching — and means **a trigger that fires at 3am must be mechanical.** The
canary aborts the chain itself rather than waiting to be noticed.

**The roadmap is planning truth, not a frozen contract.** Roadmaps are written before much is measured. Before
each tier or substage, reassess against what has been measured since and revise proactively — surfaced before
committing wallclock, not after I ask. **Leg B's plan is explicitly provisional until Leg A's results exist**;
improving it from what Leg A taught us is the point, not a deviation. If a cell already ran under the old
methodology, preserve it and redo.

**Interpret instructions completely.** Before declaring something done, ask what the full scope implies:
(1) the literal ask; (2) cleanup of the prior state's residue; (3) every doc whose cadence is triggered;
(4) the decision register; (5) memory; (6) forensic preservation of **run artifacts** — rename a replaced or
failed run dir, never delete it (this covers data, not prose: superseded document text is overwritten, since
git holds it); (7) verify the new state is actually clean. Not a licence to scope-creep — but never leave a
half-clean state.

**Substage closeout is a mechanical gate, not a habit.** After a substage completes:
`scripts/verify-substage-closeout.sh <substage>` must exit 0 (aggregate fresh · roadmap results row written
· canary run · INDEX OK · raw in S3) **before the next phase launches**. Born of a real miss (Stage 3's
results block, 2026-08-17): prose in three docs called this non-negotiable and it was still skipped once —
so the check is code, and the prose is just its rationale. Extend the checker's table in the same edit that
adds a new substage.

**Git: Claude commits and pushes autonomously** (`git add -A && git commit && git push`), at its own
cadence — the working policy is a commit per coherent work block, always preceded by `./backup.sh`, with a
message that summarizes the block. Keep commits reviewable: batch at checkpoints, not mid-edit. **Never
commit while a measured cell is in flight**: `backup.sh` carries a full S3 sync, which moves data over the
client NIC and would perturb the cell — the same exclusivity rule that binds everything else (during
sweeps, `run-leg.sh`'s own per-step sync covers durability). The push is also a teardown prerequisite, and
an unpushed repo dies with the instance — so push promptly, never let work sit local-only overnight.
`git reset --hard` / `git clean -f` remain ask-first (destructive).

**tmux:** all work runs inside `tmux new -A -s wsi` — assume you're already in it. Still tee long output (it
survives even if tmux dies). Don't propose `nohup`/`disown`.

**Benchmark data preservation is non-negotiable.** Re-running costs hours-to-days and real money. Never delete
a run directory, however broken — rename it `-FAILED-<reason>` and say so.

## Recording — non-negotiable

"If it isn't recorded, it didn't happen." Every benchmark runs through the recording wrapper. Per cell: raw
tool output verbatim, run metadata, the exact configuration, results with context, the **cache state
achieved**, and **wallclock plus the cost inputs** — because cost-to-complete is calculated from them
(`PROJECT-THESIS.md` §4) and cannot be reconstructed after the fact.

**No metric is designated primary** (thesis §4). Capture the full set on every cell where it is meaningful;
which axis turns out to be decisive is a result, not a design input, so a cell that recorded only the axis
someone expected to matter cannot be repaired later.

- **Time series, not point estimates** — capture the timeline and derive aggregates from it.
- **Multiple sources**, pre/during/post. Discrepancies are data, not noise.
- **Verify the capture** before trusting a run — an empty source means fix the infrastructure and re-run.
- **Never quote a throughput, latency or IOPS number from a source the filesystem in use bypasses.** The
  per-filesystem primaries, which sources are diagnostic-only on each leg, and the per-filesystem consistency
  relation are defined in **`PROJECT-THESIS.md`** — that is the single source; don't restate the table here.
- **Run the consistency canary after every sweep.** Disagreement means the instrumentation is wrong — fix it
  before continuing, because every subsequent number depends on it.
- **Prove the I/O path per cell.** For any cuFile cell, record cuFile's own accounting of GPU-direct versus
  bounced bytes as a first-class source. **A configuration flag is not proof of behaviour.**
- **Cold-versus-warm is an enforced axis, not an occasional variant** — both sides carry substantial cache, so
  any warm cell risks measuring cache rather than storage. Record cache state per cell.

### Durability — the cloud-specific half

**Instance-local NVMe and both filesystem mounts are ephemeral.** They die with the instance, and the instance
is deliberately rebuilt between legs. **Nothing that matters may rest only there.** Claude's conversation
context does not survive either — only the repo, the memory mirror, and S3 do.

**Authority split, no overlap:** **git** is authoritative for all small text — docs, per-run JSON and READMEs,
configs, the memory mirror. **S3** is authoritative for the heavy write-once data git can't hold — raw
telemetry and datasets.

**`backup.sh` is the single durability entry point**, with two deliberately different sync semantics:
**mirror-with-delete** where local is the source of truth and git backs it independently; **add-and-update,
never delete** for raw telemetry and datasets, because reclaiming local disk must not destroy the only
remaining copy. The sync is **verified, not assumed.**

**The teardown and rebuild checklist is mandatory, not advisory**, and its order is load-bearing: skipping a
step loses work permanently. The environment contract is what makes two legs run at different times provably
comparable; a mismatch is a fail-loud condition, not a footnote.

## Repo structure

```
docs/      what we decided — methodology, roadmaps, findings, provisioning procedure
scripts/   what we run with — the library, manifests, environment specs
runs/      what we got — INDEX.md, run directories, the per-leg resume markers, sweep logs, contracts
prompts/   the living handoff (edited to current state at each teardown)
```

Scripts derive their repo root from their own location and **never hardcode a path.**

**The filesystem is a dimension, not a fork in the code.** One `runs/` tree; `--fs {weka|lustre}` appears as a
segment in the run-directory name and a field in each run's metadata, so aggregators pivot on it and emit
head-to-head comparisons directly. *Why one tree:* the deliverable **is** the cross-filesystem delta; separate
trees would force every comparison to be assembled by hand. A hardcoded mount makes a Lustre cell silently
measure WEKA, and the number looks correct.

## Concurrent legs (D6, amended 2026-08-19)

Two sessions — one per leg, one repo, one branch. The rules that make that safe:

1. **Push via `./scripts/push-safe.sh`**, never bare `git push` — it pull-rebases with retries. A rebase
   conflict is an **ownership violation to report**, not to resolve silently.
2. **`runs/INDEX.md` is union-merged and append-only** (`.gitattributes`) — append; never rewrite another
   leg's lines. **The summary CSVs are per-leg files** (`…-summary-<leg>.csv`): aggregators rewrite them
   whole, so the two legs never share a CSV write target; the head-to-head pivot reads both legs' files
   (the D-4 helper).
3. **File ownership.** Each leg writes: its own run dirs, its own `.leg-state/<leg>/`, its own memory file
   (`cloud-session-open-items` = Leg A, `cloud-session-open-items-lustre` = Leg B), its own contract, and its
   own leg's rows/columns in the stage roadmaps. **Structural doc edits (tracker, STAGES, THESIS, RUNBOOK
   prose) belong to Leg A's session**; Leg B proposes them as numbered items instead of editing. Cross-cutting
   script changes go through the human.
4. **The stage-lag rule:** Leg B never starts stage N until Leg A has completed stage N (see D6). A shared-code
   fix after Leg A ran a stage re-runs that stage on both legs.

## Docs cadence — which doc to update when

After any exchange that shifts the picture durably, update every doc whose cadence is triggered, in place.
Batch related updates; defer the rest. Don't churn, and don't leave a stale doc a future session would plan
against.

| Doc | Purpose | Cadence |
|---|---|---|
| `PROJECT-THESIS.md` | **Source of truth** — the question, the held-constant contract, both asymmetries, what gets measured, recording, sequencing, scope | Only when the methodology itself changes |
| `CLAUDE.md` | How we work | Only when I steer a new convention (rare) |
| `README.md` | Repo entry point: what this is, layout, the path to a first result | When the layout or that path changes |
| `docs/STAGES.md` | Stage map (`--stage` values) + the per-leg plan + the **cross-stage decision register** | On stage-status, plan or decision change |
| `docs/Stage-<N>-*.md` | Per-stage roadmap: methodology, **why each substage exists**, per-cell results as produced, the stage's decision register | **Constantly** — most-edited doc |
| `docs/RESULTS.md` | **Findings and their story** — the cross-stage synthesis (see below) | When a finding lands; heaviest at stage closeout |
| `docs/SCRIPT-TRACKER.md` | Per-script reference for `scripts/` — what + why, I/O, caveats, and the deferred-work table | After each script created or changed |
| `docs/RUNBOOK.md` | How to run and record a cell; recovery; the canaries | When recording infrastructure changes |
| `docs/FILESYSTEM-MAP.md` | "Where does X live?" — both mounts, S3 layout, scratch, tools | When a load-bearing path or environment fact emerges |
| `docs/NAMING-AND-VARIABLES.md` | Every path, name and variable with its recommended value — the single source of truth for names, and the reason `$FS_MOUNT` exists. Paired with `env.example.sh` | When a variable is added, renamed, or its recommended value changes |
| `docs/cloud-setup/*` | Human-facing procedure: provisioning reasoning, and the teardown + rebuild checklist | When provisioning or the bootstrap sequence changes |
| `runs/INDEX.md`, run-dir `0_README.md` | Run history / per-run description | **Auto-generated — never hand-edit** |
| memory + `MEMORY.md` | Open items and external commitments | Per memory hygiene below |

**`docs/RESULTS.md` — findings and story, and the rule that keeps it honest.** It carries the cross-stage
synthesis: what was found, what it means, the caveats. It may be as granular as the findings require — but
**numbers live in exactly one place.** Per-cell results belong in the stage roadmap, beside the methodology
that produced them; RESULTS.md quotes only headline figures **with a pointer to the cell they came from**, and
never reproduces per-cell tables. Two copies of a number drift, and the stale one is invisible. Keep a
consistent per-stage shape so the synthesis stays compressible. It is written **after** results exist; before
that it is a skeleton, not scaffolding.

**Where decisions live:** scoped to one stage → that stage's roadmap decision register; cross-stage or
project-wide → the register in `docs/STAGES.md`. Record **what, why, and the sources** — not when, and not what
it replaced. Don't split one decision across both.

**Record the WHY everywhere.** Every methodology choice, in any doc, needs its rationale — not just the choice.
In a competitive comparison every choice is a place a skeptical reader looks for bias, so a choice recorded
without its why is **a bug to fix in the same edit.**

**Where unresolved items live.** An open question recorded only in the doc that surfaced it will not be seen
again until someone re-audits that doc. So whenever something must be resolved before the first measured cell
or watched during benchmarking, **add it to the open-items memory in the same edit**, with a pointer to the doc
holding the detail. Memory loads every session; a doc has to be found. **That memory holds only open items —
delete an entry when it is done.**

**Framing.** The framing rules that govern every document here are in `PROJECT-THESIS.md`.

## Memory hygiene

Memory (indexed by `MEMORY.md`, mirrored into the repo by `backup.sh`) holds only what the repo cannot:
**open items, decisions still in flight, and external commitments.**

- **Conventions belong in this file. Findings belong in docs. Tactical state belongs nowhere** — driver
  versions, current mounts, `weka status`, `lfs df`, free space: re-derive with a read-only command, freely.
  You're on the box.
- **Prune aggressively.** Delete anything wrong, resolved, duplicated, or that a fresh session wouldn't
  benefit from — the strongest test.
- **Treat an undated or unsourced commitment in memory as a claim to verify, not a fact.**
- The bar: a fresh session loads memory plus this file and continues without my re-describing anything. **On an
  ephemeral cloud instance this is not a nicety — with the repo and S3, it is the only continuity that exists.**

## Fresh-session reading order

**To execute:** the open-items memory (the work list) → `PROJECT-THESIS.md` → this file → `docs/STAGES.md`
(plan + decision register) → the relevant `docs/Stage-<N>-*.md` → `docs/RUNBOOK.md` before running a cell.

**To understand results:** `docs/RESULTS.md` → the stage roadmap behind any figure → the run's `0_README.md`.

**Iterative allowlist (`.claude/settings.json`):** add safe, repeated operations to `allow` as prompt-fatigue
shows up; add never-auto-run patterns to `ask`/`deny`; tell me about any change you make.
