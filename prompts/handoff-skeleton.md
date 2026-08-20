# Project handoff — WEKA vs Lustre on AWS · THE HANDOFF SKELETON

> **This file is a TEMPLATE, never pasted directly.** When a session's context is nearly full, the outgoing
> session writes a handoff **from this skeleton**: every `⟨...⟩` filled, the durable sections carried
> verbatim. Two kinds, one structure:
>
> - **Same-instance session turnover — the normal mode.** The instance runs its whole leg end-to-end;
>   handoffs happen between Claude *sessions* on the same box. The outgoing session prints the filled
>   handoff **inline in its final message**; the human copies it, `exit` → `claude` → paste. No teardown
>   machinery is involved.
> - **Destroy/rebuild — exceptional.** At the human's discretion (worth it when the teardown lands
>   mid-work), the filled handoff is written to a **durable committed file in `tmp/`** — inline chat text
>   dies with the context. Memory + repo remain the designed continuity either way; the preflight only
>   warns, never blocks, on a missing tmp/ handoff. The full checklist in
>   `docs/cloud-setup/TEARDOWN-AND-REBUILD.md` applies.
>
> A received handoff with unfilled `⟨...⟩` blanks is a **NO-GO**: report it and stop. Each leg writes its
> own handoffs (concurrent legs, D6); never hand off the other leg's state.

---

Written: ⟨YYYY-MM-DD⟩ · Leg: ⟨weka|lustre⟩ · Kind: ⟨same-instance | rebuild (file: tmp/⟨name⟩.md)⟩
Mission in one line: ⟨what the receiving session exists to do⟩

You are a fresh Claude Code session on the project's AWS GPU instance, working in this repo. Assume
commands run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance type, same workload code, same datasets, **only the
filesystem under the mount point changes.** Two legs run **concurrently on separate instances** (Leg A:
WEKA · Leg B: FSx for Lustre; STAGES.md **D6**, stage-lag rule), followed by the head-to-head synthesis.
`$LEG` says which one you are on.

---

## Current state (as of this handoff)

- **Where the leg stands:** ⟨stage/substage; last completed cell/step and HOW it was verified; the next
  cell/step not yet started⟩
