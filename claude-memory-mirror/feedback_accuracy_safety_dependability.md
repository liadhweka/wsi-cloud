---
name: user-values-accuracy-safety-dependability-exhaustive-recording-over-speed
description: "Priority order — accuracy > safety > dependability > exhaustive recording > speed. Bake verify-before-mutating, sudo discipline, tee/idempotency/version-pinning, and time-series (not snapshot) recording in by default. Full recording philosophy is in CLAUDE.md."
metadata:
  node_type: memory
  type: feedback
---

Priorities, in order: **accuracy, safety, dependability, exhaustive recording — over speed.** Bake these
in by default. Mistakes are expensive: a wrong mount or format, a broken filesystem mount, or a polluted
root costs hours-to-days of re-running.

- **Verify before mutating.** Read-only check before any state-changing step you haven't verified this
  session. For filesystem/mount/install/format/systemd/sudo: state the plan + exact command, then ask.
  Two safe turns beat one risky one.
- **Sudo discipline:** state the reason and ask before any sudo.
- **Dependability defaults:** tee long output to a dated log; persist/checkpoint anything >~10 min;
  idempotent scripts; pin versions that affect numbers; state what would be lost before any destructive
  op.
- **Recording:** "if it isn't recorded, it didn't happen." Time-series at max practical resolution (then
  derive aggregates), **multiple vantage points** (app-level + the filesystem's own telemetry + the wire
  counters for the access path actually in use), pre/during/post snapshots; verify the capture before
  trusting the run; err toward over-capture.

**Cloud-specific, and non-negotiable:** local NVMe and both filesystems are **ephemeral — they die with
the instance and the cluster.** Nothing that matters may rest only there. Raw telemetry syncs to S3
*during* the run, not only at the end, and the sync is **verified, not assumed**, before any teardown.
The cost dimension is new too: an idle or hung instance burns money, so every unattended cell carries a
watchdog timeout.

Full philosophy in `CLAUDE.md`. Related: `[[weka-vs-lustre-cloud-project]]`.
