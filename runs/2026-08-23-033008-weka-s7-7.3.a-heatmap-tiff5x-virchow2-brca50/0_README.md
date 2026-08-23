# 2026-08-23-033008-weka-s7-7.3.a-heatmap-tiff5x-virchow2-brca50

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 7.3  ·  **Started (UTC):** 2026-08-23T03:30:11Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/inference-per-slide-stage7.py --backend kvikio --model virchow2 --rawtiff-dir /mnt/weka/data/tcga-brca-rawtiff --svs-dir /mnt/weka/data/tcga-brca --coords-dir /mnt/weka/tissue-detection/3.0/tcga-brca/n64/patches --manifest /home/ec2-user/wsi-cloud/scripts/manifests/tcga-brca-stage4a-subset.tsv --heatmap-dir /mnt/weka/heatmaps/7.3/7.3.a-heatmap-tiff5x-virchow2-brca50 --heatmap-format tiff5x --inference-batch-size 256 --cache-policy warm --max-slides 50 --per-slide-csv /home/ec2-user/wsi-cloud/runs/2026-08-23-033008-weka-s7-7.3.a-heatmap-tiff5x-virchow2-brca50/per-slide-inference-latencies.csv --per-slide-heatmap-csv /home/ec2-user/wsi-cloud/runs/2026-08-23-033008-weka-s7-7.3.a-heatmap-tiff5x-virchow2-brca50/per-slide-heatmap-writes.csv --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-23-033008-weka-s7-7.3.a-heatmap-tiff5x-virchow2-brca50/inference-summary.json 
```

## Why this run exists

Stage 7 single-process inference cell: backend=kvikio model=virchow2 cache=warm heatmap=tiff5x N_slides=50. WHY: per-slide inference latency baseline with per-phase decomposition (tissue/extract/MIL/heatmap-write). The clinical-deployment-decisive 'T seconds per inference' customer number. Regime: warm — cache carries over across slides by design; re-inference on already-read slides is production steady-state.

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
