# Project handoff — WEKA vs Lustre on AWS · R3 → R4 (destroy → rebuild, mid-incident)

Written: 2026-08-21 · Leg: **lustre** · Kind: rebuild (file: `TEMP/prompt-r4-post-rebuild-efa-case.md` —
delete it in your first work-block commit once executed, per the TEMP/ convention)
Mission in one line: **rebuild-verify the client, carry the EFA-incident STOP, and resume the
pre-baseline sequence only when the AWS case resolves — starting at the reproduce probe.**

You are a fresh Claude Code session on the project's AWS GPU instance, working in this repo. Assume
commands run inside `tmux new -A -s wsi`.

**What this project is.** A competitive comparison of **WEKA vs Lustre** for a modern whole-slide-imaging /
digital-pathology pipeline on AWS: same instance type, same workload code, same datasets, **only the
filesystem under the mount point changes.** Two legs run **concurrently on separate instances** (Leg A:
WEKA · Leg B: FSx for Lustre; STAGES.md **D6**, stage-lag rule), followed by the head-to-head synthesis.
`$LEG` says which one you are on.

---

## Current state (as of this handoff)

- **Where the leg stands:** pre-baseline, **⛔ STOPPED on the EFA bulk-write instability — reproduced
  post-reboot on 2026-08-21, AWS support case pending.** The full account is
  `TEMP/efa-bulk-write-failure-dossier.md` (comprehensive, standalone) and the open-items memory item
  B.5; the evidence is the four `runs/2026-08-21-*-FAILED-efa-*` dirs. **No measured cell has ever run
  on this leg** — no calibration bands, no hydration (`hydration-complete` absent), no run-leg step
  markers (`runs/.leg-state/lustre/` holds only `contract-verified`). The client instance R3 ran on was
  **deliberately destroyed** (human decision, 2026-08-21, superseding the earlier no-second-rebuild
  ratification) to stop idle burn while the AWS case runs; you are on its rebuild.
- **In flight right now:** nothing — the box you are on is freshly built. Verify anyway (`pgrep -fa
  'record-run.sh|sweep-stage|run-leg.sh'`).
- **What R3 changed:** the reproduce probe ran and FAILED (the reproduction dir + its bracketed counter
  evidence); memory B.5 rewritten; `TEMP/aws-support-case-efa-bulk-write.md` (filing draft) and
  `TEMP/efa-bulk-write-failure-dossier.md` written; teardown prep + this handoff. All pushed.
- **Awaiting the human:** the AWS case outcome (item B.5 carries the state; the human files/relays).
  Standing [USER] item: the `FS_USD_PER_HR` invoice check (register L6).
- **Watch items beyond the memory:** if the FSx file system was ALSO destroyed in the teardown (human's
  scope decision — check whether `fs-0a0a63dea8324225b` still exists before assuming), the leg needs
  re-provisioning per `docs/cloud-setup/LUSTRE-PROVISIONING.md` first: new fs id everywhere
  (`FSX_ID`, the CloudWatch dump, the dossier's environment table), register L1–L7 values re-verified
  against the new build, contract re-written, and prices/ceilings re-fetched dated. Nothing
  data-bearing was on the old mount (hydration never ran; only fio scratch was lost).

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
autonomous-git convention), then **the memories end to end** — `cloud-session-open-items-lustre`
(**your work list**; item B.5 is this handoff's spine) and `uni2h-conditional-use-status` (UNI2-h stays
internal-only). **If `MEMORY.md` is missing:** run `./scripts/restore-memories.sh`, report, and ask the
human to restart the session; if the script refuses, STOP.

## STEP 2 — Read the project docs

