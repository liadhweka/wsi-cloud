# Task prompt — close out this leg and make the instance safe to destroy

You are Claude Code on the project's AWS GPU instance, at the **end of a leg** (or a cost pause). Your job is
to leave **nothing that matters on ephemeral storage** and to leave the next session able to continue without
the human re-describing anything. **You are not benchmarking here.**

**You will run this again** — at least twice, once per leg — so keep it repeatable, and fix this document if it
turns out wrong.

---

## Read this first — why this is a prompt and not a checklist item

Teardown has seven steps and one of them cannot be done by the human at all: **writing the account of what this
session did.** Claude's context is the thing being destroyed, so the only moment that account can be written is
now, by you. A pre-deployment audit found it was also the only one of the seven steps with **no defined file and
nothing verifying it** — so it could be "done" into a chat message and die with the very context it existed to
carry. It now has both: `docs/cloud-setup/HANDOFF-NEXT-SESSION.md`, gated by `scripts/teardown-preflight.sh`.

**The ordering constraint that shapes this task:** the pre-flight gate checks that git is clean **and pushed**,
and the human owns commit/push. So this runs in **two phases with a human step between them** — Steps 1–5, then
they commit and push, then Steps 6–7. Do not try to collapse it.

> **Numbering.** `TEARDOWN-AND-REBUILD.md` § Teardown numbers the same sequence 1–8 for the human, where its
> step 5 is their commit+push and step 8 the destruction. This file's Steps 1–5 are its steps 1–4 (the record
> is split out), and this file's Steps 6–7 are its 6–7. Same work, so cite the *content* rather than a number
> when you report.

## What only the human can do

- **`git commit && git push`** — never do this autonomously, at any point, for any reason.
- **Destroy anything** — terminating the instance and deleting the filesystem are irreversible and stay theirs.
- **Decide a cost pause vs a leg switch**, if it isn't already clear (it changes what gets deleted).

## Rules you operate under

- **Fail loud.** "Backed up" is wrong if three files errored and you didn't say so. Every sync in here is
  **verified, not assumed** — that is the whole point of the exercise.
- **Never delete a run directory**, however broken. Rename it with a `-FAILED-<reason>` suffix instead.
  Re-running costs hours-to-days and real money.
- **Ask before any destructive or mutating operation**, stating what would be lost.

---

## Step 1 — Orient, and confirm nothing is mid-flight

```bash
source env.sh
echo "leg=$LEG mount=$FS_MOUNT bucket=$S3_BUCKET"
pgrep -fa 'record-run.sh|sweep-stage|run-leg.sh|run-stage6a'      # must be empty
df -h "$SCRATCH_DIR" "$FS_MOUNT"
```

A sweep interrupted mid-cell leaves a **half-recorded run dir that looks real** — the worst artifact this
project can produce, because it silently enters the aggregates. If one is running, let the current cell finish;
if it was already killed, rename the partial dir `-FAILED-interrupted` and say so in the handoff.

## Step 2 — Finish the record while you still remember it

This is the part that is cheap now and impossible later. Update **in place**:

- **`docs/Stage-<N>-*.md`** for every stage touched — results, what each substage answered, the decision and
  change logs. This is the audit trail.
- **`docs/RESULTS.md`** — any finding or caveat that landed. **Keep single-leg claims scoped as half an
  unfinished comparison**, and leave `[STORY PENDING RESULTS]` where results genuinely don't exist yet.
- **`docs/STAGES.md`** — stage statuses, and any project-wide methodology decision (with its *why* and its
  sources).
- **Memory** — durable knowledge only. **Delete every completed entry from `cloud-session-open-items`**; its
  whole value is that it holds only what is still open. Prune anything a fresh session can re-derive from the
  box (mounts, versions, free space) — that is not memory's job.

## Step 3 — Write `docs/cloud-setup/HANDOFF-NEXT-SESSION.md`

**This is the step only you can do.** Write it as a prompt to a successor who has your files but none of your
context, and be concrete: a specific number, path, or command beats a summary sentence.

