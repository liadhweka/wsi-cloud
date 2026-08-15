---
name: cloud-session-open-items
description: "The running work list: everything still to resolve before the first measured cell, and everything to watch during benchmarking. Add an item in the same edit that surfaces it; DELETE it when done."
metadata: 
  node_type: memory
  type: project
  originSessionId: 7c762301-b9e5-4cf9-aa77-70e924a540c2
  modified: 2026-08-15T18:38:56.633Z
---

Unresolved items collect **here**, not only in the doc that surfaced them — a memory loads every session; a
doc has to be found.

**This file holds only OPEN items.** When something is done, delete it — the completion record belongs in the
relevant doc, and git holds this file's history. *Why:* a fresh session reads this to know what to **do**, and
an item left listed after completion gets redone.

**Deferred engineering is not listed here.** It lives in `docs/SCRIPT-TRACKER.md` § "Still deferred",
which holds the scope and the reason each needs the real environment. Cite the `D-n` id.

---

## A. Resolve before the first measured cell

These change what the numbers mean, so resolving them after cells have run means re-running cells.

1. **Sub-second cells vs 1 Hz recorders.** High-concurrency Stage 2/3 cells finish in under a second, so
   filesystem-side recorders capture 1–3 samples and any sustained mean is ill-defined — and both legs would
   lose filesystem-side evidence exactly where the metadata architectures differ most. *Recommendation:* raise
   the poll rate for short cells, applied identically to both legs. Detail: `docs/Stage-2-Cataloging.md`.
2. **Does WEKA-on-AWS do true GDS?** Decides whether the GPU-direct matrix is 2×2+1 or a full 2×3. Resolve
   **empirically** — `gdscheck -p` plus a recorded canary cell — not from documentation, which disagrees with
   the transport analysis. Detail: `docs/STAGES.md` **D8**.
3. **Derive each filesystem's consistency relation.** The canary cannot run without it and it must never be
   ported between legs: WEKA from the actual EC scheme, Lustre from the actual stripe layout. Detail:
   `docs/STAGES.md` **D12**. *Empirical anchors from the 2026-08-15 Stage-0 probes (5+2 cluster):* write
   wire/app ≈ **1.455** (≈ 7/5 EC + ~4% protocol, measured at `L6 Sent_client_sum` vs app 5.2 GB/s), read
   wire/app ≈ **1.034**. Re-derive + re-calibrate on the post-switch cluster before the canary bands are set
   (same 5+2 scheme expected → ratios should reproduce; a shift is itself a finding).
4. **Determine the Lustre LND actually in use** (kernel TCP vs the EFA provider). This decides which client
   counters are primary versus diagnostic — get it wrong and every Lustre number cites a bypassed source.
5. **Cache-clearing mechanism per filesystem.** How you reach a cold state differs per side and includes a
   server-side component we do not control on managed FSx. Determine what is achievable, record it, and state
   the residual uncertainty rather than labelling a cell cold on faith. **The client-side half is settled:
   `vm.drop_caches=3`, not `1` — dentries and inodes are the caches that matter for a metadata workload, and a
   warm dentry cache serves `open()` client-side on both legs alike.** What is still open is the *server-side*
   half, per filesystem. Detail: `docs/STAGES.md` **D13**, `docs/RUNBOOK.md` (what each step clears).
