# Task: full technical audit of this repository before it is deployed to a cloud instance

You are auditing a **storage benchmark project** immediately before it is deployed onto a rented cloud GPU
instance. Your job is to make it **accurate, self-consistent, and drop-in ready.**

**Why this matters concretely.** The instance and its storage cost real money per hour. Every inaccuracy you
leave behind becomes paid troubleshooting time on a metered machine — and worse, some classes of error here
produce *plausible-looking but wrong measurements*, which cost far more than a crash because they are not
noticed. The project owner has explicitly asked for a deep audit rather than a quick pass.

**Your role is technical auditor.** What the benchmark is *for* does not matter to this task — treat it as a
storage/IO benchmark over a multi-stage data-processing pipeline that reads and writes large binary image
files. You will learn the domain from `CLAUDE.md` and `PROJECT-THESIS.md`; **do not spend effort on the
subject matter.** Judge only: is this repository correct, consistent, executable, and followable?

---

## 0. Where you are, and one thing that will look wrong but isn't

You are in the project repository. It has never been run. It is about to be cloned onto a cloud instance where
a different session will execute it.

**There are no Claude memories loaded, and that is intentional.** The project's memory files live as tracked
files in `claude-memory-mirror/`. They are restored into the live memory directory *on the cloud instance*, not
here. For this audit that is desirable: **the memory files are artifacts you are auditing, not instructions you
are following.** Read them as documents. Do not restore them.

**A second, older repository exists elsewhere on this machine** (a previous, on-premises version of this
effort). **It is out of scope and must not be modified.** You may read it *only* if you need to confirm whether
something was carried over correctly — never to copy content in, and never to edit. If you cannot tell which
repository a path belongs to, stop and ask.

---

## 1. Read everything, in this order

Read **completely** — not skimmed. Where a file is long, read it in sections but read all sections.

1. **`CLAUDE.md`** — the project's operating rules. This is your **reference standard**: many audit findings
   are "document X violates a rule stated in `CLAUDE.md`."
2. **`README.md`** and **`PROJECT-THESIS.md`** — what the project is and the contract it holds itself to.
3. **`cloud-setup/NAMING-AND-VARIABLES.md`** and **`cloud-setup/env.example.sh`** — the single source of truth
   for every environment-varying value. **Load-bearing for the audit:** most cross-file inconsistencies are
   naming inconsistencies.
4. **`runs/STAGES.md`** — the plan hub and the numbered decision log. Every methodology claim elsewhere should
   trace back here.
5. **All seven `runs/Stage-<N>-*.md` roadmaps.**
6. **`runs/README.md`** — the operational runbook.
7. **`SCRIPT-TRACKER.md`** — the per-script reference, the cross-cutting patterns, and the deferred-work table.
8. **`FILESYSTEM-MAP.md`**, **`PRESENTING.md`**.
9. **All of `cloud-setup/`** — the human-facing setup guide, the provisioning checklist, the teardown/rebuild
   checklist, and the two prompts handed to future sessions.
10. **Every file in `claude-memory-mirror/`**, including its index.
11. **Every file in `runs/lib/`** — the script library. Read the code, not just the headers.
12. **`.gitignore`**, **`.claude/settings.json`**, **`backup.sh`**, **`runs/manifests/`** (structure, not every row).

---

## 2. What "perfect" means — the eight audit dimensions

Work through all eight. For each finding, record: **file · line · what's wrong · why it matters · the fix.**

**A. Factual accuracy.** Every concrete claim must be true *right now*: file counts, path names, flag names,
command syntax, variable names, function names, line references, tool behaviour. **Verify by execution or
`grep`, never by reading and believing.** If a doc says a script accepts `--foo`, check the argument parser. If
it says "36 files", count them.

**B. Staleness.** This repo has been through several rounds of change, and each round left residue. Look
specifically for: counts that have drifted; work described as pending that is actually done (or the reverse);
superseded workflows still prescribed; references to a structure that has since been renamed or removed;
instructions that were correct two revisions ago.

