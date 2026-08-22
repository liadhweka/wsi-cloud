# 2026-08-21-213344-weka-s6.B.1-generate-synthetic-corpora-standard

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 6.B.1  ·  **Started (UTC):** 2026-08-21T21:33:47Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/generate-synthetic-features-stage6b.py --standard-suite --output-base /mnt/weka/features-6.B-synthetic --n-workers 32 --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-21-213344-weka-s6.B.1-generate-synthetic-corpora-standard/generation-summary.json 
```

## Why this run exists

Stage 6.B.1 prep: generate the standard synthetic corpus suite for 6.B.2/B.3. WHY: corpus generation is itself a real recordable write workload against /mnt/weka — a sustained-write data point worth capturing per CLAUDE.md recording philosophy. Corpus sizing is the ratified Stage-6 register decision (production-scale corpus past the 2304 GiB cold floor; one identical definition on both legs); the per-(N_files, file_size, dtype) grid is fixed at substage entry against the measured 6.A Tier-2 file-size distribution.

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
