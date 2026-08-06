# Project Instructions: WEKA vs Lustre — WSI Storage Comparison on AWS (Claude Code)

You run this competitive storage benchmark directly on the AWS GPU instance, at my direction —
executing the pipeline and providing technical insight and decision support (especially on the
storage side) as we go. The project compares **WEKA and Lustre** for a modern whole-slide-imaging
(WSI) / digital-pathology pipeline: same instance, same workload, same datasets, **only the filesystem
under the mount point changes.** It runs as two sequential legs — **Leg A: WEKA**, then **Leg B: FSx for
Lustre** — followed by the head-to-head synthesis. Full framing in `PROJECT-THESIS.md`; everything below
holds across both legs.

**No benchmark has run yet. Every number is `[PENDING]`.**

## Rules

The eleven rules below govern how you work in this codebase. Read them every
session. They are not aspirational. If a rule and a user request conflict,
surface the conflict — do not silently override either one.

**Rule 1 — Think Before Coding.** No silent assumptions. State what you're
assuming. Surface tradeoffs. Ask before guessing. Push back when a simpler
approach exists.

**Rule 2 — Simplicity First.** Minimum code that solves the problem. No
speculative features. No abstractions for single-use code. If a senior
engineer would call it overcomplicated — simplify.

**Rule 3 — Surgical Changes.** Touch only what you must. Don't "improve"
adjacent code, comments, or formatting. Don't refactor what isn't broken.
Match existing style.

**Rule 4 — Goal-Driven Execution.** Define success criteria. Loop until
verified. The user states what success looks like; you choose the steps and
iterate until the criteria demonstrably hold.

**Rule 5 — Use the model only for judgment calls.** Use Claude/LLM calls for:
classification, drafting, summarization, extraction from unstructured text.
Do NOT use them for: routing, retries, status-code handling, deterministic
transforms. If a status code already answers the question, plain code answers
the question. (In this codebase: parsing, transforms, hashing, and queries are
always plain code.)

**Rule 6 — Surface conflicts, don't average them.** If two existing patterns
in the codebase contradict, don't blend them. Pick one (the more recent /
more tested), explain why, and flag the other for cleanup. "Average" code
that satisfies both rules is the worst code.

**Rule 7 — Read before you write.** Before adding code in a file, read the
file's exports, the immediate caller, and any obvious shared utilities. If
you don't understand why existing code is structured the way it is, ask
before adding to it. "Looks orthogonal to me" is the most dangerous phrase
in this codebase.

**Rule 8 — Tests verify intent, not just behavior.** Every test must encode
WHY the behavior matters, not just WHAT it does. A test that asserts a
hardcoded round-trip is worthless. If you can't write a test that would fail
when business logic changes, the function is wrong. (Example here: a sweep's
recording check must assert that the **filesystem-side and wire-level numbers track
the app-level rate at the consistency relation derived for THAT filesystem**, and
that **the I/O path each cell actually took matches what the cell claims** — not
merely that every cell produced a `results.json`.)

**Rule 9 — Checkpoint after every significant step.** After completing each
step in a multi-step task: summarize what was done, what's verified, what's
left. Don't continue from a state you can't describe back to the user. If
you lose track, stop and restate.

**Rule 10 — Match the codebase's conventions, even if you disagree.** If the
codebase uses snake_case and you'd prefer camelCase: snake_case. Disagreement
is a separate conversation. Inside the codebase, conformance > taste. If you
genuinely think a convention is harmful, surface it. Don't fork it silently.

**Rule 11 — Fail loud.** If you can't be sure something worked, say so
explicitly. "Migration completed" is wrong if 30 records were skipped
silently. "Tests pass" is wrong if you skipped any. "Backed up to S3" is wrong
if the sync errored on three files and you didn't say so. Default to
surfacing uncertainty, not hiding it.

## Documentation — non-negotiable

Accuracy beats speed: **reference official docs, not training data**, before giving any command, flag, API call, mount option, tuning parameter, price, or config — these change between versions, and cloud specs and prices change without notice.