**C. Cross-reference integrity.** Every pointer must resolve and be *correct*, not merely non-broken:
- Doc→doc links: does the target exist, and does it actually contain what the pointer claims?
- Doc→script references: does the script exist at that path, with that name?
- Script→script invocations: same.
- Memory `[[wiki-style]]` links: does a memory with that name exist?
- The memory index versus the actual memory files: exact 1:1?
- Identifier schemes (e.g. the decision-log numbering, the deferred-work item ids): used consistently
  everywhere, with no gaps, duplicates, or references to retired ids?

**D. Internal consistency.** The same fact must be stated the same way everywhere. Build a table of facts that
appear in more than one file — instance type, mount paths, file counts, which work is deferred versus done,
sizing figures, variable names — and confirm every occurrence agrees. **Where two files disagree, determine
which is right rather than splitting the difference.**

**E. Executability.** Everything must actually run:
- Every shell script parses (`bash -n`); every Python file compiles.
- Every guard, validator, and refusal path **actually fires** — test them. Several scripts are designed to
  abort loudly on misconfiguration; verify they do, and that they exit non-zero.
- Commands quoted inside documentation are runnable **as written** (correct flags, correct quoting, correct
  order). A copy-pasted command that fails costs metered time.
- **Environment-variable completeness is a specific, high-risk check:** collect every variable the scripts
  actually read, and confirm each one is defined and documented in the configuration template and the naming
  document. A variable a script needs but nobody sets is a guaranteed failure on the cloud.

**F. Simplification.** Reduce, don't add:
- Content duplicated across files → one source of truth plus pointers. Duplicated instructions **will** drift.
- Circular or multi-hop pointer chains (A says see B, B says see C, C says see A) → point directly at the
  authority.
- Over-long passages that bury the actionable step.
- **Do not delete substantive rationale.** This project deliberately records *why* behind every choice; that is
  a requirement, not verbosity. Cut redundancy, never reasoning.

**G. Completeness.** Is anything required on the cloud simply absent? Read the setup guide and the two session
prompts as an outsider: could someone follow them start to finish without needing knowledge that is written
nowhere? Note gaps as findings.

**H. The drop-in test — the one that matters most.** For each of the three audiences, simulate being them with
no prior context:
1. **The project owner** following the setup guide by hand. They are not deeply technical. Is every step
   unambiguous, in the right order, with a way to tell it worked?
2. **A fresh Claude session** on the cloud instance receiving the project handoff prompt. Does it have
   everything needed, in the right order, with nothing assumed that isn't stated?
3. **A future session resuming mid-project** after a rebuild. Can it work out where things stand?

---

## 3. Things that are deliberate — do NOT "fix" these

Changing any of these would be a regression. If you believe one is wrong, **raise it; do not act.**

- **Absent results.** Placeholders marking unmeasured numbers and unwritten interpretations are intentional and
  mandated. **Never fill one in, never estimate, never predict an outcome.** The project forbids stating what
  results will show before they exist.
- **Warning banners** on two files marking them as carried-over-and-not-yet-revalidated. They stay until
  validated on the real environment.
- **Deferred work.** A specific set of items is deliberately *not* implemented because it requires the real
  environment. Verify the list is accurate and consistent; do not attempt the work.
- **Recorded rationale.** Every methodology choice states its reasoning by design.
- **Deliberate asymmetries** in the benchmark design are the subject of the study, not bugs.
- **The absence of any reference to the earlier on-premises effort** is a project rule, not an oversight.
- **Configuration is never hardcoded.** Scripts read values from the environment and are designed to *refuse to
  run* rather than default. Do not add convenience defaults — the refusal is a safety property.

---

## 4. How to work

**You have been given a high effort budget and may spawn parallel agents. Use them.** This is a
breadth-then-depth task: many files, many pairwise consistency relations.

