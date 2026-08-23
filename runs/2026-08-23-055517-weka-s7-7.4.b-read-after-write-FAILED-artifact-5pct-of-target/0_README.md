# 2026-08-23-055517-weka-s7-7.4.b-read-after-write

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 7.4  ·  **Started (UTC):** 2026-08-23T05:55:20Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/read-after-write-stage7.py --output-dir /mnt/weka/heatmaps/7.4b --n-slides 20 --bytes-per-write 6440000 --poll-interval-s 0.001 --per-slide-csv /home/ec2-user/wsi-cloud/runs/2026-08-23-055517-weka-s7-7.4.b-read-after-write/read-after-write-latencies.csv --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-23-055517-weka-s7-7.4.b-read-after-write/raw-summary.json 
```

## Why this run exists

Stage 7.4.b read-after-write consistency — 20 writes of MEASURED-7.3-matched heatmaps; concurrent reader polls every 1ms for first-visible (ratified 2026-08-21: build-machine visibility fell BELOW the old 10ms floor, so 10ms sampled poll phase; the recorded resolution floor stays the quantisation guard). ARTIFACT MATCHED TO A MEASURED 7.3 OUTPUT ON THIS LEG (the register's synthetic-writer exception, evidenced): size target 6,440,000 B = the mean of the 50 recorded tiff5x heatmap writes in cell 2026-08-23-033008-weka-s7-7.3.a-heatmap-tiff5x-virchow2-brca50 (median 6.19 MB, range 1.3-14.6 MB); tile geometry 256x256 single-level, identical to the measured artifact by construction; the writer records target-vs-achieved. Latency = first-visible - write-complete. WHY: read-after-write visibility is a CONSISTENCY property, not a bandwidth one, and the two filesystems have different metadata architectures — so there is no reason to assume they behave the same. SCOPE: single-client (writer and reader are processes on one instance); cross-client consistency would need a second instance and is out of scope. Regime: na — the cold/warm axis deliberately does not apply: the measured quantity is visibility latency, and the reader's first read is warm by construction (bytes written milliseconds earlier), labelled cache-served and never quoted as a storage read (D13).

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
