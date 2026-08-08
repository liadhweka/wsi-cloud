# `runs/` — benchmark run records (operational runbook)

Every benchmark run lands in its own subdirectory here. This file is the **operational runbook** — how to
run a cell, what gets recorded, where data lives, both canaries, and how to recover from failures.

For *what* each stage is, the per-leg plan, and the decision log **D1–D16**, see [`STAGES.md`](STAGES.md)
and the per-stage `Stage-<N>-*.md` roadmaps. For where everything lives, see
[`../FILESYSTEM-MAP.md`](FILESYSTEM-MAP.md). For project-wide rules — recording philosophy,
per-filesystem source adapters, durability, framing — see [`../CLAUDE.md`](../CLAUDE.md).

> **Nothing has run yet.** This tree is pristine: no run dirs, and `INDEX.md` is empty until the first cell.

---

## The one thing that makes this tree different

**The filesystem is a dimension of every run, not a separate tree** (**D11**). Every cell carries its
filesystem, which becomes a segment of the run-dir name **and** a field in `metadata.json` — the two places
the head-to-head is assembled from.

> ⏳ **The aggregators do not read it yet.** None of them opens `metadata.json` or emits an `fs` column, so
> a cross-filesystem CSV still has to be assembled by hand today. Teaching them to group on `fs` is part of
> the per-filesystem adapter work (**D-4**) — see `../SCRIPT-TRACKER.md`. The *data* is recorded correctly
> now; only the pivot is missing.

```
<UTC-timestamp>-<fs>-s<stage>-<workload>-<config>/
```

Scripts resolve the mount through **`$FS_MOUNT`** (`/mnt/weka` or `/mnt/lustre`) rather than hardcoding a
path — the filesystem is a parameter, never a fork in the code.

**This tree is self-locating** — mostly. `record-run.sh` derives its runs root from its own location on
disk, and **7 of the 14 aggregators** derive their `runs/` path from `__file__`: stages 4.C, 5, 6.A, 6.B, 6.C,
6.D and 7. The other seven (`aggregate-sweep.py` plus the stage 1.5, 1.6, 2.0, 3.0, 4.A and 4.B aggregators)
**take an explicit glob argument** and exit 2 with a usage message without one. Either way, run the copies
that live in this tree's `lib/`.

---

## Quick reference

```bash
LIB=<repo>/runs/lib

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

# Re-aggregate a sweep into its summary CSV (aggregators self-locate runs/ via __file__
# and pivot on the --fs dimension)
"$LIB/aggregate-stage4c-kvikio.py"

# Inspect what a run was for, without parsing JSON
cat <run-dir>/0_README.md
```

Every run dir has `0_README.md` at the top, auto-generated from the metadata — the first thing a future
reader should look at.

---

## Layout

