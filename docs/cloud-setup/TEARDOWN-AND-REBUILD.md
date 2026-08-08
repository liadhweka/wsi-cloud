# Teardown & rebuild — the do-every-time checklist

**Use this every time the instance goes away and comes back**, whether that's the WEKA→Lustre switch, a cost
pause, or an unplanned loss. It is written to be stable across sessions: it names **variables**, not values,
so it does not go stale when the environment changes. Values live in `cloud-setup/env.sh`
(see [`NAMING-AND-VARIABLES.md`](../NAMING-AND-VARIABLES.md)).

## The two things worth internalising before you start

**1. Three things survive a teardown; everything else dies.**

| Survives | Dies |
|---|---|
| **git** (the repo, on GitHub) | Both filesystem mounts — `$WEKA_MOUNT`, `$LUSTRE_MOUNT` |
| **S3** (`s3://$S3_BUCKET/`) | Instance-store scratch — `$SCRATCH_DIR` |
| **the memory mirror** (inside git) | Claude's conversation context, entirely |

**2. Verification is automated; destruction is not.** `runs/lib/teardown-preflight.sh` proves nothing is lost
and prints **GO / NO-GO**. It does **not** tear anything down — that stays a human action, deliberately,
because it is irreversible and because a script that destroyed *and* had a bug in its own verification would
be the worst possible tool. **Run the pre-flight, then do the destruction yourself.**

---

## Teardown

> ### Hand this to Claude — steps 1–4 and 6–7
> Paste, in a session on the instance:
>
> > Read the file `cloud-setup/prompt-teardown-cloud.md` and do everything it says.
>
> **You do exactly two things: step 5 (commit + push) and step 8 (destroy).** Steps 1–4 and 6–7 are commands
> and judgement calls, and **step 2 is one only Claude can do at all** — its context is what's being destroyed,
> so the account of what this session did can only be written now, by it.
>
> Why the split rather than one handoff: the pre-flight gate in step 6 checks that git is **clean and pushed**,
> and pushing is yours. So Claude stops after step 5, you commit and push, then it runs the gate.
>
> The steps below stay here as the reference — read them to know what should have happened, and to run it by
> hand if there is no working Claude session.

### 1. Stop cleanly *(Claude)*
Confirm nothing is mid-flight — a sweep interrupted mid-cell leaves a half-recorded run dir that looks real.
```bash
pgrep -fa 'record-run.sh|sweep-stage|run-leg.sh'      # must be empty
```
If a sweep is running, let the current cell finish (or note it and forensically rename the partial run dir
with a `-FAILED-interrupted` suffix — **don't delete it**, per the data-preservation rule).

### 2. Write the handoff prompt for the next session *(Claude — only it can)*
**This is the step most easily skipped and most expensive to skip** — Claude's context does not survive, so
whatever isn't written down is genuinely gone. It goes in **`cloud-setup/HANDOFF-NEXT-SESSION.md`** (git-tracked,
so it survives and is versioned) and covers: what completed, what's mid-stage, anything learned that should
change the next leg's plan, and any open question that was mid-flight.

For the WEKA→Lustre switch specifically, the next session also needs what Leg A taught us that changes Leg B,
and the corpus-size decision if it was made.

> **It is gated now.** `teardown-preflight.sh` NO-GOes if the file is missing, if it has no
> `Written: YYYY-MM-DD` header, or if that date is more than a day old — because the file is git-tracked, so
> the *previous* teardown's copy would otherwise pass an existence check. It also warns if the file never names
> the current `$LEG`. *Why gated at all:* this was the only one of the seven steps with nothing verifying it,
> and with no defined file it could be "written" into a chat message that dies with the context it exists to
> carry.

### 3. Back up the memories *(Claude)*
```bash
cd $REPO_DIR
./backup.sh                    # live memories → mirror, then S3 sync
```
> ⚠ **Exception, first bootstrap only:** if the memories were authored straight into the mirror and no
> session has run yet, there is no live directory to copy from — the script refuses (exit 1) rather than
> emptying the mirror. That's correct; skip this step then.

### 4. Write the environment contract *(Claude)*
This is what makes the *next* leg provably comparable to this one. Without it, "were these two legs even
comparable?" becomes unanswerable exactly when it matters.
```bash
runs/lib/env-contract.py write --leg $LEG
runs/lib/sync-to-s3.sh --mode full
```
It exits non-zero if any held-constant field is unrecorded. **Fix those rather than proceeding** — an
unrecorded fact can never be shown to have matched later.

### 5. Commit and push *(human — never automated)*
```bash
git add -A && git commit -m "leg $LEG: <what completed>" && git push
```