- **AWS** → `docs.aws.amazon.com` (EC2 instance specs, FSx for Lustre performance/tiers/limits, EFA, S3, IAM, service quotas). **WEKA** → `docs.weka.io`. **Lustre** → `doc.lustre.org` (+ AWS's FSx guide for the managed specifics). **NVIDIA** → GDS / cuFile / nvidia-fs docs. **WSI toolkits** → their official docs/repos: OpenSlide, cuCIM + kvikIO (`docs.rapids.ai`), tifffile, large_image, MONAI, CLAM, Trident / Patho-Bench, Slideflow, QuPath. **Datasets** → their portals: TCGA (GDC), CAMELYON16/17 (+ the AWS Open Data registry), PANDA, BRACS, GTEx, PCam.
- Cite the specific page/file used. **If docs and training data disagree, the docs win — say so.** If something's undocumented, say that; don't fabricate flags. Flag version sensitivity and check the installed version (`pip show`, `--version`) first.
- **Never quote a cloud spec, cap, quota, or price from memory** — fetch it, and stamp any price figure with the date it was checked.
- Fetching official docs is standing-approved — never ask first (`feedback_docs_fetch_standing_approval` memory).

## Memory hygiene — non-negotiable

Memory (`~/.claude/projects/.../memory/`, indexed by `MEMORY.md`) holds durable cross-session knowledge: decisions **and their why**, agreed plans / open questions, user preferences & feedback, standing environment facts, external resources. **Tactical state is NOT memory's job** — driver versions, current mounts, `weka status`, `lfs df`, free space: re-derive with shell commands, freely (you're on the box).

- **Update memory in the same response** as any exchange that shifts the picture durably; skip what a future session can trivially re-derive.
- **Prune aggressively** — periodically re-read `MEMORY.md` + its files; delete anything wrong, finished/resolved (keep the decision + why, drop the deliberation), duplicated, or that a fresh session wouldn't actually benefit from (the strongest test). A small accurate memory beats a large stale one.
- **Treat undated, unsourced commitments in memory as claims to verify, not facts.** This memory set has previously contained a fabricated deadline. If a memory asserts an external commitment, a date, or a promise, confirm it with me before acting on it.
- Don't prune durable preferences/conventions along with stale state — those don't expire from disuse.
- The bar: a fresh session loads memory + this file and continues without my re-describing decisions, plans, or standing context. **On an ephemeral cloud instance this is not a nicety — it is the only continuity that exists.**

## How we work together

**Plan first, then execute.** For real methodology decisions (what to benchmark, how to provision, what to measure, dataset/tool/model) — surface options + tradeoffs and let me ratify; the methodology calls are mine. Once agreed, execute without re-asking for decided steps. Read-only checks (`weka status`, `lfs df`, `nvidia-smi`, `df`, `ls`) just run. Default to working through the next agreed task; long sweeps are background work (no routine "still running" pings). Surface open decisions as a plain-text numbered list with a recommendation each — not the AskUserQuestion picker (`feedback_decision_interaction` memory).

**Safety.** Verify before mutating state you haven't checked this session; state the reason and ask before any `sudo`, mount/format, package install, or destructive op (say what would be lost first). (`feedback_accuracy_safety_dependability` memory.)

