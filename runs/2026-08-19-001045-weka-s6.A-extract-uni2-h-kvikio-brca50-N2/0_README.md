# 2026-08-19-001045-weka-s6.A-extract-uni2-h-kvikio-brca50-N2

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 6.A  ·  **Started (UTC):** 2026-08-19T00:10:48Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/extract-features-foundation-stage6.py --backend kvikio --world-size 2 --model uni2-h --coords-dir /mnt/weka/tissue-detection/3.0/tcga-brca/n64/patches --manifest /home/ec2-user/wsi-cloud/scripts/manifests/tcga-brca-stage4a-subset.tsv --output-dir /mnt/weka/features/6.A/uni2-h/brca50 --batch-size 256 --extraction-steps-csv /home/ec2-user/wsi-cloud/runs/2026-08-19-001045-weka-s6.A-extract-uni2-h-kvikio-brca50-N2/extraction-steps.csv --per-slide-csv /home/ec2-user/wsi-cloud/runs/2026-08-19-001045-weka-s6.A-extract-uni2-h-kvikio-brca50-N2/per-slide.csv --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-19-001045-weka-s6.A-extract-uni2-h-kvikio-brca50-N2/extraction-summary.json --rawtiff-dir /mnt/weka/data/tcga-brca-rawtiff --n-buffer 256 --num-threads 16 --compat-mode off 
```

## Why this run exists

[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] Stage 6.A cell: model=uni2-h backend=kvikio N_gpus=2 dataset=brca50 gpus=0,1 batch=256 cufile_compat_mode=off (REQUESTED, not proven — the per-cell cuFile path accounting settles which path ran). WHY: docs/Stage-6-Feature-Extraction.md 6.A Tier 1 + that stage's decision register. Foundation-model frozen-eval extraction via mp.spawn DDP; per-rank modulo slide partitioning. AMP autocast FP16 + channels_last + cudnn.benchmark. CLS-token pooling (storage-benchmark universal choice). Cache regime=cold: client-cold per slide (the reader discards each slide's page cache before opening it; achieved result recorded in extraction-summary.json — a failed discard CONTRADICTS this declaration); CLIENT-SIDE ONLY — the server-side residual is unmanaged and recorded, not asserted (D13). Per-cell LD_PRELOAD scoping: kvikio cells preload the system libcufile, cuCIM cells leave it unset — cuCIM links its own bundled libcufile and segfaults on its first read under the ABI clash.

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
