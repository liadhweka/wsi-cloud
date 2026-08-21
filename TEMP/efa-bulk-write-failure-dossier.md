# EFA bulk-write failure on FSx for Lustre — full technical dossier

*Everything known about the 2026-08-21 EFA bulk-write instability on the Lustre benchmark leg, in one
document, for discussion with technical colleagues and AWS support. Compiled 2026-08-21 by the R3
session from the recorded evidence (pointers in §9). The companion filing-form draft is
`TEMP/aws-support-case-efa-bulk-write.md`. TEMP/ is transient: the durable record is the four run dirs
and the git history.*

---

## 1. Sixty-second summary

Sustained bulk **direct writes** from one EFA-mounted client to an EFA-enabled FSx for Lustre file
system destabilize the client↔server EFA path within ~2–3 minutes, every time tried (4 fio cells across
2 occurrences, including once on a freshly rebooted client). Signature: EFA-level retransmission
timeouts on **both** client EFA devices, LNet `kefalnd_force_cancel_tx` TX cancellations, ptlrpc
bulk-write RPC timeouts, connection-lost flaps on **all six OSTs**, and fio blocking/hanging past its
runtime (first occurrence: two fio workers stuck in D state, cleared only by reboot). Meanwhile the FSx
servers are essentially idle — CloudWatch shows **≤5% disk-throughput/IOPS utilization on every
OSS/OST** during both failure windows. Short/small transfers are perfectly clean: **zero** EFA
retransmissions across a reboot, mount-time 100 MiB transport proofs, and all incidental traffic —
the counters move only during the bulk windows, and we have an exactly bracketed pre/post measurement
proving it. Everything recovers on its own once the load stops. The client runs AWS's own published EFA
client configuration with only AWS-documented tunables — this has deliberately **not** been treated as
a tuning exercise. It reads as packet loss or a transport defect on the EFA path between the endpoints,
not server overload and not client misconfiguration.

## 2. Environment

### File system
| | |
|---|---|
| FSx for Lustre file system | `fs-0a0a63dea8324225b`, fsname `krvlrbev` |
| Type / tier | PERSISTENT_2, SSD, 1000 MB/s per TiB |
| Capacity / metadata | 28,800 GiB (28.125 TiB); 48,000 user-provisioned metadata IOPS |
| EFA | **Enabled** |
| Layout | 6 OSTs (~4.5 TiB each) on 6 OSSes; 4 MDTs. Default 4-component PFL stripe layout, unmodified |
| Region / AZ | ap-northeast-2 (Seoul), ap-northeast-2b — client colocated in-AZ |
| Server addresses (from client dmesg/mount) | MGS `10.1.1.154@tcp`; OSS: OST0000→`10.1.1.21`, OST0001→`10.1.1.207`, OST0002→`10.1.1.227`, OST0003→`10.1.1.61`, OST0004→`10.1.1.50`, OST0005→`10.1.1.104` |

### Client
| | |
|---|---|
| Instance | `i-006cc930fed5cf053`, **g6e.24xlarge** (96 vCPU, 768 GiB, 4× L40S, 200 Gbps aggregate across 2 network cards) |
| OS / kernel | Amazon Linux 2023.12.20260803, `6.1.177-224.371.amzn2023.x86_64` |
| Lustre client | **2.15.6, in-kernel AL2023 modules** (including `kefalnd`, the EFA LND; modules print the "staging directory" taint at load) |
| EFA | driver `3.0.0a`; **2 EFA interfaces**: `efa_0` (LNet NID `1.251.91.0@efa`), `efa_1` (`1.251.92.0@efa`); tcp NID `10.1.1.251@tcp` on `enp71s0` |
| Mount | `10.1.1.154@tcp:/krvlrbev` on `/mnt/lustre` |

