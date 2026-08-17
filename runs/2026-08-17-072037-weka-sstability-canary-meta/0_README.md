# 2026-08-17-072037-weka-sstability-canary-meta

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** stability  ·  **Started (UTC):** 2026-08-17T07:20:40Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
bash -c $'\n    set -u\n    d="/mnt/weka/benchmarks/stability-canary/meta.$$"; mkdir -p "$d"; n=2000\n    t0=$(date +%s.%N); for i in $(seq 1 $n); do : > "$d/f$i"; done\n    t1=$(date +%s.%N); for i in $(seq 1 $n); do stat -c %s "$d/f$i" >/dev/null; done\n    t2=$(date +%s.%N); for i in $(seq 1 $n); do rm -f "$d/f$i"; done\n    t3=$(date +%s.%N); rmdir "$d"\n    awk -v n=$n -v a=$t0 -v b=$t1 -v c=$t2 -v e=$t3 \\\n      "BEGIN{printf \\"canary_meta create_ops_s=%.1f stat_ops_s=%.1f unlink_ops_s=%.1f\\n\\", n/(b-a), n/(c-b), n/(e-c)}"\n  ' 
```

## Why this run exists

D18 stability canary (meta): create/stat/unlink 2000 empty files in a fresh dir, one timed phase each, ops/s printed to stdout. Fixed config by design — this cell's spread across the leg is the leg's noise band for metadata-class cells.

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
