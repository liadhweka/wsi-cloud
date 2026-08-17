# 2026-08-17-082924-weka-s4.B-tilesread-camelyon16-cucim-N16-nw16-bs4

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 4.B  ·  **Started (UTC):** 2026-08-17T08:29:26Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
env CONDA_PREFIX=/data/local-nvme/conda-envs/wsi-cucim /data/local-nvme/conda-envs/wsi-cucim/bin/python /home/ec2-user/wsi-cloud/scripts/read-tiles-onthefly.py --backend cucim --n-processes 16 --num-workers 16 --batch-size 4 --svs-dir /mnt/weka/data/camelyon16/images --coords-dir /mnt/weka/tissue-detection/3.0/camelyon16/n64/patches --runtime 60 --ramp 10 --coord-pool-pickle /data/local-nvme/stage4b-pool-cache/camelyon16.pkl --latency-csv /tmp/stage4b-latencies/tilesread-camelyon16-cucim-N16-nw16-bs4.csv --summary-json /tmp/stage4b-latencies/tilesread-camelyon16-cucim-N16-nw16-bs4.summary.json --seed 42 
```

## Why this run exists

Stage 4.B tier1 cell 21/26: random tile reads. Backend=cucim CPU batched. Dataset=camelyon16. N_processes=16, num_workers=16 (cuCIM C++ thread pool), batch_size=4, prefetch_factor=2. cuCIM per-process tile cache: 512 MiB (library default; recorded-not-swept per the Stage-4 register — identical on both legs). LRU(8) slide handle cache per worker. seed=42. runtime=60s + 10s ramp. Cache arm=warm. Cell order fixed and de-ordered in N (D13).

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
