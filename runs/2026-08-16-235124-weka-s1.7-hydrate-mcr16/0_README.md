# 2026-08-16-235124-weka-s1.7-hydrate-mcr16

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 1.7  ·  **Started (UTC):** 2026-08-16T23:51:27Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
bash -c $'\n      set -uo pipefail\n      for t in tcga-brca camelyon16; do\n        echo "== aws s3 sync datasets/$t (max_concurrent_requests=16) =="\n        aws s3 sync --region \'ap-northeast-2\' --only-show-errors           "s3://liad-wsi-cloud/datasets/$t/" "/mnt/weka/data/$t/" || exit 1\n      done\n    ' 
```

## Why this run exists

Stage 1.7 cell 2/4: full S3->weka hydration of both dataset prefixes, aws s3 sync, max_concurrent_requests=16. Target wiped pre-cell; the final cell's data is kept and byte-verified. Write cell: cache axis n/a.

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
