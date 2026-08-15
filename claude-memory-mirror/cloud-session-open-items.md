---
name: cloud-session-open-items
description: "The running work list: everything still to resolve before the first measured cell, and everything to watch during benchmarking. Add an item in the same edit that surfaces it; DELETE it when done."
metadata: 
  node_type: memory
  type: project
  originSessionId: 7c762301-b9e5-4cf9-aa77-70e924a540c2
  modified: 2026-08-10T17:57:07.502Z
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
   `docs/STAGES.md` **D12**.
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
6b. ⚠ **nvidia-fs I/O counters are OFF by default, and the D-6 gate row can pass all-zeros because of it.**
    On a host with the GDS stack loaded, `/proc/driver/nvidia-fs/stats` reports `IO stats: Disabled, peer IO
    stats: Disabled` with `rw_stats_enabled=0` and `peer_stats_enabled=0`. A kvikIO cell run that way records a
    GPU-direct-vs-bounced split that is **present and entirely zero** — which reads as *"no GPU-direct
    traffic"* rather than *"accounting was off"*, and would corrupt the **D8** WEKA-GDS determination. Enable
    the counters at instance build (the bootstrap does not yet do it), and have the pre-cell canary require them **enabled and non-zero on a known-good
    read** before any cuFile cell counts. `Active Shadow-Buffer (MiB)` is the compat-mode bounce signal the
    split depends on. Format is version-stamped (`NVFS statistics(ver: …)`), so re-verify on the cloud stack.
7. **Size the 6.B synthetic corpus using BOTH filesystems' cache sizes.** There are two caches to exceed, not
   one: the client page cache **plus** each filesystem's own server-side cache, which differ per side. A corpus
   genuinely cold on one and partly warm on the other produces a **cache-size artifact that looks like a
   filesystem difference.** *This is the one place a Leg-A parameter must be chosen using Leg-B information* —
   compute FSx's cache size in advance and generate **one identical corpus definition** for both legs.
   *Timing:* 6.B.1 sits late in Leg A; what is needed at spin-up is only **recording the WEKA backends'
   aggregate RAM**, the sole path by which this could force a larger corpus and affect capacity sizing.
   Detail: `docs/Stage-6-Feature-Extraction.md`.
8. **Confirm real per-slide tile counts from the actual 3.0 coords** before sizing the 6.B.1 file-size grid or
   committing 6.A Tier 2 wallclock — both currently rest on magnification arithmetic, not measurement.
9. **Counter-semantics check for cross-leg `ops/s`.** Until counter semantics are verified equivalent and that
   verification recorded, app-level metrics are the cross-leg-comparable ones and filesystem-reported ops/s
   is within-leg only. Detail: `docs/Stage-2-Cataloging.md`.
10. **Core accounting — values only; the mechanism is built.** `record-run.sh` records
    `cores_total/reserved/available` from `FS_CLIENT_RESERVED_CORES`, and every CPU aggregator excludes the
    recorded set per run, refusing null. Remaining: measure the WEKA client's reserved core **list** on the
    real instance (the client's own report), set it in `env.sh`, confirm the Lustre leg sets `none`, and
    report the reservation as part of WEKA's cost. Detail: `docs/STAGES.md` **D15**.
11. **Record both sides' provisioned configuration into the environment contract** — WEKA: backend type and
    count, capacity, EC scheme, client networking mode. FSx: tier, capacity, provisioned metadata IOPS, EFA
    state. Without these the fairness basis is unverifiable after the fact. Detail: `docs/STAGES.md` **D6/D7**.
12. **Confirm capacity headroom on both filesystems before committing — three retained corpora, not one.**
    (a) raw-TIFF, order ~7 TB at full cohort (before 4.D); (b) the **Stage-1.0 read corpus** and (c) the
    **6.B synthetic corpus** — both of which must exceed **the larger of the two server-side caches** to read
    cold (**D13**) and are retained rather than deleted per cell, so both are capacity inputs with a
    cache-derived floor. On FSx capacity is simultaneously a performance knob, so raising it to fit them
    changes what is measured (**D7**). Compute (b) and (c) from the fetched cache figures at provisioning and
    check the total against the planned capacity. Detail: `docs/cloud-setup/SPINUP-CHECKLIST.md` item 12.
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
16. **Verify the cuCIM install path on the cloud stack (conda vs pip).** pip wheels have crashed with a
    libstdc++ ABI mismatch inside `read_region()` where the RAPIDS conda build does not.
17. **[USER] Should `env.sh --check` hard-fail on the running leg's canary field?** `WEKA_EC_SCHEME` and
    `LUSTRE_STRIPE_LAYOUT` are warn-only, yet the canary relation for the running leg cannot be derived
    without whichever applies (**D12**) — so a leg can start with `--check` passing and no consistency check
    possible. A leg-conditional requirement would catch it but changes *when* the gate blocks: it would fail
    before the filesystem is provisioned. *Recommend* a separate `--check-ready` mode meaning "ready to
    measure", distinct from "configured" — the two questions are genuinely different.
18. **[USER] WEKA license cost in the price claim.** **Settled for now: every cost figure is labelled
    infrastructure-only, excluding storage-software licensing** — so the figure is publishable without being
    misleading. What stays open is whether to *price the licence in* before anything is externalised; "we're
    cheaper" with it excluded is the most attackable number in the deliverable, and the label mitigates that
    rather than removing it. Detail: `docs/STAGES.md` **D7**, `docs/RUNBOOK.md` (where the formula lives).
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
    `prompts/handoff-cloud.md`: **Tier 0** transport, before *any* cell including the throwaway; **Tier 1**
    recording adapters, consistency relation, worker-correctness bugs, the 1.7 driver, and the Stage-1.0 cache
    regime — all before hydration and the baseline, because those produce kept numbers; **Tier 2** the rest,
    before the main sweep. Reported at the baseline greenlight *and* before the leg starts. **What is still open is closing the
    rows**, not the ordering.

## B. Watch during benchmarking

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
11. **Next-rebuild verifications (raise at the next boot/teardown).** (a) SSM deploy key first
   silent install — the next boot log's step 11 must read "fixed deploy key installed from SSM"
   (fallback message means the SSM parameter or IAM is wrong). (b) First real teardown must run
   `sync-to-s3.sh`'s FIRST-RUN PROCEDURE (its header, steps 1-7 — the archive-vs-mirror semantics
   test is the one that matters), then remove its UNVERIFIED banner. Tracked cosmetic, no action:
   a mamba "error opening log file: Permission denied" warn at the env-build log tail — envs build
   and smoke-pass regardless; investigate only if impact ever appears.
