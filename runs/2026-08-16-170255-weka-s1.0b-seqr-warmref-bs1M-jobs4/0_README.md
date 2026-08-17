# 2026-08-16-170255-weka-s1.0b-seqr-warmref-bs1M-jobs4

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 1.0b  ·  **Started (UTC):** 2026-08-16T17:02:58Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
fio --name=seqr-warmref-bs1M-jobs4 --filename=/mnt/weka/benchmarks/stage1-read-corpus/seq-corpus.bin --rw=read --bs=1M --numjobs=4 --iodepth=1 --ioengine=libaio --direct=1 --offset=0 --offset_increment=16G --size=16G --loops=2 --group_reporting --output-format=json+ --status-interval=1 
```

## Why this run exists

Stage 1.0b WARM REFERENCE cell RE-RUN (the original never persisted — its creation failed at 0 bytes free during the 2026-08-16 ENOSPC; the INDEX row is its record) (D13 route 2, inverted: the grid default regime is cold, so the reference is warm). 4 jobs x 16 GiB disjoint head slices, --loops=2: pass 1 ~cold (the head was evicted by the preceding 2.7 TiB re-run scan), pass 2 deliberately server-cache-warm. The split-window contrast is the evidence the grid cold construction rests on; pass 2 is also the server-cache-served sequential read rate. Identical parameters to the driver invocation.

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
