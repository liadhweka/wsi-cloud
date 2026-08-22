# 2026-08-22-090440-weka-s6.C-concurrent-extract

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 6.C  ·  **Started (UTC):** 2026-08-22T09:04:43Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/home/ec2-user/wsi-cloud/scripts/orchestrate-concurrent-stage6c.sh --workloads extract --ramp 300 --runtime 1500 --run-dir /home/ec2-user/wsi-cloud/runs/2026-08-22-090440-weka-s6.C-concurrent-extract 
```

## Why this run exists

Stage 6.C concurrent multi-workload cell on fs=weka: workloads={extract} extract_model=virchow2 ramp=300s steady=1500s. WHY: concurrent heterogeneous load on one namespace is where storage architectures diverge, and no single-workload cell surfaces it. Retention is measured against THIS leg's own solo baselines re-measured at the same concurrent config, so the cross-leg comparison is of retention percentages, not absolute rates. Per D15, check the core accounting before attributing any interference to the filesystem rather than the host. Regime: na — the cold/warm axis deliberately does not apply to 6.C (ratified 2026-08-21): the measured quantity is per-workload QoS retention, and solo baselines carry the same declaration as the concurrent tiers because they are the retention denominators measured under the identical construction — labelling the two sides differently would put numerator and denominator in different regimes.

## What's in this directory

- `metadata.json` — structured metadata (programmatic).
- `cmd.txt` / `cmd.log` — exact command and tee'd stdout+stderr from the benchmark.
- `pre/` — cluster + host state snapshot before the run.
- `raw/` — during-run time series at 1-second resolution. The recorder set is
  per-filesystem (`docs/RUNBOOK.md` holds each leg's Primary-vs-Diagnostic
  table). On this leg:
  - `weka-stats.csv` — per-process cluster stats, 1 Hz poll (filter `Mode==client` for this client).
  - `nvidia-smi.csv` — per-GPU per-second.
  - `sar-{cpu,disk,net,mem,swap,paging,queue,ctxsw}.csv` — host-side categories.
  - `netdev-counters.csv` — kernel NIC counters (Diagnostic here — DPDK bypasses
    the kernel — except on 1.7, where the S3 source traffic makes them Primary).
  - `rdma-counters.csv` — RDMA/EFA device counters; header-only where no such device exists.
  - `nvidia-fs-stats.log` — verbatim 1 Hz nvidia-fs accounting (cuFile path proof, D8).
- `post/` — same snapshot taken after the run, for delta computation.
- `results.json` — parsed aggregates. Re-runnable any time via `scripts/parse-results.py <this-dir>`.

## Project context

This run is part of the WEKA-vs-Lustre WSI storage comparison on AWS.
- `CLAUDE.md` — project rules (docs citation, memory hygiene, recording philosophy).
- `/home/ec2-user/wsi-cloud/docs/STAGES.md` — the `--stage` code map, the per-leg plan, and the cross-stage decision register.
- `/home/ec2-user/wsi-cloud/docs/RUNBOOK.md` — operational runbook (how to run, how to re-parse, how to recover from failures).
