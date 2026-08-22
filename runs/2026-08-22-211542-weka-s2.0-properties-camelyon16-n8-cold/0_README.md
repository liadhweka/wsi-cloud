# 2026-08-22-211542-weka-s2.0-properties-camelyon16-n8-cold

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 2.0  ·  **Started (UTC):** 2026-08-22T21:15:46Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
env CONDA_PREFIX=/data/local-nvme/conda-envs/wsi-cucim-2604 /data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/extract-slide-properties.py --concurrency 8 --output-dir /mnt/weka/cataloging/2.0/camelyon16/n8-cold --manifest /tmp/stage2-manifests/camelyon16.txt --latency-csv /tmp/stage2-manifests/camelyon16-n8-cold-latencies.csv 
```

## Why this run exists

Stage 2.0 cell 15/16: OpenSlide property extraction. Dataset=camelyon16 (399 slides), concurrency=8, cache arm=cold (cold: vm.drop_caches=3 with recorded acknowledgment; warm: unrecorded n=64 warmup pass immediately before). Single-pass full dataset via openslide-python + multiprocessing.Pool. Headline: 'cataloged 399 slides in X seconds at concurrency 8, cold'.

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
