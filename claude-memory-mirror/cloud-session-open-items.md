---
name: cloud-session-open-items
description: "The running work list: everything still to resolve before the first measured cell, and everything to watch during benchmarking. Add an item in the same edit that surfaces it; DELETE it when done."
metadata: 
  node_type: memory
  type: project
  originSessionId: 7c762301-b9e5-4cf9-aa77-70e924a540c2
  modified: 2026-08-17T05:27:01.563Z
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

1. **Sub-second cells vs 1 Hz recorders — DECIDED (2026-08-16: raise the poll rate for short cells,
   ~10 Hz, identically on both legs; Stage-2 register). Remaining: the implementation (tracker `D-34`,
   `record-run.sh`'s recorder set) plus its does-the-rate-perturb verification — must land before the first
   Stage 2/3 cell.** Detail: `docs/Stage-2-Cataloging.md`.
2. **(resolved 2026-08-16 — WEKA-on-AWS does NOT do true GDS; cuFile path = compat/bounce, strict-GDS open
   refused. Evidence + consequences recorded in `docs/Stage-4-Patching.md` § GPU-direct design; determination
   run dirs `…-d8gds-*`. No mode-controlled paired cell on Leg A.)** Delete this entry once the Stage-4/5/6
   drivers' best-available-mode settings are confirmed against it at their gates.
3. **Consistency relation — WEKA bands CALIBRATED on the 6xlarge cluster (2026-08-16:
   `calibrate-canary-bands.sh`, 12 cells; anchors reproduce — write 1.456 vs 1.455, read 1.042 vs 1.034;
   4K derived separately: read 1.424, write 1.372 → smallbs_widening 1.366; `check` PASSES end-to-end).
   Remaining: (a) wire the check into the chain (D-7 canary-abort + prove-recording's pending assertion) —
   until then, run `wsi_agg_helper.py check` after every sweep by hand; (b) mixed-cell widening needs mixed
   calibration cells before 1.6 (B.3); (c) the Lustre relation from the actual stripe layout on Leg B (the
   helper refuses until built).** Detail: `docs/STAGES.md` **D12**, `docs/RUNBOOK.md`.
4. **Determine the Lustre LND actually in use** (kernel TCP vs the EFA provider). This decides which client
   counters are primary versus diagnostic — get it wrong and every Lustre number cites a bypassed source.
5. **Cache-clearing mechanism per filesystem.** How you reach a cold state differs per side and includes a
   server-side component we do not control on managed FSx. Determine what is achievable, record it, and state
   the residual uncertainty rather than labelling a cell cold on faith. **The client-side half is settled:
   `vm.drop_caches=3`, not `1` — dentries and inodes are the caches that matter for a metadata workload, and a
   warm dentry cache serves `open()` client-side on both legs alike.** What is still open is the *server-side*
   half, per filesystem. Detail: `docs/STAGES.md` **D13**, `docs/RUNBOOK.md` (what each step clears).
6b. **nvidia-fs accounting — enabled, persisted, and now VERIFIED UNDER LOAD on the rebuilt cluster
    (2026-08-16: the D8 determination cells exercised all three layers — shadow-buffer signal live on the
    cuFile-bounce read, nvidia-fs zero on the kvikio-posix read, `unknown-accounting-off` never fired).
    What remains of the D-6 canary half:** wire the pre-cuFile-cell requirement into the mechanical pre-cell
    canary (with D-7) — on THIS leg the known-good signature is *bounce accounting non-zero* (gds stays 0
    by determination); nvidia-fs read bytes non-zero is a Leg-B-only expectation. Stats format:
    `NVFS statistics(ver: 4.0)`, driver 2.29.4; `Active Shadow-Buffer (MiB)` is the bounce signal.
    Remaining D-6 engineering: Stage-5/6 worker wiring + the nvidia-fs block parser (tracker **D-6**).
8. **Confirm real per-slide tile counts from the actual 3.0 coords** before sizing the 6.B.1 file-size grid or
   committing 6.A Tier 2 wallclock — both currently rest on magnification arithmetic, not measurement.
9. **Counter-semantics check for cross-leg `ops/s`.** Until counter semantics are verified equivalent and that
   verification recorded, app-level metrics are the cross-leg-comparable ones and filesystem-reported ops/s
   is within-leg only. Detail: `docs/Stage-2-Cataloging.md`.
10. **Core accounting — WEKA value SET and RE-VERIFIED on the rebuilt cluster (2026-08-16:
    `FS_CLIENT_RESERVED_CORES="1-4,49-52"`; FRONTENDs on vCPUs 1–4 per the client's own report, HT siblings
    confirmed 1↔49…4↔52).** Remaining: the Lustre leg sets `none`, and the reservation is reported as part
    of WEKA's cost at writing time. Detail: `docs/STAGES.md` **D15**.
11. **Record both sides' provisioned configuration into the environment contract** — WEKA: backend type and
    count, capacity, EC scheme, client networking mode. FSx: tier, capacity, provisioned metadata IOPS, EFA
    state. Without these the fairness basis is unverifiable after the fact. Detail: `docs/STAGES.md` **D6/D7**.
12. **Capacity headroom — fits everywhere; corpus sizes now FROZEN (2026-08-16: `STAGE1_*` = 3072/256/26,
    6.B = 3.0 TiB; Stage-1 + Stage-6 registers, carried in the contract).** Worst case: datasets 1.75 TiB +
    full-cohort raw-TIFF ~6.4 TiB (retained at rest per the Stage-4 register) + Stage-1.0 read corpora
    **9.5 TiB** (seq 3 TiB + 26 × 256 GiB one-touch regions) + 6.B corpus 3.0 TiB +
    features/heatmaps/scratch ≲ 1 TiB ≈ **21.7 TiB** — fits FSx at 26.4 TiB (~18% headroom) and the WEKA
    cluster (61.37 TiB usable) trivially. If FSx headroom feels tight at Leg-B spin-up, raising FSx
    capacity is a D7-visible change — surface, don't absorb. Note: 4.D's wallclock grows to the full 1073
    slides — measured work, not dead time, but plan the leg's schedule with it.
13. **Worker measurement-correctness remainders — the 4.C half is DONE (2026-08-15):** `gds_engaged` now
    carries the recorded three-layer path-accounting verdict via the new `wsi_cufile_accounting.py` +
    `read-tiles-kvikio.py` wiring (see tracker **D-6** for what remains: Stage-5/6 worker wiring before
    Stage 5 runs; the recorded Phase-0 cell post-switch; the INCOMPLETE wiring with D-30). Still open here:
    - **`read-after-write-stage7.py`'s 10 ms poll.** The interval is now reported as the visibility-latency
      resolution floor, so quantisation is visible rather than silent. Whether to *tighten* it is a tuning
      judgment against CPU cost and is unmade. Verified on the build machine: measured latencies fell
      **below** the floor, so at 10 ms this cell is sampling poll phase, not visibility — decide the interval
      before 7.4.b runs, or its headline number means nothing.
13d. **Stage 3–7 sweep drivers must declare `RECORD_CACHE_STATE` per cell (kvikIO cells also
    `RECORD_KVIKIO_CELL=1`) before their stages run** — the D21 verdict semantics (ratified 2026-08-16,
    implemented in `record-run.sh`) now mark an undeclared stage≥1 cell INCOMPLETE, so an undeclared driver
    aborts the unattended chain at its first cell. Regimes follow each roadmap's cache-discipline row;
    propose the per-stage regime labels at the baseline greenlight rather than inventing them at 3am. The
    driver list is tracker **D-30**'s remainder. Stage-1/2/stability drivers are done.
14. **Decide the cuCIM tile-cache policy.** Every cuCIM path sets a 512 MiB per-process cache that is not
    swept, not recorded, and absent from the cold/warm discussion — yet sits in front of the filesystem on
    every cuCIM cell. Record it per cell or make it swept, and apply the same choice to both legs.
15. **Re-derive `CHUNK_SIZE` for 6.A Tier 2 from this leg's provisioned capacity.** Both Tier-2 orchestrators
    default to 200, sized against a different environment. **This decides whether Tier 2 fits on disk at all**
    — too large and the conversion fails mid-cohort after hours; too small and it wastes wallclock. Use the
    **same** value on both legs, since chunk size changes the write/delete cadence the filesystem sees.
17. **`env.sh --check-ready` mode — RATIFIED (2026-08-16): build a separate "ready to measure" mode**
    (leg-conditional hard requirements: the running leg's canary field `WEKA_EC_SCHEME` /
    `LUSTRE_STRIPE_LAYOUT`, distinct from `--check`'s "configured") — **deliberately deferred until after
    the Stage-1.0 baseline**; not blocking. Detail: the original gap is that a leg can start with `--check`
    passing while the D12 consistency relation is underivable.
18. **[USER] Cost-metering basis with WEKA Sales — the one cost remainder.** Does the Marketplace software
    rate meter RAW NVMe (120 TB @ 0.1141553/TB-hr = 13.699/hr, the recorded value) or USABLE (~67.5 TB →
    ~7.70/hr, the alternative in env.sh's comment)? Backfillable — cells record wallclock + dated prices,
    cost is re-derived arithmetic. Everything else from the old item is DONE and verified on the rebuilt
    cluster 2026-08-16 (type/count/RAM/capacity/EC/reserved cores; backend AMI recorded, STAGES **D20**;
    `weka_version` pin confirmed by the human; values in env.sh + the contract's recovery fields). Leg B's
    documented per-client caps (2026-08-15, performance.html): EFA 700 Gbps, EFA+GDS 1200 Gbps — set at
    Leg-B spin-up.
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
    `prompts/handoff-cloud.md`: **Tier 0** transport, before *any* cell including the throwaway (**CLOSED,
    re-evidenced on the REBUILT 6xlarge cluster 2026-08-16** — 4 FRONTENDs NETWORK=DPDK on this host from
    the client's own report, 4 NICs igb_uio-bound, bootstrap evidence line; run-leg.sh refusal verified);
    **Tier 1** recording adapters, consistency relation, worker-correctness bugs, the 1.7 driver, and the
    Stage-1.0 cache regime — **ALL CLOSED and exercised in anger (2026-08-17): the Stage-1.0 baseline +
    1.7 hydration ran, 118 cells, every canary PASS, hydration byte-verified, markers written. STATE:
    STOPPED at the baseline greenlight gate — nothing past 1.7 runs without the human's word.** Next steps
    on greenlight: 3.0 → 4.D → … per run-leg order; **before 3.0 runs, its driver needs its
    RECORD_CACHE_STATE declaration (memory 13d / tracker D-30)**. **Tier 2** rows (cuCIM tile-cache policy
    item 14 before Stage 4; CHUNK_SIZE item 15 before 6.A Tier 2; D-34 poll rate before 2.0; mixed-band
    calibration before 1.6; 7.4.b poll before 7.4.b) remain open at their gates.
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
9. **`run-leg.sh`'s abort-on-failure guard only sees the driver's exit status — the
   attempt-all-then-exit-nonzero pattern is implemented in stage 5, 2.0, 1.6, 4.B, 6.C, and the new
   1.0b/1.0d drivers (2026-08-15). Still swallowing failures:** `sweep-stage1-{seqw,randw,fpsync}.sh`,
   `sweep-stage3-tissue-detection.sh`, `sweep-stage4a-patches.sh`, `sweep-stage4c-kvikio.sh`,
   `sweep-stage6a-extract.sh`, `sweep-stage6b-{mil,stress}.sh`, `sweep-stage7-clinical.sh`. Apply the same
   pattern when each is next touched, or in one sweep before the leg starts.
10. **UNI2-h results stay internal-only** — don't strip the tags in refactors; filter those rows before
   anything leaves the building. More important here than in an internal study, since a competitive comparison
   is likelier to be externalised. Detail: `[[uni2h-conditional-use-status]]`.
10b. **Root-volume space is a live hazard for the rest of the leg (ENOSPC aborted 1.0b's last two cells
    2026-08-16).** The 48 GB root volume holds the repo + accumulating `runs/*/raw`; the fix in force: raw
    payloads relocate to `/data/local-nvme/runs-raw-overflow/` (symlinked back, S3 authoritative) after each
    step's verified sync — the session chain does it; durable fix + rebuild sizing is tracker **D-35**.
    Watch `df /` before any long step; HF cache now lives on scratch via symlink (re-point it if a rebuild
    recreates `~/.cache/huggingface`). Driver resume-skip gap is **D-36** — before Leg B.
11. **sync-to-s3 first-run verification DONE (2026-08-15, ahead of the first teardown):** `--self-test`
   built (was D-23), PASSED against the real bucket (mirror probe deleted on local delete; archive probe
   survived), UNVERIFIED banner removed, and `teardown-prep.sh` now runs the self-test mechanically before
   every teardown. Leftover to clean manually when convenient: `aws s3 rm --recursive
   s3://liad-wsi-cloud/_selftest/`. (SSM deploy-key silent-install check passed on the 2026-08-15 boot.)
   Tracked cosmetic, no action: a mamba "error opening log file: Permission denied" warn at the env-build
   log tail — envs build and smoke-pass regardless; investigate only if impact appears.
