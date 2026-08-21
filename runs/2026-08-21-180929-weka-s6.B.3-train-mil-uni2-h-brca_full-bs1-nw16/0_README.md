# 2026-08-21-180929-weka-s6.B.3-train-mil-uni2-h-brca_full-bs1-nw16

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 6.B.3  ·  **Started (UTC):** 2026-08-21T18:09:35Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
/data/local-nvme/conda-envs/wsi-cucim-2604/bin/python /home/ec2-user/wsi-cloud/scripts/train-mil-stage6b.py --features-dir /mnt/weka/features/6.A/uni2-h/brca_full --embedding-dim 1536 --num-workers 16 --ramp 300 --runtime 900 --training-steps-csv /home/ec2-user/wsi-cloud/runs/2026-08-21-180929-weka-s6.B.3-train-mil-uni2-h-brca_full-bs1-nw16/training-steps.csv --summary-json /home/ec2-user/wsi-cloud/runs/2026-08-21-180929-weka-s6.B.3-train-mil-uni2-h-brca_full-bs1-nw16/training-summary.json 
```

## Why this run exists

[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] Stage 6.B.3 canonical CLAM MIL training cell — real features from 6.A. model=uni2-h batch_size=1 num_workers=16. WHY: grounds the Phase 2 metadata-stress story in actual production training context. Storage concurrency driven by DataLoader num_workers (each worker prefetches one slide); batch_size=1 matches mahmoodlab/CLAM canonical (collate_MIL + CLAM_SB.forward([N,D])). num_workers is the customer-quotable IO axis. Regime: warm — the per-model feature corpus fits host RAM, so this is memory-served steady-state by construction after the first pass (Stage-6 roadmap regime row); it measures MIL throughput, not storage bandwidth — the cold storage number belongs to 6.B.2's synthetic corpus.

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
