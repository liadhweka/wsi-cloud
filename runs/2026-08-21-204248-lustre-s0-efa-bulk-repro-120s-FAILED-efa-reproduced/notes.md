# EFA bulk-write reproduce probe (120 s) — INCIDENT REPRODUCED → FAIL, STOP stands

**Verdict: FAIL** by the probe's own mechanical criteria (all three met), evidenced manually because the
recording wrapper was interrupted before the probe's verdict step ran. Diagnostic cell — never quote a rate.

## What happened

`probe-efa-bulk-repro.sh` (120 s, the 2026-08-21 incident's exact shape: 16 jobs × 4M direct writes,
libaio, iodepth=8) was invoked by the human at 20:42:48Z on the first boot after the incident reboot
(boot 20:29:35Z; phase-2 gate + counter-proof PASSED on this boot). The 120 s time-based fio failed to
complete: first ptlrpc OST_WRITE timeout at 20:46:01Z (~60 s after the job should have ended),
connection-lost flaps on ALL six OSTs (20:46–20:55Z), `kefalnd_force_cancel_tx()` on efa_0 at 20:48:12Z,
rc=-11 network errors. The human interrupted the foreground wrapper at ~7 min (~20:49:47Z, before the
540 s watchdog); the cleanup trap's group-TERM left fio workers stuck ("hasn't exited in 300 seconds"
per cmd.log). The R3 session SIGKILLed the recorded process group (raw/.cmd_pgid = 21534) at ~20:52Z —
clean reap, **no D-state survivors this time** (unlike the original incident; no reboot forced).

## FAIL criteria — all three met

1. **fio non-zero / did not complete** — killed while stuck; workers in fio's own "stuck, forceful exit"
   state (cmd.log tail).
2. **retrans_timeout_events moved** — since-boot EFA hw_counters at capture: efa_0 retrans_pkts 20,475 /
   retrans_timeout_events 1,200; efa_1 retrans_pkts 35,903 / retrans_timeout_events 2,227. The only bulk
   traffic since boot is this probe (phase-2's 100 MiB proof was clean).
3. **New dmesg error lines** — ptlrpc timeouts, six-OST connection-lost flaps, efalnd TX cancellation
   (incident-evidence.txt carries the verbatim lines).

## Server-side view (raw/fsx-cloudwatch.{json,csv}, final=True)

Peak utilization across ALL OSSes/OSTs during the window: FileServerDiskThroughputUtilization ≤ 4.8%,
DiskIopsUtilization ≤ 4.7%, network lower still — the servers were idle while the client saw sustained
EFA-path loss. Identical profile to the original incident's dumps: **client↔server EFA-path loss, not
server overload.**

## Recording caveats

- `metadata.json`'s `started_utc`/`ended_utc` were null (wrapper died before finalize) and were stamped
  afterwards from recorded facts — start from `raw/rdma-counters.csv` first sample (20:42:49Z), end
  padded past the last dmesg OST error (20:55:20Z) to 20:56:00Z — so `fsx-cloudwatch-dump.py` could
  fetch the server-side window. `wallclock_s` stays null: the cell has no valid wallclock.
- No `INDEX.md` line and no `results.json`: the wrapper never finalized. The 1 Hz raw streams
  (rdma-counters, lustre-stats, lnet-stats, sar, netdev) recorded through 20:49:47Z.
- Filesystem recovered on its own once the load was gone: all 6 OSTs answering `lfs df`, 28 osc imports
  FULL, 4 MiB direct write in 23 ms at 20:5xZ. The instability engages under SUSTAINED bulk writes only.

## Consequence

The ⛔ STOP stands (open-items memory B.5). Post-reboot reproduction on a clean boot rules out
incident-day transient state; next step is the AWS support case (never a tuning exercise — D16 /
LUSTRE-PROVISIONING register L7).
