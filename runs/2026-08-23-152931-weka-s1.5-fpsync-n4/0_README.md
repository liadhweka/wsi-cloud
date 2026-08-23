# 2026-08-23-152931-weka-s1.5-fpsync-n4

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 1.5  ·  **Started (UTC):** 2026-08-23T15:29:39Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
fpsync -v -n 4 -d /tmp/fpsync-stage1.5/n4 /data/local-nvme/fpsync-source/tcga-brca/ /mnt/weka/data/fpsync-target/n4/ 
```

## Why this run exists

Stage 1.5 fpsync sweep cell 2/4 on fs=weka: local NVMe -> /mnt/weka, fpsync -n 4. Source: /data/local-nvme/fpsync-source/tcga-brca/ (1133 files, 1158795413424 bytes). Target: /mnt/weka/data/fpsync-target/n4 (cleaned pre-cell). fpsync default partition (-f 2000 -s 4G), default rsync opts (-lptgoD -v --numeric-ids), shdir /tmp/fpsync-stage1.5/n4. Per-cell isolation via record-run.sh: any single cell failure leaves rest of sweep intact.

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