- **In flight right now:** ⟨background jobs in this tmux — command, PID, log path, expected completion,
  what to do when each finishes; or "nothing in flight — verified with pgrep"⟩ *(same-instance handoffs
  inherit live processes; a job the handoff doesn't name is a job the next session kills or double-runs.)*
- **What this session changed:** ⟨decisions ratified (register entry ids), docs edited, scripts touched,
  values written — pointers, not restatements⟩
- **Awaiting the human:** ⟨open ratifications / greenlights, with where they're recorded⟩
- **Watch items beyond the memory:** ⟨anything time-sensitive the open-items memory doesn't carry, else
  "none — the memory is current"⟩

## THE CENTRAL DIRECTIVE

**Your job is to make the comparison valid, not just to make it run.** The difference between the legs must
be attributable to **the filesystem** and nothing else: the held-constant contract is real, the recording is
path-appropriate per leg, and every deviation is recorded rather than absorbed.

1. **Results precede story** (`PROJECT-THESIS.md` §10). Record the why of every method; record nothing
   about what the numbers will show. Report losses.
2. **Nothing is portable. Re-derive, never copy** — a pre-written or recovered value is not a measured fact
   until verified against the live system.
3. **Every cell records the full measurement set; no metric is designated primary** (§4), including
   wallclock and the dated price inputs. `docs/RUNBOOK.md` defines the set.

## STEP 1 — Read the governing instructions

**`CLAUDE.md`** (the eleven rules; recording; durability; concurrent-legs ownership; docs cadence; the
autonomous-git convention), then **the memories end to end** — your leg's open-items memory
(`cloud-session-open-items` on Leg A · `cloud-session-open-items-lustre` on Leg B; **your work list** —
section A before the first measured cell, later sections during benchmarking) and
`uni2h-conditional-use-status` (UNI2-h stays internal-only). **If `MEMORY.md` is missing:** run
`./scripts/restore-memories.sh`, report, and ask the human to restart the session; if the script refuses,
STOP.

## STEP 2 — Read the project docs

**`PROJECT-THESIS.md`** → **`docs/STAGES.md`** (stage map + decision register) → the relevant
**`docs/Stage-<N>-*.md`** roadmaps → **`docs/RUNBOOK.md`** (the per-cell set, both canaries,
`wsi_agg_helper.py check`) → **`docs/SCRIPT-TRACKER.md`** (+ the deferred table) →
**`docs/NAMING-AND-VARIABLES.md`** → **`docs/FILESYSTEM-MAP.md`** → **`docs/RESULTS.md`** — and on Leg B,
**`docs/cloud-setup/LUSTRE-PROVISIONING.md`** (the leg's provisioning decision register).

> ### ⛔ GATE TIER 0 — the transport, evidenced, before ANY cell including the throwaway
>
> **The transport this leg is actually on**, per **D16**, from the client's own report — never from mount
> options or configuration flags. **Leg A:** WEKA on **DPDK** (`weka cluster process` showing this host's
> FRONTEND with `NETWORK=DPDK`; igb_uio-bound NICs). **Leg B:** Lustre on **EFA** (`lnetctl net show`
> listing efa net(s) up **and** a direct-I/O probe moving the efa net's counters — the `@tcp` in the mount
> string is the MGS NID and proves nothing).
>
> **A fallback transport (UDP/tcp), or no evidence, = STOP AND REPORT. Do not run any cell, including a
> throwaway.** Only a written human waiver changes that; `run-leg.sh` refuses the leg otherwise.
> On a same-instance handoff this is cheap re-verification; after any reboot or rebuild it is mandatory
> fresh evidence.

---

## What to do, in order

*(Always start with 1; fill the rest for this specific handoff.)*

### 1 — Re-verify before touching anything (read-only)
⟨Scale to the handoff kind. Same-instance: env sourced + `./env.sh --check`, mount up, Tier 0 re-evidenced,
disk headroom, the in-flight jobs from "Current state" still alive, `git status` clean-or-explained.
Rebuild: the full discovery of `docs/cloud-setup/TEARDOWN-AND-REBUILD.md`'s rebuild half — boot triage,
contract verify, recording proof — before anything mutates.⟩

### 2..N — ⟨the actual work, numbered⟩
⟨Each entry: the action, the gate/stop attached to it, and where its result gets recorded. Name the STOP
points explicitly — greenlights, ratifications, canary aborts. The last entry is always: leave the state
describable — memory current, docs cadence honored, backup + push clean.⟩

---

## Standing facts to carry

- **`--fs` is a dimension, not a fork.** One `runs/` tree; the `-<leg>-` segment is what the S3 sync and
  the teardown gate glob on.
- **No metric is designated primary**; every cell records the full set + wallclock + dated price inputs
  (both cost bases, **D7**).
- **Per-filesystem primaries invert** (thesis §7): client kernel network counters are diagnostic on WEKA,
  **primary on Lustre**. Never quote a source the filesystem bypasses.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell**; ceilings and their bases are
  per-leg contract fields.
- **Cold vs warm is enforced and recorded as achieved** (**D13**); do not "simplify" the read sweeps'
  staging or ordering.
- **kvikIO cells record the three-layer path accounting**; a config flag is not proof (**D8** — compat is
  the expected end state on BOTH legs; a contradicting split is a finding, not wiring to add). `LD_PRELOAD`
  scoped per cell.
- **Cross-leg integrity gates** are fingerprinted per **D19**.
- **MIL is canonical `batch_size=1` + `collate_MIL`**; UNI2-h stays internal-only.
- **Concurrent-legs discipline** (D6): own files only; push via `scripts/push-safe.sh`; structural docs are
  proposals to the human; stage-lag check before every stage start.
- **Git: Claude commits and pushes autonomously** — per work block, `./backup.sh` first, never mid-cell.
  **Ephemerality:** both mounts, local scratch, and your context die with the instance — only git, the
  memory mirror, and S3 survive. Persist continuously; a long-running instance is not a durable one.

## Your first response

After the reading and the re-verification: what you understand the state to be (including every in-flight
job you found and adopted), anything that contradicts this handoff, and the plan through the next STOP
point — decisions as a plain-text numbered list with a recommendation each. **Mutate nothing before
sign-off. Run nothing — not even a throwaway — until Tier 0 is evidenced.**
