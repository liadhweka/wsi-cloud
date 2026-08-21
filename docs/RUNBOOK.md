# RUNBOOK — how to run and record a cell, and how to recover

Every benchmark run lands in its own subdirectory of `../runs/`. This file is the **operational reference**:
what a cell must record, both canaries, how to run a sweep unattended, and how to recover from a failure.

For *what* each stage is, the per-leg plan, and the decision register, see [`STAGES.md`](STAGES.md) and the
per-stage `Stage-<N>-*.md` roadmaps. For where everything lives, [`FILESYSTEM-MAP.md`](FILESYSTEM-MAP.md). For
what each script does, [`SCRIPT-TRACKER.md`](SCRIPT-TRACKER.md). For the measurement rules this file
implements, [`../PROJECT-THESIS.md`](../PROJECT-THESIS.md) §4 and §7; for project-wide rules,
[`../CLAUDE.md`](../CLAUDE.md).

---

## The one thing that makes this tree different

**The filesystem is a dimension of every run, not a separate tree** (**D11**). Every cell carries its
filesystem, which becomes a segment of the run-dir name **and** a field in `metadata.json` — the two places the
head-to-head is assembled from.

```
<UTC-timestamp>-<fs>-s<stage>-<workload>-<config>/
```

Scripts resolve the mount through **`$FS_MOUNT`** (`/mnt/weka` or `/mnt/lustre`) rather than hardcoding a path
— the filesystem is a parameter, never a fork in the code.

> ⏳ **Teaching the aggregators to group on the `fs` field is deferred work** — see the deferred table in
> `SCRIPT-TRACKER.md`. The *data* is recorded correctly now; only the pivot is missing, so a cross-filesystem
> CSV still has to be assembled by hand until that lands.

---

## What every cell records

**No metric is designated primary** (`../PROJECT-THESIS.md` §4). Choosing the decisive axis in advance would be
a prediction, and which axis turns out to be decisive is a *result* — so a cell that recorded only the axis
someone expected to matter cannot be repaired later. **Capture the full set on every cell where it is
meaningful:**

| | |
|---|---|
| **Throughput** | bytes/sec, app-level and filesystem-side |
| **Operations** | operations/sec, and metadata-operation rates where the workload generates them |
| **Latency** | the distribution, not just the mean — p50 / p95 / p99 and max |
| **Concurrency scaling** | the value swept, the effective parallelism, and the resulting curve |
| **Wallclock** | measured, not estimated — it is also a cost input |
| **Cache state achieved** | recorded, never asserted (**D13**) |
| **Core accounting** | cores reserved by the filesystem client, cores available to the application, total cores (**D15**) |
| **I/O path proof** | on any cuFile cell, cuFile's own GPU-direct-vs-bounced byte accounting (**D8**) |

**Time series, not point estimates** — 1-second resolution minimum, with aggregates derived from the timeline.
Prefer an **idle-robust active-window mean** for a throughput figure — a storage-idle setup or model-load phase
inside the recording window otherwise dilutes it badly — and keep the naive full-window value alongside so both
are visible.

### Cost inputs — recorded per cell, because they cannot be reconstructed later

`infra-only = (instance + filesystem $/hr) × wallclock` and `all-in = (instance + filesystem + software $/hr)
× wallclock`, both calculated **per cell and per leg** (`../PROJECT-THESIS.md` §4). So every cell records:

- **measured wallclock** (already in the set above),
- **the instance price**, **the filesystem price** for the provisioned configuration, and **the
  storage-software price** — `0` on the Lustre leg (the FSx service rate is software-inclusive; the recorded
  basis says so), the **public AWS Marketplace rate** on the WEKA leg,
- **the date each price was checked.**

**Prices are fetched from the vendor's current pricing, never recalled.** Cloud prices change without notice,
and a stale price silently rewrites the conclusion. An undated price is not usable — treat it as missing.

**How the wrapper gets them.** `record-run.sh` measures the wallclock itself and reads the prices from the
environment — `INSTANCE_USD_PER_HR`, `FS_USD_PER_HR`, `SOFTWARE_USD_PER_HR`, `PRICE_CHECKED_UTC` — writing all
of it into each cell's `metadata.json` as `wallclock_s` plus a `cost_inputs` block. **No price is ever baked
into a script.** Set the four in `env.sh` at provisioning, from pricing fetched that day; the filesystem and
software prices are per-leg by construction. An unset price is recorded as `null` and warned about rather than
guessed — a cell with null prices is one whose cost cannot be computed, which is visible and repairable,
whereas a fabricated one is neither.

