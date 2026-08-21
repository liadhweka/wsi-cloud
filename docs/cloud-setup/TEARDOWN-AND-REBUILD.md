# Teardown & rebuild — the do-every-time checklist

**Use this every time the instance goes away and comes back**, whether that's the WEKA→Lustre switch, a cost
pause, or an unplanned loss. It is written to be stable across sessions: it names **variables**, not values,
so it does not go stale when the environment changes. Values live in `env.sh` at the repo root
(see [`NAMING-AND-VARIABLES.md`](../NAMING-AND-VARIABLES.md)).

## The two things worth internalising before you start

**1. Three things survive a teardown; everything else dies.**

| Survives | Dies |
|---|---|
| **git** (the repo, on GitHub) | Both filesystem mounts — `$WEKA_MOUNT`, `$LUSTRE_MOUNT` |
| **S3** (`s3://$S3_BUCKET/`) | Instance-store scratch — `$SCRATCH_DIR` |
| **the memory mirror** (inside git) | Claude's conversation context, entirely |

**2. Verification is automated; destruction is not.** `scripts/teardown-preflight.sh` proves nothing is lost
and prints **GO / NO-GO**. It does **not** tear anything down — that stays a human action, deliberately,
because it is irreversible and because a script that destroyed *and* had a bug in its own verification would
be the worst possible tool. **Run the pre-flight, then do the destruction yourself.**

---

## Teardown

