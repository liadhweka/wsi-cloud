# 2026-08-18-191804-weka-s5.B-train-resnet50-cucim-brca-N1

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 5.B  ·  **Started (UTC):** 2026-08-18T19:18:07Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/train-resnet50-stage5.py --backend cucim_batched_cpu --world-size 1 --coords-dir /mnt/weka/tissue-detection/3.0/tcga-brca/n64/patches --manifest /home/ec2-user/wsi-cloud/scripts/manifests/tcga-brca-stage4a-subset.tsv --batch-size 256 --ramp 300 --runtime 1200 --training-steps-csv /home/ec2-user/wsi-cloud/runs/2026-08-18-191804-weka-s5.B-train-resnet50-cucim-brca-N1/training-steps.csv --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-18-191804-weka-s5.B-train-resnet50-cucim-brca-N1/training-summary.json --lru-size 64 --seed 42 --svs-dir /mnt/weka/data/tcga-brca 
```

## Why this run exists

Stage 5.B cell on fs=weka: backend=cucim_batched_cpu N_gpus=1 gpus=0 batch_per_rank=256 effective_batch=256 ramp=300s steady=1200s cufile_compat_mode=<n/a> (REQUESTED, not proven — the per-cell cuFile path accounting settles which path ran). Cache regime=warm: steady-state by construction (D13) — the cell is long enough for its own working set to warm and production training is warm; the cold read ceilings live in Stage 1.0/4.B/4.C, and the achieved state is recorded, never asserted. cuCIM per-process tile cache: 512 MiB (library default on this stack; recorded-not-swept per the Stage-4 register — identical on both legs). WHY this cell: see Stage-5-Training.md § 5.A/5.B — ResNet-50 is the storage-stressing choice (small fast model = more demand per unit of compute). DDP self-launched via mp.spawn with an explicit loopback master. GPU set=0 (⏳ D-8: NUMA-aware ordering to be re-derived on this instance). LD_PRELOAD=<unset>, CUFILE_ENV_PATH_JSON=/home/ec2-user/cufile-config/cufile.json. Per-training-step CSV at training-steps.csv is the PRIMARY headline source; nvidia-smi is also PRIMARY from Stage 4 onward. Trainer: /home/ec2-user/wsi-cloud/scripts/train-resnet50-stage5.py.

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