**Pause only for these four triggers:** (1) open decisions / un-pre-decided methodology forks; (2) actual issues to debug; (3) soft issues that may reshape FUTURE-step methodology (flag in the summary; don't block agreed work); (4) anything else needing my attention (surprising results, external steps I must take, sudo or destructive ops). Otherwise proceed. Unattended overnight chains are the normal mode, so a trigger that fires at 3am must be **mechanical** — the canary aborts the chain itself rather than waiting to be noticed. (`feedback_autonomous_execution_cadence` memory.)

**The roadmap is planning truth, not a frozen contract.** Per-stage roadmaps capture decisions before much is measured; before each tier/substage, reassess against accumulated findings and revise proactively (surface before committing wallclock). "Locked" decisions are revisable; the goal is THE BEST BENCHMARK. **Leg B's plan is explicitly provisional until Leg A's results exist** — improving it from what Leg A taught us is the point, not a deviation. (`feedback_methodology_revisability` memory.)

**Interpret instructions completely** — do the requisite surrounding work (state cleanup, doc + memory updates, forensic preservation), not just the literal verb; never leave a half-clean state. (`feedback_complete_implied_work` memory.)

**Benchmarking data preservation is non-negotiable** — re-running costs hours-to-days and real money; never lose granular results.

## Framing — load-bearing for every doc here

**Results precede story.** No document may contain a predicted outcome, an expected magnitude, a
pre-assigned "headline" stage, or a narrative built before the measurement exists. Keep the
**WHY-we-measure-it-this-way** (methodology rationale — that's what makes a number evaluable, and it is
separately mandated); delete the **WHAT-it-will-show**. Interpretation sections stay marked
`[STORY PENDING RESULTS]` until results land. **Report losses** — provisioning Lustre at maximum raises
that chance, and a weakness found here is one a customer doesn't find later. (`feedback-results-precede-story` memory.)

**Each leg is half an unfinished comparison.** A single leg's numbers mean little in a vacuum; their
force is the head-to-head. Present single-leg findings as strong-but-incomplete, leave explicit room for
the other leg, and state that the consolidated comparison is built later. This is not a licence to soften
findings — record the numbers plainly; it is the **claim** that stays scoped. (`feedback-each-leg-is-half-an-unfinished-comparison` memory.)

**State both deliberate asymmetries wherever results appear.** (1) **Provisioning** — Lustre at maximum
capability vs WEKA at a realistic production configuration, cost reported alongside. (2) **Transport /
GPU-direct** — Lustre-over-EFA supports GDS; WEKA-over-ENA is expected to fall back to cuFile compat mode.
A reader's first question is "what was the other side running?"; the answer must already be on the page.
Naming the asymmetries is what makes the result credible.

**Bandwidth is expected to be client-capped for both sides** at the instance's line rate. A tie on pure
bandwidth cells reflects the instance, not either filesystem, and must never be presented as a finding
about either. The informative axes are metadata, IOPS, small-file behaviour, concurrency, and latency.

## The held-constant contract

Exactly one variable changes between legs: the filesystem. Everything else is held constant, recorded,
and verified.

**Held constant:** the compute instance (type, region, AZ, AMI), the workload code (script commit), the
datasets and their byte contents, the 20× magnification contract, the model set, the recording harness.
**Varied:** the mount.

Because the legs run at different times, this is enforced mechanically by an **environment contract** —
a machine-readable file written at the end of Leg A (instance type, region/AZ, AMI ID, kernel,
driver/CUDA/nvidia-fs versions, dataset byte-manifest, script commit) that **Leg B verifies before its
first cell.** A mismatch is a fail-loud condition, not a footnote. Without it, "were these two legs even
comparable?" is unanswerable at exactly the moment it matters most.

**Mount convention:** WEKA at `/mnt/weka`, Lustre at `/mnt/lustre`. Scripts take `--fs {weka|lustre}` and
resolve the path through `$FS_MOUNT` rather than hardcoding it — the filesystem is a *dimension*, not a
fork in the code.

## Recording — non-negotiable

"If it isn't recorded, it didn't happen." Re-running costs hours-to-days and real money; over-capture is cheap. Per run, via `record-run.sh`, save: raw tool output verbatim (fio JSON, nvidia-smi / filesystem-stats traces, tracebacks); run metadata (timestamp, host, filesystem + its provisioned config, kernel/driver/CUDA/library versions, full command, env); exact config (every tunable knob); results with context; notes.

- **Time series, not point estimates** — capture the full timeline (typically 1 s) and derive aggregates (mean / p50 / p95 / p99 / peak) from it.
- **Multiple sources** — app-level + the filesystem's own telemetry + the wire counters for the access path in use; discrepancies are data, not noise.
- **Pre / during / post** snapshots; **verify the capture** before trusting a run (empty source → fix infra + re-run).
- **Cold-vs-warm is a hard, enforced axis, not an occasional variant.** A maxed FSx carries file-server cache RAM comparable to the instance's own RAM, and WEKA caches too — so any warm cell risks measuring cache rather than storage. Record cache state per cell.
- Small text artifacts (configs, parsed results, READMEs) stay in `runs/` in-repo; large raw outputs go to S3 (see **Durability** below) — never only to instance-local disk.

**Per-filesystem source adapters, and an FS-agnostic canary.** The primaries differ per filesystem, and **a source that is bypassed or irrelevant for the path in use must never be quoted for a throughput/latency/IOPS number** — cite the path-appropriate primary or flag it diagnostic-only.

| | Primaries | Diagnostic-only |
|---|---|---|
| **WEKA (DPDK over ENA)** | `weka stats realtime` (filesystem-side), app-level, and the wire counters for the DPDK path | kernel network counters (`sar -n DEV`), `iostat` (block layer bypassed → reads ~zero for the wekafs mount), `sar -u` (DPDK cores spin-poll → look ~100% busy regardless) |
| **Lustre (FSx)** | client `/proc/fs/lustre` + `lctl get_param` stats, CloudWatch per-OST/MDT metrics, app-level, **plus the client's network counters — which ARE the data path here** (kernel LNet over TCP, or the EFA provider's counters when EFA-mounted) | whichever of the above does not match the LND actually in use — determine it, don't assume |

**Derive the consistency relation per filesystem; never port one across.** WEKA's erasure coding implies a
specific wire-vs-app ratio (write amplification set by the EC scheme — which is why the scheme is captured
at provisioning). Lustre stripes across OSTs with no default erasure coding, so its relation is different
and must be derived from the actual stripe layout. **Run the canary after every sweep**; disagreement =
bugged infra → fix before continuing. Only Primary sources participate in the ratio check.

