# 2026-08-23-054528-weka-s7-7.4.a-streaming-loop-virchow2-kvikio

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 7.4  ·  **Started (UTC):** 2026-08-23T05:45:31Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/home/ec2-user/wsi-cloud/scripts/streaming-loop-stage7.sh --run-dir /home/ec2-user/wsi-cloud/runs/2026-08-23-054528-weka-s7-7.4.a-streaming-loop-virchow2-kvikio --n-slides 10 --cadence-s 60 --model virchow2 --backend kvikio --manifest /home/ec2-user/wsi-cloud/scripts/manifests/tcga-brca-stage4a-subset.tsv 
```

## Why this run exists

Stage 7.4.a streaming clinical loop — 10 slides emitted @ 60s cadence (~1500 slides/day rate). Captures end-to-end 'scanner-to-pathologist-visibility' wallclock per slide + cross-slide queueing if inference falls behind scanner. WHY: the end-to-end workflow bookend — it also captures cross-slide queueing if inference falls behind the emitter, which a per-slide latency number alone hides. Regime: warm — cache carries over across the loop by design; production steady-state (roadmap 7.4.a).

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