6. ⚠ **Four read sweeps need driver changes before they are run — the decisions are made, the drivers lag.**
   Docs are now the correct spec; `scripts/` was out of scope for the docs pass, so every one of these is
   still unimplemented. **The 1.0b/1.0d item is the most urgent thing on this list**, because those cells are
   the denominator for every "% of ceiling" in the project.
   - **1.0b / 1.0d** (`sweep-stage1-{seqr,randr}.sh`): today `--size=4G --numjobs=N --unlink=1` with a layout
     phase, so the working set is 4 GiB×N and **every cell reads bytes written seconds earlier** — plausibly
     the write cache. Size the working set past the larger server-side cache, stage data ahead of the timed
     window, stop unlinking between cells, reverse or randomise cell order, and add one cold reference cell.
   - **1.6** (`sweep-stage1-mixed.sh`): exemption granted on stated grounds (`--direct=1` plus deliberate
     steady state), but it needs **one cold reference cell** to evidence it, and cell order de-ordered.
   - **2.0** (`sweep-stage2-properties.sh`): gains an explicit cold/warm axis, **8 cells → 16 per leg**, with
     `vm.drop_caches=3` and randomised order. No cache handling exists in the driver today.
   - **4.B** (`sweep-stage4b-tilesread.sh`): `TIER3_DROP_CACHES=0` hardwires the only cold mechanism off, and
     the header justifies it with a *previous host's* RAM. 4.B is where the working-set-vs-cache crossover has
     to be characterised per filesystem. Re-derive and re-enable.
   **Do the cell de-ordering as part of the staging rework, not separately** — it is one line per driver, but
   the same loops are restructured for staging, and touching them twice invites a mistake.
   **Sizes are parameters, never literals:** the corpus size is a function of the provisioned server-side
   cache, so it is read from configuration set at provisioning, not written into the driver.
   Detail: `docs/Stage-1-Ingest.md`, `docs/Stage-2-Cataloging.md`, `docs/Stage-4-Patching.md`, **D13**.
6b. **nvidia-fs I/O counters — enablement DONE (Leg-A instance, 2026-08-15: enabled live, persisted in
    `/etc/modprobe.d/nvidia-fs-stats.conf`, and the bootstrap now enables them at build). What remains is the
    D-6 canary half:** the pre-cell canary must require them **enabled and non-zero on a known-good read**
    before any cuFile cell counts — a present-but-all-zero split reads as "no GPU-direct traffic" rather than
    "accounting was off" and would corrupt the **D8** determination. `Active Shadow-Buffer (MiB)` is the
    compat-mode bounce signal. Stats format on this stack: `NVFS statistics(ver: 4.0)`, driver 2.29.4.
6c. **GDS stack version skew — verify before any kvikIO cell counts (D-10 / Tier-2 row 7).** This instance
    runs libcufile **1.14.1** (CUDA 12.9 toolkit) against nvidia-fs **2.29.4** (driver 595.71.05; the module
    self-reports GDS 1.18.0.62). `gdscheck -p` runs clean and reports compat mode, but "matched" must be
    verified (docs + the D-6 known-good-read showing the counters move), not assumed from a clean probe.
    Matters more on Leg B, where GDS is expected to engage for real.
7. **Size the 6.B synthetic corpus using BOTH filesystems' cache sizes — inputs fetched; freeze after the
   backend switch is real.** The corpus must exceed the client page cache (768 GiB) **plus** the larger
   server-side cache. Fetched 2026-08-15: FSx PERSISTENT-1000 carries **27.3 GiB RAM cache/TiB**
   (docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html) → ≈721 GiB at the proposed 26.4 TiB; after
   the ratified switch to 8 × i8ge.6xlarge the WEKA backends' RAM is **1536 GiB (8 × 192 GiB)** and becomes
   the larger side. Working sizes: **6.B corpus 3.0 TiB** (> 768+1536 = 2304 GiB, ~30% margin);
   **Stage-1.0 read corpus 2.0 TiB** (> 1536 GiB). Freeze both — one identical definition per corpus for
   both legs — once the new cluster's actual RAM is confirmed at spin-up. Detail:
   `docs/Stage-6-Feature-Extraction.md`.
8. **Confirm real per-slide tile counts from the actual 3.0 coords** before sizing the 6.B.1 file-size grid or
   committing 6.A Tier 2 wallclock — both currently rest on magnification arithmetic, not measurement.
9. **Counter-semantics check for cross-leg `ops/s`.** Until counter semantics are verified equivalent and that
   verification recorded, app-level metrics are the cross-leg-comparable ones and filesystem-reported ops/s
   is within-leg only. Detail: `docs/Stage-2-Cataloging.md`.
10. **Core accounting — WEKA value SET (2026-08-15): `FS_CLIENT_RESERVED_CORES="1-4,49-52"` in env.sh**
    (4 DPDK FRONTENDs pinned to vCPUs 1–4 per the client's own report, plus their HT siblings per the D15
    sibling rule; ratified). Remaining: the Lustre leg sets `none`, and the reservation is reported as part
    of WEKA's cost at writing time. Detail: `docs/STAGES.md` **D15**.
