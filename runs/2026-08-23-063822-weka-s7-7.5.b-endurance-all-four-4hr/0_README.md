# 2026-08-23-063822-weka-s7-7.5.b-endurance-all-four-4hr

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 7.5  ·  **Started (UTC):** 2026-08-23T06:38:25Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/home/ec2-user/wsi-cloud/scripts/orchestrate-clinical-deployment-stage7.sh --workloads inference\,ingest\,heatmap-viewer\,viewer --n-concurrent 4 --inference-batch-size 256 --ramp 300 --runtime 14400 --run-dir /home/ec2-user/wsi-cloud/runs/2026-08-23-063822-weka-s7-7.5.b-endurance-all-four-4hr 
```

## Why this run exists

Stage 7 orchestrator cell: workloads={inference,ingest,heatmap-viewer,viewer} N_concurrent=4 per-process bs=256 (per Q8 schedule) ramp=300s runtime=14400s. WHY: per-slide latency under concurrent inference load — the clinical-deployment SLA number ('p99 latency stays under X sec at deployment concurrency Y'). bs scales DOWN with N to keep per-GPU memory bounded. Regime: na — the cold/warm axis deliberately does not apply to a mixed multi-workload cell (ratified 2026-08-21): the measured quantity is per-workload QoS retention against same-filesystem solo baselines.

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
