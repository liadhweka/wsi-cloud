# 2026-08-17-061617-weka-s3.0-tissue-tcga-brca-n1

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 3.0  ·  **Started (UTC):** 2026-08-17T06:16:21Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
bash -c $'\n        set +e\n        # Launch N parallel CLAM instances, one per chunk, all writing to the same save_dir.\n        # CLAM\'s per-slide outputs land in per-slide-named files inside patches/ and masks/,\n        # so concurrent writes from N workers don\'t collide as long as no two chunks share a slide\n        # (round-robin guarantees that).\n        echo \'[wrapper] launching 1 parallel CLAM instances\'\n        for i in $(seq 0 0); do\n          (\n            cd /home/ec2-user/wsi-tools/CLAM\n            /data/local-nvme/conda-envs/wsi-cucim-2604/bin/python3 create_patches_fp.py \\\n              --source /tmp/stage3-chunks/tcga-brca/n1/chunk$i \\\n              --save_dir /mnt/weka/tissue-detection/3.0/tcga-brca/n1 \\\n              --seg --patch \\\n              --patch_level 0 --patch_size 512 --step_size 512\n          ) &\n        done\n        wait\n        echo \'[wrapper] all CLAM instances done\'\n\n        # Quick app-level summary that the aggregator will parse from cmd.log\n        n_h5=$(find /mnt/weka/tissue-detection/3.0/tcga-brca/n1/patches -name \'*.h5\' 2>/dev/null | wc -l)\n        n_masks=$(find /mnt/weka/tissue-detection/3.0/tcga-brca/n1/masks -name \'*.jpg\' 2>/dev/null | wc -l)\n        echo \'=== summary ===\'\n        echo "slides_total:        1133"\n        echo "slides_with_h5:      $n_h5"\n        echo "slides_with_mask:    $n_masks"\n        echo "concurrency:         1"\n        echo "dataset:             tcga-brca"\n        # Note: total wallclock comes from record-run.sh\'s .run_start/.run_end\n      ' 
```

## Why this run exists

Stage 3.0 cell 1/6: CLAM tissue detection on tcga-brca (1133 slides) at concurrency n=1, 20× tiling (--patch_level 0 --patch_size 512 --step_size 512; CAM16 native level 1, BRCA 512px@40× resized to 256px@20× by downstream readers). Single-pass full dataset, --seg --patch (NO --stitch — visualization not needed downstream, also makes the workload more purely compute-bound for the 'Stage 3 is compute-stress' narrative). N parallel create_patches_fp.py instances (main-env interpreter) each consuming a round-robin chunk of the manifest, all writing to /mnt/weka/tissue-detection/3.0/tcga-brca/n1. HDF5 tile coords + per-slide tissue mask JPEG.

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