11. **Record both sides' provisioned configuration into the environment contract** — WEKA: backend type and
    count, capacity, EC scheme, client networking mode. FSx: tier, capacity, provisioned metadata IOPS, EFA
    state. Without these the fairness basis is unverifiable after the fact. Detail: `docs/STAGES.md` **D6/D7**.
12. **Capacity headroom — recomputed 2026-08-15 for the ratified 6xlarge switch; fits everywhere.** Worst
    case: datasets 1.75 TiB + full-cohort raw-TIFF ~6.4 TiB (if D-28 retains it) + Stage-1.0 corpus 2.0 TiB
    + 6.B corpus 3.0 TiB + features/heatmaps/scratch ≲ 1 TiB ≈ **14.2 TiB** — fits FSx at 26.4 TiB and fits
    the new WEKA cluster trivially (8 × i8ge.6xlarge carries ~109 TiB raw). Corpus sizes stay parameters
    read from env, never literals (variables defined during the read-driver rework). Delete once both sizes
    are frozen (item 7) and recorded in the stage roadmaps.
13. **Two remainders from the worker measurement-correctness pass.** The seven bugs themselves are **fixed**
    (see `docs/SCRIPT-TRACKER.md` for what each script now does); these two were deliberately left because
    each needs something that does not exist yet:
    - **`aggregate-stage4c-kvikio.py`'s `gds_engaged` is `"unknown"`.** The fabricated column — derived from
      the run-dir name, i.e. from the *requested* config — is gone, and `cufile_mode_requested` now carries
      that honestly. Populating the *achieved* path needs cuFile's own byte accounting (**D-6**). Until then
      no cell can evidence which path it took, so **the GPU-direct matrix cannot be interpreted** and the
      **D8** WEKA-GDS question stays unanswered.
    - **`read-after-write-stage7.py`'s 10 ms poll.** The interval is now reported as the visibility-latency
      resolution floor, so quantisation is visible rather than silent. Whether to *tighten* it is a tuning
      judgment against CPU cost and is unmade. Verified on the build machine: measured latencies fell
      **below** the floor, so at 10 ms this cell is sampling poll phase, not visibility — decide the interval
      before 7.4.b runs, or its headline number means nothing.
13b. **6.C's MIL workload can vanish from the cell without failing it.**
    `orchestrate-concurrent-stage6c.sh` resolves features from `MIL_FEATURES_TAG`; if that dir has under 10
    `.pt` files it falls back to the `brca50` subset, and if *that* is also thin it touches `.mil-skipped` and
    `return 0`. So a 6.C cell can complete having run **three of its four workloads**, or having run MIL
    against a *different corpus than configured* — and 6.C exists precisely to measure four workloads
    contending. Both outcomes are recorded only in a log file. **Decide the failure semantics**: the
    substituted-corpus path and the skipped path both need to fail the cell, or at minimum surface into
    `results.json` so the aggregator can exclude it. Left unfixed because it needs the orchestrator's error
    contract settled — the same question as B.9 (drivers swallow failures), so decide them together.
    `EXTRACT_GPUS` had the same shape and **is now guarded** (fails loud on a GPU index this instance does not
    have); this one is the remaining instance.
13c. ⚠ **A pre-cloud sweep found 51 unambiguous defects across `scripts/`; most are fixed, and what remains
    is registered as `D-25`…`D-32` in `docs/SCRIPT-TRACKER.md`.** Four of the eight gate a first cell and are
    the ones to look at first:
    - **`D-27`** — `train-resnet50-stage5.py` and `extract-features-foundation-stage6.py` hardcode
      `compat_mode="off"` from a *previous environment's* result and expose no CLI knob, so **the
      mode-controlled paired cell `docs/STAGES.md` specifies for 5.A and 6.A cannot be run**, and a leg where
      GDS is unachievable cannot request compat. Adding the flag needs no target value.
    - **`D-29`** — **D13** cache state and **D15** core accounting have *no field to be recorded into*, so
      both requirements are unmeetable by any cell as things stand.
    - **`D-30`** — `record-run.sh` stamps a cell `OK` while it is missing cost inputs, cache state, core
      accounting and cuFile path proof. Decide with **D-21** phase 2.
    - **`D-28`** — Stage 7.2 is configured to read full-cohort raw-TIFF that **no step in the leg plan
      produces**. Either 4.D retains the full cohort (order ~7 TB, a capacity input) or 7.2 runs the subset.
