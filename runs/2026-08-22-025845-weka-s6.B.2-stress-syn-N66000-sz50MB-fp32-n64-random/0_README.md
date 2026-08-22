# 2026-08-22-025845-weka-s6.B.2-stress-syn-N66000-sz50MB-fp32-n64-random

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 6.B.2  ·  **Started (UTC):** 2026-08-22T02:58:48Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/read-feature-files-stage6b.py --corpus-dir /mnt/weka/features-6.B-synthetic/syn-N66000-sz50MB-fp32 --pattern random --n-processes 64 --runtime 600 --ramp 300 --latency-csv /home/ec2-user/wsi-cloud/runs/2026-08-22-025845-weka-s6.B.2-stress-syn-N66000-sz50MB-fp32-n64-random/per-file-latencies.csv --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-22-025845-weka-s6.B.2-stress-syn-N66000-sz50MB-fp32-n64-random/file-io-summary.json 
```

## Why this run exists

Stage 6.B.2 cell on fs=weka: corpus=syn-N66000-sz50MB-fp32 pattern=random n_processes=64 ramp=300s steady=600s. WHY: the small-file/metadata substage — structurally NOT bandwidth-bound, so it stays discriminating even under a client-capped ceiling, and it exercises whichever metadata architecture this leg's filesystem uses. Per-file-load latency CSV is the PRIMARY headline source. Cache state recorded as achieved, not asserted (D13). Regime: cold by construction — corpus 3222 GiB exceeds client RAM + the larger server-side cache (2304 GiB floor, Stage-6 register); client page cache additionally discarded at cell start, achieved recorded in file-io-summary.json.

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
