# 2026-08-16-035401-weka-s0-d8gds-kvon-posix

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 0  ·  **Started (UTC):** 2026-08-16T03:54:04Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
env LD_PRELOAD=/usr/local/cuda/targets/x86_64-linux/lib/libcufile.so.1.14.1 CUFILE_ENV_PATH_JSON=/home/ec2-user/cufile-config/cufile.json KVIKIO_COMPAT_MODE=ON CUDA_VISIBLE_DEVICES=0 PYTHONPATH=/home/ec2-user/wsi-cloud/scripts bash -c \"/usr/local/cuda/gds/tools/gdscheck\"\ -p\;\ \"/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python\"\ \"/home/ec2-user/wsi-cloud/scripts/probe-gds-phase0.py\"\ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ --file\ \"/mnt/weka/benchmarks/gds-phase0/testfile.bin\"\ --kvikio-compat\ \"on\"\ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ --summary-json\ \"/home/ec2-user/wsi-cloud/runs/2026-08-16-035401-weka-s0-d8gds-kvon-posix/gds-phase0-summary.json\" 
```

## Why this run exists

D8 Phase-0 GDS determination cell: C: kvikio compat ON — kvikio's own POSIX path, never enters cuFile; nvidia-fs must stay zero (posix-by-construction). Modes FORCED, never AUTO (three-layer path accounting); gdscheck -p captured in cmd.log; verdict = the recorded path_accounting split, not any config flag. Reads are backend-RAM-resident by construction — the PATH is the question, not the rate.

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