14. **Decide the cuCIM tile-cache policy.** Every cuCIM path sets a 512 MiB per-process cache that is not
    swept, not recorded, and absent from the cold/warm discussion — yet sits in front of the filesystem on
    every cuCIM cell. Record it per cell or make it swept, and apply the same choice to both legs.
15. **Re-derive `CHUNK_SIZE` for 6.A Tier 2 from this leg's provisioned capacity.** Both Tier-2 orchestrators
    default to 200, sized against a different environment. **This decides whether Tier 2 fits on disk at all**
    — too large and the conversion fails mid-cohort after hours; too small and it wastes wallclock. Use the
    **same** value on both legs, since chunk size changes the write/delete cadence the filesystem sees.
17. **[USER] Should `env.sh --check` hard-fail on the running leg's canary field?** `WEKA_EC_SCHEME` and
    `LUSTRE_STRIPE_LAYOUT` are warn-only, yet the canary relation for the running leg cannot be derived
    without whichever applies (**D12**) — so a leg can start with `--check` passing and no consistency check
    possible. A leg-conditional requirement would catch it but changes *when* the gate blocks: it would fail
    before the filesystem is provisioned. *Recommend* a separate `--check-ready` mode meaning "ready to
    measure", distinct from "configured" — the two questions are genuinely different.
18. **Cost + ceiling inputs — WRITTEN into env.sh 2026-08-15 (ratified). Two remainders:** (a) the software
    basis is **raw NVMe** ($1,000/TB/12mo × 40 TB = 4.566/hr) per the ratification; **the human checks the
    raw-vs-usable metering basis with WEKA Sales** — the usable-capacity alternative (22.49 TB → 2.567/hr)
    is recorded in env.sh's comment; prices are backfillable as long as methodology/sources/dates stay
    recorded (all are). (b) **Re-derive `FS_USD_PER_HR`, `SOFTWARE_USD_PER_HR`, `WEKA_BACKEND_RAM_TOTAL`,
    `WEKA_BACKEND_TYPE` and capacity after the ratified backend switch** (item 22): 8 × i8ge.6xlarge →
    infra 8 × 3.3516 = **26.8128/hr**, raw NVMe 120 TB → software **13.699/hr** (fewer-drives-per-host, if
    the terraform module supports it, shrinks this). Leg B's documented per-client caps (2026-08-15,
    performance.html): EFA 700 Gbps, EFA+GDS 1200 Gbps — set at Leg-B spin-up.
19. **Is a synthetic *metadata* ceiling worth adding to Stage 1?** Decided for now: **no**, and Stage 2 reports
    no ceiling-relative figure at all — 1.0a–d are all data-path, so there is no denominator that would mean
    "% of this filesystem's metadata capability", and 1.0d's random-read IOPS would be a mismatched one. Stage 2
    normalises against its own lowest-concurrency cell instead. **Left open deliberately:** a maxed FSx has
    *user-provisioned* metadata IOPS, so a synthetic metadata ceiling (`mdtest`, or fio's `filestat` /
    `filecreate` engines, as a new 1.0e) is the only way to show whether 2.0 reached what was paid for. Revisit
    if that claim needs making. **The tooling cost is real, which is why the answer is "not now":** `mdtest` is
    not installed, and `fio` 3.35 lists no `filestat`/`filecreate` engine — so this means introducing a new
    tool and validating it on **both** filesystems before any number from it is quotable.
    Detail: `docs/Stage-2-Cataloging.md`.