**`PROJECT-THESIS.md`** → **`docs/STAGES.md`** (stage map + decision register) →
**`docs/Stage-1-Ingest.md`** → **`docs/RUNBOOK.md`** (the per-cell set, both canaries,
`wsi_agg_helper.py check`) → **`docs/SCRIPT-TRACKER.md`** (+ the deferred table; the D-7/D-4/D-5 rows and
the probe/dump entries are this handoff's context) → **`docs/NAMING-AND-VARIABLES.md`** →
**`docs/FILESYSTEM-MAP.md`** → **`docs/cloud-setup/LUSTRE-PROVISIONING.md`** (register L1–L7 — ratified;
carry, don't re-litigate) → **`TEMP/efa-bulk-write-failure-dossier.md`** (the incident, end to end).

> ### ⛔ GATE TIER 0 — the transport, evidenced, before ANY cell including the throwaway
>
> **Leg B is on EFA** per **D16**, from the client's own report — never from mount options or
> configuration flags: `sudo lnetctl net show` listing efa net(s) up **and** a direct-I/O probe moving
> the efa net's `send_count` (~1 RPC/MiB) with tcp near-flat — the `@tcp` in the mount string is the MGS
> NID and proves nothing. **On a rebuild this is mandatory fresh evidence**, and
> `wsi-lustre-phase2.service` must show its gate + counter-proof passed on THIS boot (a failed
> counter-proof leaves the filesystem unmounted, by design).
>
> **A fallback transport (tcp), or no evidence, = STOP AND REPORT. Do not run any cell, including a
> throwaway.** Only a written human waiver changes that; `run-leg.sh` refuses the leg otherwise.

---

## What to do, in order

### 1 — Re-verify before touching anything (read-only, rebuild-grade)
The full rebuild half of `docs/cloud-setup/TEARDOWN-AND-REBUILD.md`: boot triage
(`grep WSI- /var/log/wsi-bootstrap.log`; FATAL = stop), `journalctl -u wsi-lustre-phase2.service`
(gate + counter-proof on THIS boot), `verify-conda-env.sh`, `./env.sh --check`, Tier 0 evidenced by you,
`env-contract.py verify --against runs/env-contract-leg-weka.json --leg lustre` (every held-constant
field must verify; re-arms the marker; **a VIOLATION is a stop**), `./scripts/prove-recording.sh` before
any wallclock. Deliverable: a discovery report; anything broken is a numbered list and pauses the plan.

### 2 — Hold or resume: keyed to the AWS case (memory B.5)
**The STOP stands until the human reports the AWS case outcome.** No cells — no calibration, no coldset
demo, no throwaways beyond Tier 0's own probe — while it stands. If the human reports a fix or a
config change to test: apply/verify it as a recorded provisioning event (human-ratified), then
`./scripts/probe-efa-bulk-repro.sh` (120 s) → PASS → `PROBE_RUNTIME=300` full length. **Any FAIL → the
STOP stands, report back into the case. Never a tuning exercise (D16/L7).**

### 3 — On a full-length PASS: resume the ratified pre-baseline sequence
Exactly as memory B.5 records it: rewrite B.5 to a recurrence watch item → `calibrate-canary-bands.sh`
(tee'd, watchdogged) → verify bands + a calibrated `wsi_agg_helper.py check` → extend
`prove-recording.sh`'s D-5 SKIP → `probe-lustre-coldset.sh` → `probe-gds-phase0.sh` → CloudWatch
retro-dump housekeeping → stage-lag check → the `run-leg.sh --only` window C0 → 1.0a → 1.0r-prep →
1.0b → 1.0c → 1.0d → 1.7 (closeout gate between phases) → **STOP for the baseline greenlight. Do not
start 3.0.**

### 4 — Always: leave the state describable
Memory current, docs cadence honored, backup + push clean; delete this TEMP file as spent in the first
work-block commit.

---

## Standing facts to carry

- **`--fs` is a dimension, not a fork.** One `runs/` tree; the `-<leg>-` segment is what the S3 sync and
  the teardown gate glob on.
- **No metric is designated primary**; every cell records the full set + wallclock + dated price inputs
  (both cost bases, **D7**).
- **Per-filesystem primaries invert** (thesis §7): client kernel network counters are diagnostic on WEKA,
  **primary on Lustre** — as built, the EFA devices' hw_counters are the wire Primary and the FSx
  CloudWatch dump is the server-side Primary (D-39). Never quote a source the filesystem bypasses.
- **Every "% of ceiling" divides by the block-size-matched Stage-1.0 cell**; ceilings and their bases are
  per-leg contract fields (register L5: 700 Gbps documented, 200 Gbps line rate binding — both in the
  basis string).
- **Cold vs warm is enforced and recorded as achieved** (**D13**); the lustre cold set is BOTH steps
  (drop_caches=3 + ldlm lru clear, both acknowledged). Do not "simplify" the read sweeps' staging or
  ordering.
- **kvikIO cells record the three-layer path accounting**; a config flag is not proof (**D8** — compat is
  the expected end state on BOTH legs; a contradicting split is a finding, not wiring to add).
  `LD_PRELOAD` scoped per cell.
- **Cross-leg integrity gates** are fingerprinted per **D19**.
- **MIL is canonical `batch_size=1` + `collate_MIL`**; UNI2-h stays internal-only.
- **Concurrent-legs discipline** (D6): own files only; push via `scripts/push-safe.sh`; structural docs
  are proposals to the human; stage-lag check before every stage start.
- **Kill by explicit process group, never by pattern** — `pkill -f` matches the wrapper's own argv. The
  watchdog and cleanup trap own this; don't hand-roll kills.
- **EFA hw_counters persist across reboot** (proven 2026-08-21) — bracket with snapshots, never assume
  "since boot".
- **Git: Claude commits and pushes autonomously** — per work block, `./backup.sh` first, never mid-cell.
  **Ephemerality:** both mounts, local scratch, and your context die with the instance — only git, the
  memory mirror, and S3 survive. Persist continuously; a long-running instance is not a durable one.

## Your first response

After the reading and the re-verification: what you understand the state to be, anything that
contradicts this handoff, and the plan through the next STOP point — decisions as a plain-text numbered
list with a recommendation each. **Mutate nothing before sign-off. Run nothing — not even a throwaway —
until Tier 0 is evidenced.**