> ### How the work splits
> **Claude does steps 1–6, in order** — the stop-check, the continuity step (memory current; optionally a
> handoff, which only it can write — its context is what's being destroyed), the backup + sync proof, the
> contract, the commit + push (the autonomous-git
> convention), and the pre-flight — then **hands the human an explicit GO with the rebuild inputs named.
> The human does exactly one thing: step 7, the destruction** — irreversible, therefore never automated.
> Steps 3–5 are mechanised as one command (`teardown-prep.sh`); every piece is idempotent, so re-running
> costs seconds. The pre-flight must follow the push, because "git clean and pushed" is one of the things
> it verifies — an unpushed repo dying with the instance is precisely what it exists to catch.

### 1. Stop cleanly *(Claude)*
Confirm nothing is mid-flight — a sweep interrupted mid-cell leaves a half-recorded run dir that looks real.
```bash
pgrep -fa 'record-run.sh|sweep-stage|run-leg.sh'      # must be empty
```
If a sweep is running, let the current cell finish (or note it and forensically rename the partial run dir
with a `-FAILED-interrupted` suffix — **don't delete it**, per the data-preservation rule).

### 2. Leave continuity behind: memory current; a `TEMP/` handoff if mid-work *(Claude — only it can)*
Claude's context does not survive, so whatever isn't written down is genuinely gone. **The designed
continuity is memory + repo** — the open-items memory current (resolved items deleted, new items added),
docs cadence honored, resume markers pushed. **Optionally, at the human's discretion** — worth it whenever
the teardown lands mid-work — also write a handoff prompt **from `prompts/handoff-skeleton.md`** (every
`⟨...⟩` filled) into a durable committed file in `TEMP/`: an inline chat handoff would die with the context,
so for a rebuild only a file survives.

*(This checklist is for destroy/rebuild only. Ordinary session turnover on a running instance uses the
skeleton's same-instance mode — the handoff is printed inline, no teardown machinery — see the skeleton's
header.)*

> The pre-flight **warns** (never NO-GOes) when no dated `TEMP/*.md` handoff names the current `$LEG`, and
> when the newest one looks old — a reminder that the next session will start from memory + repo alone;
> confirm that is intended rather than assuming.

### 3. Back up the memories, and prove the sync semantics *(Claude)*
```bash
cd $REPO_DIR
scripts/sync-to-s3.sh --self-test   # mirror probe must vanish, archive probe must survive
./backup.sh                         # live memories → mirror, then S3 sync
```
> ⚠ **Exception, first bootstrap only:** if the memories were authored straight into the mirror and no
> session has run yet, there is no live directory to copy from — `backup.sh` refuses (exit 1) rather than
> emptying the mirror. That's correct; skip that half then.

### 4. Write the environment contract *(Claude)*
This is what makes the *next* leg provably comparable to this one. Without it, "were these two legs even
comparable?" becomes unanswerable exactly when it matters.
```bash
scripts/env-contract.py write --leg $LEG
scripts/sync-to-s3.sh --mode full
```
It exits non-zero if any held-constant field is unrecorded. **Fix those rather than proceeding** — an
unrecorded fact can never be shown to have matched later.

### 5. Commit, push, and gate — one command *(Claude)*
```bash
source env.sh
scripts/teardown-prep.sh            # add --write-contract at a leg end / mid-leg rebuild
```
It **re-verifies steps 3–4** (self-test, backup, contract — all idempotent, so a prior run costs seconds),
then **commits and pushes** (the autonomous-git convention; `../CLAUDE.md`), fail-loud: an unpushed repo
dies with this instance, and the push is what carries `runs/.leg-state/` — the resume markers — to the next
build. It finishes by running `teardown-preflight.sh`, which prints **GO / NO-GO** after checking: nothing
in flight · memories mirrored · a `TEMP/` handoff for this leg (warn-only — optional) · git clean **and pushed** · contract
complete **and in S3** · **`env.sh` agreeing with the instance's own metadata** · **every local run dir's
raw telemetry present in S3** · nothing else stranded on ephemeral storage · rebuild inputs recorded.

**The telemetry check is the one that matters.** `raw/` is gitignored, so S3 is its only home, and a
silently-failed sync is invisible until you go looking for data that no longer exists. Do not use `--quick`
before a real teardown — that skips precisely this check.

**On NO-GO: stop.** Each blocking line names something that would be lost permanently.

### 6. Hand over the GO *(Claude)*
Claude reports the pre-flight verdict to the human with the rebuild inputs named: `AMI_ID` /
`INSTANCE_TYPE` / `AWS_REGION` / `AWS_AZ`, already cross-checked between `env.sh` and the contract — plus
anything the destruction should know (e.g. a terraform variable changing on the rebuild). **What no script
can check: the AMI must be *pinned*, not "latest"** — a newer base image silently changes the kernel and
the driver, both held-constant fields, so Leg B would fail its own contract verify for a reason nobody
chose. **On NO-GO, nothing is handed over** — Claude fixes what the blocking line names and re-runs step 5.

### 7. Now destroy — in this order *(human — never automated)*
1. **Instance** — terminate (or stop, if you're pausing rather than switching legs).
2. **The filesystem you're finished with** — WEKA cluster, or the FSx file system.
3. **Leave the S3 bucket and the IAM role alone.** They are the durable store; deleting the bucket is what
   actually loses the project.

> **Cost note:** the filesystem bills for as long as it exists, attached or not, so stopping the instance
> alone is not a cost pause. But do not delete a filesystem you still need — bringing it back means re-running
> the full dataset hydration (cell 1.7).

---

## Rebuild

**Three human actions; the bootstrap does everything else.**

### 1. `terraform apply`
In this leg's Terraform root (on the WEKA leg: `clients_number` 0 → 1). Terraform pins the AMI, instance
type, region/AZ, security group and IAM profile — the held-constant fields — so "launch identically" is
configuration, not care. `scripts/bootstrap-instance.sh` runs at first boot and builds the whole client
unattended: packages, the pinned NVIDIA/CUDA/GDS stack, local-NVMe scratch, the mount (Leg A), `env.sh`
generated from instance evidence including `FS_TRANSPORT`, `LIBCUFILE_PRELOAD`, the cuFile config, both
conda environments with smoke tests, model prefetch, and the memory restore — each verified, warnings
prefixed `WSI-WARN`. Boot log: `/var/log/wsi-bootstrap.log`; triage with `grep WSI-`.

### 2. Start Claude
```bash
tmux new -A -s wsi && cd ~/wsi-cloud && claude   # then /login
```
**Leg B only:** the Lustre mount is automatic (baked `wsi-lustre-phase2.service`, run by the bootstrap and
re-proven per boot); its EFA-vs-TCP gate is a hard stop (**D16**) enforced *before* anything is spent.
Verify with `findmnt /mnt/lustre` + `journalctl -u wsi-lustre-phase2.service`; on failure the fs stays
unmounted by design — triage per `LUSTRE-PROVISIONING.md` (manual fallback there).

### 3. Paste the handoff, or start from memory + repo
If the teardown left a `TEMP/` handoff (the GO names it):
> Read the file `TEMP/<name>` and do everything it says, then report back.

Otherwise the session starts from the designed continuity — the open-items memory is the work list and
`CLAUDE.md`'s fresh-session reading order applies. Either way the sequence is the same: verifying the
bootstrap's
work read-only (`scripts/verify-conda-env.sh` for the environments), the environment-contract `verify`
against the previous leg (**a VIOLATION is a stop** — any head-to-head number from two non-matching
environments attributes an environment difference to the filesystem, the one error this project exists to
avoid), the 1.7 re-hydration with byte-verification (`scripts/sweep-stage1-hydrate.sh`; `run-leg.sh` aborts
rather than skips without its marker), the scripted Stage-0 recording proof before wallclock is spent
(`scripts/prove-recording.sh`), and `run-leg.sh --leg $LEG`, which **resumes** from the git-tracked
markers in `runs/.leg-state/$LEG/`. **Every completed substage then closes through
`scripts/verify-substage-closeout.sh` (exit 0 gates the next phase — `RUNBOOK.md` § Substage closeout),**
as non-negotiable as the recording wrapper.

> ⚠ **If the marker directory is empty on a mid-leg rebuild, stop** — the previous teardown never committed
> them, and running on would silently redo hours of sweeps into duplicate run dirs.
> **At the start of Leg B** the state directory is per-leg, so Leg B correctly starts from scratch while
> Leg A's markers stay untouched.

---

## Quick reference

**Teardown:** *Claude, in order:* stop cleanly → memory current (+ optionally a `TEMP/` handoff from
`prompts/handoff-skeleton.md` if mid-work) → sync self-test + backup → write the contract →
`scripts/teardown-prep.sh` (**commit+push** → **pre-flight**) → hand the human the GO with the rebuild
inputs (naming the TEMP/ handoff if one was written). *Human:* destroy (instance, then filesystem; **never
the bucket**).

**Rebuild:** `terraform apply` → `claude /login` → paste the TEMP/ handoff if one exists, else start from
memory + repo (the designed continuity) → contract **verify** → re-hydrate + byte-verify → Stage-0 proof →
`run-leg.sh` resumes.

**The three that are easiest to skip and most expensive to skip:** the memory/docs currency (step 2 — the
next session's only continuity), the environment contract (step 4 — and `env.sh` recovery depends on it),
and the pre-flight telemetry check (inside step 5 — never `--quick` it before a real teardown).