### 6. Run the pre-flight — GO / NO-GO *(Claude)*
```bash
source cloud-setup/env.sh
runs/lib/teardown-preflight.sh
```
It checks: nothing in flight · memories mirrored · **the handoff prompt written and dated today** · git clean
**and pushed** · contract complete **and in S3** · **`env.sh` agreeing with the instance's own metadata** ·
**every local run dir's raw telemetry present in S3** · nothing else stranded on ephemeral storage · rebuild
inputs recorded.

**The telemetry check is the one that matters.** `raw/` is gitignored, so S3 is its only home, and a
silently-failed sync is invisible until you go looking for data that no longer exists. Do not use `--quick`
before a real teardown — that skips precisely this check.

**On NO-GO: stop.** Each blocking line names something that would be lost permanently.

### 7. Record the rebuild inputs *(Claude)*
Step 6 already checked `AMI_ID` / `INSTANCE_TYPE` / `AWS_REGION` / `AWS_AZ` in both `env.sh` and the contract —
read its output rather than re-confirming by eye; the prose here is not a second opinion. **What the script
cannot check: the AMI must be *pinned*, not "latest"** — a newer base image silently changes the kernel and the
driver, both held-constant fields, so Leg B would fail its own contract verify for a reason nobody chose.

### 8. Now destroy — in this order *(human — never automated)*
1. **Instance** — terminate (or stop, if you're pausing rather than switching legs).
2. **The filesystem you're finished with** — WEKA cluster, or the FSx file system.
3. **Leave the S3 bucket and the IAM role alone.** They are the durable store; deleting the bucket is what
   actually loses the project.

> **Cost note:** the filesystem usually costs more per hour than the instance, so stopping the instance alone
> is not a cost pause. But do not delete a filesystem you still need — re-hydrating is hours.

---

## Rebuild

### 1. Launch identically
Same `INSTANCE_TYPE`, same `AWS_REGION`/`AWS_AZ`, **the pinned `AMI_ID`**, EFA-capable, with the EFA
security-group rule and the **IAM instance profile** attached at launch.

### 2. Bootstrap
Follow [`NEW-CLOUD-SETUP.md`](NEW-CLOUD-SETUP.md) **Part 3 and Part 4** — tmux, base tools, AWS CLI,
SSH↔GitHub, Claude Code, clone, `env.sh`, restore memories. Skip **Part 0 and Part 1** (names and the AWS
foundations are already decided and provisioned); Part 2 is covered by step 1 above.

### 3. Restore the memories — before anything else
Nothing downstream makes sense without them.
```bash
cd $REPO_DIR
./cloud-setup/restore-memories.sh          # derives the slug, refuses an empty mirror, verifies the result
```
> **Restore before you ever run `backup.sh`.** They move memories in opposite directions, and `backup.sh`
> mirrors *out of* the live directory — which on a fresh instance is empty. It refuses in that case, but the
> ordering is what makes the refusal unnecessary.

### 4. Re-create the configuration
```bash
aws s3 cp "s3://$S3_BUCKET/env-contracts/env-contract-leg-<previous-leg>.json" /tmp/
cp cloud-setup/env.example.sh cloud-setup/env.sh   # env.sh is gitignored, so it did NOT survive

# Emit ready-made export lines from the contract instead of retyping them:
runs/lib/env-contract.py env --file /tmp/env-contract-leg-<previous-leg>.json
$EDITOR cloud-setup/env.sh                          # paste them OVER the placeholders in the top half
source cloud-setup/env.sh
./cloud-setup/env.sh --check                        # must pass before anything else
```
> **Why `env` and not `show`:** the recovery step used to be "read the contract, retype the values" — a
> transcription step sitting in front of the one artifact whose entire purpose is proving the two legs
> matched. A typo in `AMI_ID` or `INSTANCE_TYPE` defeats the check it exists to pass. `env` emits the
> held-constant values as live `export` lines and the **previous leg's filesystem values commented out** —
> deliberately, since on a cross-leg rebuild those describe the *other* filesystem and the cluster-setup
> prompt writes the new ones. `show` still exists for reading a contract as a human.
>
> **Paste, don't `>>` append.** `--check` lives at the bottom of `env.sh` and runs before anything appended
> after it, so appended values source correctly and are still reported `MISSING`.
> `env.sh` is deliberately gitignored, so **it is always lost.** The contract in S3 is where you recover the
> values from — another reason step 4 of teardown is not optional.
>
> **Two values `--check` will only warn about, and both are needed before a cell runs:** `LIBCUFILE_PRELOAD`
> (the env-prep session in step 5 reports the new path — the old one is almost certainly wrong on a rebuilt
> instance) and, for Leg B, `LUSTRE_STRIPE_LAYOUT` (step 6). `AMI_ID`, `INSTANCE_TYPE`, `AWS_REGION` and
> `AWS_AZ` must match the contract exactly — that is what step 7 verifies.

### 5. Re-do the ephemeral setup
Scratch (`$SCRATCH_DIR`) and the Python environments died with the instance. Paste the env-prep prompt:
> Read the file `cloud-setup/prompt-env-prep-cloud.md` and do everything it says, then report back.

Then rebuild the conda environments and regenerate the cuFile config for **this** instance (its addresses
are new).

> **On a rebuild, use the pinned `*.conda-explicit.txt` files, not the loose recipe.** `conda_env_main` and
> `python_version` are `MUST_MATCH` contract fields, so the environment is a held-constant input: the point is
> to reproduce the previous leg's environment **bit-identically**, not to re-solve it. The full route table —
> which of the four `env-specs/` file types to use when, and why — is in
> [`handoff-cloud.md`](../../prompts/handoff-cloud.md) § 4.1. If the explicit file will not solve on this instance, that is a
> **finding to surface**, not something to work around silently: it means the two legs cannot share an
> environment.

Then do the **Hugging Face login** again (`NEW-CLOUD-SETUP.md` § 7.2) — the token lives in the home directory,
which did not survive either.

### 6. Mount the filesystem for this leg
Paste the prompt for the leg you're on — both are written to be re-run on exactly this occasion, and both
record their provisioning facts into `env.sh` themselves:
> Read the file `cloud-setup/prompt-weka-cluster-cloud.md` and do everything it says, then report back.

> Read the file `cloud-setup/prompt-lustre-cluster-cloud.md` and do everything it says, then report back.

WEKA lands at `$WEKA_MOUNT`, FSx at `$LUSTRE_MOUNT` **over EFA** (required both for GPUDirect Storage and to
escape the per-client-per-server bandwidth cap). **Each prompt has a hard gate you must not wave through** — a
DPDK-vs-UDP mount for WEKA, an `efa`-vs-`tcp` LNet for Lustre. Either fallback yields a full set of believable
numbers for a configuration this project promised not to measure.

### 7. Verify comparability — the gate
```bash
runs/lib/env-contract.py verify --against <leg-A-contract.json> --leg $LEG
```
It separates **VIOLATION** (a held-constant field differs — the comparison is invalid) from **differs as
expected** (the filesystem fields, which are the variable under test). It also fails on *unverifiable*
fields, because a null cannot be shown to have matched.

**A VIOLATION here means stop.** Any head-to-head number produced from two non-matching environments would
be attributing an environment difference to the filesystem — which is the one error this whole project is
built to avoid.

### 8. Re-hydrate the datasets
From S3, not from the original sources — that's what makes them a byte-identical held-constant input across
legs. This is also measured cell **1.7**, so run it through `record-run.sh`.

⏳ **The hydration driver does not exist yet (`D-13`)** — `run-leg.sh` reports step 1.7 as MISSING and
aborts rather than skipping it. Note the direction: `sync-to-s3.sh --mode datasets` pushes local → S3, so it
is **not** the hydration command. Hydration is S3 → `$FS_MOUNT`, and building it is part of the cloud
session's work.

Then **byte-verify against the manifests** and fail loud on any mismatch.

### 9. Prove the recording pipeline before spending wallclock
Run a throwaway Stage-0 cell and confirm: recording complete, both canaries functional, S3 sync verified,
`INDEX.md` row correct, aggregator emits a row pivoted on `--fs`. **Do this before a real cell** — otherwise
a recording bug is discovered after hours of unusable runs.

### 10. Resume
```bash
runs/lib/run-leg.sh --leg $LEG --list          # see what's done vs pending
runs/lib/run-leg.sh --leg $LEG                 # resumes; completed steps are skipped
```
Completion markers live in `runs/.leg-state/$LEG/`, which is **git-tracked**, so a rebuild mid-leg picks up
where it stopped — **provided teardown step 5 committed them.** It does (`git add -A`), and that is the whole
reason they are tracked rather than ignored: they used to die with the instance, and a rebuilt `run-leg.sh`
would then silently re-run every completed step and create duplicate run dirs instead of erroring.

> **If this is the start of Leg B:** the state directory is per-leg, so Leg B correctly starts from scratch
> while Leg A's markers remain untouched.

---

## Quick reference

**Teardown:** stop cleanly → handoff prompt → `./backup.sh` → contract → commit+push → **pre-flight GO** →
record rebuild inputs → destroy (instance, then filesystem; **never the bucket**).
*All of it is `cloud-setup/prompt-teardown-cloud.md` except commit+push and the destruction.*

**Rebuild:** launch identically → bootstrap → **restore memories** → recreate `env.sh` + `--check` →
env-prep + conda + cuFile → mount → **verify contract** → re-hydrate + byte-verify → Stage-0 proof →
`run-leg.sh`.
*The first thing a rebuilt session should read is `cloud-setup/HANDOFF-NEXT-SESSION.md` — the previous
session's own account of where it left off.*

**The three that are easiest to skip and most expensive to skip:** the handoff prompt (step 2), the
environment contract (step 4 — and `env.sh` recovery depends on it), and the pre-flight telemetry check
(step 6).
