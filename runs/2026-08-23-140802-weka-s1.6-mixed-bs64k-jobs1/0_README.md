# 2026-08-23-140802-weka-s1.6-mixed-bs64k-jobs1

**Filesystem:** weka (mounted at /mnt/weka)
**Stage:** 1.6  ·  **Started (UTC):** 2026-08-23T14:08:05Z
**Hostname:** ip-10-0-1-21.ap-northeast-2.compute.internal  ·  **User:** ec2-user  ·  **Kernel:** 6.1.177-224.371.amzn2023.x86_64

## What was tested

Exact command:

```
bash -c $'\n        set +e\n        # Background: fpsync n=4 in its own process group via setsid.\n        # FPSYNC_PID is the session/process-group leader — kill -- -PGID\n        # kills the whole tree (fpsync master + rsync workers) without\n        # pattern-matching that could collide with the parent bash\'s argv.\n        setsid fpsync -v -n 4 -d /tmp/fpsync-stage1.6/bs64k-jobs1-warm /data/local-nvme/fpsync-source/tcga-brca/ /mnt/weka/data/fpsync-target/mixed/ &\n        FPSYNC_PID=$!\n        echo \'[wrapper] fpsync backgrounded in own session, pid=\'$FPSYNC_PID\n\n        # Foreground: fio. --output-format=json+ writes JSON to stdout (cmd.log).\n        # filename_format matches the prep\'s, so the files already exist at full\n        # size and fio skips the layout phase — checked before the sweep started.\n        fio \\\n          --name=read-mixed-bs64k-jobs1 \\\n          --directory=/mnt/weka/benchmarks/fio-scratch-mixed \\\n          --filename_format=\'fio-scratch-mixed.$jobnum.$filenum\' \\\n          --rw=randread --bs=64k --size=4G \\\n          --numjobs=1 --iodepth=8 \\\n          --ioengine=libaio --direct=1 \\\n          --runtime=600 --ramp_time=60 --time_based --group_reporting \\\n          --output-format=json+ --status-interval=1\n        FIO_RC=$?\n        echo \'[wrapper] fio exited rc=\'$FIO_RC\n\n        # Kill the entire fpsync process group (negative PID syntax). No\n        # pattern matching, so cannot accidentally kill the parent bash.\n        kill -TERM -- -$FPSYNC_PID 2>/dev/null\n        sleep 2\n        kill -KILL -- -$FPSYNC_PID 2>/dev/null\n        wait 2>/dev/null\n        echo \'[wrapper] fpsync tree cleaned up\'\n        exit $FIO_RC\n      ' 
```

## Why this run exists

Stage 1.6 mixed sweep cell 6/9: concurrent ingest+read. Steady-state cell under the grid's RECORDED EXEMPTION from the cold/warm dimension (D13 route 4): production is warm, --direct=1 removes the client page cache from the question, and the server side is uncontrolled — evidenced by the sweep's cold reference cell. Ingest = fpsync -n 4 (fixed, and set as a FRACTION OF THIS LEG'S OWN 1.5 write curve — an absolute rate carried across legs would make the two cells different workloads). Read = fio --rw=randread --bs=64k --numjobs=1 --iodepth=8 --runtime=600 --ramp_time=60 libaio --direct=1 --filename_format=fio-scratch-mixed.$jobnum.$filenum against pre-staged fio scratch (64 complete files at /mnt/weka/benchmarks/fio-scratch-mixed; the format matches the prep's, so this cell reads the pre-staged corpus and not files it laid out itself inside the timed window). Cell order is fixed and de-ordered in jobs so warmth never tracks the swept variable. Wrapper: fpsync kicked off in background, fio runs in foreground for the timed window, fpsync killed when fio exits. Per-cell isolation via record-run.sh; any cell failure leaves rest of sweep intact.

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