**Two figures, one label rule.** Infra-only and all-in are both computed everywhere; **every quoted cost names
its basis** — and the software input's asymmetry is stated in the data itself (**D7**): FSx's rate is
software-inclusive so its software price is `0` with that basis recorded; WEKA's is the public AWS Marketplace
rate, citable where a negotiated price is not.

This is the figure that turns the deliberate provisioning asymmetry (**D7**) from a caveat into arithmetic:
"Lustre at maximum versus WEKA at a realistic production configuration" is a fairness claim a reader can argue
with; *what each configuration cost to complete the same pipeline* is a number.

---

## Quick reference

```bash
LIB=<repo>/scripts

# Run one cell, fully recorded
"$LIB/record-run.sh" \
  --fs    <weka|lustre> \
  --stage <stage-code-from-STAGES.md> \
  --run-name <descriptive-slug> \
  --note  "what this run is, in plain English" \
  -- <benchmark-cmd> [args...]

# Re-parse an existing run's raw CSVs into results.json (parser fix / new metric —
# no need to re-run the benchmark)
"$LIB/parse-results.py" <run-dir>/

# Re-aggregate a sweep into its summary CSV
"$LIB/aggregate-stage4c-kvikio.py"

# Inspect what a run was for, without parsing JSON
cat <run-dir>/0_README.md
```

Every run dir has `0_README.md` at the top, auto-generated from the metadata — the first thing a future reader
should look at.

---

## Layout

```
runs/
  INDEX.md            one line per run, append-only — AUTO-GENERATED, never hand-edit
  .leg-state/<leg>/   run-leg.sh's per-step completion markers — TRACKED in git, deliberately:
                      they are the only thing that stops a resumed leg re-running completed
                      steps into duplicate run dirs after the instance is rebuilt
  sweep-logs/         consolidated tee'd sweep-driver output (gitignored — large)
  <UTC>-<fs>-s<stage>-<run-name>/
    0_README.md       plain-English summary of THIS run (auto-generated, in git)
    cmd.txt           exact command line (in git)
    cmd.log           tee'd stdout+stderr (gitignored — can be large)
    metadata.json     run name, fs, stage, host, kernel, command, note (in git)
    notes.md          optional post-run observations (in git, manual)
    pre/  post/       filesystem + host state snapshots (in git, small text)
    raw/              during-run 1-second time series (gitignored — heavy, synced to S3)
    results.json      parsed aggregate stats (in git)
```

**Small text stays in git; heavy raw goes to S3** (**D14**). Both filesystem mounts and the instance's local
NVMe are **ephemeral** — they die with the instance and the cluster, and each leg's instance can be rebuilt
at any time. Run `./backup.sh` before any commit or teardown.

---

## The source table — operational, and different on each leg

Sources are **Primary** (numbers that may be quoted, and that participate in ratio checks) or **Diagnostic**
(context only). **The split is mandatory and it is not the same on both legs** — the rule and its rationale are
`../PROJECT-THESIS.md` §7 and **D12**; the table below is that rule expressed as the commands that produce each
stream.