```bash
date -u +%F        # use THIS for the Written: header — do not trust your idea of today's date
```

Required structure — the header lines are **parsed by the pre-flight gate**, so keep their exact shape:

```markdown
# Handoff — end of leg <weka|lustre>
Written: YYYY-MM-DD          <- from `date -u +%F`; a stale date is a NO-GO
Leg: <weka|lustre>
Instance destroyed: <yes | no, paused>

## What completed
<stages / substages, with run-dir names — not "Stage 4 done" but which cells exist>

## What is mid-stage or missing
<anything half-finished, every -FAILED- dir and why, every step skipped and why>

## What this leg taught us that should change the plan
<the highest-value section. Methodology revisions, surprises, things that cost time.
 For a WEKA->Lustre switch this is where Leg B's provisional plan gets improved —
 doing that is the point, not a deviation.>

## Open questions I was mid-way through
<each with where the detail lives, and a recommendation>

## What the next session should do first
<the literal first three actions>
```

Then double-check the gate will accept it:

```bash
grep -E '^(Written|Leg):' docs/cloud-setup/HANDOFF-NEXT-SESSION.md
```

## Step 4 — Back up the memories *(then verify)*

```bash
./backup.sh                      # live memories -> mirror, then S3 sync
```

**Read its output rather than its exit code alone**, and report any file that errored. On a *first* bootstrap
where memories were authored straight into the mirror and no session has written any, it refuses (exit 1)
rather than emptying the mirror — that is correct, not a failure.

## Step 5 — Write the environment contract, then sync *(verified)*

```bash
scripts/env-contract.py write --leg "$LEG"
scripts/sync-to-s3.sh --mode full
```

It **exits non-zero if any held-constant field is unrecorded** — fix those rather than proceeding, because an
unrecorded fact can never be shown to have matched later, and that is exactly when the question gets asked.
The contract is written **before** the commit and the sync deliberately: it is *both* a git-tracked file and an
S3 object, so writing it last would leave it in neither, and the pre-flight checks both.

**Then stop and report** — the human commits and pushes before the gate can pass. Tell them plainly: what you
changed, what the contract says, and that the pre-flight cannot go GO until they push.

## Step 6 — The gate *(after they have pushed)*

```bash
source env.sh
scripts/teardown-preflight.sh                 # never --quick before a real teardown
```

`--quick` skips the per-run S3 telemetry comparison, which is the check that matters: `raw/` is gitignored, so
S3 is its only home, and a silently-failed sync is invisible until someone looks for data that no longer
exists.

**On NO-GO, diagnose and fix, then re-run — do not interpret it away.** Every blocking line names something
that would be lost permanently. Loop until it prints GO or until a line genuinely needs the human.

## Step 7 — Confirm the rebuild inputs, then hand back

The next instance must be launched *identically*, and these are the only record of how:

```bash
scripts/env-contract.py show --file "runs/env-contract-leg-$LEG.json" | grep -E 'ami_id|instance_type|aws_region|aws_az|kernel'
```

**`AMI_ID` must be a pinned id, not "latest"** — a newer base image silently changes the kernel and the driver,
both held-constant fields, and Leg B would then fail its own contract verify for a reason nobody chose.

Then report and **stop**:

1. **GO / NO-GO**, with the pre-flight output verbatim.
2. **The four rebuild inputs**, and confirmation each is in `env.sh` **and** in the contract.
3. **What is now safe to destroy, in order** — instance first, then the filesystem this leg used; **leave the
   S3 bucket and the IAM role alone**, they are the durable store and deleting the bucket is what actually
   loses the project. Note that the filesystem usually costs more per hour than the instance, so stopping the
   instance alone is not a cost pause.
4. **Anything you could not verify**, stated as unverified rather than assumed.
5. **Anything that differed from this document** — you run it again next time.

Destruction is theirs. The rebuild path is `docs/cloud-setup/TEARDOWN-AND-REBUILD.md` § Rebuild.
