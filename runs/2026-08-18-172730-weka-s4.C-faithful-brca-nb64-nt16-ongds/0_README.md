# 2026-08-18-172730-weka-s4.C-faithful-brca-nb64-nt16-ongds

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 4.C  ·  **Started (UTC):** 2026-08-18T17:27:34Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/read-tiles-kvikio.py --mode faithful --rawtiff-dir /mnt/weka/data/tcga-brca-rawtiff --manifest /home/ec2-user/wsi-cloud/scripts/manifests/tcga-brca-stage4a-subset.tsv --compat-mode on --n-buffer 64 --num-threads 16 --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-18-172730-weka-s4.C-faithful-brca-nb64-nt16-ongds/reader-summary.json --level 0 
```

## Why this run exists

Stage 4.C faithful mode on fs=weka. dataset=brca compat_mode=on n_buffer=64 num_threads=16. LD_PRELOAD=/usr/local/cuda/targets/x86_64-linux/lib/libcufile.so.1.14.1, CUFILE_ENV_PATH_JSON=/home/ec2-user/cufile-config/cufile.json, single GPU=0. 4096-byte aligned reads via NVIDIA's _get_aligned_read_props. Cache regime=cold: client-cold at read/window entry via cucim discard_page_cache (faithful: per slide before its read; random: whole pool before the timed window — within-window re-draws may self-warm and the discard counters keep that legible), achieved result recorded in reader-summary.json; CLIENT-SIDE ONLY — the server-side residual is unmanaged and recorded, not asserted (D13). Reader: /home/ec2-user/wsi-cloud/scripts/read-tiles-kvikio.py. Extra: --level 0

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