| Source | WEKA leg | Lustre leg |
|---|---|---|
| **App-level** (`cmd.log`, per-step / per-file CSVs) | **Primary** | **Primary** |
| **`weka stats realtime`** | **Primary** — throughput, latency, ops | n/a |
| **Wire counters for the DPDK data path** | **Primary** | n/a |
| **`lctl get_param` client stats** (`lustre-stats.log`: llite/osc/mdc, 1 Hz verbatim) | n/a | **Primary** — the quotable byte series is **osc summed across OSTs** (every byte moved to storage; per-OST spread is the striping evidence). **llite is Diagnostic: blind to libaio traffic** (proven 2026-08-21) — its shortfall vs osc doubles as cache/aio-path evidence, never the cell's rate |
| **CloudWatch per-OST/MDT metrics** (`raw/fsx-cloudwatch.{json,csv}`: every `AWS/FSx` series for the file system — per-OST/MDT via `StorageTargetId`, per-OSS/MDS via `FileServer`) | n/a | **Primary** — server-side view, the one source not measured from the client. Captured per cell by `fsx-cloudwatch-dump.py` (post-cell hook + per-step backfill — publish lag makes the immediate dump provisional, `"final"` says which). 1-minute resolution, so it **never joins the 1 Hz ratio checks** |
| **Client network counters** | **Diagnostic** (`sar -n DEV`) — DPDK bypasses the kernel network stack, so this is control-plane only | **PRIMARY — this IS the data path.** As built (EFA-mounted, counter-proven per boot, D16): the **EFA devices' hw_counters** (`rdma-counters.csv`) are the wire Primary; kernel netdev / `sar -n DEV` carries only the tcp side (control plane, S3 on 1.7). Phase-2 re-proves the transport each boot — a tcp-mounted boot demotes nothing silently, it unmounts |
| **cuFile path accounting** (`CUFILE_STATS`, nvidia-fs stats) | **Primary** on every kvikIO cell | **Primary** on every kvikIO cell |
| **`nvidia-smi`** | Primary from Stage 4 onward | same |
| **`sar -u`** over **application-available** cores | Primary where compute matters (**D15**). **Raw CPU-busy over *all* cores is diagnostic-only on this leg** — thesis §7 puts it there because the DPDK cores spin-poll regardless of load, so it is the restriction to application-available cores that makes the reading quotable | same, but **the excluded core set differs** — WEKA reserves cores for DPDK, Lustre does not |
| **`sar -d`** per block device | Diagnostic for any filesystem-side number. It reads ~zero for the mount, which is how we confirm the cell is not secretly hitting local disk — **except where local disk is a deliberate participant** (a local-NVMe source or staging target), where it is how we confirm the *source* was not the limit | same |
| **Memory statistics** | Primary where host RAM is an axis | same |
| **Pre/post snapshots** | Primary (state delta) | same |

> **The line to remember:** the client's network counters are **diagnostic on the WEKA leg and primary on the
> Lustre leg.** Using one leg's table for the other produces confidently wrong numbers.

Per-stage roadmaps record only their **changes** to this table — a source promoted or demoted for that stage,
and why. They do not restate it.

---

## The two canaries — both mandatory, both mechanical

### 1. Pre-cell: environment + exclusivity check

Before every cell, confirm the environment still matches what the fairness basis specifies and that nothing
else is competing for the filesystem:

- **Transport is the intended one** (**D16**), evidenced from the client's own report, not from the mount
  options passed. `run-leg.sh` refuses to start a leg otherwise.
- **Provisioning matches the environment contract** — instance type, and on the storage side the values
  captured at spin-up (WEKA: backend type/count, capacity, EC scheme, client networking mode; FSx: tier,
  capacity, provisioned metadata IOPS, EFA state). A configuration change mid-leg **is** a benchmark change; if
  it happens, re-baseline and record it.
- **Filesystem health** — no degraded state, no alerts, expected server/target count present.
- **Exclusivity** — no other client or tenant actively moving data. A neighbour's I/O silently depresses our
  numbers, and post-hoc it is indistinguishable from a filesystem property.
- **The cell's cache regime is known before it runs** (**D13**). For any read cell, that means: the working set
  is either **larger than the bigger of the two server-side caches** — in which case the cell is cold by
  construction — or it is not, in which case the cell is **labelled and reported as cache-served** and its
  number is never quoted as storage throughput. `O_DIRECT` settles only the client page cache; it does nothing
  about the server's. **A cell whose regime nobody established is not a cold cell, it is an unlabelled one.**

**If exclusivity fails, do not start.** Wait, or record it in `--note` and treat the cell as contaminated.

**Reaching a cold state, and what each step actually clears.** The mechanism is per-filesystem and only partly
ours on a managed service, so what was achieved is recorded rather than assumed (**D13**):

| Step | Clears | Does not clear |
|---|---|---|
| `O_DIRECT` on the I/O itself | the client page cache, for that I/O | dentry/attribute caches; anything server-side |
| `vm.drop_caches=1` | the client page cache | **dentries and inodes** — so `open()`/`stat()` can still be served locally |
| `vm.drop_caches=3` | page cache **plus dentries and inodes** | anything server-side |
| unmount / remount | client-side caches wholesale | anything server-side |
| whatever the filesystem exposes | its own server-side cache, where it exposes anything at all | — |

