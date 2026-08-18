# 2026-08-17-191632-weka-s4.D-rawtiff-brca-par4

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 4.D  ·  **Started (UTC):** 2026-08-17T19:16:35Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/home/ec2-user/wsi-cloud/scripts/convert-stage4c-rawtiff.sh --inner brca /tmp/tmp.qDJ7KcPxN2 /home/ec2-user/wsi-cloud/runs/2026-08-17-191632-weka-s4.D-rawtiff-brca-par4 
```

## Why this run exists

Stage 4.D: TRUE 20x raw-TIFF conversion of brca (1073 slides, PARALLEL=4 — workload shape, must match on both legs). Sustained large-read (canonical source) + large-write (single-level 256px-tiled uncompressed 20x TIFF, D4) via convert-rawtiff-20x.py; per-dataset read params per the coord contract (CAM16 native L1@256; BRCA 512@40x resized to 256). Fail-loud mpp guard; write-to-.partial-then-rename; idempotent skip on existing non-empty output (SKIP-EXISTS is a distinct status — verify cleanup before regenerating, RUNBOOK silent-skip hazard). Artifact RETAINED at rest (Stage-4 register). Per-invocation log: conversion-log.tsv in this run dir.

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