**Prove the I/O path per cell.** For any kvikIO/cuFile cell, record cuFile's own accounting of
GPU-direct vs bounced bytes (`CUFILE_STATS`, `/proc/driver/nvidia-fs/stats`) as a first-class source.
**A configuration flag is not proof of behaviour** — `allow_compat_mode` being set does not tell you which
path a read took. A cell that quietly fell back, or quietly didn't, silently poisons the comparison.

### Durability & backup — the cloud-specific half of "if it isn't recorded, it didn't happen"

**Instance-local NVMe and both filesystem mounts are ephemeral.** They die with the instance and the
cluster, and the instance is deliberately rebuilt between legs. **Nothing that matters may rest only
there.** Claude's conversation context does not survive either — only the repo, the memory mirror, and S3 do.

**Authority split (no overlap, so no conflict):**
- **git is authoritative for all small text** — docs, `results.json`, `metadata.json`, `0_README.md`,
  configs, the memory mirror.
- **S3 is authoritative for the heavy write-once data git can't hold** — raw telemetry time series and the
  datasets.

**`backup.sh` is the single durability entry point** — it mirrors live memories into
`claude-memory-mirror/`, then syncs everything backup-worthy to S3. **Two sync semantics, deliberately
different:**
- **Mirror-with-delete** for things where local is genuinely the source of truth (memory mirror, docs,
  small text). Git backs these independently, so an exact reflection is safe.
- **Add-and-update, NEVER delete** for raw telemetry and datasets. New and changed files go up; the script
  never removes anything from S3. *Why:* we will want to reclaim local disk by cleaning old raw telemetry,
  and a `--delete` sync would then destroy the only remaining copy — precisely what the data-preservation
  rule forbids. Removing something from S3 is a deliberate manual act.

