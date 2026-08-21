# 2026-08-20-034202-weka-s6.A-extract-multimodel-kvikio-brca_full-N4

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 6.A  ·  **Started (UTC):** 2026-08-20T03:42:08Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/home/ec2-user/wsi-cloud/scripts/run-stage6a-tier2-chunked-multimodel.sh --models virchow2\,gigapath\,uni2-h --n-gpus 4 --gpu-csv 0\,1\,2\,3 --output-dir-base /mnt/weka/features/6.A --run-dir /home/ec2-user/wsi-cloud/runs/2026-08-20-034202-weka-s6.A-extract-multimodel-kvikio-brca_full-N4 --chunk-size 200 
```

## Why this run exists

[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] Stage 6.A Tier 2 MULTI-MODEL chunked cell: models=virchow2,gigapath,uni2-h backend=kvikio N=4 dataset=brca_full (the uniform-magnification cohort per STAGES.md D5, chunked into batches of 200 slides). Cross-model conversion sharing: each chunk SVS→raw-TIFF converts ONCE, then extracts for each model in turn, then cleans up. Sharing conversion across models is STRUCTURAL: the chunk cadence (convert→extract→delete) is itself the measured production pattern (Stage-4 register: transient by design, independent of 4.D's retained artifact, which this cell never touches — it converts into its own chunk dirs), and conversion is a large share of per-chunk wallclock. Cache regime=na-mixed-rw-chunk-resident: each chunk's extraction reads raw-TIFF this cell wrote minutes earlier — server-cache-resident BY CONSTRUCTION, which is the workload, not a contamination; no cold arm exists by construction (D13 route-4 stated ground); the reader still discards client page cache per slide, achieved recorded in the per-chunk summaries under chunk-artifacts/. Per-cell LD_PRELOAD scoping: kvikIO cells preload the system libcufile (cuCIM cells never do — it links its own bundled copy and segfaults on its first read under the ABI clash).

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
