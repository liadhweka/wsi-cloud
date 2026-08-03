# Pre-deployment audit report — 2026-08-03

Audit of this repository immediately before it is cloned onto the rented cloud GPU instance. Brief:
[`AUDIT-PROMPT.md`](AUDIT-PROMPT.md). Scope: every file inside this repository, judged on factual accuracy,
staleness, cross-reference integrity, internal consistency, executability, simplification, completeness, and
the drop-in test for three audiences.

**Method.** A mechanical pass (syntax checks on all 61 scripts, guard-path execution, `git check-ignore`
tests, variable extraction, official-doc verification) plus a ten-cluster parallel deep-read with an
independent adversarial verification stage on every proposed finding — 20 agents, 0 errors. 248 candidate
findings were raised; **85 were refuted** on verification (mostly deliberate features mistaken for defects,
or claims whose evidence did not reproduce) and **163 survived**, 136 of them at blocker or major severity.
Everything below was re-derived before being acted on.

Two verifier agents (the Python-worker and sweep-driver clusters) returned after the fixes had been applied.
Their 72 verdicts were checked against what had actually changed: **none of their three refutations
invalidated a change.** One refuted the aggregator-`fs`-pivot finding as "declared deferred work, do not
re-report" — correct, and no aggregator code was touched; only the *documents that claimed the pivot already
worked* were corrected, which is a separate and real accuracy defect. One refuted a finding as "true at HEAD,
false now", having watched the fix land mid-audit. One refuted the 8-GPU maps as "deferred item `D-8`, not an
undiscovered defect" — also correct, and that change was made on the owner's explicit ratification, with the
remaining pinning order left marked ⏳ `D-8`. Their verdicts additionally confirmed four small defects not yet
reached, now fixed (see § Late additions).

**Verdict: not drop-in ready when the audit started — two defects would have stopped the first cell, and
four more would have silently corrupted or lost measurements. It is drop-in ready now for provisioning and
the build phase, with a short list of items that must be closed before the first *measured* cell.** See
§ Verdict.

---

## What was verified and found correct

Worth recording, because two of these look wrong and are not:

- **`4× L40S (178 GiB)` is right.** AWS lists g6e.24xlarge GPU memory as *"178 GiB (4 x 44 GiB)"*, not 192.
  Also confirmed: 96 vCPU, 768 GiB, **2 network cards**, 200 Gigabit, 2 × 1900 GB NVMe, EFA supported;
  g6e.48xlarge = 8× L40S / 400 Gbps / 192 vCPU / 357 GiB; g6e.12xlarge = 100 Gbps / 48 vCPU.
  *(docs.aws.amazon.com/ec2/latest/instancetypes/ac.html, fetched 2026-08-03.)*
- **Every FSx figure checks out verbatim**: PERSISTENT-1000 = 1000 MBps/TiB disk, **2600** MBps/TiB network
  baseline, **27.3** GiB cache RAM per TiB; user-provisioned metadata IOPS to a **192,000** maximum,
  independent of capacity on Persistent 2; the **5 Gbps per-client-per-object-storage-server** limit is
  footnoted to the non-EFA and EFA-with-ENA rows only, so an EFA-mounted client does escape it; GPUDirect
  Storage is supported on EFA-enabled file systems with EFA-enabled clients. Derived arithmetic is
  self-consistent (25 TiB × 1000 MBps = 25 GB/s; 27.3 × 25 = 682.5 ≈ "~680 GiB").
  *(LustreGuide `ssd-storage.html` and `performance.html`, fetched 2026-08-03.)*
- **Cohort counts reconcile end to end**: 1133 downloaded → 1131 with coords → **1073** kept, 51 true-20×
  and 7 unknown-mpp excluded. `tcga-brca-full.tsv` sums to 1.054 TiB, matching the "1.05 TiB" claim. The
  50-slide subsets contain 50 slides.
- **Every count in the deferred-work tables**: 25 shell files retargeted to `$FS_MOUNT`, 28 repo-root
  derivations, 7 Python argparse defaults across 4 files, 19 files carrying the previous hostname, 13
  per-stage aggregators, 21 orchestrator steps (now 22) with exactly 2 missing by design. All exact.
- **Deferred-item ids `D-1`…`D-14`**: complete, no gaps, no duplicates, no references to retired ids.
- **`.gitignore` behaves as documented** for `raw/`, `cmd.log`, `sweep-logs/`, `workload-*.csv`, and does not
  swallow `results.json`, `metadata.json`, `0_README.md` or `notes.md` (tested with `git check-ignore`).
- **All 32 shell files parse; all 29 Python files compile.** Every guard tested exits non-zero with a correct
  message: `record-run.sh` (8 paths), `sync-to-s3.sh` (6), `run-leg.sh`, `env.example.sh --check`,
  `backup.sh`'s empty-source refusal, `env-contract.py write` on an incomplete contract.
- **Memory index is exactly 1:1** with the 19 memory files. All markdown links resolve. All 48 distinct
  script paths named in docs exist.