```
runs/
  README.md           this runbook
  STAGES.md           --stage code map, per-leg plan, decision log D1–D16
  INDEX.md            one line per run, append-only — AUTO-GENERATED, never hand-edit
  Stage-<N>-*.md      per-stage roadmaps (the audit trail)
  lib/                the script library
    record-run.sh     wrapper: pre/during/post recording around a benchmark cmd
    parse-results.py  raw CSVs → results.json
    aggregate-*.py    per-stage sweep aggregators (7 self-locating, 7 take a glob;
                      the --fs pivot is deferred to D-4)
    sweep-*.sh        per-stage sweep drivers (loop params, call record-run.sh per cell)
    …                 readers, converters, trainers, orchestrators (see ../SCRIPT-TRACKER.md)
  manifests/          dataset manifests, incl. the 1073-slide cohort
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

**Small text stays in git; heavy raw goes to S3.** Both filesystem mounts and the instance's local NVMe are
**ephemeral** — they die with the instance and the cluster, and the instance is rebuilt between legs. See
`../CLAUDE.md` → Durability & backup, and run `./backup.sh` before any commit or teardown.

---

## What gets recorded — and why the source table differs per filesystem

Sources are **Primary** (headline numbers and ratio checks) or **Diagnostic** (context only). The split is
mandatory, and it is **not the same on both legs** (**D12**) — this is the single most important operational
difference in this project.

| Source | WEKA leg | Lustre leg |
|---|---|---|
| **App-level** (`cmd.log`, per-step / per-file CSVs) | **Primary** | **Primary** |
| **`weka stats realtime`** | **Primary** — throughput, latency, ops | n/a |
| **Wire counters for the DPDK data path** | **Primary** | n/a |
| **`/proc/fs/lustre` + `lctl get_param`** | n/a | **Primary** — per-OSC/MDC throughput, RPCs, latency |
| **CloudWatch per-OST/MDT metrics** | n/a | **Primary** — server-side view |
| **Client network counters** (`sar -n DEV`) | **Diagnostic** — DPDK bypasses the kernel network stack, so this is control-plane only | **PRIMARY — this IS the data path** (kernel LNet over TCP, or the EFA provider's counters when EFA-mounted; **determine which, don't assume**) |
| **cuFile path accounting** (`CUFILE_STATS`, nvidia-fs stats) | **Primary** on every kvikIO cell | **Primary** on every kvikIO cell |
| **`nvidia-smi`** | Primary from Stage 4 onward | same |
| **`sar -u`** over **application-available** cores | Primary where compute matters (**D15**) | same, but **the excluded core set differs** — WEKA reserves cores for DPDK, Lustre does not |
| **`sar -d`** per block device | Diagnostic — ~zero for a network filesystem; confirms we are not hitting local disk | same |
| **Memory stats** | Primary for Stage 6.B | same |
| **Pre/post snapshots** | Primary (state delta) | same |

> **The line to remember:** the client's network counters are **diagnostic on the WEKA leg and primary on
> the Lustre leg.** Using one leg's table for the other produces confidently wrong numbers.

---

## The two canaries — both mandatory, both mechanical

### 1. Pre-cell: environment + exclusivity check

Before every cell, confirm the environment still matches what the fairness contract specifies and that
nothing else is competing for the filesystem:

- **Provisioning matches the environment contract** — instance type, and on the storage side the values
  captured at spin-up (WEKA: backend type/count, capacity, EC scheme, client networking mode; FSx: tier,
  capacity, provisioned metadata IOPS, EFA state). A configuration change mid-leg **is** a benchmark
  change; if it happens, re-baseline and record it.
- **Filesystem health** — no degraded state, no alerts, expected server/target count present.
- **Exclusivity** — no other client or tenant actively moving data. A neighbour's I/O silently depresses our
  numbers, and post-hoc it is indistinguishable from a filesystem property.

**If exclusivity fails, do not start.** Wait, or record it in `--note` and treat the cell as contaminated.

### 2. Post-cell: cross-source consistency

After every cell, the Primary sources must tell a physically consistent story. **The expected relation is
derived per filesystem and never ported across** (**D12**):

- **WEKA** — erasure coding implies a specific wire-vs-app write amplification set by the EC scheme captured
  at provisioning; reads carry no equivalent amplification. Derive the ratio from the actual scheme.
- **Lustre** — data is striped across OSTs with no default erasure coding, so the relation follows from the
  **actual stripe layout** (`lfs getstripe`) plus any replication. Derive it from the layout in use, and
  record that layout per cell.

Additional rules that apply on both legs:

- **Only Primary sources participate in a ratio check.**
- **Mixed read+write cells need wider bands than single-direction cells**, because the wire carries read
  data plus write acknowledgements in one direction and requests plus payload in the other. At small block
  sizes the non-payload share is material. **Widen deliberately and say so** — never silently.
- **Very short cells under-sample.** A sub-second cell yields 1–3 samples at 1 Hz, and any sustained mean is
  ill-defined. That is a sampling limit, not a consistency failure — **record the judgement** rather than
  adjusting a band to make it pass.
- **kvikIO cells additionally require path accounting** — a cell without recorded GPU-direct-vs-bounced
  bytes is **incomplete**, because a configuration flag does not prove which path a read took.

**Disagreement beyond a stated tolerance means bugged infra → fix before continuing.** On an unattended
chain the canary **aborts the chain itself** rather than waiting to be noticed — otherwise a 3am failure
yields hours of contaminated cells that look fine.

---

## How to run a sweep, unattended

A sweep is a driver in `lib/` that loops parameters and calls `record-run.sh` per cell. Each cell is its own
run dir, so a single bad cell goes `INCOMPLETE` in `INDEX.md` without taking down the rest.

```bash
source cloud-setup/env.sh          # sets LEG, FS_MOUNT, S3_BUCKET, CONDA_ENVS_DIR, ...
LIB=<repo>/runs/lib
mkdir -p "$(dirname "$LIB")/sweep-logs"
"$LIB/sweep-stage1-seqw.sh" 2>&1 \
  | tee "$(dirname "$LIB")/sweep-logs/$(date -u +%F-%H%M)-$LEG-stage1-seqw.log"