### Client configuration provenance — no deviation from AWS's published path
- EFA/LNet configured by **AWS's official `configure-efa-fsx-lustre-client.py`** (vendored, sha-pinned):
  tcp + efa nets, UDSP preferring efa, `peer_credits 32`, `ksocklnd credits=2560`,
  `ptlrpcd_per_cpt_max=32`, `cpu_npartitions=2` with two 48-CPU CPTs (its own CPU-scaled values for
  96 vCPU), systemd re-arm per boot.
- Client tunables: **exactly and only** AWS's documented set for a >64-vCPU/>64-GiB client
  (`performance-tips.html`, fetched 2026-08-20): `ldlm lru_max_age=600000`, `lru_size=100×nCPU`,
  `osc max_rpcs_in_flight=32`, `mdc max_rpcs_in_flight=64` / `max_mod_rpcs_in_flight=50`,
  `llite statahead_max=512`, `statahead_agl=1`, `statahead_xattr=1`.
- Transport is **counter-proven per boot**, never assumed: `lnetctl net show` must list both efa NIs up,
  and a 100 MiB direct write must move the efa net's `send_count` ~1 RPC/MiB with tcp near-flat.
  Passed on every boot including the current one (+106 send_count / 100 MiB at 20:30:12Z).

> **Reading dmesg on this system:** Lustre logs peers by their tcp-named NIDs (`…@tcp`) because FSx
> publishes tcp NIDs — that is naming, not the data path. The data path is EFA, proven by the per-boot
> counter-proof; the `kefalnd_force_cancel_tx` lines carry the servers' actual `@efa` peer NIDs.

## 3. The triggering workload

```
fio --name=efa-bulk-repro --directory=/mnt/lustre/benchmarks/fio-canary-calib \
    --filename_format='calib.$jobnum' --size=10G --numjobs=16 --ioengine=libaio \
    --direct=1 --iodepth=8 --rw=write --bs=4M --runtime=120 --time_based \
    --group_reporting --output-format=json+ --status-interval=1
```

16 concurrent sequential-write jobs, 4 MiB blocks, O_DIRECT, libaio iodepth 8 — a plain multi-GB/s bulk
write. (Original occurrence: identical shape at `--runtime=300`.) Files land in the PFL's 8-stripe
component → spread across all 6 OSTs. On the wire this is the normal Lustre-over-EFA bulk-write
pattern: the client's EFA counters show the payload leaving as **RDMA-read responses**
(`rdma_read_resp_bytes` ≈ 294 GB per device at the occurrence-1 capture, `rdma_write_* = 0`), i.e. the
servers pull bulk data from the client; the retransmissions accumulate on the client's send/response
path.

**Failure envelope, from 4/4 failing cells:** engages only under *sustained* bulk — RPCs sent ~2–3 min
after load start begin expiring ~1–2 min later. Never observed on short/small transfers: a 19 s fio
proof cell (15:46Z), every 100 MiB mount-time proof, 4 MiB direct writes, and metadata traffic are all
clean, with **zero** EFA retransmissions.

## 4. Timeline (all 2026-08-21 UTC)