- `runs/lib/cufile-full-rdma.template.json` is not strict JSON — **correctly so**: NVIDIA's shipped
  `cufile.json` uses the same `//`-comment dialect. Flagged, not "fixed".

---

## Fixed — would have stopped execution

**1. No cell could run: `record-run.sh` required `--fs`, and nothing passed it.** *(A, E — BLOCKER)*
`record-run.sh` refuses without `--fs {weka|lustre}` (exit 2), and it was the **only file in the repository
that mentioned `--fs`** — all 24 drivers invoked it with `--stage`/`--run-name`/`--note` only. Every sweep
would have died on its first cell. `SCRIPT-TRACKER.md:46` listed this as ✅ done; only the wrapper half was
built. The two docs also disagreed about the intended shape (`runs/README.md` showed
`sweep-stage1-seqw.sh --fs weka`; `run-leg.sh:59` stated drivers *"take no arguments"*).
**Fix (owner-ratified, option A):** `record-run.sh` still takes `--fs` and now falls back to `$LEG` when the
flag is absent — explicit configuration, not a default; with neither set it still refuses. `NAMING-AND-VARIABLES.md`,
`runs/README.md` and `SCRIPT-TRACKER.md` corrected to describe the actual mechanism.

**2. `run-leg.sh` could not execute 7 of its 21 steps.** *(A, E — BLOCKER)* The step table invoked each
driver bare, but `sweep-stage4c-kvikio.sh`, `-stage5-training.sh`, `-stage6a-extract.sh`, `-stage6b-mil.sh`,
`-stage6b-stress.sh`, `-stage6c.sh` and `-stage7-clinical.sh` all dispatch on `$1` and exit 2 with a usage
message when given none. The chain would have aborted at step 4.C — seven steps in.
**Fix:** each step now carries its target (4.C `tier1`, 5 `all`, 6.A `tier1`, 6.A.3 `tier3`, 6.B.3 `all`,
6.B.2 `all`, 6.C `all`, 7 `all`), with the rationale for each choice recorded inline; the runner word-splits
the command. Tier 2/3 of 4.C stay out of the chain because the roadmap defines them as adaptive and
conditional on Tier 1's results. A new step **6.A.3** was added — `sweep-stage6a-extract.sh tier3` existed but
nothing in the orchestrator ran it, so Tier 3 was silently absent from every leg. **22 steps now.**

---

## Fixed — would have silently corrupted or lost measurements

These are the expensive class: the run completes, the numbers look plausible, and the defect is invisible.

**3. Nine drivers built run-dir names without the filesystem segment — so their telemetry would never have
reached S3, and the teardown gate would still have said GO.** *(A, D — BLOCKER)*
`sync-to-s3.sh` and `teardown-preflight.sh` both glob `runs/*-$LEG-s*/`. Nine drivers pre-computed
`<ts>-s<stage>-<name>`, and `record-run.sh` honours a caller-supplied `RECORD_RUN_DIR` verbatim. Every cell
from Stage 4.C, 5, 6.A, 6.B, 6.C, 7 and both Phase-0 baseline helpers would have been invisible to the sync
**and** to the check that exists to prove nothing is lost — the one failure mode the durability rules are
written against.
**Fix:** `${LEG}` inserted into all **21** pre-computed names; a fail-loud `LEG` guard added to all nine
drivers; the load-bearing reason documented at the naming site, in `NAMING-AND-VARIABLES.md` and in the
handoff prompt.

