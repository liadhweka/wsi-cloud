# WORKFLOW — one page: what to read, what to paste, in what order

**This is a router, not a procedure.** It holds *ordering and pointers only*. The steps themselves live in
[`NEW-CLOUD-SETUP.md`](NEW-CLOUD-SETUP.md) (first build) and [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md)
(every teardown and rebuild). *Why the split:* a second copy of a procedure drifts from the first, and the
drifted copy is the one someone follows at 2am. So when this file and those disagree, **they win** — and
whatever was wrong here gets fixed.

---

## The five prompts

Each is self-contained and **re-runnable on every rebuild** — that is the design, not a convenience.

| # | Paste | When | Leaves behind | Its hard gate |
|---|---|---|---|---|
| 1 | `prompt-env-prep-cloud.md` | every build, once the repo is cloned | GPU/CUDA/GDS stack, NVMe scratch, miniforge, `LIBCUFILE_PRELOAD` | stops on a missing driver or a running-vs-pending kernel split |
| 2a | `prompt-weka-cluster-cloud.md` | every **WEKA** build | the filesystem, the mount, `WEKA_*` + `FS_TRANSPORT` in `env.sh` | **DPDK, or stop** |
| 2b | `prompt-lustre-cluster-cloud.md` | every **Lustre** build | the mount, `FSX_*`, `LUSTRE_STRIPE_LAYOUT`, `FS_TRANSPORT` | **EFA, or stop** |
| 3 | `handoff-cloud.md` | every build, to build + benchmark | the environments, the cells, the results | the 13-row blocker gate before the first measured cell |
| 4 | `prompt-teardown-cloud.md` | end of every leg **and** every pause | `HANDOFF-NEXT-SESSION.md`, the contract, a verified S3 sync | pre-flight **GO / NO-GO** |

Paste text is always the same shape:

> Read the file `cloud-setup/<prompt>.md` and do everything it says, then report back.

---

## 1 — First spin-up (once, ever)

**Read before starting:** [`../PROJECT-THESIS.md`](../../PROJECT-THESIS.md) — the question and the held-constant
contract. Ten minutes, and it is what makes any number mean something. Then `NEW-CLOUD-SETUP.md` top to bottom.
[`SPINUP-CHECKLIST.md`](SPINUP-CHECKLIST.md) carries the *reasoning* behind the provisioning choices if you want
it; the guide carries the procedure.

| Phase | Where | You do | Claude does |
|---|---|---|---|
| **Parts 0–2** | browser, no instance yet | region/AZ · GPU quota (**start day 1**, approval is slow) · security group · **S3 bucket § 1.4** · **IAM role § 1.5** · key pair · launch on a **pinned GPU AMI** | *nothing — no session exists* |
| **Parts 3–4** | on the box | tmux · apt · AWS CLI + bucket smoke test · GitHub SSH · install Claude § 3.5 · clone § 4.1 · `env.sh` § 4.2 · `./cloud-setup/restore-memories.sh` § 4.3 · HF **token** § 4.4 | — |
| **Part 5** | — | paste **prompt 1** | preps the stack; re-derives your five `env.sh` values from instance metadata and reconciles |
| **Part 6** | — | build the WEKA cluster (Port blueprint), then paste **prompt 2a**; § 6.3 saves the config to S3 | creates + mounts the filesystem, writes the WEKA facts itself |
| **Part 7** | — | paste **prompt 3**, then HF **login** § 7.2 once the envs exist | builds envs · deferred script work · **verifies the S3 sync semantics** · proves the pipeline on a throwaway cell · blocker gate · runs Leg A |

**The S3 setup has two halves, and the second is the one people skip.** The bucket and IAM role (§ 1.4–1.5) are
the easy half. The other half happens inside Part 7: `sync-to-s3.sh` ships with an **`UNVERIFIED AGAINST A REAL
BUCKET`** banner and a first-run procedure whose load-bearing step proves a file under an *archive* path is
**not** deleted when it disappears locally. Until that passes, "backed up" is an assumption — and archive
semantics are the only thing protecting raw telemetry when local disk gets reclaimed.

---

## 2 — Teardown (identical for both legs)

Paste **prompt 4**. It runs in **two phases because the pre-flight checks that git is *pushed*,** and pushing is
yours.

| Step | Who | What |
|---|---|---|
| 1–4 | **Claude** | stop cleanly · finish the roadmaps + `PRESENTING.md` + memory · write **`HANDOFF-NEXT-SESSION.md`** · `./backup.sh` · contract + verified sync |
| 5 | **you** | `git add -A && git commit && git push` — **never automated**, and it is what carries `runs/.leg-state/` (the resume markers) to the next instance |
| 6–7 | **Claude** | pre-flight to **GO** · confirm the rebuild inputs |
| 8 | **you** | destroy: **instance first**, then the filesystem you are finished with. **Never the S3 bucket or the IAM role** |

