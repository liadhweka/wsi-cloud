---
name: cloud-session-open-items
description: "THE running work list of everything still to resolve, build, or watch before/during cloud benchmarking. Discoveries live here so they are not buried in a roadmap. Add in the SAME edit that surfaces an item; DELETE the item when it is done — completions belong in the relevant doc, not here."
metadata:
  node_type: memory
  type: project
---

**Purpose:** unresolved items surfaced while building this repo (and later, while benchmarking) collect
**here**, not only in whichever doc surfaced them. A memory is loaded every session automatically; a doc has
to be found. **When an audit or exchange surfaces an unresolved item, add it here in the same edit.**

**This file holds ONLY open items.** When something is done, **delete it from here** — the completion record
belongs in the relevant doc (`SCRIPT-TRACKER.md`'s done table, a stage change log), and git history preserves
this file's prior state. *Why:* a fresh session loads this to know what to **do**; a completed-items list
grows without bound and — worse — an item left listed after completion gets redone.

Nothing here is a decision awaiting the user's ratification unless marked **[USER]**. Assumed *environment
values* live separately in `[[weka-vs-lustre-cloud-open-decisions]]`.

---

## A. Resolve BEFORE the first measured cell

These change what the numbers mean, so resolving them after cells have run means re-running cells.

1. **Sub-second cells vs 1 Hz recorders.** High-concurrency Stage 2/3 cells finish in <1 s, so
   filesystem-side recorders capture 1–3 samples and any sustained mean is ill-defined. Matters more in a
   head-to-head: both legs could lose filesystem-side evidence exactly where the metadata architectures
   differ most. *Recommendation:* raise the poll rate for short cells (keeps single-pass methodology; avoids
   re-reading warm data, which would collide with the cold/warm rule). **Must be applied identically to both
   legs.** Detail: `runs/Stage-2-Cataloging.md` § open methodology item.
2. **Does WEKA-on-AWS do true GDS?** Determines whether the GPU-direct matrix is 2×2+1 or a full 2×3.
   Resolve empirically — `gdscheck -p` plus a recorded canary cell — **not** from documentation (WEKA's
   materials claim GDS on AWS; the transport analysis says ENA isn't RDMA-capable). Detail: `STAGES.md`
   **D8**.
3. **Derive each filesystem's cross-source consistency relation.** The canary cannot run without it, and it
   must **not** be ported between legs. WEKA: from the actual EC scheme (captured at provisioning). Lustre:
   from the actual stripe layout (`lfs getstripe`) plus replication. Detail: `STAGES.md` **D12**.
4. **Determine the Lustre LND actually in use** (kernel TCP/ksocklnd vs the EFA provider). This decides
   which client counters are **primary** vs diagnostic on the Lustre leg — get it wrong and every Lustre
   throughput number cites a bypassed source.
5. **Cache-clearing mechanism per filesystem.** Cold-vs-warm is an enforced axis, but *how* you actually
   reach a cold state differs per side and includes a server-side component we do not control on managed
   FSx. Determine what is achievable, record it, and state the residual uncertainty rather than labelling a
   cell "cold" on faith. Detail: `STAGES.md` **D13**.
5a. **Stage 4.B's only cold-cache mechanism is hardwired OFF.** `sweep-stage4b-tilesread.sh` sets
   `TIER3_DROP_CACHES=0`, so the `vm.drop_caches` call can never fire, and the justification in the header is
   a claim about a **previous host's RAM** ("BRCA's 1.05 TiB compressed total exceeds host RAM"). On a
   768 GiB instance that reasoning does not transfer, and 4.B is precisely where the roadmap says cache
   discipline is load-bearing: at high worker counts the coord pool can become cache-resident, and the two
   filesystems cache differently, so the crossover must be characterised **per filesystem** rather than
   assumed shared (**D13**). Re-derive on the real instance and decide whether to re-enable — a warm 4.B
   labelled as storage would misreport both sides. Detail: `runs/Stage-4-Patching.md` § 4.B.

5b. ⚠ **Size the 6.B synthetic corpus before 6.B.1 runs — using BOTH filesystems' cache sizes.**
   *Timing:* **not needed before moving to the cloud.** 6.B.1 sits late in Leg A (after Phase 0, hydration,
   3.0, 4.D, all of Stage 4, Stage 5, all three 6.A tiers, and 6.B.3), so this is days of benchmarking away.
   What *is* needed at spin-up is only that both filesystems have **capacity** for a corpus of this scale on
   top of the datasets, raw-TIFF, and features — which the planned capacity already covers — plus one cheap
   check: **record the WEKA backends' aggregate RAM at spin-up.** That is the only path by which this could
   force a larger corpus than planned (if WEKA's cache exceeded FSx's) and therefore affect capacity sizing.
   There are **two** caches to exceed, not one: the client page cache (~768 GiB on the current instance)
   **plus** the filesystem's own server-side cache — and those differ per side (a maxed FSx carries roughly
   27.3 GiB of file-server cache per TiB provisioned, order ~680 GiB at 25 TiB; WEKA's depends on backend
   type and count). A corpus that is genuinely cold on one filesystem may be partly warm on the other,
   producing a **cache-size artifact that looks like a filesystem difference**. *This is the one place a
   Leg-A parameter must be chosen using Leg-B information* — recommendation: compute FSx's cache size in
   advance (its config is already fixed by **D7**) and generate **one identical corpus definition** for both
   legs; per-leg corpus sizes would break the held-constant contract on the substage most sensitive to it.
   Detail: `runs/Stage-6-Feature-Extraction.md` § cold-cache problem.
5c. **Confirm real per-slide tile counts from the actual 3.0 coords** before sizing the 6.B.1 file-size grid
   or committing 6.A Tier 2 wallclock. Feature file sizes and Tier-2 duration currently rest on
   magnification arithmetic, not measurement. Detail: `runs/Stage-6-Feature-Extraction.md` § risks.
6. **Counter-semantics check for cross-leg `ops/s`.** Decide whether filesystem-reported operation counts
   are comparable across legs; until verified, app-level throughput is the cross-leg headline and ops/s is a
   within-leg diagnostic only. Detail: `runs/Stage-2-Cataloging.md` § cross-leg comparability caveat.
7. **Core accounting per D15.** Measure the WEKA client's reserved core count on the real instance (and
   confirm Lustre's is zero), so compute-saturation headlines are computed over application-available cores
   and the reservation is reported as part of WEKA's cost. Detail: `STAGES.md` **D15**.
8. **Record the provisioned configuration of both sides into the environment contract** — WEKA: backend
   type/count, capacity, EC scheme, client networking mode. FSx: tier, capacity, provisioned metadata IOPS,
   EFA state. Without these the fairness basis is unverifiable after the fact. Detail: `STAGES.md`
   **D6/D7**; `cloud-setup/SPINUP-CHECKLIST.md` § D.
9. **Confirm raw-TIFF capacity headroom on BOTH filesystems before starting the 4.D conversion.** The
   artifact is order ~7 TB at the full cohort, and on FSx capacity is simultaneously a performance knob — so
   it is a sizing input, not an afterthought. Detail: `runs/Stage-4-Patching.md` § 4.D.
9b. ⚠ **Fix the measurement-correctness bugs the 2026-08-03 audit found in the Python workers, BEFORE any
   measured cell.** Each produces a plausible number that is wrong, which is worse than a crash. Full detail
   and exact locations in `cloud-setup/AUDIT-REPORT.md` § Raised, not fixed. In severity order:
   (a) `read-tiles-kvikio.py` samples the completion timestamp **before** the `f.get()` drain loop, so the
   recorded per-tile latency **excludes the actual I/O wait** — the headline latency of the GPU-direct path;
   (b) `extract-features-foundation-stage6.py` allocates the per-slide embedding buffer with `torch.empty`
   and never checks that all `n_tiles` rows were filled, so a short read saves **uninitialised GPU memory**
   as features; (c) `read-tiles-onthefly.py` resolves each slide path with a full `iterdir()` over ~1133
   directories **inside the timed loop**, so 4.B partly measures directory scanning; (d) `parse-results.py`
   emits `<col>_per_sec` as the **raw delta between samples without dividing by the actual dt**, and the
   recorders sleep 1 s *plus* loop overhead — a systematic overstatement of every wire-counter rate, which
   feeds the canary ratio check; (e) `read-feature-files-stage6b.py` discards the page cache in worker 0
   *after* the pool has started, so the other workers are already warming it; (f)
   `aggregate-stage4c-kvikio.py` publishes a `gds_engaged` column inferred **from the run-dir name**, i.e.
   from the requested config — which is exactly the "a config flag is not proof of behaviour" rule (D8);
   (g) `read-after-write-stage7.py` sizes its heatmap from an assumed ~5× compression ratio while the
   synthetic content compresses far harder, so `--bytes-per-write` is not the bytes written, and its 10 ms
   poll quantises the visibility latency it is trying to measure.

9c. **Decide the cuCIM tile-cache policy.** Every cuCIM path sets a 512 MiB per-process cuCIM cache
   (`read-tiles-onthefly.py`, `train-resnet50-stage5.py`, `extract-features-foundation-stage6.py`). It is
   not swept, not recorded in any summary, and not mentioned in the cold/warm discussion — yet it sits in
   front of the filesystem on every cuCIM cell. Either record it per cell or make it a swept parameter, and
   apply the same choice to both legs.

9d. **Re-derive `CHUNK_SIZE` for 6.A Tier 2 from THIS leg's provisioned capacity.** Both Tier-2
   orchestrators (`run-stage6a-tier2-chunked.sh`, `-multimodel.sh`) default to `CHUNK_SIZE=200`, which was
   sized against a different environment's capacity — the carried-over figures were removed in the
   2026-08-03 audit, but the value was not, because it cannot be until `WEKA_CAPACITY_TB` /
   `FSX_CAPACITY_TIB` and the measured per-slide raw-TIFF size are known. **This is the parameter that
   decides whether Tier 2 fits on disk at all:** too large and the conversion fails mid-cohort after hours,
   too small and it wastes wallclock on extra chunk cycles. Compute it before starting Tier 2, and use the
   **same** value on both legs (chunk size changes the write/delete cadence the filesystem sees, so a
   per-leg value would be a workload difference). Override with `--chunk-size`; detail in each script's
   header and `runs/Stage-6-Feature-Extraction.md` § 6.A Tier 2.

10. **Verify the cuCIM install path on the cloud stack (conda vs pip).** pip wheels have been observed to
    crash with a libstdc++ ABI mismatch inside `read_region()` where the RAPIDS conda build does not.
    Re-verify rather than assuming the same versions behave the same. Detail: `runs/Stage-4-Patching.md`
    § tool inventory install note.

11. **[USER DECISION] Should `env.sh --check` hard-fail on the current leg's canary field?** Today
    `WEKA_EC_SCHEME` and `LUSTRE_STRIPE_LAYOUT` are both `_rec` (warn only), yet **the canary relation for the
    running leg cannot be derived without the one that applies** (`D12`) — so a leg can start with `--check`
    passing and no consistency check possible. A leg-conditional `_req` would catch it, but it **changes when
    the gate blocks**: it would fail during Part 5, before Part 6 has provisioned the filesystem. *Options:*
    (a) leave as warnings and rely on the pre-flight; (b) leg-conditional `_req`, plus a documented "expect
    this to fail until Part 6"; (c) a separate `--check-ready` mode meaning "ready to measure", distinct from
    "configured". **Recommend (c)** — the two questions are genuinely different and conflating them is what
    makes (b) awkward. Detail: `cloud-setup/AUDIT-REPORT.md` § delegation-boundary pass.

## B. BUILD in the cloud session (deferred engineering — needs the real environment)

Items are labelled by their **`D-n` id** — the stable identifier shared with the table in
`SCRIPT-TRACKER.md`, which holds the per-script detail. (They used to carry positional numbers that
collided with section A's and had a gap; cite the `D-n` id, never a position.)
**File counts are measured.** All of it is a hard prerequisite for a valid cell, not cleanup.

> `D-1`, `D-2`, `D-3`, `D-12`, `D-14` were completed on the build machine (2026-08-03) and are **no longer
> listed here.** What they were and how they were verified is in `SCRIPT-TRACKER.md` § "Done before leaving
> the build machine"; the prior state of this file is in git.

- **`D-4` — Per-filesystem recording adapters** in `record-run.sh`, `parse-results.py`, and the
   **13 aggregators** that assume one filesystem's telemetry. Includes the per-timestamp client-summing
   filter, whose *pattern* generalises across legs but whose *filter* is schema-specific. Needs the real
   stats output to write against.
- **`D-5` — Per-filesystem consistency relation** in the canary logic — derived from the actual EC scheme
    (WEKA) and the actual stripe layout (Lustre). **Never ported across.** See also item 3.
- **`D-6` — cuFile path accounting as a first-class recorded source** in `record-run.sh` and the kvikIO
    readers. A kvikIO cell without recorded GPU-direct-vs-bounced bytes is **incomplete** (**D8**). Needs the
    real cuFile/nvidia-fs stats format.
- **`D-7` — per-cell sync, watchdog, canary-abort.** **Partly done:** `sync-to-s3.sh` exists (with an
    `UNVERIFIED AGAINST A REAL BUCKET` banner and a 7-step first-run procedure in its header — **step 6 is
    the one that matters**), and `run-leg.sh` syncs after every step. **Still needed:** per-**cell** sync
    inside `record-run.sh`, the per-cell watchdog timeout, and making the canary abort the chain.
- **`D-8` — Re-derive the GPU/NUMA/NIC map and the DDP GPU-count ranges** for the actual instance
    (`run-multiproc-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6a-extract.sh`,
    `sweep-stage7-clinical.sh`).
- **`D-9` — Core accounting in the aggregators** computing CPU headlines: the reserved-core exclusion set is
    a **per-filesystem parameter**, not a constant (**D15**), and the reserved count is only measurable on the
    real client. See also item 7.
- **`D-10` — cuFile config and environment values.** **20 files** reference conda / cuFile / CUDA paths —
    now via variables, but the *values* are unknown. Includes generating `cufile.json` with this instance's
    own addresses, and **rewriting `runs/lib/GDS-TUNING-CHECKLIST.md`**, which carries a `⏳ PENDING RETARGET
    — DO NOT FOLLOW AS WRITTEN` banner listing the four things its rewrite must do (re-derive all values;
    **add a Lustre-over-EFA branch**; treat "is GDS active?" as empirical per cell; keep `LD_PRELOAD` scoped
    per cell).
- **`D-11` — Lustre tuning:** stripe layout (`lfs setstripe` / progressive layout) plus the client tunables
    AWS recommends for high-core, high-memory clients. **Tuning is part of "Lustre at maximum" (D7)** —
    skipping it would understate Lustre and break the fairness basis. Leg B.
- **`D-4` also owns the aggregator `fs` pivot.** No aggregator opens `metadata.json` or emits an `fs`
   column, so a cross-filesystem CSV must still be assembled by hand. The docs asserted this worked; that
   claim is now corrected. Also inside `D-4`: **7 of the 14 aggregators require an explicit glob argument**
   rather than self-locating, and three hardcode a previous host's name or filesystem in their output header.

- **`D-15` (new) — make step 4.D actually recorded.** `convert-stage4c-rawtiff.sh` is `run-leg.sh` step 4.D
   and its own header calls it a recorded cell, but it **never invokes `record-run.sh`** — it writes a flat
   TSV and prints to stdout. So the 20× raw-TIFF conversion, which the roadmap treats as a measured
   large-sequential-write workload, produces no run dir, no telemetry, no `INDEX.md` row and no S3 sync. It
   also does not fail loud when zero slides resolve from the manifest.

- **`D-16` (new) — Lustre client-side EFA configuration is missing from Part 8.** `NEW-CLOUD-SETUP.md`
   enables EFA on the instance and asks for it on the file system, and installs the generic EC2 EFA
   software — but never runs AWS's FSx-Lustre EFA client setup, so the client would mount over TCP. That
   silently forfeits both GPUDirect Storage and the escape from the per-client-per-server cap, i.e. it
   breaks the "Lustre at maximum" fairness basis (**D7**) while still producing numbers. Verify against the
   current AWS FSx-Lustre client documentation and add the step **plus a gate** that `lnetctl net show` lists
   an `efa` net before any Leg-B cell.

- **`D-17` (new) — the Leg-B kernel-vs-contract conflict.** Part 8.4 installs `linux-aws`, which can move the
   kernel, and `kernel` is a `MUST_MATCH` contract field — so the documented Leg-B procedure can invalidate
   the comparison it exists to protect. Part 3's `apt-get upgrade -y` can do the same. Decide the policy
   (pin the kernel and install the matching `lustre-client-modules-$(uname -r)`, or re-baseline both legs)
   and write it into Part 8 **before** the rebuild.

- **`D-18` (new) — document the per-stage workload parameters.** 25 environment variables that the Stage-6.C
   and Stage-7 orchestrators read (`INFER_MODEL`, `INFER_BACKEND`, `INFER_CACHE_POLICY`,
   `INFER_HEATMAP_FORMAT`, `INFER_MANIFEST`, `EXTRACT_MODEL`, `EXTRACT_GPUS`, `EXTRACT_N_GPUS`, `INGEST_SRC`,
   `INGEST_DST`, `INGEST_N`, `MIL_FEATURES_TAG`, `VIEWER_N`, … ) appear in **neither**
   `cloud-setup/NAMING-AND-VARIABLES.md` **nor** `env.example.sh`. They all have in-script defaults, so
   nothing fails loudly — which is the problem: they are the knobs those two stages are configured through,
   and an undocumented knob is one that can silently differ between legs and never appear in the contract.
   *Recommendation:* add a Table 5 for per-stage workload parameters, and record the values used per cell.

- **`D-19` (new) — substage 1.8 has no implementation and no marker.** The FSx-native S3 import
   (`runs/Stage-1-Ingest.md`) is the only substage in any roadmap with neither a "Sweep driver" row, an
   explicit "no implementation" note, nor a deferred-item id — so it is the easiest thing in the project to
   lose. It is a Lustre-leg single-filesystem capability cell, deliberately excluded from the head-to-head
   (**D8**/Stage 1), which is exactly why omitting it would go unnoticed: no cross-leg comparison breaks.
   *Recommendation:* build it in Leg B, or record a decision not to; either way give it a row.

- **`D-13` — Hydration driver for 1.7** (S3 → filesystem) — needs the real bucket, region, and IAM role.
    `run-leg.sh` reports this step as **MISSING and aborts** rather than skipping it.

- **`D-20` (new) — `runs/lib/prove-recording.sh`.** Rebuild step 9 and `handoff-cloud.md` both say to run a
   throwaway Stage-0 cell and "confirm" **five** things by eye — recording complete, both canaries functional,
   S3 sync verified, the `INDEX.md` row correct, an aggregator emitting a row pivoted on `--fs` — with no
   command given. It runs on **every** rebuild, before spending wallclock, and five eyeball checks is where one
   gets skipped. Build it as one script with a named non-zero exit per failed assertion. *Needs the real
   environment:* it runs an actual cell end-to-end.

- **`D-21` (new) — a contract-verified marker `run-leg.sh` refuses without.** Rebuild step 7 runs
   `env-contract.py verify` as "the gate", then three steps later `run-leg.sh` starts the leg **without
   checking that the gate ever ran or passed.** Phase 1 (safe now): `verify` writes
   `runs/.leg-state/$LEG/contract-verified` on PASS and unlinks it on FAIL, and `run-leg.sh` warns loudly when
   the marker is absent or older than the contract. Phase 2 (**needs the user's explicit ratification**, since
   it can abort a leg): promote the warning to a refusal.

- **`D-22` (new) — `cloud-setup/verify-conda-env.sh`.** Rebuild step 5 asks for nine imports plus a visible-GPU
   count to be checked by hand on every rebuild. Script the **verification only** (imports, GPU count vs
   `nvidia-smi`, `python_version` against the reference contract, non-zero on drift) and leave environment
   *creation* in the prompt where it stays ask-gated.

- **`D-23` (new) — `sync-to-s3.sh --self-test`.** Its header carries a **seven-step manual first-run
   procedure**, including the one that actually matters: prove a file under a MIRROR path disappears when
   deleted locally, and a file under an ARCHIVE path does **not**. Mechanise it under a namespaced
   `_selftest/` prefix, printing (not running) the cleanup command, and make removal of the file's UNVERIFIED
   banner conditional on it passing. *Needs the real bucket.*

- **`D-24` (new) — cross-leg artifact fingerprints.** `runs/README.md` declares four cross-leg integrity gates
   ("same slides producing coords, same per-slide tile counts", "same raw-TIFF byte counts and tile-grid
   dimensions", "same feature file count / per-slide tile count / tensor shapes"), each "fail-loud and
   invalidates downstream comparison" — and **nothing computes or compares them.** A declared gate that no code
   implements is worse than no gate: it reads as covered. *Sequence:* propose the per-artifact-class fingerprint
   definitions in the `STAGES.md` decision log for ratification **now**; build `capture`/`compare` after Stage
   3.0 has real output.

> **Nothing was deleted from the script library.** An earlier plan assumed GDS would be dropped, which would
> have removed the kvikIO / raw-TIFF / cuFile scripts. **GDS is retained and asymmetric by design** (**D8**),
> so all 62 files carry forward. Phase-5 "prune" work is therefore **zero**.

## C. WATCH during benchmarking

**C1.** **Instance revisit trigger (D10)** — if the synthetic ceiling pins at line rate across block sizes
    **and** the `num_workers` sweep saturates on CPU cores, the instance is measuring itself; move up before
    Leg B. Pre-committed so the call isn't made under sunk cost.
**C2.** **Coord-equivalence gate between legs** — completeness and per-slide tile counts are
    storage-independent, so any cross-leg divergence proves the legs didn't process identical inputs.
    **Fail-loud; invalidates downstream comparison.** Detail: `runs/Stage-3-Tissue-Detection.md`.
**C3.** **Mixed-workload canary bands** must be wider than single-direction bands **and** re-derived per
    filesystem. Detail: `runs/Stage-1-Ingest.md` § engineering notes.
**C4.** **Delete any stale raw-TIFF before re-converting.** The 4.D driver does an idempotent skip on existing
    non-empty output, so a stale artifact (wrong magnification, older converter) is **silently kept and read
    as if current** — nothing fails loudly. Also: 4.D output byte counts and tile-grid dimensions are
    storage-independent and must **match between legs**; a divergence means the legs converted different
    inputs. Detail: `runs/Stage-4-Patching.md` § 4.D.
**C5.** **`LD_PRELOAD` must be scoped per cell in every mixed kvikIO/cuCIM sweep.** Symptom if forgotten: clean
    init, then a segfault on the first cuCIM read — easily misdiagnosed as a multiprocessing bug. Nearly
    every sweep in this project is mixed. Detail: `[[cucim-segfaults-when-libcufile-is-ld-preloaded]]`.
**C6.** **Silent-skip hazards — three places where existing output is reused without failing loud:** the 4.D
    raw-TIFF converter, the 6.A extractor (needs **cleanup-before-cell**, or every cell after the first
    short-circuits and reports a plausible-looking meaningless number), and 6.A Tier 2's chunked conversion
    (an aborted run leaves chunks that get reused). Verify cleanup between runs in all three.
**C7.** **6.D composition hygiene** — every component wallclock must come from **the same leg's** run dirs.
    Mixing phases across legs yields a number describing neither filesystem, and the aggregators glob run
    dirs, so it is easy to do by accident. Detail: `runs/Stage-6-Feature-Extraction.md` § 6.D.
**C8.** **Any per-model adjustment (e.g. a reduced batch size for the largest model) must be applied
    identically on both legs** and noted in the run README. An adjustment made on one leg only becomes a
    filesystem difference in the results.
**C9.** **[USER] WEKA license cost in the price claim** — deliberately deferred. "We're cheaper" isn't credible
    with license excluded and unlabelled; either price it in or label the figure infrastructure-only.
    Detail: `STAGES.md` **D7**.
**C10.** ⚠ **The GPU instance needs a driver/CUDA/GDS-bearing AMI, and nothing in the setup guide provides
   one.** A plain Ubuntu image ships no NVIDIA driver, no CUDA, no `nvidia-fs`, no `libcufile`, and the
   env-prep prompt explicitly **refuses** to install a driver ("stop and report"). So the documented path
   dead-ends at Part 5. Choose a GPU AMI at launch (e.g. the current AWS Deep Learning Base GPU AMI on
   Ubuntu), confirm its exact name in the console rather than trusting a remembered title, and **pin the AMI
   ID** — Leg B rebuilds from it and `kernel`/`driver_version`/`cuda_version` are contract fields.

**C11.** **`run-leg.sh`'s "abort the chain on step failure" guard only sees the DRIVER's exit status.** The
   drivers do not propagate per-cell failures: they run under `set -uo pipefail` without `-e` and pipe each
   `record-run.sh` call into `tee`, so a failed cell leaves the driver's exit status at 0 and the step is
   marked done. Stage 5's `all()` was changed during the audit to abort on the first failed cell; **the other
   sweeps still swallow them.** Decide the policy and apply it uniformly — note it interacts with
   `runs/README.md`'s stated design that a bad cell should go `INCOMPLETE` without taking down the sweep. The
   middle option (attempt every cell, then exit non-zero if any failed) satisfies both and is the
   recommendation.

**C12.** **UNI2-h results stay internal-only** — don't strip the tags in refactors; filter those rows before
    anything leaves the building. More important here than in an internal study, since a competitive
    comparison is likelier to be externalised. Detail: `[[uni2h-conditional-use-status]]`.

---
