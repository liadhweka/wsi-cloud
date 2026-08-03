---
name: cloud-session-open-items
description: "THE running tracker of everything that must be resolved, built, or watched before/during cloud benchmarking. Discoveries made during the doc build live here so they are not buried in a roadmap and forgotten until a later audit. Add to this in the SAME edit that surfaces an item; strike items when done."
metadata:
  node_type: memory
  type: project
---

**Purpose:** unresolved items surfaced while building this repo (and later, while benchmarking) collect
**here**, not only in whichever doc surfaced them. A memory is loaded every session automatically; a doc has
to be found. **When an audit or exchange surfaces an unresolved item, add it here in the same edit** — and
strike it (with the resolution + date) when it's done, rather than deleting it silently.

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
10. **Verify the cuCIM install path on the cloud stack (conda vs pip).** pip wheels have been observed to
    crash with a libstdc++ ABI mismatch inside `read_region()` where the RAPIDS conda build does not.
    Re-verify rather than assuming the same versions behave the same. Detail: `runs/Stage-4-Patching.md`
    § tool inventory install note.

## B. BUILD in the cloud session (deferred engineering — needs the real environment)

**This is the authoritative list.** Each item carries its `D-n` id from the table at the top of
`SCRIPT-TRACKER.md`, which holds the per-script detail. **File counts are measured**, not estimated —
they are what makes the scope concrete. Nothing here could be done before the environment exists, and
**all of it is a hard prerequisite for a valid cell.**

9. **`D-1` — Mount retargeting to `$FS_MOUNT`** (`/mnt/weka`, `/mnt/lustre`). **36 files** hardcode the
   previous single mount path. *Highest-severity item on this list:* a hardcoded mount silently makes a
   Lustre cell measure WEKA, and the number still looks fine — there is no failure signal.
10. **`D-2` — Repo-root retargeting.** **32 files** reference the previous repo/tree path. Prefer deriving
    from script location (as `record-run.sh` already does) over introducing a new hardcoded constant.
11. **`D-3` — `--fs {weka|lustre}` plumbing** through `record-run.sh`, every `sweep-*.sh`, and every
    `aggregate-*.py`: run-dir name segment, `metadata.json` field, aggregator pivot — so head-to-head CSVs
    fall out directly. Detail: `STAGES.md` **D11**.
12. **`D-4` — Per-filesystem recording adapters** in `record-run.sh`, `parse-results.py`, and the
    **13 aggregators** that currently assume one filesystem's telemetry. Includes the per-timestamp
    client-summing filter, whose *pattern* generalises across legs but whose *filter* is schema-specific.
13. **`D-5` — Per-filesystem consistency relation** in the canary logic — derived from the actual EC scheme
    (WEKA) and the actual stripe layout (Lustre). See also item 3.
14. **`D-6` — cuFile path accounting as a first-class recorded source** in `record-run.sh` and the kvikIO
    readers. A kvikIO cell without recorded GPU-direct-vs-bounced bytes is **incomplete** (**D8**).
15. **`D-7` — `record-run.sh` + `backup.sh`: during-run S3 sync, per-cell watchdog timeout, and
    canary-aborts-the-chain.** All three are prerequisites for trusting an unattended overnight run. Only
    the memory-mirror half of `backup.sh` exists today; the S3 half needs the real bucket/region/role, with
    the two sync semantics (mirror-with-delete for docs and memories; **add-and-update-never-delete** for
    telemetry and datasets). Detail: `CLAUDE.md` → Durability & backup.
16. **`D-8` — Re-derive the GPU/NUMA/NIC map and the DDP GPU-count ranges** for the actual instance
    (`run-multiproc-kvikio.sh`, `sweep-stage5-training.sh`, `sweep-stage6a-extract.sh`,
    `sweep-stage7-clinical.sh`).
17. **`D-9` — Core accounting in the aggregators** computing CPU headlines: the reserved-core exclusion set
    is a **per-filesystem parameter**, not a constant (**D15**). See also item 7.
18. **`D-10` — cuFile config and environment paths.** **20 files** reference conda / cuFile / CUDA absolute
    paths, all environment-specific — re-derive, never copy. **Includes rewriting
    `runs/lib/GDS-TUNING-CHECKLIST.md`**, which currently carries a `⏳ PENDING RETARGET — DO NOT FOLLOW AS
    WRITTEN` banner listing the four things its rewrite must do (re-derive all values; **add a
    Lustre-over-EFA branch**, since the kvikIO path runs on both filesystems; treat "is GDS active?" as
    empirical per cell; keep `LD_PRELOAD` scoped per cell).