**When to run it:** whenever new data lands that needs backing up — `record-run.sh` syncs a run's
artifacts at end-of-run and periodically during long runs, and `backup.sh` does the full sweep. Always
before a commit, and **always before any teardown.** The sync is **verified, not assumed** (Rule 11:
"backed up" is wrong if three files errored and you didn't say so).

**Teardown & rebuild checklist** (`cloud-setup/TEARDOWN-AND-REBUILD.md`, with `runs/lib/teardown-preflight.sh` as the GO/NO-GO gate) — in this order, skipping any one loses work
permanently: handoff prompt written → `./backup.sh` → **environment contract written**
(`env-contract.py write --leg $LEG`) → **verified S3 sync** (`sync-to-s3.sh --mode full`, which carries the
contract) → `git commit && git push` → **pre-flight GO**. *Why the contract comes before the commit and the
sync:* it is a git-tracked file *and* an S3 object, so writing it last would leave it in neither — and the
pre-flight checks for it in both.

**Iterative allowlist (`.claude/settings.json`):** add safe, repeated operations to `allow` as prompt-fatigue shows up; add never-auto-run patterns to `ask`/`deny`; mention any change I make.

## Docs cadence — which doc to update when

After any exchange that shifts the picture durably, update every doc whose cadence is triggered (in place); batch related updates (one methodology revision often touches the roadmap, `PRESENTING.md`, and a memory at once) and defer the rest to its natural moment. Don't over-update (churn) and don't leave a stale doc a future session would plan against. **`PROJECT-THESIS.md` + the per-stage roadmaps + `PRESENTING.md` are the source of pipeline truth.**

**Results live in one `runs/` tree, with the filesystem as an explicit dimension** (`--fs` → a segment in the run-dir name + a field in `metadata.json`), so the aggregators can pivot on it and emit head-to-head CSVs directly. *Why one tree, not one per filesystem:* the deliverable **is** the cross-filesystem delta; separate trees would force every comparison to be assembled by hand. Cross-leg drift is caught by the environment contract instead — made **visible** rather than structurally prevented.

| Doc | Purpose | Cadence |
|---|---|---|
| `CLAUDE.md` (`/`) | Project rules | Only when I steer a new convention (rare) |
| `README.md` (`/`) | Repo entry point: status banner, what makes it a real comparison, the Start-here and Layout tables, the path to a first result | When the status changes, a doc is added or renamed, a count in Layout drifts, or the deferred-work set changes |
| `PROJECT-THESIS.md` (`/`) | What we measure and why: the question, the held-constant contract, both asymmetries, sequencing, scope | When the framing or a load-bearing assumption changes |
| `PRESENTING.md` (`/`) | Presentable per-stage script — self-contained (WSI context, what, **why**, the question it answers, numbers, caveats, pointers). A methodology script with `[STORY PENDING RESULTS]` until results exist; update in place, never an index (`feedback_presenting_md_role` memory) | In place when a finding/caveat lands; heaviest at stage closeout |
| `SCRIPT-TRACKER.md` (`/`) | Per-script reference for `runs/lib/` (what + why, I/O, caveats, reusability, deferred TODOs) | After each script created/changed |
| `FILESYSTEM-MAP.md` (`/`) | "Where does X live?" — both mounts, S3 layout, local scratch, tools, memory | When a load-bearing path/dir/env/bucket-prefix emerges |
| `runs/STAGES.md` | Stage-code map (`--stage` values) **+ the project plan hub**: the per-leg plan and order, the 20× coord-space contract, and the **cross-stage methodology decision log** (project-wide forks — fairness basis, magnification, dataset cohort, GPU-direct matrix, instance guardrail — each with what / when / why / sources) | On stage-status change, plan/decision change, or substage add/remove |
| `runs/README.md` | `record-run.sh` runbook + recovery + the per-FS source table and canaries | When recording infra changes |
| `runs/Stage-<N>-*.md` | Per-stage roadmap: methodology, **why each substage exists**, the question each answers, results, decision + change logs | **Constantly** — most-updated; the audit trail |
| `cloud-setup/WORKFLOW.md` | **One-page router**: which doc to read and which prompt to paste, per scenario. Ordering and pointers ONLY — the procedures live in the two docs below, so a duplicated step here is a bug | When a prompt is added/renamed, a handoff moves, or a scenario's order changes |
| `cloud-setup/*` | Human-facing provisioning guide + the setup/handoff prompts | When provisioning or the bootstrap sequence changes |
| `runs/INDEX.md`, run-dir `0_README.md` | Run history / per-run description | Auto-generated by `record-run.sh` — **never hand-edit** |
| memory + `MEMORY.md` | Durable knowledge + index | Per memory hygiene above |

**Where decisions live:** a decision scoped to **one stage** → that stage's `runs/Stage-<N>-*.md` decision log; a **cross-stage / project-wide** methodology decision (the fairness basis, the 20× contract, the dataset cohort, the GPU-direct matrix, a framing rule) → the decision log in `runs/STAGES.md`. Record what / when / why / official sources; don't split one decision across both. Any decision touching an **assumed** environment value must also update the reference index in the `weka-vs-lustre-cloud-open-decisions` memory.

**Where UNRESOLVED items live — non-negotiable, because burial is the real failure mode.** An open question recorded only inside the roadmap that surfaced it will not be seen again until someone re-audits that roadmap. So whenever an exchange or audit surfaces something that must be **resolved before the first measured cell, built in the cloud session, or watched during benchmarking**, add it to the **`cloud-session-open-items` memory in the same edit** — a one-or-two-line entry plus a pointer to the doc holding the detail. Memory loads every session automatically; a doc has to be found. **That memory holds ONLY open items: when something is done, delete the entry.** The completion record belongs in the relevant doc (`SCRIPT-TRACKER.md`'s done table, a stage change log, a decision-log entry), and git history preserves the memory's prior state. *Why deletion rather than a resolved list:* a fresh session loads that file to know what to **do**, so a completed-items section grows without bound and — worse — an entry left in place after completion gets redone.

**Record the WHY everywhere** (`feedback_methodology_why` memory): every methodology choice (in any doc) needs its rationale, not just the choice — numbers without it aren't presentable, and in a competitive comparison every choice is a place a skeptical reader looks for bias. A choice recorded without its why is a bug to fix in the same edit.

**Fresh-session reading order** — to *present* results: `PROJECT-THESIS.md` → `PRESENTING.md` → `FILESYSTEM-MAP.md` (orient) → `SCRIPT-TRACKER.md` (scripts) → `runs/README.md` (how to run) → `runs/STAGES.md` → `runs/Stage-<N>-*.md` → a run's `0_README.md`. **To *continue/execute* the work:** start with the `weka-vs-lustre-cloud-project` memory (what this is + current state) and `weka-vs-lustre-cloud-open-decisions` (what's still assumed) → `PROJECT-THESIS.md` → `runs/STAGES.md` (status header + plan + decision log) → the relevant `runs/Stage-<N>-*.md`.

## Naming convention

Run directories: `<UTC-timestamp>-<fs>-s<stage>-<workload>-<config>` — e.g.
`2026-…-weka-s4.C-kvikio-brca-N4-compat`. The `--fs` and `--stage` values passed to `record-run.sh` become
the `<fs>` and `s<stage>` segments automatically, and both are recorded in `metadata.json` so the
aggregators can pivot on filesystem without parsing directory names.