Suggested shape (adapt as you see fit):
1. **Inventory pass** — enumerate every file, and build the fact table (dimension D) and the full
   cross-reference graph (dimension C) mechanically. Prefer scripted extraction over manual reading here.
2. **Parallel deep-read** — one agent per document cluster (root docs · stage roadmaps · setup/prompts ·
   memories · script library), each reporting findings in a structured form against dimensions A–H.
3. **Mechanical verification** — run the syntax checks, the guard tests, the variable-completeness extraction,
   the link resolution. **This is the highest-value phase: it produces findings that are certainly true.**
4. **Adversarial verification** — for each proposed finding, independently check whether it is actually wrong
   before changing anything. **A confidently-wrong "fix" is worse than the original issue**, because the
   original at least got read again. Default to *not changing* when uncertain.
5. **Apply fixes**, then **re-verify** — several earlier fixes in this repo introduced new inconsistencies
   (changed counts, renamed things, moved content). Re-run the mechanical checks after editing.
6. **Convergence check** — repeat until a full pass produces nothing new.

**Discipline requirements:**
- **Ground every claim about external tools, commands, or flags in official documentation** rather than
  recall — this is a project rule, and version drift is a real source of error. Cite what you used.
- **Fail loud.** If you cannot verify something, say so explicitly rather than assuming it is fine.
- **Do not commit or push.** The project owner does that. Leave the working tree with your changes in it and
  report what you changed.
- **Ask before anything destructive**, and never modify the older repository.

---

## 5. Known-fragile areas — look hardest here

These have already caused problems in this repo, so treat them as suspect until proven correct:

1. **The deferred-work list appears in at least three places.** They must agree exactly on which items exist,
   their identifiers, their scope, and which are done. This has drifted before.
2. **File and item counts.** Several counts have been wrong more than once. Verify every number.
3. **Environment-variable coverage** (dimension E). The scripts were recently converted from hardcoded paths to
   environment variables. Confirm *every* variable they read is documented and set — this conversion is the
   most likely place for an omission, and the failure mode is a script that dies on the cloud.
4. **Guard behaviour.** Multiple scripts must refuse to run on misconfiguration. Test each refusal path and
   confirm a non-zero exit. One guard in particular cross-checks two values against each other; verify it
   catches a genuine mismatch.
5. **Duplicated procedures.** One checklist was recently de-duplicated into a pointer. Check for others —
   especially between the human-facing setup guide, the provisioning checklist, and the teardown checklist.
6. **The two session prompts** handed to future Claude sessions. They summarise the repo's state, so they go
   stale first. Verify every claim they make about what exists and what remains.
7. **Naming consistency after a rename.** The project and its directory were renamed partway through. Confirm
   no path references the old name, while noting that some *identifiers* legitimately still contain it — decide
   which is which rather than blanket-replacing.
8. **The relationship between the plan's step list and the scripts that implement it.** Confirm every planned
   step maps to a real script, and that steps with no implementation are explicitly marked rather than silently
   missing.

---

## 6. Deliverables

1. **An audit report** (write it to `cloud-setup/AUDIT-REPORT.md`): findings grouped by dimension, each with
   file, line, severity, and whether you fixed it or are raising it. Include what you verified and found
   **correct** — knowing what was checked is as useful as knowing what was wrong.
2. **The fixes applied**, surgically. Match existing style and structure; do not restructure documents that are
   merely imperfect.
3. **A short list of items needing the owner's decision** — anything you judged out of scope, ambiguous, or
   where fixing it would change methodology rather than correct an error. Plain numbered list, with a
   recommendation for each.
4. **A verdict:** is this repository drop-in ready? If not, what specifically blocks it?

---

## 7. Your first response

Before changing anything, report:
- What you read and what the repository contains.
- Your audit plan, including how you will parallelise it.
- Anything that already looks wrong or ambiguous.
- Any questions, as a plain numbered list with a recommendation each.

Then proceed through the audit, checkpointing as you complete each phase. Apply fixes only after the
verification phase supports them.