**Use `3`, not `1`, on any cell whose subject is metadata** — the dentry and attribute caches are the ones that
matter there, and leaving them warm makes the cell measure the client's VFS on both legs alike.

### 2. Post-cell: cross-source consistency

After every cell, the Primary sources must tell a physically consistent story. **The expected relation is
derived per filesystem and never ported across** (**D12**):

- **WEKA** — erasure coding implies a specific wire-vs-app write amplification set by the EC scheme captured at
  provisioning; reads carry no equivalent amplification. Derive the ratio from the actual scheme.
- **Lustre** — data is striped across OSTs with no default erasure coding, so the relation follows from the
  **actual stripe layout** plus any replication. Built (`wsi_agg_helper.parse_stripe_layout`, from the
  recorded `LUSTRE_STRIPE_LAYOUT`): raid0-only components, mirror_count 1 → wire/app centers 1.0 both
  directions; a mirrored or non-raid0 layout refuses rather than assumes. The layout is recorded per cell by
  the snapshot (`lfs-getstripe-root.txt`).

Additional rules that apply on both legs:

- **Only Primary sources participate in a ratio check.**
- **Mixed read+write cells need wider bands than single-direction cells**, because the wire carries read data
  plus write acknowledgements in one direction and requests plus payload in the other. At small block sizes the
  non-payload share is material. **Widen deliberately and say so** — never silently.
- **Very short cells under-sample.** A sub-second cell yields 1–3 samples at 1 Hz, and any sustained mean is
  ill-defined. That is a sampling limit, not a consistency failure — **record the judgement** rather than
  adjusting a band to make it pass.
- **kvikIO cells additionally require path accounting** — a cell without recorded GPU-direct-vs-bounced bytes
  is **incomplete**, because a configuration flag does not prove which path a read took.

**Disagreement beyond a stated tolerance means bugged infra → fix before continuing.** On an unattended chain
the canary **aborts the chain itself** rather than waiting to be noticed — otherwise a 3am failure yields hours
of contaminated cells that look fine.

**The evaluator is `scripts/wsi_agg_helper.py check <run-dir>`** — verdict per direction, every widening
named, exit non-zero on FAIL **or** UNCALIBRATED. Its bands come from the leg's
`runs/.leg-state/$LEG/canary-bands.json`, written by calibration cells on the **provisioned** cluster (≥3
repeats of a read and a write probe cell; lo/hi from the observed ratio spread plus margin) — with no
calibration file the canary refuses loudly rather than invent a tolerance, because a guessed band can both
mask a real inconsistency and manufacture a false one. `wsi_agg_helper.py cache <run-dir>` is the
declared-vs-achieved cache reconciliation (**D13**).

**Cache state is reconciled, not trusted (D13):** a cell's declared `cache_state` must be matched by its
achieved evidence (the readers' recorded discard returns, drop_caches acknowledgments, the canary's own
check). Declared-without-evidence or declared-versus-evidence disagreement → the cell is **marked and never
quoted as its declared regime**. The check ships with the shared aggregation helper (tracker **D-4**).

---

## Run-to-run variance — the D18 policy

Cloud performance drifts, and the legs run days apart — so a cross-leg delta is a finding only once it clears
the noise. Identical on both legs (the policy is itself a held-constant input):

- **The stability-canary pair** (`sweep-stability-canary.sh`) runs at nine fixed points per leg —
  `run-leg.sh` steps `C0`–`C8` bracket the leg and interleave the major sweeps. Both cells are deliberately
  fixed configs; **their spread across the leg is the leg's empirical noise band.** A cross-leg delta is
  **quoted only where it clears both legs' bands.** (Band computation ships with the shared aggregation
  helper — tracker **D-4**.)
- **N=3 for headline cells.** The knee and pinned-peak cells are discovered per leg by each Tier-1, so the
  repeats cannot be pre-wired: **immediately after a pinned-peak / knee cell completes, re-invoke the same
  target with `REP=2`, then `REP=3`** (same env, same config — `record-run.sh` suffixes `-repN` and records
  the `rep` metadata field). Designated fixed headline cells get the same treatment. Aggregation reports
  **median with spread** where a config carries multiple reps; a single-shot cell quoted as a headline must
  say so.
- **Long cells** (hours-scale) are not repeated — their stability evidence is the **split-window check**:
  first-half vs second-half agreement computed from the already-recorded timeline, at zero added wallclock.

---

