# Project handoff — WEKA vs Lustre on AWS · R2 → R3 (post-reboot)

Written: 2026-08-21 · Leg: **lustre** · Kind: same-instance across a REBOOT (file:
`TEMP/prompt-r3-post-reboot-efa-repro.md` — the reboot kills the session and tmux, so the handoff is a
durable committed file; delete it in your first work-block commit once executed, per the TEMP/ convention)
Mission in one line: **verify the reboot, reproduce-probe the EFA bulk-write instability, and either resume
the pre-baseline plan through the Stage-1.0 baseline greenlight or hold the STOP and prepare the AWS case.**

You are a fresh Claude Code session on the project's AWS GPU instance, working in this repo. Assume
commands run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance type, same workload code, same datasets, **only the
filesystem under the mount point changes.** Two legs run **concurrently on separate instances** (Leg A:
WEKA · Leg B: FSx for Lustre; STAGES.md **D6**, stage-lag rule), followed by the head-to-head synthesis.
`$LEG` says which one you are on.

---

## Current state (as of this handoff)

- **Where the leg stands:** pre-baseline, **⛔ STOPPED on the 2026-08-21 EFA bulk-write incident** — the
  full account, evidence pointers, and the RATIFIED post-reboot sequence are the open-items memory's item
  B.5; the evidence itself is the three `runs/2026-08-21-1*-FAILED-efa-*` dirs (notes.md +
  incident-evidence.txt + FSx CloudWatch dumps). Completed and verified by R2 before the stop: the full
  mechanical sanity pass (contract re-verify PASSED, marker re-armed; Tier 0 evidenced; conda/GPU/nvidia-fs
  clean); `prove-recording.sh` ALL PASS on this build; **D-36, D-38, D-39 closed** and **D-7's per-cell
  watchdog BUILT + PROVEN** (the deliberately-INCOMPLETE `s0-watchdog-proof` cell is the proof); the
  ratified lustre cold set (drop_caches=3 + ldlm lru clear) wired into the reconciler and the three shell
  drivers. The calibration attempt lost all three seqw cells to the incident; **bands do NOT exist**
  (`wsi_agg_helper.py check` is UNCALIBRATED by design). Next step not started: the reproduce probe.
- **In flight right now:** nothing — the box was rebooted between R2 and you. Verify anyway: `pgrep -af
  'fio|record-run|calibrate'` must be empty, and R2's two D-state fio remnants must be gone (the reboot's
  purpose). A survivor is a stop-and-report.
- **What this session (R2) changed:** commits `c309999`→`f62853c` on main (all pushed). Pointers: tracker
  D-36/D-38/D-39 → closed-ids; D-7 row rewritten (watchdog done; per-cell sync + canary-abort remain); D-4
  row rewritten (cold set DECIDED; python-side workers gated at 6.B.2/7.1). New scripts:
  `fsx-cloudwatch-dump.py` (D-39, proven; needs the granted CloudWatch IAM), `probe-lustre-coldset.sh`
  (cold-set demonstration, NOT yet run), `probe-efa-bulk-repro.sh` (your step 2). RUNBOOK: CloudWatch
  source row, lustre cold-set table row + paragraph, night-chain requirement 3. NAMING Table 2:
  `RECORD_TIMEOUT_S`. `PROVISIONING-AND-PRICING.md`: Leg-B section + price rows filled.
- **Awaiting the human:** nothing pending ratification — the post-reboot sequence is ratified (memory
  B.5). Standing [USER] item: the `FS_USD_PER_HR` invoice check (register L6).
- **Watch items beyond the memory:** none — the memory is current.

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
autonomous-git convention), then **the memories end to end** — `cloud-session-open-items-lustre` (**your
work list**; item B.5 is this handoff's spine) and `uni2h-conditional-use-status` (UNI2-h stays
internal-only). **If `MEMORY.md` is missing:** run `./scripts/restore-memories.sh`, report, and ask the
human to restart the session; if the script refuses, STOP.

## STEP 2 — Read the project docs

