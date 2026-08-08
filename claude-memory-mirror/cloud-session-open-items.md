---
name: cloud-session-open-items
description: "The running work list: everything still to resolve before the first measured cell, and everything to watch during benchmarking. Add an item in the same edit that surfaces it; DELETE it when done."
metadata: 
  node_type: memory
  type: project
  originSessionId: 7c762301-b9e5-4cf9-aa77-70e924a540c2
  modified: 2026-08-08T02:16:30.806Z
---

Unresolved items collect **here**, not only in the doc that surfaced them — a memory loads every session; a
doc has to be found.

**This file holds only OPEN items.** When something is done, delete it — the completion record belongs in the
relevant doc, and git holds this file's history. *Why:* a fresh session reads this to know what to **do**, and
an item left listed after completion gets redone.

**Deferred engineering (`D-4`…`D-24`) is not listed here.** It lives in `SCRIPT-TRACKER.md` § "Still deferred",
which holds the scope and the reason each needs the real environment. Cite the `D-n` id.

---

## A. Resolve before the first measured cell

These change what the numbers mean, so resolving them after cells have run means re-running cells.

1. **Sub-second cells vs 1 Hz recorders.** High-concurrency Stage 2/3 cells finish in under a second, so
   filesystem-side recorders capture 1–3 samples and any sustained mean is ill-defined — and both legs would
   lose filesystem-side evidence exactly where the metadata architectures differ most. *Recommendation:* raise
   the poll rate for short cells, applied identically to both legs. Detail: `runs/Stage-2-Cataloging.md`.
2. **Does WEKA-on-AWS do true GDS?** Decides whether the GPU-direct matrix is 2×2+1 or a full 2×3. Resolve
   **empirically** — `gdscheck -p` plus a recorded canary cell — not from documentation, which disagrees with
   the transport analysis. Detail: `STAGES.md` **D8**.
3. **Derive each filesystem's consistency relation.** The canary cannot run without it and it must never be
   ported between legs: WEKA from the actual EC scheme, Lustre from the actual stripe layout. Detail:
   `STAGES.md` **D12**.
4. **Determine the Lustre LND actually in use** (kernel TCP vs the EFA provider). This decides which client
   counters are primary versus diagnostic — get it wrong and every Lustre number cites a bypassed source.
5. **Cache-clearing mechanism per filesystem.** How you reach a cold state differs per side and includes a
   server-side component we do not control on managed FSx. Determine what is achievable, record it, and state
   the residual uncertainty rather than labelling a cell cold on faith. Detail: `STAGES.md` **D13**.
6. **Stage 4.B's only cold-cache mechanism is hardwired off.** `sweep-stage4b-tilesread.sh` sets
   `TIER3_DROP_CACHES=0`, so `vm.drop_caches` can never fire, and the header justifies it with a claim about a
   *previous host's* RAM. 4.B is exactly where cache discipline is load-bearing — at high worker counts the
   coord pool can become cache-resident, and the two filesystems cache differently, so the crossover must be
   characterised per filesystem. Re-derive and decide whether to re-enable. Detail: `runs/Stage-4-Patching.md`.
7. **Size the 6.B synthetic corpus using BOTH filesystems' cache sizes.** There are two caches to exceed, not
   one: the client page cache **plus** each filesystem's own server-side cache, which differ per side. A corpus
   genuinely cold on one and partly warm on the other produces a **cache-size artifact that looks like a
   filesystem difference.** *This is the one place a Leg-A parameter must be chosen using Leg-B information* —
   compute FSx's cache size in advance and generate **one identical corpus definition** for both legs.
   *Timing:* 6.B.1 sits late in Leg A; what is needed at spin-up is only **recording the WEKA backends'
   aggregate RAM**, the sole path by which this could force a larger corpus and affect capacity sizing.
   Detail: `runs/Stage-6-Feature-Extraction.md`.