| Time | Event |
|---|---|
| 00:02 | Client built from scratch (AWS configure-efa script; gated walk validated 2026-08-20). EFA mount counter-proven. |
| 15:46 | 19 s stage-0 recording-proof fio cell — clean. |
| 16:05:46 | **Occurrence 1 begins.** Calibration cell rep1 (300 s, 16j×4M direct seqw). First timed-out RPC was *sent* 16:08:39 (~3 min into load), first expiry logged 16:10:42. fio `err=35` (EAGAIN), "stuck grabbing stat_sem", rc=134. |
| 16:16:38 | rep2, same shape — same failure, rc=10. |
| 16:33:06 | rep3 — fio hung on lost aio completions **>3 h**; wrapper eventually SIGKILLed; **two fio workers left in D state** (unkillable). |
| 16:10–16:45 | dmesg: ptlrpc o4 (OST_WRITE) timeouts, rc -11; connection lost/restored flaps across all six OSTs (last restore 16:45:08); `kefalnd_force_cancel_tx` on **efa_1** → `1.61.71.0@efa` (OST0003's OSS) and **efa_0** → `1.207.71.0@efa` (OST0001's OSS), the latter with "Skipped 13 previous similar messages". |
| ~19:5x | Evidence captured; EFA counters read `efa_0 retrans_pkts=17,852 / retrans_timeout_events=1,011`, `efa_1 30,104 / 1,832`. Server-side CloudWatch dumps for all three cells: OSSes ≤1% network / ≤5% disk utilization throughout. |
| 20:29:35 | **Reboot** (to clear the D-state workers). Phase-2 re-ran clean on the new boot: EFA gate passed (both efa NIs up, MGS answering), transport counter-proof +106 send_count / 100 MiB direct write, filesystem mounted, tunables re-applied. Environment contract re-verified PASSED (18/18 held-constant fields). |
| 20:42:48 | **Occurrence 2 (reproduce probe, 120 s), fresh boot.** Probe's pre-start counter snapshot: **identical to the 19:5x values** — zero retrans movement across reboot + mount proof + small traffic. |
| 20:44:50 | Last writes of the 120 s window; RPCs sent around here begin expiring at 20:46:01 (both "slow reply" and "sent delay … real 0" variants — the latter never made it onto the wire). Connection-lost flaps on all six OSTs follow (20:46–20:55); `kefalnd_force_cancel_tx` on efa_0 → `1.207.71.0@efa` at 20:48:12. |
| ~20:49:47 | fio still running at 495 s elapsed (120 s job); workers in fio's own "stuck … forceful exit" state; wrapper interrupted; orphaned process group later SIGKILLed cleanly (**no D-state this time**). |
| ~20:52 | Post capture: `efa_0 20,475 / 1,200`, `efa_1 35,903 / 2,227`. **Window deltas: efa_0 +2,623 pkts / +189 timeout events; efa_1 +5,799 / +395.** ~54.2 GB (efa_0) + ~53.0 GB (efa_1) had left the client during the window. |
| 20:5x | Filesystem recovered unaided: all 6 OSTs answering `lfs df`, all osc imports FULL, 4 MiB direct write in 23 ms. Server-side CloudWatch for the window (final): **≤4.8% disk-throughput / ≤4.7% IOPS utilization on every OSS/OST**, network lower. |

## 5. The failure signature, layer by layer

- **Application (fio):** blocks past `--runtime`; EAGAIN (err=35); internal "stuck grabbing stat_sem";
  on kill, workers report "hasn't exited in 300 seconds … forceful exit"; worst case (occurrence 1
  rep3) D-state workers surviving SIGKILL — cleared only by reboot.
- **Lustre / ptlrpc:** `ptlrpc_expire_one_request` on `o4` (OST_WRITE) RPCs — both "timed out for slow
  reply" and "timed out for sent delay: [sent …/real 0]" (the RPC never transmitted); retries fail with
  `rc -11` (EAGAIN) "network error"; `Connection to krvlrbev-OSTnnnn was lost` across **all six** OSTs,
  with restores interleaving while load continues — a flap cycle, not a single cut.
- **LNet / efalnd:** `kefalnd_force_cancel_tx() Device[efa_0/efa_1] canceling TX type[IMMEDIATE]` to
  OSS `@efa` peer NIDs — on **both** client devices (occurrence 1) / efa_0 (shorter occurrence 2),
  against **multiple different OSSes**.
- **EFA device (`hw_counters`):** thousands of `retrans_pkts` and hundreds–thousands of
  `retrans_timeout_events` per bulk window, on **both** devices, exactly bracketed (§6). Notably
  **`rx_drops=0`, `impaired_remote_conn_events=0`, `unresponsive_remote_events=0`** on the client —
  the loss is not visible as client-side receive drops or remote-health events; the client's sends
  (RDMA-read responses carrying the bulk payload) time out at the SRD reliability layer and retransmit.