19. **`D-11` — Lustre tuning:** stripe layout (`lfs setstripe` / progressive layout) plus the client
    tunables AWS recommends for high-core, high-memory clients. **Tuning is part of "Lustre at maximum"
    (D7)** — skipping it would understate Lustre and break the fairness basis.
20. **`D-12` — Environment-contract writer** (end of Leg A) **+ verifier** (start of Leg B), fail-loud on
    mismatch (**D6**).
21. **`D-13` — Hydration driver for 1.7** (S3 → filesystem) — needs the real bucket, region, and IAM role.
22. **`D-14` — Leg-level orchestrator** with checkpoint/resume, so a crash re-runs only what is missing.

> **Nothing was deleted from the script library.** An earlier plan assumed GDS would be dropped, which
> would have removed the kvikIO / raw-TIFF / cuFile scripts. **GDS is retained and asymmetric by design**
> (**D8**), so all 59 files carry forward. Phase-5 "prune" work is therefore **zero**; the deferred list
> above is where that effort went instead.

## C. WATCH during benchmarking

19. **Instance revisit trigger (D10)** — if the synthetic ceiling pins at line rate across block sizes
    **and** the `num_workers` sweep saturates on CPU cores, the instance is measuring itself; move up before
    Leg B. Pre-committed so the call isn't made under sunk cost.
20. **Coord-equivalence gate between legs** — completeness and per-slide tile counts are
    storage-independent, so any cross-leg divergence proves the legs didn't process identical inputs.
    **Fail-loud; invalidates downstream comparison.** Detail: `runs/Stage-3-Tissue-Detection.md`.
21. **Mixed-workload canary bands** must be wider than single-direction bands **and** re-derived per
    filesystem. Detail: `runs/Stage-1-Ingest.md` § engineering notes.
21b. **Delete any stale raw-TIFF before re-converting.** The 4.D driver does an idempotent skip on existing
    non-empty output, so a stale artifact (wrong magnification, older converter) is **silently kept and read
    as if current** — nothing fails loudly. Also: 4.D output byte counts and tile-grid dimensions are
    storage-independent and must **match between legs**; a divergence means the legs converted different
    inputs. Detail: `runs/Stage-4-Patching.md` § 4.D.
21c. **`LD_PRELOAD` must be scoped per cell in every mixed kvikIO/cuCIM sweep.** Symptom if forgotten: clean
    init, then a segfault on the first cuCIM read — easily misdiagnosed as a multiprocessing bug. Nearly
    every sweep in this project is mixed. Detail: `[[cucim-segfaults-when-libcufile-is-ld-preloaded]]`.
21d. **Silent-skip hazards — three places where existing output is reused without failing loud:** the 4.D
    raw-TIFF converter, the 6.A extractor (needs **cleanup-before-cell**, or every cell after the first
    short-circuits and reports a plausible-looking meaningless number), and 6.A Tier 2's chunked conversion
    (an aborted run leaves chunks that get reused). Verify cleanup between runs in all three.
21e. **6.D composition hygiene** — every component wallclock must come from **the same leg's** run dirs.
    Mixing phases across legs yields a number describing neither filesystem, and the aggregators glob run
    dirs, so it is easy to do by accident. Detail: `runs/Stage-6-Feature-Extraction.md` § 6.D.
21f. **Any per-model adjustment (e.g. a reduced batch size for the largest model) must be applied
    identically on both legs** and noted in the run README. An adjustment made on one leg only becomes a
    filesystem difference in the results.
22. **[USER] WEKA license cost in the price claim** — deliberately deferred. "We're cheaper" isn't credible
    with license excluded and unlabelled; either price it in or label the figure infrastructure-only.
    Detail: `STAGES.md` **D7**.
23. **UNI2-h results stay internal-only** — don't strip the tags in refactors; filter those rows before
    anything leaves the building. More important here than in an internal study, since a competitive
    comparison is likelier to be externalised. Detail: `[[uni2h-conditional-use-status]]`.

---

## Resolved

*(none yet — move items here with the resolution and date rather than deleting them, so a later reader can
see the question was asked and answered.)*

Related: `[[weka-vs-lustre-cloud-open-decisions]]`, `[[weka-vs-lustre-cloud-project]]`,
`[[feedback_cloud_session_workflow]]`, `[[feedback_complete_implied_work]]`.