**Step 2 is the one only Claude can do** — its context is what is being destroyed. The pre-flight NO-GOes if
that file is missing, undated, or older than a day.

**Cost note:** the filesystem usually costs more per hour than the instance, so stopping the instance alone is
not much of a pause.

---

## 3 — Rebuild, same leg (cost pause or instance loss)

**Read first: `HANDOFF-NEXT-SESSION.md`.** It outranks every prompt on anything about current state. Then
`TEARDOWN-AND-REBUILD.md` § Rebuild.

| Step | What | Note |
|---|---|---|
| 1 | launch identically | pinned `AMI_ID`, EFA-capable, **IAM profile attached at launch** |
| 2 | `NEW-CLOUD-SETUP.md` **Parts 3–4 only** | skip 0–2; they are already provisioned |
| 3 | `./cloud-setup/restore-memories.sh` | **before** ever running `backup.sh` — they move memories in opposite directions |
| 4 | `env-contract.py env --file <contract>` → paste into `env.sh` | **same leg: uncomment** the leg-specific lines it emits. Do **not** `>>` append — `--check` sits below and would report them missing |
| 5 | paste **prompt 1** · conda from the pinned `*.conda-explicit.txt` · regenerate the cuFile config · HF login | the env is a held-constant input: reproduce it, don't re-solve it |
| 6 | paste **prompt 2a/2b** | the cluster survived; **this instance has never mounted it** |
| 7 | contract `verify` | must be clean on every held-constant field |
| 8–9 | re-hydrate datasets (byte-verify) · prove the recording pipeline | S3 has the data; the mount is what died |
| — | `run-leg.sh --leg <leg>` | **resumes** — skips steps whose markers are in `runs/.leg-state/$LEG/` |

> ⚠ **If the marker directory is empty on a mid-leg rebuild, stop.** It means the previous teardown never
> committed them, and running on would silently redo hours of sweeps into duplicate run dirs.

---

## 4 — WEKA → Lustre: the leg switch

Same teardown, same rebuild shape. Four differences:

1. **The teardown is heavier.** Leg A's contract is what Leg B verifies against, so an unrecorded held-constant
   field blocks the whole next leg. The handoff must carry **what Leg A taught that changes Leg B** — Leg B's
   plan is explicitly provisional, and improving it is the point, not a deviation.
2. **Now you destroy the WEKA cluster** as well as the instance.
3. **`env.sh`:** *leave* the previous leg's filesystem lines **commented** — they describe the other
   filesystem — and set `LEG=lustre`.
4. **Part 8:** you create FSx **at maximum** (Persistent 2 · 1000 MB/s/TiB · ≥ 25 TiB · high metadata IOPS ·
   EFA), then paste **prompt 2b**, which verifies the contract *before* spending anything.

Pauses *within* Leg B are scenario 3 with `lustre` substituted.

Then: the head-to-head synthesis — the actual deliverable.

---

## The three things that stop everything

| Stop | Where | Why it is a stop and not a caveat |
|---|---|---|
| **Wrong transport** — WEKA not on DPDK, Lustre not on EFA (**D16**) | prompts 2a/2b, then `run-leg.sh` refuses via `FS_TRANSPORT` | the fallbacks (UDP / TCP) mount cleanly and report **plausible numbers for a configuration we decided not to measure**. Measuring first and flagging later spends the wallclock and the money before anyone can act |
| **An open blocker-gate row** | prompt 3 § 4.5b | each one either stops a cell or lets a cell report a number wrong in a way nothing downstream detects |
| **Pre-flight NO-GO** | prompt 4 step 6 | every blocking line names something that would be lost **permanently** |

## What only you ever do

The Port blueprint · the FSx console configuration · every secret (HF token, keys) · `S3_BUCKET` · every
reboot · approving `sudo`, installs, mounts and destructive operations · **`git commit && git push`** ·
**destroying anything**.

Everything else, on every build, is a prompt.

---

## Which doc answers which question

| Question | Doc |
|---|---|
| Why are we measuring it this way? | [`../PROJECT-THESIS.md`](../../PROJECT-THESIS.md) |
| What do I physically do next? | `NEW-CLOUD-SETUP.md` · `TEARDOWN-AND-REBUILD.md` |
| Where did the last session leave off? | `HANDOFF-NEXT-SESSION.md` *(exists after the first teardown)* |
| What is still open? | the `cloud-session-open-items` memory |
| Every methodology decision, with its why | [`../runs/STAGES.md`](../STAGES.md) — decision log **D1–D16** |
| What does this script do, and why? | [`../SCRIPT-TRACKER.md`](../SCRIPT-TRACKER.md) |
| What should this path / variable be? | [`NAMING-AND-VARIABLES.md`](../NAMING-AND-VARIABLES.md) |
| Where does X live? | [`../FILESYSTEM-MAP.md`](../FILESYSTEM-MAP.md) |
| How do I run or recover one cell? | [`../runs/README.md`](../RUNBOOK.md) |