**4. Four drivers wrote a cell's app-level primary source into an orphan directory.** *(A — BLOCKER)*
`sweep-stage4c-kvikio.sh` (4 sites), `sweep-stage5-training.sh`, `sweep-stage6c.sh` and
`sweep-stage6a-extract.sh`'s `smoke()` interpolated `$run_dir/…` into the wrapped command's arguments but
never set `RECORD_RUN_DIR`. `record-run.sh` then created a *different* directory, and the child `mkdir -p`'d
the stray one — so Stage 5's per-step CSV, 4.C's `reader-summary.json` and 6.C's per-workload CSVs would have
landed outside the run dir, with the recording and the application data permanently unjoined. This is
cross-cutting pattern **#4** in `SCRIPT-TRACKER.md`, applied in six places and missing in four.
**Fix:** `RECORD_RUN_DIR="$run_dir"` added to all four. The invariant is now checked mechanically (every
function that interpolates `$run_dir` into a child's args must also set it) — currently zero violations.

**5. The GPU-direct cells would have run on the wrong libcufile, silently.** *(A, E — BLOCKER)*
`LIBCUFILE_117=/usr/local/cuda-13.2/…/libcufile.so.1.17.0` was hardcoded in **8 files**, and **5 never
checked the file exists**. A missing `LD_PRELOAD` target is a no-op with a warning, so those cells would have
used the conda environment's bundled copy and still reported numbers. `LIBCUFILE_PRELOAD` was documented in
`NAMING-AND-VARIABLES.md` Table 3 and read by **zero** scripts.
**Fix:** all 8 read `$LIBCUFILE_PRELOAD`, refuse if unset, and verify the file exists. Added to
`env.example.sh` (with `--check`) and promoted to Table 1 with the path-vs-`LD_PRELOAD` distinction spelled
out. `run-multiproc-kvikio.sh`'s two self-referential defaults
(`${CUFILE_ENV_PATH_JSON:-${CUFILE_ENV_PATH_JSON}}`) replaced with real guards.

**6. Prior-environment results and pre-assigned conclusions were embedded in recorded run metadata.**
*(D9 violation — BLOCKER)* Cell `--note` strings are written verbatim into every run's `metadata.json` and
`0_README.md`, and several carried measured figures from a different environment as the *rationale* for the
cell — "Tier 2 found N=4 hits WEKA ceiling (~5.36 GB/s, matching Stage 1.0d synthetic 5.25 GB/s)",
"1.72 GiB/s from 1.5 = ~56% of write ceiling", "the Stage 4.C peak config (5.48 GB/s reference)", "Saves
~55 hr". `sweep-stage3-tissue-detection.sh` asserted an outcome outright: *"WEKA never bottlenecks on
either"*. `sweep-stage6c.sh` called Tier 4 *"the killer-differentiator story"*. `sweep-stage1-mixed.sh` and
`-fpsync.sh` wrote a `notes.md` canary template naming a previous host, a previous NIC and a specific
erasure-coding scheme into **every** cell — including Lustre-leg cells.
**Fix:** every note and header rewritten leg-agnostic. The methodology *why* is kept in full (it is
mandated); every prior number, expected magnitude and pre-assigned headline is gone. Canary templates now
point at this leg's Primary sources and this leg's relation, marked ⏳ `D-5`.

**7. `0_README.md` was written empty on every run.** *(E — MAJOR)* `record-run.sh` referenced `${REPO}`,
which `D-2` had removed; under `set -u` the heredoc redirection failed and the file was created at 0 bytes.
Reproduced in isolation and confirmed by the committed smoke run's 0-byte file. It is git-authoritative per
`D14` and `runs/README.md` calls it "the first thing a future reader should look at".
**Fix:** derives `REPO_ROOT` from its own location. Verified: now 1629 bytes with the filesystem, mount,
command and note. The title and the `INDEX.md` line also omitted the `-<fs>-` segment, so no index entry
matched its directory — both corrected. The stale generated body ("8 GPUs", "1.1 = TCGA pilot", "the WEKA WSI
benchmarking project") rewritten.

**8. The environment contract never reached S3, and its completeness check had drifted.** *(A, D, G —
BLOCKER)* `sync-to-s3.sh` had no `env-contracts/` path in any mode, yet `teardown-preflight.sh` NO-GOes
without it, Leg B fetches Leg A's contract from there (`NEW-CLOUD-SETUP.md` § 8.7), and `env-contract.py`
itself says "Upload with sync-to-s3.sh". Separately, `teardown-preflight.sh` restated the held-constant field
list as **9** fields against the contract's **17** — so it would report "complete" for a contract
`env-contract.py write` had itself rejected. Demonstrated: on a contract missing 8 held-constant fields the
old check returned 0 (GO); the fixed one returns 8 (NO-GO).
**Fix:** contracts uploaded with archive (never-delete) semantics, with the reason recorded; preflight
imports `MUST_MATCH` from `env-contract.py` via `importlib` (the filename is hyphenated), one source of truth.

**9. `libcufile_version` could never be recorded, so the contract could never pass.** *(A — BLOCKER)*
`ls … | head -1` sorts the SONAME symlink `libcufile.so.0` first; it has no 3-component version, so the grep
found nothing and this **`MUST_MATCH`** field came out null — making `write` exit non-zero and `verify`
report it UNVERIFIABLE (= FAILED) on every run, on both legs, forever. The whole cross-leg comparability
mechanism hinged on it.
**Fix:** prefers the libcufile actually preloaded (`$LIBCUFILE_PRELOAD`), falls back to the newest *versioned*
file via `sort -V`. Round-tripped: 16/17 fields captured in a synthetic environment (the 17th is
`script_commit`, absent because the test dir is not a git repo). `libcufile_path` added to `MAY_DIFFER`.

**10. The Stage-7 aggregator matched nothing.** *(A — BLOCKER)* Its regex anchored `-s7-` immediately after
the timestamp, so the filesystem segment broke it — and the glob `*-s7-*` missed the `-s7.1-`…`-s7.6-` dirs
that `record-run.sh` names from `--stage`. **This one was partly created by fix 3**, which is why the
re-verification pass exists: only this aggregator anchored on the timestamp; the other 13 use unanchored
`-sN.M-…$` patterns that tolerate the new segment.
**Fix:** stage part unanchored, sub-stage optional, glob widened, timestamp and filesystem extracted
separately. Five naming cases tested, all pass.

**11. `runs/.leg-state/` was not gitignored, so every teardown would have blocked.** *(E — MAJOR)*
`run-leg.sh`'s done-markers dirtied the tree and `teardown-preflight.sh` NO-GOes on a dirty tree — the gate
would have refused until someone committed per-leg scratch state. **Fix:** ignored, with the reason.

**12. The conda interpreter path was a hardcoded literal in 16 drivers.** *(E — MAJOR)*
`CONDA_ENV=/data/local-nvme/conda-envs/wsi-cucim-2604`, documented nowhere, contradicting
`NAMING-AND-VARIABLES.md`'s own "Nothing is hardcoded in the scripts". It happens to match the *planned*
value — worse than a mismatch, because it works until it silently doesn't. Same class: five drivers hardcoded
`/data/local-nvme/...` scratch paths. **Fix:** new documented `CONDA_ENVS_DIR`; all 21 sites derive from
`$CONDA_ENVS_DIR`/`$CONDA_ENV_MAIN`/`$CONDA_ENV_ALT`/`$SCRATCH_DIR` with fail-loud guards.

**13. `run-leg.sh --from`/`--only` accepted any value.** *(E — MAJOR)* A typo (`3.O` for `3.0`) matched no
step, skipped everything, and exited **0** reporting "0 step(s) run" — which reads as success on an overnight
run. **Fix:** both validated against the step-id list, with the valid ids printed.

---

## Fixed — accuracy, staleness, and cross-reference integrity

- **Broken memory references.** `CLAUDE.md` cited four memories by names that do not exist
  (`autonomous-execution-cadence`, `complete-implied-work`, `docs-fetch-standing-approval`,
  `methodology-revisability` — all missing their `feedback_` prefix); `runs/STAGES.md` and two memories cited
  three more under retired names; four scripts cited `cucim_libcufile_preload_abi_clash`, which was never a
  memory name. All corrected; a resolver now reports zero unresolved references.
- **References to `project_a100_state.md`, a memory that does not exist in this repository**, cited seven
  times across three aggregators as the authority for the reserved-core exclusion set. Re-pointed at
  `STAGES.md` **D15** and cross-cutting pattern #1, with the hardcoded core range marked ⏳ `D-9` rather than
  asserted as fact.
- **Stale section pointers into the setup guide.** `TEARDOWN-AND-REBUILD.md` sent the rebuild to
  "`NEW-CLOUD-SETUP.md` **B2–B6**", `handoff-cloud.md` to "§ B8", `NAMING-AND-VARIABLES.md` to "§ B8", a
  memory to "§ B8" — the guide has no B-sections at all (Part 0…Part 8 with `N.M` subsections). All
  re-pointed; the rebuild path now names Part 3 and Part 4 and says which parts to skip and why.
- **A wrong command in the rebuild path.** `TEARDOWN-AND-REBUILD.md` § 8 told the operator to re-hydrate
  datasets with `sync-to-s3.sh --mode datasets`, which uploads local → S3. Corrected, with the direction
  stated and the missing hydration driver marked ⏳ `D-13`.
- **Contract filenames.** `FILESYSTEM-MAP.md`, `SPINUP-CHECKLIST.md` and `env-contract.py`'s own docstring
  named `leg-a-weka.json` / `leg-b-lustre.json`; the code writes `env-contract-leg-<leg>.json`. Unified on the
  code's name.
- **Nine stale `⏳ DEFER` lines in `SCRIPT-TRACKER.md`** still named `D-1`/`D-2`/`D-3`, which the same file's
  Done table lists as complete — including `record-run.sh` deferring the flag it now requires. All re-scoped
  to the work that genuinely remains.
- **`README.md` listed completed work as deferred**; `handoff-cloud.md` told a fresh session that "`D-1`
  mount retargeting (**36 files**) is the highest-severity item" — `D-1` is done, and the count was never 36
  (25 + 4). Both corrected, so the cloud session does not redo finished work.
- **Claims the aggregators do not support.** `runs/README.md` and `README.md` asserted "aggregators pivot on
  `--fs`" and "the aggregators derive their `runs/` path from `__file__`". Neither holds: **no** aggregator
  reads `metadata.json` or emits an `fs` column, and only **7 of 14** self-locate — the other seven exit 2
  without an explicit glob. Corrected, with a copy-pasteable example for the glob-taking group and the pivot
  marked ⏳ `D-4`.
- **`PROJECT-THESIS.md` showed a 2×2 GPU-direct matrix** where every other authority specifies 2×3
  (POSIX / compat / GDS on both sides). Corrected to 2×3 with the reason.
- **`PRESENTING.md`** claimed five block sizes for all four fio ceiling sweeps — true for the sequential
  pair, but the IOPS pair uses three (4K/16K/64K) at deeper queue depth. Corrected. It was also the only
  document naming UNI2-h **without** the internal-only constraint every other file carries — and it is the
  document written to be presented. Tag and filtering instruction added.
- **`CLAUDE.md`'s teardown checklist ordered the environment contract last**, after `git push` and the final
  S3 sync — but it is both a git-tracked file and an S3 object, so writing it last leaves it in neither, and
  the pre-flight checks for it in both. Reordered to match what `TEARDOWN-AND-REBUILD.md` actually does; the
  same error in `feedback_git_commit_cadence` fixed. `CLAUDE.md`'s docs-cadence table had **no row for
  `README.md`** despite `README.md` carrying counts and a deferred-work list that drift — row added.
- **`FILESYSTEM-MAP.md`** listed 2 of the 8 entries in `cloud-setup/` (omitting the setup guide, the naming
  doc, the config template, the teardown checklist and both session prompts), said `backup.sh`'s S3 half was
  still a build item (it is wired in), and showed the build machine's memory slug as if it were the value.
  All corrected.
- **`prompt-env-prep-cloud.md`** asked apt for a package named `fpsync`. There is none: `/usr/bin/fpsync`
  ships inside `fpart` *(packages.ubuntu.com/jammy/amd64/fpart/filelist)*. Corrected, with a post-install
  check, since Stages 1.5/1.6/6.C need it.
- **`NEW-CLOUD-SETUP.md`**: the Hugging Face login was placed with a note to retry "after Part 5", but `hf`
  arrives with the environments in **Part 7**; `git config user.name/user.email` was never set, so the
  operator's first commit — and this project's commits are all theirs — would have failed; `LIBCUFILE_PRELOAD`
  had no capture step; and § 6.5 did not warn that an early `env-contract.py write` legitimately exits
  non-zero. All four addressed.
- **Open-item identifiers were ambiguous and gapped.** Section A and section B both numbered items 9 and 10,
  and no item 18 existed — while five documents cited items by position, three of them pointing at the wrong
  item. Section B now uses the stable `D-n` ids, section C uses `C1`…`C12`, and the five external references
  were re-pointed at `D-n` ids.
- **Stale counts and figures**: "63-script library" (63 files, 61 scripts); "21 steps" (now 22); "1131
  slides" in two recorded Stage-6.A notes where the cohort of record is **1073**; `NAMING-AND-VARIABLES.md`'s
  "8 docs and 60 scripts".
- **Host-specific residue** removed from live code and comments: the old NIC fallback list in
  `record-run.sh`, a previous host's NUMA/NIC map and hostname-resolution diagnosis in the Stage-5 and
  Stage-6 workers, `/usr/local/cuda-13.2/…` paths in two Python usage examples, and a claim that the host has
  256 cores (the instance has 96 vCPU). Owner-approved deletion of the committed build-machine smoke run
  (`runs/2026-08-03-190845-weka-s0-x/`, 50 tracked files: hostname `a100`, `/mnt/liad`, InfiniBand counters)
  and reset of `runs/INDEX.md` — which also makes `runs/README.md`'s "this tree is pristine" true again.
- **GPU-count sweeps brought to the instance** (owner-ratified): Stage 5 is N ∈ {1,2,4} across both blocks
  (6 cells, was 5 with an unrunnable N=8 pair and one lone 5.B cell); Stage 6.A's map is 0-based with the
  N=8 Tier-2 target removed; `orchestrate-clinical-deployment-stage7.sh` derives its GPU assignment from a
  device count instead of a hardcoded 8-GPU map; Stage 4.C's Tier-3 ceiling-stress cell becomes an explicit
  8-processes-over-4-GPUs oversubscription cell, which is what the roadmap's "push process count" actually
  asks for on this instance. Every remaining index literal is valid on a 4-GPU host, and each is marked
  ⏳ `D-8` for the NUMA/NIC ordering. Stage 5's `all()` no longer swallows a failed cell.
- **`fe-core-fio.sh` / `fe-core-kvikio.sh`** were framed as a WEKA-only "frontend-core scaling" experiment
  with a prior throughput reference, and `fe-core-kvikio.sh` was not executable despite its own documented
  `./fe-core-kvikio.sh` invocation. Both are now leg-agnostic single-cell spot checks, and both they and
  `handoff-cloud.md` § 4.5 now say plainly that they are **not** the per-block-size ceiling capture — the
  Stage 1.0a–d sweeps are, and those are what every "% of ceiling" denominator must come from.

---

## Raised, not fixed — needs your decision or the real environment

Numbered for reply. **Each maps to an entry in the `cloud-session-open-items` memory — verified by search,
not asserted** (an earlier version of this report claimed coverage that three items did not have):

| Item | Memory entry |
|---|---|
| 1 — nine worker measurement bugs | `A.9b` |
| 2 — GPU-bearing AMI | `C10` |
| 3 — Lustre client EFA configuration | `D-16` |
| 4 — kernel-vs-contract conflict | `D-17` |
| 5 — step 4.D not actually recorded | `D-15` |
| 6 — inconsistent failure propagation | `C11` |
| 7 — 25 undocumented workload variables | `D-18` |
| 8 — substage 1.8 unimplemented and unmarked | `D-19` |
| 9 — Stage 4.B cold-cache hardwired off | `A.5a` |
| 10 — manifest provenance headers | *(none — see below)* |

Item 10 deliberately has **no** memory entry: the recommendation is no action, and it is not something to
resolve before a cell, build in the cloud session, or watch during benchmarking — the three things that
memory is for. Adding it would grow the file without changing what anyone does.

Items **fixed** during the audit are likewise not in that memory — it holds only open items, and completions
belong in `SCRIPT-TRACKER.md`'s two done tables (`D-*` and `A-1`…`A-13`). One fix was only partial and so does
carry an entry: `CHUNK_SIZE`'s carried-over justification was removed but the value still needs the real
capacity — open item **9d**.

1. **Nine measurement-correctness bugs in the Python workers** (memory item A.9b). Each yields a plausible
   wrong number. Highest three: `read-tiles-kvikio.py` samples its completion timestamp *before* the
   `f.get()` drain loop, so the recorded per-tile latency **excludes the actual I/O wait** — the headline
   latency of the GPU-direct path; `extract-features-foundation-stage6.py` allocates with `torch.empty` and
   never checks all `n_tiles` rows were filled, so a short read saves **uninitialised GPU memory** as
   features; `parse-results.py` emits `<col>_per_sec` as the raw inter-sample delta **without dividing by the
   actual dt**, systematically overstating every wire-counter rate that feeds the canary ratio check.
   *Recommendation:* fix all nine in the cloud session before the first measured cell — they are small,
   local, and each is independently testable. I did not touch them because each needs a run to validate
   against, and a wrong "fix" to a measurement path is worse than the bug.
2. **The instance needs a GPU-bearing AMI, and no document provides one** (memory C10). A plain Ubuntu image
   ships no NVIDIA driver, no CUDA, no `nvidia-fs`, no `libcufile`, and `prompt-env-prep-cloud.md` explicitly
   refuses to install a driver. The documented path dead-ends at Part 5.
   *Recommendation:* launch from the current AWS Deep Learning Base GPU AMI (Ubuntu), confirm the exact image
   name in the console rather than a remembered title, and pin the AMI ID. This is a provisioning decision,
   so it is yours.
3. **Part 8 never configures the Lustre client for EFA** (memory `D-16`). It enables EFA on the instance and
   requests it on the file system, and installs the generic EC2 EFA software — but never runs AWS's
   FSx-Lustre EFA client setup, so the client would mount over TCP. That forfeits GPUDirect Storage *and* the
   escape from the per-server cap while still producing numbers, which breaks the "Lustre at maximum"
   fairness basis (**D7**) invisibly. *Recommendation:* add the step against current AWS documentation plus a
   hard gate that `lnetctl net show` lists an `efa` net before any Leg-B cell.
4. **Part 8.4 installs `linux-aws`, which can move the kernel — and `kernel` is a `MUST_MATCH` contract
   field** (memory `D-17`). The documented Leg-B procedure can therefore invalidate the comparison the
   contract exists to protect; Part 3's `apt-get upgrade -y` can too. *Recommendation:* pin the kernel and
   install the matching `lustre-client-modules-$(uname -r)`; record `uname -r` immediately after launch and
   compare it to the contract *before* installing anything.
5. **Step 4.D is not actually recorded** (memory `D-15`). `convert-stage4c-rawtiff.sh` is `run-leg.sh` step
   4.D and its own header calls it a recorded cell, but it never invokes `record-run.sh` — so the 20×
   raw-TIFF conversion, which the roadmap treats as a measured large-sequential-write workload, produces no
   run dir, no telemetry, no `INDEX.md` row and no S3 sync. It also does not fail loud when zero slides
   resolve. *Recommendation:* wrap it in `record-run.sh` in the cloud session; the change is small but it
   changes what a substage produces, so it is a methodology touch.
6. **Failure propagation is inconsistent** (memory C11). `run-leg.sh`'s "abort the chain on step failure"
   guard only sees the driver's exit status, and no driver propagates per-cell failures. I removed the
   swallowing in Stage 5 as you ratified; the other eight sweeps still swallow. Note this collides with
   `runs/README.md`'s stated design that a bad cell should go `INCOMPLETE` without taking down the sweep.
   *Recommendation:* attempt every cell, then exit non-zero if any failed — satisfies both, and gives
   `run-leg.sh` the signal it needs.
7. **25 `INFER_*` / `EXTRACT_*` / `MIL_*` environment variables** that the Stage-6.C and Stage-7
   orchestrators read are documented in neither `NAMING-AND-VARIABLES.md` nor `env.example.sh`. They all have
   in-script defaults, so nothing fails — but they are the knobs those stages are configured through, and an
   undocumented knob is one that silently differs between legs. *Recommendation:* add a Table 5 for
   per-stage workload parameters; low risk, and it closes the variable-coverage gap properly.
8. **Substage 1.8 (FSx-native S3 import) has no implementation and no marker.** It is the only substage in
   any roadmap with neither a driver row, an explicit "no implementation" note, nor a deferred-item id.
   *Recommendation:* give it a `D-n` id so it cannot be quietly forgotten — it is a Lustre-leg capability
   cell, so it is also the easiest to lose.
9. **Stage 4.B's only cold-cache mechanism is hardwired off**, justified by a claim about a previous host's
   RAM. On a 768 GiB instance the justification does not transfer, and cold-vs-warm is a hard enforced axis
   (**D13**). *Recommendation:* re-derive the crossover on the real instance before running 4.B; it is a
   methodology call, so I left it.
10. **Three manifest headers still record `/mnt/liad` as the path the coords were generated from.** This is
    provenance, not a live path, and editing a manifest changes `dataset_manifest_sha`. *Recommendation:*
    leave them. Flagged only so it is a decision rather than an oversight.

---

## Late additions

Four defects confirmed by the two late verifier agents, each with reproduced evidence, each fixed:

- **`sweep-stage1-mixed.sh` invoked `fio` by absolute path** (`/usr/local/bin/fio`, at the measured wrapper
  and in the copy-pasteable prep block) while all four sibling Stage-1 drivers use bare `fio`, and
  `prompt-env-prep-cloud.md` installs it from apt (→ `/usr/bin/fio`). Stage 1.6 would have failed with
  "no such file". Now bare `fio` like its siblings.
- **`inference-per-slide-stage7.py` silently defaulted to GPU 2** when `CUDA_VISIBLE_DEVICES` was unset —
  and that index encoded a previous machine's NIC-adjacency finding, so it would have pinned to a GPU chosen
  for different hardware. It now refuses, matching every other unset-configuration path in the project. All
  four callers pin it explicitly, so nothing regresses.
- **`sweep-stage6b-stress.sh`'s cell counts were wrong in five places**: `b2c` loops four file sizes
  (5/10/50/200 MB) but the header, both usage lines and the `all` banner claimed three, and the total claimed
  24 instead of 25.
- **`CHUNK_SIZE=200` was keyed to another environment's capacity** ("Full BRCA raw-TIFF is ~32 TB…
  Filesystem is 31 TB") in both Tier-2 orchestrators. It is the parameter that decides whether Tier 2 fits on
  disk, so a stale value either wastes capacity or fails mid-cohort after hours of conversion. The carried-over
  figures are gone. **The value itself remains open** — it cannot be computed until the real provisioned
  capacity and per-slide raw-TIFF size are known — so it is tracked as open item **9d** rather than left as an
  inline code comment, which is the buried-where-nobody-looks failure the memory rule exists to prevent.

`D-10`'s scope was also corrected: it said "20 files reference conda/cuFile/CUDA paths — **now via
variables**", which was false when written (they were literals) and is true only after audit items `A-4`/`A-5`.
It now says so, and scopes the remaining work to the *values*.

---

## Follow-up pass: `cloud-setup/` end to end

Requested separately after the main audit, because this folder is the part executed **by hand** and the part the
audit had edited most without re-reading whole. Read in its post-edit state and traced as an executor, not a
reader. Nine findings, all fixed.

**Ordering — three, one of which blocked a step:**
- **The Hugging Face login sat at § 4.4 but cannot run there** — `hf` arrives with the Python environments in
  Part 7. Split: 4.4 now gets the token and requests model access (which takes approval time, so early is
  genuinely better); the login is **new § 7.2**, with an interpreter-qualified command so it works before
  anything is on `PATH`. `handoff-cloud.md` and the rebuild path both remind at the right moment.
- **The AMI warning was below the launch table**, but the OS image is the wizard's *first* field — you would
  have chosen before reading it. Moved above, and it now also flags the other two fields that cannot be changed
  after launch (EFA interface type, IAM instance profile).
- **§ 3.2's kernel warning followed the code block** and said to record `uname -r` "immediately after launch"
  when the reader has only just logged in. Rewritten as an ordered sequence, with the honest framing: a kernel
  change is fine on Leg A, it just becomes the value Leg B must reproduce.

**Missing information — four:**
- **Nothing said how to build the Python environments.** `env-specs/` holds four non-interchangeable file types
  and `env-create-history.txt` — the only file with the actual `mamba create` commands — was referenced by
  nothing. `handoff-cloud.md` § 4.1 now carries a route table: recipe for the first build, **pinned
  `*.conda-explicit.txt` for the Leg-B rebuild** (because `conda_env_main` and `python_version` are `MUST_MATCH`,
  so the environment is a held-constant input), `environment.yml` as fallback with its `-p`-not-`-n` gotcha,
  pip-freeze as cross-check only — plus regenerate the specs from what was actually built.
- **§ 6.2 listed six WEKA values with no indication where any came from.** Now attributed, with an escape hatch
  and one exception (`WEKA_EC_SCHEME`, which the canary cannot be derived without).
- **`SPINUP-CHECKLIST.md` never mentioned the AMI** — and it is the document handed to whoever provisions, so
  they would have launched plain Ubuntu. Added as item 2b. It also had no pointer to the step-by-step guide;
  added, with an explicit division of labour (checklist owns the *reasoning*, guide owns the *procedure*) so the
  eight facts appearing in both have a defined authority.
- **Nothing warned that the meter starts at launch**, or that stopping the instance is not a cost pause.

**Rebuild path — two:** "restore values from the contract in S3" gave no command (now `aws s3 cp` +
`env-contract.py show`, and names the two values `--check` only *warns* about); and the conda rebuild had the
same route ambiguity plus no mention that the HF token died with the home directory.

## Follow-up pass: the WEKA half of Part 6

Part 6 was four subsections of "use your usual process" against Part 8's fully-specified eight — an asymmetry in
the *instructions* mirroring the asymmetry the study is about. Rewritten to nine subsections, grounded in eight
`docs.weka.io` pages cited inline. The four things a first-time WEKA-on-AWS operator hits:

1. **Capacity is already allocated.** WEKA's docs: on a cloud platform "the WEKA system includes a default
   filesystem configured to maximum capacity" — so `weka fs add` fails until it is shrunk (`weka fs update
   <name> --total-capacity`). New § 6.3 makes you look first; § 6.4 does the shrink, with a data-loss warning.
   An explicit "just use the default filesystem" option is offered as Option B.
2. **A filesystem group is mandatory** — `weka fs add <name> <group-name> <total-capacity>` takes it as a
   positional argument, so § 6.5 creates one. Its tiering options are deliberately left at defaults: object
   store access is out of scope.
3. **Reaching the cluster** — the CLI lives on every backend; `weka -H <ip>` drives it from the GPU instance;
   authentication via `weka user login` / token file / `WEKA_USERNAME`, defaulting to `admin`/`admin` when
   neither exists. Note one backend IP before leaving the console.
4. **The client installs from a backend on port 14000**, and the **first mount joins the cluster**.

Two things were made load-bearing rather than incidental: `num_cores` is a **measured** quantity (those cores
are unavailable to the benchmark — decision **D15**) and must not change mid-leg; and the UDP fallback is a
**finding, not a workaround**, because it would understate WEKA and break **D7** as silently as an
under-configured Lustre would.

Where WEKA's own docs disagree across versions (`weka fs add` vs `weka fs create`, the group commands, the
client-install URL) both forms are given with a "confirm with `--help` against your cluster's version" note,
rather than picking one and being confidently wrong. What the Port blueprint itself does is **not** described —
only what WEKA's reference AWS deployment builds, as context.

---

## Re-verification after fixes

Re-run clean after every edit (the prompt's step 5, and it caught finding 10 above):

| Check | Result |
|---|---|
| `bash -n` on all 32 shell files | pass |
| `py_compile` on all 29 Python files | pass |
| `record-run.sh` guards — 8 paths | all exit 2, correct messages |
| `record-run.sh` end-to-end (scratch run dir) | `0_README.md` 1629 bytes, title and `INDEX.md` line match the dir |
| `sync-to-s3.sh` guards — 6 paths | all exit 1 |
| `run-leg.sh --list` / `--dry-run --from 3.0` | 22 steps, every driver resolves executable, both MISSING steps abort by design |
| `run-leg.sh` bad `--from` / `--only` | rejected, exit 2, valid ids printed |
| `env.example.sh --check` with required unset | exit 1 |
| contract completeness check vs the drift case | old check said GO on 8 missing fields; new says NO-GO |
| Stage-7 run-dir patterns | 5 naming cases, all pass |
| memory index ↔ files | exactly 1:1, 19 each |
| memory references repo-wide | 0 unresolved |
| markdown links | 0 broken |
| script paths named in docs | 48 distinct, 0 missing |
| `RECORD_RUN_DIR` invariant | 0 violations |
| host-specific residue in live code | `/mnt/liad`, `cuda-13.2`, `192.168.*` all zero; remaining `a100`/`mlx5` are confined to the 13 aggregators, which is the `D-4` adapter surface and deliberately deferred |

---

## Verdict

**Drop-in ready for provisioning and the build phase.** The two defects that would have stopped the first
cell are fixed and tested; the four that would have silently corrupted or lost measurements are fixed and
tested; every count, pointer and identifier scheme now resolves.

**Not yet ready for the first *measured* cell.** Four things must close first, and none can be done from
here: item 1 (the nine worker bugs), item 3 (Lustre EFA client configuration — or Leg B measures TCP and
calls it maximum), item 4 (the kernel-vs-contract conflict), and the already-tracked `D-4`/`D-5` adapter and
consistency-relation work, without which the canary cannot evaluate and no number is verifiable. Item 2 is a
prerequisite for the instance existing at all.

The pattern behind almost every finding is worth stating, because it will recur: **a mechanism was built
correctly in one place and the callers were never updated**, while the tracking recorded it as done. `--fs`
existed in the wrapper and no driver; `RECORD_RUN_DIR` in six sites and not four; the filesystem segment in
`record-run.sh`'s own naming and not in nine pre-computed ones; `LIBCUFILE_PRELOAD` in the documentation and
no script. Each was invisible to reading and obvious to grep. The mechanical checks in the table above are
cheap to re-run and are the thing that catches this class — run them after any change to the script library.
