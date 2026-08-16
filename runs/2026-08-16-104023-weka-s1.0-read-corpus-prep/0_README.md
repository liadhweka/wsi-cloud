# 2026-08-16-104023-weka-s1.0-read-corpus-prep

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 1.0  ·  **Started (UTC):** 2026-08-16T10:40:26Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
bash -c $'\n    set -euo pipefail\n    echo \'== phase 1: seq corpus ==\'\n    fio --name=stage-seq --filename=\'/mnt/weka/benchmarks/stage1-read-corpus/seq-corpus.bin\'         --rw=write --bs=1M --ioengine=libaio --iodepth=4 --direct=1         --numjobs=8 --offset_increment=384G --size=384G         --group_reporting --output-format=json+ --status-interval=1\n    echo \'== phase 2: randr one-touch regions ==\'\n    fio --name=stage-regions --directory=\'/mnt/weka/benchmarks/stage1-read-corpus\'         --filename_format=\'region-$jobnum.bin\'         --rw=write --bs=1M --ioengine=libaio --iodepth=4 --direct=1         --numjobs=26 --size=256G         --group_reporting --output-format=json+ --status-interval=1\n    echo \'== phase 3: eviction pass (full seq-corpus read) ==\'\n    fio --name=evict --filename=\'/mnt/weka/benchmarks/stage1-read-corpus/seq-corpus.bin\'         --rw=read --bs=1M --ioengine=libaio --iodepth=4 --direct=1         --numjobs=8 --offset_increment=384G --size=384G         --group_reporting --output-format=json+ --status-interval=1\n  ' 
```

## Why this run exists

Stage-1.0 read-corpora staging (not a comparison cell; a real sustained-write + sustained-read workload). Phase 1: seq-corpus.bin 3072 GiB (8 parallel writers). Phase 2: 26 one-touch regions x 256 GiB for 1.0d. Phase 3: eviction pass — full sequential read of the seq corpus, so the staging writes' tail leaves server RAM before any cell runs. Sizes are env parameters derived from the provisioned server-side caches (D13).

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
