# AWS support case draft — FSx for Lustre over EFA: sustained bulk writes cause EFA-path packet loss

*Prepared 2026-08-21 by the R3 session for [USER] to file. Before/while filing, also check (instance role
cannot): **Personal Health Dashboard** for events on the instance/FSx/AZ, and the **EC2 instance-status
console** for the client. Delete this file once the case is filed (case id goes into the open-items
memory B.5).*

**Suggested severity:** Production system impaired.
**Service:** Amazon FSx for Lustre. **Region:** ap-northeast-2 (Seoul), AZ apne2-b.

---

## Environment

- **File system:** `fs-0a0a63dea8324225b` (fsname `krvlrbev`), PERSISTENT_2, 1000 MB/s/TiB, 28,800 GiB,
  48,000 provisioned metadata IOPS, **EFA enabled**. 6 OSTs / 4 MDTs.
- **Client:** `i-006cc930fed5cf053`, g6e.24xlarge, same AZ as the file system. Amazon Linux
  2023.12.20260803, kernel `6.1.177-224.371.amzn2023.x86_64`, **in-kernel Lustre client 2.15.6**
  (including `kefalnd`), EFA driver `3.0.0a`, **2 EFA interfaces** (`efa_0`, `efa_1`).
- **Client EFA configuration:** AWS's official `configure-efa-fsx-lustre-client.py` (the documented
  procedure at `docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html`), plus only the
  documented performance-tips tunables for a >64-vCPU client. No custom tuning.
- **Transport is verified EFA per boot:** `lnetctl net show` lists both efa NIs up, and a 100 MiB
  direct-write counter-proof moves the efa net's `send_count` ~1 RPC/MiB with tcp near-flat.

## Symptom

Under **sustained bulk direct writes** (fio, 16 jobs × 4 MiB sequential, libaio, iodepth 8, O_DIRECT —
aggregate demand a few GB/s), the client↔server EFA path destabilizes within ~60–120 s:

- EFA hw_counters accumulate large retransmission counts on **both** EFA devices. The second
  occurrence is exactly bracketed by pre/post snapshots around a single 120 s job:
  `efa_0 +2,623 retrans_pkts / +189 retrans_timeout_events`;
  `efa_1 +5,799 retrans_pkts / +395 retrans_timeout_events` — against **zero** counter movement
  across the preceding reboot, the 100 MiB mount-time transport proof, and all small traffic.
- Kernel log: `kefalnd_force_cancel_tx()` TX cancellations; ptlrpc `Request sent has timed out` on
  OST_WRITE (o4) with rc -11 network errors; `Connection to krvlrbev-OSTnnnn was lost` flaps across
  **all six OSTs**.
- fio blocks/hangs past its runtime (first occurrence: workers left in D state, cleared only by reboot).
- **Server side shows no saturation:** CloudWatch AWS/FSx over the failure windows has
  FileServerDiskThroughputUtilization ≤ ~5%, DiskIopsUtilization ≤ ~5%, network utilization lower still,
  on every OSS/OST.

Short/small transfers are consistently clean (100 MiB direct-write proofs, 4 MiB writes, ~19 s cells).
After load stops, connections recover on their own (all imports FULL, direct writes complete normally).

## Occurrences (both 2026-08-21 UTC, reproducible)

1. **~16:05–16:45** — three consecutive 300 s cells of the shape above, all failed the same way
   (~48k retrans_pkts + ~2,850 retrans_timeout_events across the window; two fio workers left in
   D state; client rebooted to clear them).
2. **20:42–20:56, on a fresh boot** (booted 20:29; EFA transport re-proven clean at mount) — a single
   **120 s** cell of the same shape reproduced the full signature. A clean-boot reproduction rules out
   accumulated client state from the first occurrence.

We can reproduce on demand with a 120 s fio run and are happy to run diagnostics on request.

## Evidence available (attachable)

Four diagnostic capture directories, each with 1 Hz client-side telemetry (EFA hw_counters, Lustre
client stats, LNet stats), verbatim kernel-log excerpts (`incident-evidence.txt`), a narrative
(`notes.md`), and the matching server-side CloudWatch dump (`raw/fsx-cloudwatch.csv`, every AWS/FSx
series for the file system over the window):

- `2026-08-21-160543-…-FAILED-efa-retrans-timeouts` (occurrence 1, cell 1)
- `2026-08-21-161634-…-FAILED-efa-retrans-timeouts` (occurrence 1, cell 2)
- `2026-08-21-163306-…-FAILED-efa-retrans-hung-nocleanup` (occurrence 1, cell 3)
- `2026-08-21-204248-…-FAILED-efa-reproduced` (occurrence 2, post-reboot 120 s reproduction)

## Questions for AWS

1. Please investigate the EFA path between this client and the file system's servers over the two
   windows above — the loss pattern (client-side retransmission timeouts + TX cancellations while the
   OSSes sit ≤5% utilized) points between the endpoints, not at either one.
2. Is this a known issue for EFA-enabled FSx for Lustre with this client stack (g6e.24xlarge, 2 EFA
   interfaces, EFA driver 3.0.0a, kernel 6.1.177 in-kernel Lustre 2.15.6 / kefalnd) under sustained
   bulk writes?
3. Were there AWS-side network or infrastructure events in apne2-b over these windows?
4. What diagnostics or configuration changes do you recommend we run next? (We have deliberately not
   deviated from the documented EFA client configuration.)