- **Server side (CloudWatch `AWS/FSx`, every metric, per-OST/OSS):** no saturation signal at any point —
  disk-throughput/IOPS utilization ≤~5%, network utilization lower, on every file server, during both
  windows. The servers were nearly idle while the client's transport was failing.

## 6. The bracketed counter measurement (the cleanest single piece of evidence)

EFA `hw_counters` are device-cumulative and **persist across an OS reboot**, which gave an exact
bracket around the 120 s reproduction:

| Counter | 19:5xZ (post-occurrence-1 capture) | 20:42:48Z (probe pre-start, after reboot + mount proof) | ~20:52Z (post-repro) | **Δ during 120 s bulk window** |
|---|---|---|---|---|
| efa_0 retrans_pkts | 17,852 | **17,852** (unchanged) | 20,475 | **+2,623** |
| efa_0 retrans_timeout_events | 1,011 | **1,011** (unchanged) | 1,200 | **+189** |
| efa_1 retrans_pkts | 30,104 | **30,104** (unchanged) | 35,903 | **+5,799** |
| efa_1 retrans_timeout_events | 1,832 | **1,832** (unchanged) | 2,227 | **+395** |

Zero movement across the reboot, the mount-time 100 MiB proof, and every piece of small traffic in
between; thousands of retransmitted packets within the single bulk window. (By the same logic, the
19:5x absolute values are attributable to occurrence 1's three cells — this client had never sustained
full-rate EFA bulk before them.) Pre-start snapshot preserved at
`…-FAILED-efa-reproduced/pre/efa-hw-counters-probe-prestart.txt`.

## 7. Ruled out / established

1. **Server overload** — ruled out by CloudWatch: ≤~5% utilization on every OSS/OST in both windows.
2. **Accumulated client state / bad boot** — ruled out: reproduced 13 minutes after a clean boot whose
   EFA gate and transport counter-proof had just passed.
3. **Client misconfiguration drift** — no deviation from AWS's published client path (vendored official
   script, documented tunables only); environment contract re-verified PASSED the same day; kernel
   pinned (uname tripwire).
4. **Small-transfer path** — unaffected, with zero retransmissions (the bracketed measurement).
5. **Permanent damage** — none: connections recover unaided once load stops; imports return to FULL;
   direct writes normal.
6. **Read path** — *not yet exercised* at sustained bulk rates (the failing cells are the write-side
   calibration; reads were next in the plan). Unknown, not ruled out.
7. **Single-NIC/device fault** — disfavored: both EFA devices retransmit and cancel TXs, against
   multiple different OSSes.
8. **This is not a tuning problem we intend to tune around** — the benchmark's methodology (decision
   D16/L7) treats transport stability as a precondition, and any deviation from AWS's published client
   configuration would also invalidate the "vendor's own configuration" basis of the benchmark.

## 8. Why we can't just fall back to TCP (context for colleagues)

Per the FSx performance page (fetched 2026-08-21): per-client throughput is 700 Gbps over EFA, but any
non-EFA client path (plain ENA/TCP included, even on an EFA-enabled file system) is capped at 100 Gbps
**with a 5 Gbps limit per client↔OSS pair**. This file system has 6 OSSes → a TCP-mounted client caps
at ~30 Gbps ≈ 3.5 GiB/s aggregate. The comparison leg this client exists for (WEKA vs Lustre, Lustre
provisioned at maximum) measured ~11 GiB/s single-client reads on the WEKA side — so a TCP fallback
would cap Lustre at a third of that **by mount mode**, invalidating the head-to-head. EFA is
load-bearing for bandwidth on this client class independent of GPUDirect Storage (which is separately
unavailable on g6e — GDS requires P5-class clients per AWS docs — and was never the reason for EFA).

## 9. Evidence inventory