## How to run a sweep, unattended

A sweep is a driver in `scripts/` that loops parameters and calls `record-run.sh` per cell. Each cell is its
own run dir, so a single bad cell goes `INCOMPLETE` in `INDEX.md` without taking down the rest.

```bash
source env.sh                      # sets LEG, FS_MOUNT, S3_BUCKET, CONDA_ENVS_DIR, ...
LIB=<repo>/scripts
mkdir -p <repo>/runs/sweep-logs
"$LIB/sweep-stage1-seqw.sh" 2>&1 \
  | tee "<repo>/runs/sweep-logs/$(date -u +%F-%H%M)-$LEG-stage1-seqw.log"
```

**The sweep drivers take no *environment* arguments** — they read `FS_MOUNT` and `LEG`. But **several dispatch
on a positional target** (`tier1`, `all`, …) and exit 2 with a usage message when invoked bare, so for those the
target is part of the command; `run-leg.sh`'s plan carries the right target per step and its comment says which
and why. Check the driver's `usage:` line before invoking one by hand.

`record-run.sh` accepts an explicit `--fs`, and falls back to `$LEG` when it is absent, so a driver never has
to pass it. With neither set the wrapper refuses. Every driver also refuses to start without `FS_MOUNT` and
`LEG`.

**Tee even though you are in tmux** — the log survives even if tmux dies, and on an overnight run it is the
primary forensic record of what happened while nobody was watching.

**Four requirements before trusting a night to a chain:**

1. **Telemetry syncs to S3 during the run**, not only at the end — a crash at 4am must not lose the night.
2. **The canary aborts the chain** on failure.
3. **Each cell has a watchdog timeout** — a hung cell wastes both time and money.
4. **The chain resumes from checkpoint**, re-running only what is missing.

> **Mixed-backend sweeps: scope `LD_PRELOAD` per cell.** Set it on kvikIO cells, never on cuCIM cells — the ABI
> clash segfaults cuCIM's first read. Nearly every sweep here is mixed by construction.

---

## Substage closeout — mechanical, gates the next phase

**A completed substage is closed only when `scripts/verify-substage-closeout.sh <substage>` exits 0**, which
asserts with named failures: every cell OK in `INDEX.md` (forensically renamed dirs excluded) · the
substage's aggregate CSV exists and is **newer than its newest cell** · the stage roadmap carries a
**`**Leg <X> results` row inside that substage's section** (the numbers-into-the-roadmap cadence, checked
mechanically — that row prefix is the convention) · the consistency canary runs on every cell with no
NO_DATA · every cell's raw telemetry verifiably in S3. **No next phase launches until the previous phase's
substages are closeout-clean.** *Why a script:* the closeout lived as prose called "non-negotiable" across
three documents and still got skipped (Stage 3, 2026-08-17) — a trigger must be mechanical. Within an
unattended chain, steps get the mechanical half (canary + INDEX + S3) between steps; the full closeout —
which includes the human-authored results row — gates the next launch. **Extend the checker's table in the
same edit that adds a new substage**; an unknown substage is a refusal, not a skip.

---

## How to re-parse / re-aggregate without re-running

**Re-parse one run** — the parser is independent of the wrapper, so a parser fix or a new derived metric does
not need the benchmark re-run:

```bash
"$LIB/parse-results.py" <run-dir>/     # overwrites results.json in place; raw untouched
```

**Re-aggregate a sweep** — run the aggregator for that stage. Some self-locate the `runs/` tree; others take an
explicit glob and exit with a usage message without one. Which is which, and each one's arguments, are in
`SCRIPT-TRACKER.md`.

```bash
"$LIB/aggregate-stage2-properties.py" '<repo>/runs/*-'"$LEG"'-s2.0-*'
```

---

## Spot-checking a run mid-flight

Recorders stream to disk continuously, so anything under `<run-dir>/raw/` is inspectable live.

```bash
tail -f <run-dir>/cmd.log        # benchmark progress
tail -f <run-dir>/raw/*.csv      # live telemetry (per-filesystem file names)
```

`results.json` is only written at end-of-run; don't expect it mid-flight.

---

## What to do if a run fails

