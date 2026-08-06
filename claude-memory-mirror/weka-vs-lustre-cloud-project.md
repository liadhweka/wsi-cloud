---
name: weka-vs-lustre-cloud-project
description: "The project: a competitive WEKA-vs-Lustre storage comparison for the WSI/digital-pathology pipeline on AWS. Two sequential legs (WEKA first, then FSx for Lustre), POSIX both sides, GPU-direct retained and asymmetric by design, Lustre provisioned at maximum with cost reported alongside. Current state: build phase, nothing measured."
metadata:
  node_type: memory
  type: project
---

**What this project is.** A head-to-head comparison of **WEKA vs Lustre** for a modern whole-slide-imaging
pipeline on **AWS**: same GPU instance, same workload code, same datasets, same magnification contract —
only the filesystem under the mount point changes. The pipeline is the real seven-stage one (ingest →
cataloging → tissue detection → patching → training → foundation-model feature extraction + MIL →
clinical inference), because a storage comparison that measures only peak bandwidth answers almost none
of the questions a pathology platform team has.

**Two sequential legs, then a synthesis.** **Leg A = WEKA**, **Leg B = FSx for Lustre**, run one after the
other (separate provisioning; the instance is rebuilt between them). *Why sequential matters:* the legs
must stay comparable across time, which is enforced by a machine-readable **environment contract**
written at the end of Leg A and verified by Leg B before its first cell.

**GPU-direct is retained, not dropped, and is asymmetric on purpose.** Lustre-over-EFA supports GDS;
WEKA-on-AWS runs DPDK over ENA, which is not RDMA-capable, so compat-mode fallback is *expected* —
**verified empirically per cell (`gdscheck -p` + recorded cuFile GPU-direct-vs-bounced byte accounting),
never assumed from a config flag.** kvikIO/cuFile runs on both sides, so the same code and the same
raw-TIFF artifact execute on both and only the transport differs. Both filesystems also get a
plain-POSIX cell — kvikIO-in-compat stacks a bounce buffer on top of POSIX and may be slower than a
filesystem's native path, so without it we would understate whichever side falls back. *Why keep it:*
it is the actual choice a customer faces, and it restores the only genuinely bandwidth-saturating stage.

**Fairness basis: Lustre at maximum, WEKA at a realistic production config, cost reported alongside.**
*Why:* beating a competitor's best configuration is worth far more than beating one we sized ourselves,
and it forecloses "whoever picked the tier picked the winner." The asymmetry is stated in every result
headline rather than hidden — that statement is what makes it credible. "Maximum" is per-axis:
PERSISTENT-1000 tier, ≥25 TiB (where FSx disk throughput reaches the ~25 GB/s client ceiling),
user-provisioned high metadata IOPS, EFA-enabled. **Bandwidth is client-capped for both at ~25 GB/s, so a
bandwidth tie reflects the instance, not either filesystem** — the informative axes are metadata, IOPS,
small-file, concurrency, latency. WEKA must still clear ~25 GB/s so it isn't the constraint either.

**Open flag (deferred, deliberately):** the cost comparison needs WEKA licensing priced in, or it must be
explicitly labelled infrastructure-only. Agreed to fix the numbers later rather than block on it.

**Cold-vs-warm is a hard enforced axis, not an occasional variant.** A maxed FSx ships ~27.3 GiB of
file-server cache RAM per TiB (~680 GiB at 25 TiB — comparable to the instance's own RAM), so any warm
cell risks measuring cache rather than storage. Cache state is recorded per cell.

**Current state (2026-07-31): the repo build is COMPLETE; the cloud environment does not exist yet.**
`~/wsi-cloud/` holds the full doc set (thesis, CLAUDE.md, seven stage roadmaps, STAGES.md with
decision log **D1–D16**, PRESENTING, SCRIPT-TRACKER, FILESYSTEM-MAP, runbook), the **63-script library** (syntax-clean;
59 carried over intact — nothing deleted, since GDS is retained — plus `sync-to-s3.sh`, `env-contract.py`,
`run-leg.sh`, `teardown-preflight.sh` written here), 7 manifests, 20 memories, the
cloud provisioning + handoff docs, and the supporting artifacts (`.gitignore`, `.claude/settings.json`,
conda env specs, `backup.sh`). **Nothing has been benchmarked; every number is `[PENDING]`.**

**What was done on the build machine (2026-08-03):** mount + repo retargeting (every script resolves the
mount through `$FS_MOUNT` and **aborts loudly if unset** rather than defaulting — the guard that turns
"silently measures the wrong filesystem" into "refuses to run"), `--fs` plumbing with label-vs-mount
cross-validation, the environment contract (`env-contract.py`), the leg orchestrator (`run-leg.sh`), the S3
sync layer (`sync-to-s3.sh`), the teardown pre-flight verifier, and the naming layer
(`cloud-setup/NAMING-AND-VARIABLES.md` + `env.example.sh --check`).

**What is deliberately NOT done — 9 items, all genuinely environment-dependent:** per-filesystem recording
adapters across 13 aggregators, the per-filesystem consistency relations, cuFile path accounting, per-cell
sync/watchdog/canary-abort, GPU-NUMA re-derivation, core accounting, cuFile config values, Lustre tuning, and
the 1.7 hydration driver. Tracked in `[[cloud-session-open-items]]` section B. A hard prerequisite for a valid
cell, not cleanup.

**Next step:** the human provisions per `cloud-setup/SPINUP-CHECKLIST.md`, bootstraps per
`cloud-setup/NEW-CLOUD-SETUP.md`, and hands off with `cloud-setup/handoff-cloud.md`. The human creates the
GitHub remote and commits/pushes — never autonomously.

*(A prior on-prem effort supplied the reusable methodology and scripts. It is a separate story and is
deliberately not referenced anywhere in this repo.)*

Related: `[[weka-vs-lustre-cloud-open-decisions]]`, `[[feedback-results-precede-story]]`,
`[[feedback-each-leg-is-half-an-unfinished-comparison]]`, `[[feedback_methodology_why]]`.
Provisioning detail: `cloud-setup/SPINUP-CHECKLIST.md`. Full framing: `PROJECT-THESIS.md`.