Four run directories (git holds the small text; full raw telemetry mirrored to
`s3://liad-wsi-cloud/runs/lustre/<dir>/raw/`). Each contains: `notes.md` (narrative),
`incident-evidence.txt` (verbatim dmesg excerpts + EFA counter dumps), `pre/`+`post/` state snapshots
(lnetctl, lfs, tunables, versions), `raw/` 1 Hz time series (EFA/RDMA counters, Lustre
llite/osc/mdc stats, LNet stats, sar, netdev), and `raw/fsx-cloudwatch.{json,csv}` (every AWS/FSx
CloudWatch series for the file system over the cell's window, per-OST/OSS):

1. `runs/2026-08-21-160543-lustre-s0-calib-seqw-bs4m-jobs16-rep1-FAILED-efa-retrans-timeouts`
2. `runs/2026-08-21-161634-lustre-s0-calib-seqw-bs4m-jobs16-rep2-FAILED-efa-retrans-timeouts`
3. `runs/2026-08-21-163306-lustre-s0-calib-seqw-bs4m-jobs16-rep3-FAILED-efa-retrans-hung-nocleanup`
4. `runs/2026-08-21-204248-lustre-s0-efa-bulk-repro-120s-FAILED-efa-reproduced` ← the post-reboot
   reproduction; its `pre/efa-hw-counters-probe-prestart.txt` is the bracket baseline of §6.

Also: `runs/sweep-logs/2026-08-21-2042-lustre-efa-repro-120s.log` (probe launch log);
`journalctl -u wsi-lustre-phase2.service` on the box (per-boot EFA gate + counter-proof records);
`runs/2026-08-20-lustre-efa-walk-transcript.md` (the validated client-build walk).

**Reproducer:** the §3 fio command against any directory on the mount; expect failure onset ~2–3 min
into sustained load. `scripts/probe-efa-bulk-repro.sh` wraps it with bracketed counter/dmesg snapshots
and a mechanical PASS/FAIL verdict (120 s default; `PROBE_RUNTIME=300` for full length). It is
self-watchdogged; even so, expect possible multi-minute stuck fio processes afterwards — kill by
process group, and know that D-state stragglers may require a reboot.

## 10. Current state and asks

- The benchmark leg is **stopped** pre-baseline (no measured cells run on this filesystem); idle burn
  ≈ $48/hr (instance $18.52 + file system $29.61, prices checked 2026-08-20).
- AWS support case to be filed from `TEMP/aws-support-case-efa-bulk-write.md` (suggested severity:
  production impaired; reproducible on demand in 120 s). Also to check, from a human account (the
  instance role cannot): **Personal Health Dashboard** and the **EC2 instance-status console** for
  events on the client, the file system, or apne2-b over 16:05–16:45Z and 20:42–20:56Z.
- Questions for AWS: (1) investigate the EFA path between these endpoints over the two windows — the
  pattern (client-side SRD retransmission timeouts + TX cancellations while OSSes sit ≤5% utilized)
  points between the endpoints; (2) known issue for this stack (g6e.24xlarge, 2× EFA, driver 3.0.0a,
  AL2023 kernel 6.1.177 in-kernel Lustre 2.15.6/kefalnd, EFA-enabled FSx PERSISTENT_2) under sustained
  bulk writes? (3) any AWS-side events in apne2-b over the windows? (4) recommended next diagnostics —
  we have deliberately not deviated from the documented configuration and can reproduce on request.
- If AWS ultimately cannot fix it, the recorded fallback is a **written-waiver TCP re-baseline** with
  the fairness basis restated and the 5 Gbps/OSS cap printed beside every number — a last resort,
  because it forfeits the "Lustre at maximum" basis (§8).

## References (all fetched/verified on the dates shown)

- FSx for Lustre performance (per-client table + 5 Gbps/OSS footnote):
  `https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html` (2026-08-21)
- EFA client setup: `https://docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html` (2026-08-20)
- GDS client-instance requirement (P5-class):
  `https://docs.aws.amazon.com/fsx/latest/LustreGuide/efa-file-systems.html` (2026-08-20)
- Client tunables: `https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance-tips.html` (2026-08-20)