**`PROJECT-THESIS.md`** → **`docs/STAGES.md`** (stage map + decision register) →
**`docs/Stage-1-Ingest.md`** → **`docs/RUNBOOK.md`** (the per-cell set, both canaries,
`wsi_agg_helper.py check`) → **`docs/SCRIPT-TRACKER.md`** (+ the deferred table; the D-7/D-4/D-5 rows and
the three new probe/dump entries are this handoff's context) → **`docs/NAMING-AND-VARIABLES.md`** →
**`docs/FILESYSTEM-MAP.md`** → **`docs/cloud-setup/LUSTRE-PROVISIONING.md`** (register L1–L7 — ratified;
carry, don't re-litigate).

> ### ⛔ GATE TIER 0 — the transport, evidenced, before ANY cell including the throwaway
>
> **Leg B is on EFA** per **D16**, from the client's own report — never from mount options or
> configuration flags: `sudo lnetctl net show` listing efa net(s) up **and** a direct-I/O probe moving the
> efa net's `send_count` (~1 RPC/MiB) with tcp near-flat — the `@tcp` in the mount string is the MGS NID
> and proves nothing. **After a reboot this is mandatory fresh evidence**, and
> `wsi-lustre-phase2.service` must show its gate + counter-proof passed on THIS boot (a failed
> counter-proof leaves the filesystem unmounted, by design).
>
> **A fallback transport (tcp), or no evidence, = STOP AND REPORT. Do not run any cell, including a
> throwaway.** Only a written human waiver changes that; `run-leg.sh` refuses the leg otherwise.

---

## What to do, in order

### 1 — Re-verify before touching anything (read-only, rebuild-grade because of the reboot)
Boot triage: `grep WSI- /var/log/wsi-bootstrap.log` (FATAL = stop; a stale boot-time contract WARN from the
2026-08-21 00:02 build is explained and superseded — see R2's commit `c309999` message).
`journalctl -u wsi-lustre-phase2.service` — gate + counter-proof passed on THIS boot;
`wsi-lustre-tuning.service` re-applied L4. No leftover benchmark processes (the in-flight check above).
`git pull --ff-only`. `./env.sh --check`. Tier 0 evidenced by you (the gate above). Re-run
`env-contract.py verify --against runs/env-contract-leg-weka.json --leg lustre` — every held-constant
field must verify; verify re-arms `runs/.leg-state/lustre/contract-verified`. Deliverable: a short
discovery report; anything broken is a numbered list and pauses the plan.

### 2 — Reproduce probe, short (the ratified sequence, memory B.5)
`./scripts/probe-efa-bulk-repro.sh` (120 s, the incident's exact shape, mechanical PASS/FAIL on the EFA
retrans counters + new dmesg error lines + fio rc; self-watchdogged). **FAIL → the STOP stands: report to
the human, prepare the AWS support case from the `-FAILED-efa-*` evidence bundle ([USER] files it; also
[USER]: Personal Health Dashboard + instance-status console — the box's role cannot see them). Never a
tuning exercise (D16 / register L7).** Its cells are diagnostics — never quote a rate.

### 3 — Reproduce probe, full length
On a 120 s PASS: `PROBE_RUNTIME=300 ./scripts/probe-efa-bulk-repro.sh`. Same FAIL semantics. Only a
full-length PASS clears calibration.

### 4 — Calibrate the canary bands (D18/D-5)
Rewrite memory item B.5 from STOP to a recurrence watch item (section C: any recurrence during measured
cells = abort + surface as a provisioning question), then
`set -o pipefail; ./scripts/calibrate-canary-bands.sh 2>&1 | tee runs/sweep-logs/<UTC>-lustre-calib-bands.log`
(background; cells are watchdogged at 1800 s). On completion verify `runs/.leg-state/lustre/canary-bands.json`
exists and `wsi_agg_helper.py check` on a calibration cell exits calibrated. Then extend
`prove-recording.sh`'s D-5 SKIP into a real assertion (the tracker's standing "extend when it lands"
instruction). No commits while cells are in flight (`CLAUDE.md`).

### 5 — The cold-set demonstration cell
`RECORD_CACHE_STATE=na-cold-mechanism-demo ./scripts/record-run.sh --stage 0 --run-name coldset-ldlm-demo
--note "..." -- ./scripts/probe-lustre-coldset.sh` — the measured C-vs-B evidence behind the ratified
lustre cold set. Surprising deltas (ldlm flush load-bearing for data reads, or B≈warm) are findings to
surface, not absorb.

### 6 — The recorded D8 Phase-0 determination cell
`./scripts/probe-gds-phase0.sh` — modes forced, three-layer accounting recorded. **Expected: compat/bounce
(no true GDS on g6e, doc-grounded both legs); a contradicting split is a finding to surface immediately,
not wiring to add.**

### 7 — Retro-dump + housekeeping
`fsx-cloudwatch-dump.py` over any stage-0 run dirs without a final dump (memory item; the post-cell hook
covers new cells automatically). Close the memory retro-dump line. Commit the work block (backup.sh +
push-safe; delete this TEMP file as spent in the same commit).

### 8 — The pre-greenlight run-leg window
Stage-lag check first (Leg A's `.leg-state/weka/` markers — already past 6.A as of this handoff;
re-verify). Then, sequentially — `--only` runs exactly one step, and the window STOPS after 1.7:
`for s in C0 1.0a 1.0r-prep 1.0b 1.0c 1.0d 1.7; do ./scripts/run-leg.sh --leg lustre --only $s || break; done`
(inside the tmux, tee'd). After each sweep: `wsi_agg_helper.py check` on its cells by hand (canary-abort
is still D-7's remainder), numbers into `Stage-1-Ingest.md` as they land, and
`verify-substage-closeout.sh <substage>` must exit 0 before the next phase. Corpora staging (1.0r-prep)
runs against the contract's D13 `stage1_*` values. Watch item (register L7): a knee/peak plateau below
expectation with the efa net unsaturated → stop and surface as a provisioning question.

### 9 — STOP for the baseline greenlight
After 1.7: report Tier 0 and every Tier-1 row, row by row, with evidence named; check the D10
instance-revisit trigger; compare measured vs documented ceiling honestly (register L5: 700 Gbps
documented per client; the 200 Gbps line rate is the binding bound — both in the basis string). **Do not
start 3.0.** Leave the state describable — memory current, docs cadence honored, backup + push clean.

---

## Standing facts to carry

- **`--fs` is a dimension, not a fork.** One `runs/` tree; the `-<leg>-` segment is what the S3 sync and
  the teardown gate glob on.
- **No metric is designated primary**; every cell records the full set + wallclock + dated price inputs
  (both cost bases, **D7**).
- **Per-filesystem primaries invert** (thesis §7): client kernel network counters are diagnostic on WEKA,
  **primary on Lustre** — as built, the EFA devices' hw_counters are the wire Primary and the FSx
  CloudWatch dump is the server-side Primary (D-39, per-cell hook + backfill). Never quote a source the
  filesystem bypasses.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell**; ceilings and their bases are
  per-leg contract fields.
- **Cold vs warm is enforced and recorded as achieved** (**D13**); the lustre clearing-based cold set is
  **both** steps (drop_caches=3 + ldlm lru clear, both acknowledged — the reconciler marks a half-cleared
  cell). Do not "simplify" the read sweeps' staging or ordering.
- **kvikIO cells record the three-layer path accounting**; a config flag is not proof (**D8** — compat is
  the expected end state on BOTH legs; a contradicting split is a finding, not wiring to add). `LD_PRELOAD`
  scoped per cell.
- **Cross-leg integrity gates** are fingerprinted per **D19**.
- **MIL is canonical `batch_size=1` + `collate_MIL`**; UNI2-h stays internal-only.
- **Concurrent-legs discipline** (D6): own files only; push via `scripts/push-safe.sh`; structural docs are
  proposals to the human; stage-lag check before every stage start. A push-safe rebase conflict is an
  ownership violation to report — R2 hit two benign both-legs-same-paragraph collisions; resolve by hand
  preserving both legs' content, and report it.
- **Kill by explicit process group, never by pattern** — `pkill -f` and pattern-built PID lists match the
  wrapper's own argv (bit R2 during incident recovery). The watchdog and cleanup trap now own this;
  don't hand-roll kills.
- **Git: Claude commits and pushes autonomously** — per work block, `./backup.sh` first, never mid-cell.
  **Ephemerality:** both mounts, local scratch, and your context die with the instance — only git, the
  memory mirror, and S3 survive. Persist continuously; a long-running instance is not a durable one.

## Your first response

After the reading and the re-verification: what you understand the state to be (including every in-flight
job you found and adopted), anything that contradicts this handoff, and the plan through the next STOP
point — decisions as a plain-text numbered list with a recommendation each. **Mutate nothing before
sign-off. Run nothing — not even a throwaway — until Tier 0 is evidenced.**