```

**The sweep drivers take no arguments** — they read the environment. `record-run.sh` accepts an explicit
`--fs`, and falls back to `$LEG` when it is absent, so a driver never has to pass it. With neither set the
wrapper refuses. Every driver also refuses to start without `FS_MOUNT` and `LEG`.

**Tee even though you are in tmux** — the log survives even if tmux dies, and on an overnight run it is the
primary forensic record of what happened while nobody was watching.

**Four requirements before trusting a night to a chain** (all are cloud-session build items):

1. **Telemetry syncs to S3 during the run**, not only at the end — a crash at 4am must not lose the night.
2. **The canary aborts the chain** on failure.
3. **Each cell has a watchdog timeout** — a hung cell wastes both time and money.
4. **The chain resumes from checkpoint**, re-running only what is missing.

> **Mixed-backend sweeps: scope `LD_PRELOAD` per cell.** Set it on kvikIO cells, never on cuCIM cells — the
> ABI clash segfaults cuCIM's first read. Nearly every sweep here is mixed by construction.

---

## How to re-parse / re-aggregate without re-running

**Re-parse one run** — the parser is independent of the wrapper, so a parser fix or a new derived metric
does not need the benchmark re-run:

```bash
"$LIB/parse-results.py" <run-dir>/     # overwrites results.json in place; raw untouched
```

**Re-aggregate a sweep** — the seven self-locating aggregators (4.C, 5, 6.A, 6.B, 6.C, 6.D, 7) derive their
glob and output path from `__file__`, so running them from this tree walks this tree's run dirs and writes the
summary CSV here. The other seven — `aggregate-sweep.py` and the stage 1.5, 1.6, 2.0, 3.0, 4.A, 4.B
aggregators — take an explicit glob:

```bash
"$LIB/aggregate-stage2-properties.py" '<repo>/runs/*-'"$LEG"'-s2.0-*'
```

Neither group groups by filesystem yet (⏳ **D-4**).

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
stream produced fewer than two lines (header plus at least one data row).

1. **`<run-dir>/cmd.log`** — what did the benchmark say?
2. **`<run-dir>/raw/*.err`** — recorder-side errors; each recorder writes its own.
3. **`<run-dir>/raw/parse.log`** — parser stderr if `results.json` is missing.
4. **Capacity** — free space on the filesystem under test *and* on the run-dir target.
5. **Filesystem state** — health, alerts, and whether the provisioned configuration still matches the
   environment contract. A configuration drift is a benchmark change, not a footnote.
6. **cuFile path accounting** on a kvikIO cell — did it silently fall back?

**Do not delete a failed run dir before diagnosing.** The failure data is itself useful, and the project's
data-preservation rule forbids discarding it silently.

**Recovering a sweep:** because each cell is its own run dir, re-running the driver re-does only what is
needed. To exclude a known-bad dir from an aggregator glob, **forensic-rename it** with a
`-FAILED-<reason>` suffix rather than deleting — that preserves the evidence while dropping it from the
`<UTC>-<fs>-s<stage>-*` pattern.

> **⚠ Silent-skip hazards.** Three drivers reuse existing output *without failing loud*: the raw-TIFF
> converter (4.D), the 6.A extractor (needs **cleanup-before-cell**, or every cell after the first
> short-circuits and reports a plausible-looking meaningless number), and 6.A Tier 2's chunked conversion
> (an aborted run leaves chunks that get reused). **Verify cleanup between runs in all three.** These fail
> quietly, which is the dangerous kind.

---

## Cross-leg integrity gates

Several artifacts are **storage-independent by construction**, which makes them free integrity checks that
the two legs really did process identical inputs. A divergence is **fail-loud and invalidates downstream
comparison** — it means different bytes, a truncated hydration, or a different code version, none of which
is visible in the throughput data.

| Artifact | Check | Gate before |
|---|---|---|
| Dataset bytes | Byte-verified against the manifest after hydration (1.7) | Anything |
| 3.0 coords | Same slides producing coords; same per-slide tile counts | Stage 4 of the second leg |
| 4.D raw-TIFF | Same output byte counts and tile-grid dimensions | Stage 4.C |
| 6.A features | Same file count, per-slide tile count, tensor shapes | 6.B.3 and 7.3 |

---

## Recording principles (from `../CLAUDE.md`)

- **"If it isn't recorded, it didn't happen."** Under-recording is a recording failure.
- **Time series, not point estimates.** 1-second resolution minimum; aggregates derived from the timeline.
  Prefer an **idle-robust active-window mean** for throughput headlines — a storage-idle setup or model-load
  phase inside the recording window otherwise dilutes the number badly — and keep the naive full-window
  value alongside so both are visible.
- **Multiple sources, not one.** App-level + the filesystem's own telemetry + the wire counters for the path
  in use. Discrepancies are data, not noise.
- **Verify the recording before trusting the run.** `INDEX.md` flags `INCOMPLETE` — investigate before
  declaring success.
- **Cold vs warm is an axis, and it is recorded as achieved, not asserted** (**D13**).