8. **Confirm real per-slide tile counts from the actual 3.0 coords** before sizing the 6.B.1 file-size grid or
   committing 6.A Tier 2 wallclock — both currently rest on magnification arithmetic, not measurement.
9. **Counter-semantics check for cross-leg `ops/s`.** Until verified comparable, app-level throughput is the
   cross-leg headline and ops/s is a within-leg diagnostic. Detail: `runs/Stage-2-Cataloging.md`.
10. **Core accounting.** Measure the WEKA client's reserved core count on the real instance (and confirm
    Lustre's is zero), so saturation headlines divide by application-available cores and the reservation is
    reported as part of WEKA's cost. Detail: `STAGES.md` **D15**.
11. **Record both sides' provisioned configuration into the environment contract** — WEKA: backend type and
    count, capacity, EC scheme, client networking mode. FSx: tier, capacity, provisioned metadata IOPS, EFA
    state. Without these the fairness basis is unverifiable after the fact. Detail: `STAGES.md` **D6/D7**.
12. **Confirm raw-TIFF capacity headroom on both filesystems before the 4.D conversion** — order ~7 TB at full
    cohort, and on FSx capacity is simultaneously a performance knob, so it is a sizing input.
13. ⚠ **Fix seven measurement-correctness bugs in the Python workers before any measured cell.** Each produces
    a plausible number that is wrong, which is worse than a crash:
    - `read-tiles-kvikio.py` samples the completion timestamp **before** the `f.get()` drain loop, so recorded
      per-tile latency **excludes the actual I/O wait** — the headline latency of the GPU-direct path.
    - `extract-features-foundation-stage6.py` allocates the embedding buffer with `torch.empty` and never
      checks all `n_tiles` rows were filled, so a short read saves **uninitialised GPU memory** as features.
    - `read-tiles-onthefly.py` resolves each slide path with a full `iterdir()` over ~1133 directories
      **inside the timed loop**, so 4.B partly measures directory scanning.
    - `parse-results.py` emits `<col>_per_sec` as the raw delta between samples **without dividing by dt**,
      while recorders sleep 1 s *plus* loop overhead — a systematic overstatement of every wire-counter rate,
      which feeds the canary ratio check.
    - `read-feature-files-stage6b.py` drops the page cache in worker 0 *after* the pool has started, so the
      other workers are already warming it.
    - `aggregate-stage4c-kvikio.py` infers its `gds_engaged` column **from the run-dir name** — i.e. from the
      requested config, which is precisely the "a config flag is not proof of behaviour" rule (**D8**).
    - `read-after-write-stage7.py` sizes its heatmap from an assumed ~5× compression ratio while the synthetic
      content compresses far harder, so `--bytes-per-write` is not the bytes written; its 10 ms poll also
      quantises the visibility latency it measures.
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
18. **[USER] WEKA license cost in the price claim** — deliberately deferred. "We're cheaper" is not credible
    with the licence excluded and unlabelled; either price it in or label the figure infrastructure-only.
    Detail: `STAGES.md` **D7**.

## B. Watch during benchmarking

1. **Instance revisit trigger.** If Leg A's synthetic ceiling pins at line rate across block sizes **and** the
   `num_workers` sweep saturates on CPU cores rather than storage, the instance is measuring itself rather
   than the filesystems — move up before Leg B. Pre-committed so the call is not made later under sunk cost.
   Detail: `STAGES.md` **D10**.
2. **Coord-equivalence gate between legs.** Completeness and per-slide tile counts are storage-independent, so
   any cross-leg divergence proves the legs did not process identical inputs. **Fail loud; invalidates
   downstream comparison.** Detail: `runs/Stage-3-Tissue-Detection.md`.
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
   `runs/README.md`'s design that a bad cell goes `INCOMPLETE` without taking down the sweep.
10. **UNI2-h results stay internal-only** — don't strip the tags in refactors; filter those rows before
   anything leaves the building. More important here than in an internal study, since a competitive comparison
   is likelier to be externalised. Detail: `[[uni2h-conditional-use-status]]`.
