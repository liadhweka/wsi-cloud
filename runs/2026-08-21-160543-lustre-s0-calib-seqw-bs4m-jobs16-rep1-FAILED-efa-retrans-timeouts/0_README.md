# 2026-08-21-160543-lustre-s0-calib-seqw-bs4m-jobs16-rep1

**Filesystem:** lustre (mounted at /mnt/lustre)
**Stage:** 0  ·  **Started (UTC):** 2026-08-21T16:05:44Z
**Hostname:** ip-10-1-1-251.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
fio --name=calib-seqw-bs4m-jobs16-rep1 --directory=/mnt/lustre/benchmarks/fio-canary-calib --filename_format=calib.\$jobnum --size=10G --numjobs=16 --ioengine=libaio --direct=1 --iodepth=8 --time_based --group_reporting --output-format=json+ --status-interval=1 --rw=write --bs=4M --runtime=300 
```

## Why this run exists

CANARY-BAND CALIBRATION cell (D-5), diagnostic, never quote: calib-seqw-bs4m-jobs16-rep1. Probe-shaped fio against /mnt/lustre/benchmarks/fio-canary-calib; wire/app ratio feeds runs/.leg-state/lustre/canary-bands.json via wsi_agg_helper.py calibrate. Read cells are deliberately backend-RAM-resident (drives out of the picture; the ratio is the measurement).

## What's in this directory

- `metadata.json` — structured metadata (programmatic).
- `cmd.txt` / `cmd.log` — exact command and tee'd stdout+stderr from the benchmark.
- `pre/` — cluster + host state snapshot before the run.
- `raw/` — during-run time series at 1-second resolution. The recorder set is
  per-filesystem (`docs/RUNBOOK.md` holds each leg's Primary-vs-Diagnostic
  table). On this leg:
  - `lustre-stats.log` — verbatim 1 Hz cumulative llite (client VFS) / osc (per-OST
    RPC) / mdc (per-MDT metadata) stats blocks; the parser derives per-second rates.
    The quotable client series is the OSC bytes summed across OSTs (llite is blind
    to libaio traffic — diagnostic only).
  - `lnet-stats.log` — verbatim 1 Hz `lnetctl net show -v 4` blocks: the per-cell
    transport proof (D16 — data on the efa net, tcp near-flat).
  - `rdma-counters.csv` — EFA hw_counters byte/packet rates: the wire-level Primary
    on this leg (the client NIC IS the data path).
  - `nvidia-smi.csv` — per-GPU per-second.
  - `sar-{cpu,disk,net,mem,swap,paging,queue,ctxsw}.csv` — host-side categories.
  - `netdev-counters.csv` — kernel NIC counters (the tcp/metadata side here).
  - `nvidia-fs-stats.log` — verbatim 1 Hz nvidia-fs accounting (cuFile path proof, D8).
- `post/` — same snapshot taken after the run, for delta computation.
- `results.json` — parsed aggregates. Re-runnable any time via `scripts/parse-results.py <this-dir>`.

## Project context

This run is part of the WEKA-vs-Lustre WSI storage comparison on AWS.
- `CLAUDE.md` — project rules (docs citation, memory hygiene, recording philosophy).
- `/home/ec2-user/wsi-cloud/docs/STAGES.md` — the `--stage` code map, the per-leg plan, and the cross-stage decision register.
- `/home/ec2-user/wsi-cloud/docs/RUNBOOK.md` — operational runbook (how to run, how to re-parse, how to recover from failures).
