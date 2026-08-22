# 2026-08-22-073513-weka-s0-calib-randr-bs4k-jobs16-rep2

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 0  ·  **Started (UTC):** 2026-08-22T07:35:17Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
fio --name=calib-randr-bs4k-jobs16-rep2 --directory=/mnt/weka/benchmarks/fio-canary-calib --filename_format=calib.\$jobnum --size=10G --numjobs=16 --ioengine=libaio --direct=1 --iodepth=8 --time_based --group_reporting --output-format=json+ --status-interval=1 --rw=randread --bs=4K --runtime=180 
```

## Why this run exists

CANARY-BAND CALIBRATION cell (D-5), diagnostic, never quote: calib-randr-bs4k-jobs16-rep2. Probe-shaped fio against /mnt/weka/benchmarks/fio-canary-calib; wire/app ratio feeds runs/.leg-state/weka/canary-bands.json via wsi_agg_helper.py calibrate. Read cells are deliberately backend-RAM-resident (drives out of the picture; the ratio is the measurement).

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