20. **Two consumer-side inputs the 6.B canary and the 7.4.b writer now depend on.** Both criteria are decided
    and written down, but each needs a measured value from the same leg before the cell it guards can run:
    - 6.B.2's file-load p99 check is judged against **6.B.3's measured per-step time** on that leg (fallback:
      6.B.2's own lowest-concurrency cell). The stated sequence puts 6.B.3 first, so confirm that holds.
    - 7.4.b's synthetic artifact is **sized and tiled from a measured 7.3 output** on that leg, so 7.3 must
      land first. Content stays synthetic — visibility depends on size, tiling and fsync-then-rename, not
      pixels. Detail: `docs/Stage-6-Feature-Extraction.md`, `docs/Stage-7-Clinical-Inference-Deployment.md`.
21. **The blocker gate is now three tiers, and two of them gate cells that used to precede it.**
    `prompts/handoff-cloud.md`: **Tier 0** transport, before *any* cell including the throwaway (**CLOSED on
    Leg A, 2026-08-15** — DPDK evidenced from the client's own report; run-leg.sh refusal verified in code);
    **Tier 1** recording adapters, consistency relation, worker-correctness bugs, the 1.7 driver, and the
    Stage-1.0 cache regime — all before hydration and the baseline, because those produce kept numbers;
    **Tier 2** the rest, before the main sweep. Reported at the baseline greenlight *and* before the leg
    starts. **What is still open is closing the rows**, not the ordering. **Row-1 status (2026-08-15): its
    closure criterion is met** — the Stage-0 cell `2026-08-15-171240-weka-s0-smoke-recording-proof` records
    the WEKA-leg primaries and INDEX.md says OK, with client-summed FS-side vs fio app-level agreeing within
    ~5%. The D-4 remainder (shared aggregation helper; Lustre half) stays open in the tracker and must land
    before the first sweep's numbers are read.
22. **Backend switch to 8 × i8ge.6xlarge — RATIFIED in principle 2026-08-15, then CHALLENGED on cost and
    SETTLED EMPIRICALLY the same day (Stage-0 probes `2026-08-15-182302-…-probe-clientcap-seqw…` and
    `…-182852-…-probe-clientcap-seqr…`, diagnostic, never quote):** the 4-FE-core client sustained
    **11.6 GB/s reads for 8 min flat** (FE CPU ~68% — headroom left) against backend-RAM-resident data —
    ≥40% above the 8×2xlarge backends' 67.2 Gbps (8.4 GB/s) sustained aggregate, only possible on burst
    credits; writes ran 5.2 GB/s app × **1.455 measured wire amplification** (≈ 5+2 EC's 7/5 + ~4% protocol;
    read relation measured 1.034) = wire already grazing baseline. So the ceiling cells WOULD measure the
    backend fabric and its credit state; the switch is confirmed necessary, execution pending, timing =
    after this build session, before hydration/baseline. The human runs the destroy/switch/reapply; treat it as a standard
    TEARDOWN-AND-REBUILD cycle (handoff edit → backup → commit+push → preflight → destroy → apply), since
    env.sh and the mount die with it and Tier 0 must be re-evidenced against the NEW cluster. On the rebuilt
    environment: (a) re-verify transport (DPDK) from the client's own report; (b) re-derive
    `WEKA_BACKEND_TYPE/RAM_TOTAL`, capacity, EC scheme, `FS_CLIENT_RESERVED_CORES`, `FS_USD_PER_HR`,
    `SOFTWARE_USD_PER_HR` (item 18); (c) **sweep every stale `i8ge.2xlarge` reference out of docs, env.sh
    and memory** (human asked explicitly); (d) keep protection 5+2 + hot spare identical unless deliberately
    changed (the D-5 relation derives from the actual scheme either way). ⚠ Surfaced consequences: raw NVMe
    becomes 120 TB → software 13.699/hr at the raw basis (ask whether the terraform module can give WEKA one
    drive per host — 60 TB → 6.85/hr — before locking); backend RAM 1536 GiB → corpus sizes per item 7.
    Frontend stays one g6e.24xlarge with 4 FE cores unless the human ratifies otherwise (thesis §9:
    single-client is the unit of analysis; the FE-core count is part of WEKA's "realistic production config"
    and its cost accounting).
23. **Full dataset prefetch to S3 is RUNNING (relaunched 2026-08-15 at PREFETCH_PARALLEL=32 after PAR=8
    measured WAN-bound at ~13 MB/s aggregate; now ~80 MB/s; log
    `runs/sweep-logs/2026-08-15-*-prefetch-full-par32.log`).** Expected: 1133 TCGA files / 1079 GiB + 1365
    CAMELYON16 objects / 710 GiB. On completion: verify object counts + total bytes against both manifests,
    confirm `datasets/.prefetch-complete-full` exists (the patched script refuses it on any failure), then
    delete this item. 1.7 hydration cannot run before this finishes — and hydration also waits for the
    item-22 backend switch (a cluster destroy wipes the mount, so hydrate only the NEW cluster).

## B. Watch during benchmarking

0. **D18 repeats are per-leg discoveries — do not miss them.** Immediately after each Tier-1 identifies the
   knee / pinned-peak cell, re-invoke that exact target with `REP=2` then `REP=3` (same env). The canary pair
   is wired into `run-leg.sh` (`C0`–`C8`); the knee repeats are NOT wireable in advance and exist only if run.
   Detail: `docs/RUNBOOK.md` "Run-to-run variance", `docs/STAGES.md` **D18**.

1. **Instance revisit trigger.** If Leg A's synthetic ceiling pins at line rate across block sizes **and** the
   `num_workers` sweep saturates on CPU cores rather than storage, the instance is measuring itself rather
   than the filesystems — move up before Leg B. Pre-committed so the call is not made later under sunk cost.
   Detail: `docs/STAGES.md` **D10**.
2. **Coord-equivalence gate between legs.** Completeness and per-slide tile counts are storage-independent, so
   any cross-leg divergence proves the legs did not process identical inputs. **Fail loud; invalidates
   downstream comparison.** Detail: `docs/Stage-3-Tissue-Detection.md`.
3. **Mixed-workload canary bands** must be wider than single-direction bands **and** re-derived per filesystem.
4. **Delete any stale raw-TIFF before re-converting.** The 4.D driver skips existing non-empty output, so a
   stale artifact at the wrong magnification is silently kept and read as current. Its byte counts and
   tile-grid dimensions must also match between legs.
5. **Scope `LD_PRELOAD` per cell in every mixed kvikIO/cuCIM sweep** — nearly every sweep here is mixed.
   Symptom if forgotten: clean init, then a segfault on the first cuCIM read, easily misdiagnosed as a
   multiprocessing bug.
6. **Three silent-skip hazards** where existing output is reused without failing loud: the 4.D converter, the
   6.A extractor (needs cleanup-before-cell, or every cell after the first short-circuits and reports a
   plausible meaningless number), and 6.A Tier 2's chunked conversion (an aborted run leaves reusable chunks).
7. **6.D composition hygiene** — every component wallclock must come from the **same leg's** run dirs. Mixing
   legs yields a number describing neither filesystem, and the aggregators glob run dirs, so it is easy to do
   by accident.
8. **Any per-model adjustment must be applied identically on both legs** and noted in the run README. An
   adjustment made on one leg only becomes a filesystem difference in the results.
9. **`run-leg.sh`'s abort-on-failure guard only sees the driver's exit status.** The drivers run under
   `set -uo pipefail` without `-e` and pipe each `record-run.sh` call into `tee`, so a failed cell leaves the
   driver at exit 0 and the step is marked done. Stage 5 was fixed; **the other sweeps still swallow
   failures.** *Recommendation:* attempt every cell, then exit non-zero if any failed — which also satisfies
   `docs/RUNBOOK.md`'s design that a bad cell goes `INCOMPLETE` without taking down the sweep.
10. **UNI2-h results stay internal-only** — don't strip the tags in refactors; filter those rows before
   anything leaves the building. More important here than in an internal study, since a competitive comparison
   is likelier to be externalised. Detail: `[[uni2h-conditional-use-status]]`.
11. **Next-teardown verification.** First real teardown must run `sync-to-s3.sh`'s FIRST-RUN PROCEDURE
   (its header, steps 1-7 — the archive-vs-mirror semantics test is the one that matters), then remove its
   UNVERIFIED banner. (The SSM deploy-key silent-install check passed on the 2026-08-15 boot: "fixed deploy
   key installed from SSM".) Tracked cosmetic, no action: a mamba "error opening log file: Permission denied"
   warn at the env-build log tail — envs build and smoke-pass regardless; investigate only if impact appears.