A run is marked `INCOMPLETE` in `INDEX.md` if the benchmark returned non-zero, **or** any required recording
stream produced fewer than two lines (header plus at least one data row), **or** — the ratified verdict
semantics (`STAGES.md` **D21**) — a stage ≥ 1 cell declared no `RECORD_CACHE_STATE` (write cells declare
`na-write-cell`; a deliberate non-axis declares an `na-*` value; stage 0 is exempt), **or** a cell declared
`RECORD_KVIKIO_CELL=1` and recorded no `path_accounting` split (**D8**: a configuration flag is not proof of
path). **Missing cost inputs warn but do not flip the verdict** — cost is re-derivable arithmetic from the
measured wallclock plus a dated price, while a missing cache regime or path proof cannot be repaired after
the fact. Separately, `run-leg.sh` **refuses to start a leg** whose environment contract exists but has no
matching `contract-verified` marker (written by `env-contract.py verify` on PASS, sha-bound to the contract
file).

1. **`<run-dir>/cmd.log`** — what did the benchmark say?
2. **`<run-dir>/raw/*.err`** — recorder-side errors; each recorder writes its own.
3. **`<run-dir>/raw/parse.log`** — parser stderr if `results.json` is missing.
4. **Capacity** — free space on the filesystem under test *and* on the run-dir target.
5. **Filesystem state** — health, alerts, and whether the provisioned configuration still matches the
   environment contract. A configuration drift is a benchmark change, not a footnote.
6. **cuFile path accounting** on a kvikIO cell — did it silently fall back?

**Never delete a run directory, however broken.** Re-running costs hours-to-days and real money. To exclude a
known-bad dir from an aggregator glob, **forensic-rename it** with a `-FAILED-<reason>` suffix — that preserves
the evidence while dropping it from the `<UTC>-<fs>-s<stage>-*` pattern. Diagnose before renaming; the failure
data is itself useful.

**Recovering a sweep:** because each cell is its own run dir, re-running the driver re-does only what is
needed.

> **⚠ Silent-skip hazards.** Three drivers reuse existing output *without failing loud*: the raw-TIFF converter
> (4.D), the 6.A extractor (needs **cleanup-before-cell**, or every cell after the first short-circuits and
> reports a plausible-looking meaningless number), and 6.A Tier 2's chunked conversion (an aborted run leaves
> chunks that get reused). **Verify cleanup between runs in all three.** These fail quietly, which is the
> dangerous kind.

---

## Cross-leg integrity gates

Several artifacts are **storage-independent by construction**, which makes them free integrity checks that the
two legs really did process identical inputs. A divergence is **fail-loud and invalidates downstream
comparison** — it means different bytes, a truncated hydration, or a different code version, none of which is
visible in the throughput data.

| Artifact | Check (fingerprint definition: **D19**) | Gate before |
|---|---|---|
| Dataset bytes | SHA-256 over the sorted (relpath, size, md5-TCGA / size-only-CAM16) list + counts — the 1.7 verifier's data, re-emitted comparably | Anything |
| 3.0 coords | Per slide: coord count + SHA-256 of the raw coords **array contents** (not the HDF5 container) | Stage 4 of the second leg |
| 4.D raw-TIFF | Per slide: output byte count + tile-grid dimensions | Stage 4.C |
| 6.A features | Per (model, dataset): file count, per-slide tile count, tensor shape + dtype — never tensor values (GPU reduction order breaks bitwise equality) | 6.B.3 and 7.3 |

Fingerprints are captured into `runs/.leg-state/<leg>/fingerprints/<class>.json` (git-tracked, so the
second leg compares against the first's committed capture) by `fingerprint.py capture <class>`;
`fingerprint.py compare` exits non-zero on any mismatch. All four classes are built and captured on Leg A.

---

## Recording principles (from `../CLAUDE.md` and `../PROJECT-THESIS.md` §7)

- **"If it isn't recorded, it didn't happen."** Under-recording is a recording failure, and over-capture is
  cheap next to a re-run.
- **Multiple sources, pre/during/post.** App-level + the filesystem's own telemetry + the wire counters for the
  path in use. Discrepancies are data, not noise.
- **Never quote a throughput, latency or IOPS number from a source the filesystem in use bypasses.** This is
  the easiest way to publish a confidently wrong figure.
- **Verify the capture before trusting the run.** `INDEX.md` flags `INCOMPLETE` — investigate before declaring
  success. An empty source means fix the infrastructure and re-run.
- **Cold vs warm is an axis, recorded as achieved, not asserted** (**D13**).
