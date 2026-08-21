# The benchmark pipeline, stage by stage

*Transient TEMP/ note for humans. The authoritative methodology lives in `PROJECT-THESIS.md`,
`docs/STAGES.md`, and the stage roadmaps.*

The workload is a digital pathology pipeline. A whole-slide image is a gigapixel microscope scan of a
tissue sample, 0.5 to 4 GB compressed. The pipeline turns slides into AI predictions. Every cell runs
identically on both filesystems (WEKA and FSx for Lustre) through a recording wrapper that captures
application, filesystem, and wire telemetry. Stages are listed 1 to 7 here; the actual run order differs
(dependencies run first). Each entry: what it does, then Tool / Storage pattern / Bottleneck.

## Stage 1: Ingest and raw speed limits

- **1.0 (a-d): Measure the fastest the filesystem can go, with no real workload in the way.** Tool: fio
  (O_DIRECT). Pattern: a sequential write, b sequential read, c random write IOPS, d random read IOPS,
  swept over block sizes and job counts; read corpora sized past the server caches. Bottleneck: storage,
  by design. Every later number is quoted against these ceilings.
- **1.4: Prove the local NVMe scratch is fast enough to be a copy source.** Tool: fio. Pattern: local-disk
  streaming read. Bottleneck: local NVMe (it must outrun the filesystem or 1.5 measures the wrong thing).
- **1.5: Copy the slide library from local disk into the filesystem, like a scanner dumping a day's
  output.** Tool: fpsync. Pattern: parallel large sequential writes plus file-create metadata. Bottleneck:
  storage write path.
- **1.6: Run that ingest while simulated viewers read at the same time.** Tools: fpsync + fio. Pattern:
  streaming writes mixed with 4K random reads. Bottleneck: storage QoS (who suffers first).
- **1.7: Download the two slide datasets from S3 onto the filesystem, checksum-verified.** Tool:
  `aws s3 sync`. Pattern: many-stream large writes. Bottleneck: measured as the S3 fetch side, not storage.
- **1.8: Do the same import with FSx's built-in S3 integration.** Lustre leg only, a capability check, not
  part of the head-to-head.

## Stage 2: Cataloging

- **2.0: Open every slide and read its header metadata, like building an archive catalog.** Tool:
  OpenSlide. Pattern: thousands of tiny metadata reads (open/stat/header), cold versus warm. Bottleneck:
  storage metadata path; cells finish in seconds.

## Stage 3: Tissue detection

- **3.0: Find the tissue on each slide and save the list of tiles worth reading.** Most of a slide is
  empty glass; everything downstream reads through these lists. Tool: CLAM (OpenSlide-based). Pattern:
  scattered reads of low-resolution slide levels, small HDF5 writes. Bottleneck: CPU (image processing).

## Stage 4: Getting tiles off disk

- **4.A: Cut every tile out once and pack them into one file per slide.** Tool: OpenSlide + h5py. Pattern:
  read, JPEG-encode, write; many medium writes. Bottleneck: CPU (encode).
- **4.B: Read tiles on the fly from the original compressed slides.** Tools: OpenSlide (one call per tile)
  versus cuCIM (batched). Pattern: random small reads inside large files. Bottleneck: CPU (decode).
- **4.C: Read tiles from disk straight into GPU memory, no CPU decode.** Tool: kvikIO/cuFile, both modes,
  with per-cell proof of which path the bytes took. Pattern: aligned ~200 KB random reads at high queue
  depth. Bottleneck: storage read path; the closest real workload to storage-bound.
- **4.D: Convert slides into the uncompressed, GPU-readable format that 4.C needs.** Tool: a tifffile
  converter. Pattern: large sequential writes, ~5.9 TB total. Bottleneck: CPU (decode and resize).

## Stage 5: Training as a storage consumer

- **5.A / 5.B: Train a classic image classifier (ResNet-50) on tiles streamed from the filesystem, on 1,
  2, and 4 GPUs.** Tool: PyTorch DDP; 5.A reads via the GPU path, 5.B via cuCIM. Pattern: sustained random
  tile reads feeding GPUs, with per-step timing that separates data-loading from compute. Bottleneck: GPU
  and inter-GPU communication; the measurement is whether storage ever becomes the drag. A storage stress
  test, not a job a real user runs today.

## Stage 6: The modern AI workload

- **6.A: Run large pretrained AI models over every tile and write one embedding file per slide.** An
  embedding file is the slide reduced to a matrix of numbers, 50 to 70 MB. Tools: Virchow2, GigaPath,
  UNI2-h via PyTorch. Pattern: streaming tile reads plus steady medium-file writes; the full-cohort tier
  cycles convert, extract, delete in 200-slide chunks. Bottleneck: GPU compute (storage sat at ~2% of
  ceiling on WEKA).
- **6.B.1: Generate a huge synthetic library of embedding files.** About 5.8 TB, including one corpus
  deliberately larger than client RAM plus server cache. Tool: a PyTorch/NumPy generator. Pattern:
  sustained many-file writes. Bottleneck: generator CPU versus storage write.
- **6.B.2: Read that library back with up to 256 parallel workers.** Tool: a multiprocess `torch.load`
  reader, random / shuffled / sequential order, several file sizes. Pattern: small-file random reads with
  heavy metadata traffic. Bottleneck: storage metadata path, deliberately never bandwidth.
- **6.B.3: Train the small diagnosis classifier on the real embedding files.** MIL: it combines all of a
  slide's embeddings into one prediction. Tool: PyTorch, canonical CLAM design. Pattern: parallel
  whole-file reads; the corpus fits in RAM, so storage matters mostly on the first pass. Bottleneck: host
  CPU and RAM.
- **6.C: Run ingest, extraction, classifier training, and a viewer all at once on one namespace.** Tools:
  an orchestrator over fpsync, the 6.A extractor, the 6.B.3 trainer, and fio (the viewer stand-in).
  Pattern: everything at once. Bottleneck: storage QoS; each workload is scored on how much of its solo
  speed it keeps, ending with a 4-hour endurance run.
- **6.D: Add the measured stage times into one end-to-end pipeline number.** Tool: arithmetic over
  recorded wallclocks. No new run.

## Stage 7: Clinical deployment (latency, not throughput)

- **7.1: Process one slide start to finish and time every phase.** Detect tissue, extract embeddings,
  classify, write a heatmap image marking suspicious regions. Cold and warm. Tools: the stage 3/6
  components plus tifffile/Pillow. Pattern: burst reads then one medium write per slide. Bottleneck: GPU
  and storage, split per phase in the record.
- **7.2: The same with 1, 4, 16, and 64 slides in flight.** The p99-latency-under-load SLA number.
  Pattern: concurrent burst reads and writes. Bottleneck: storage and queueing (GPUs deliberately
  oversubscribed at high N).
- **7.3: Time the writing of the result heatmaps in three formats spanning ~10x in size.** Pattern:
  per-slide medium-to-large writes. Bottleneck: writer CPU versus storage write, reported separately.
- **7.4a: Feed slides in on a fixed clock, like a scanner, and time arrival to result.** Pattern: the 7.1
  loop on a timer. Bottleneck: whichever pipeline phase falls behind the clock.
- **7.4b: Write a file, and time how fast a second process can see and read it.** Tool: a
  write-fsync-rename writer and a 1 ms polling reader. Pattern: pure consistency and visibility, no
  bandwidth. Bottleneck: filesystem consistency semantics.
- **7.5: Run the full clinical mix at once, 30 minutes, then 4 hours.** Inference, ingest, heatmap
  viewing, slide viewing. Bottleneck: storage QoS.
- **7.6: Repeat the concurrent test on the second dataset.** A cross-vendor format check.

**Stability canaries (C0 to C8):** one fixed fio cell plus one create/stat/unlink cell, repeated at nine
points across the leg; their spread is the noise band any cross-filesystem delta must clear.

## What a real user would actually run

Benchmark-only stages: 1.0, 1.4, 1.6, 5, 6.B.1, 6.B.2, 6.D, and the canaries exist to isolate storage
behavior, not as user steps. The real-world sequences:

- **Hospital running AI-assisted diagnostics:** scanners write slides to storage all day (the 1.5
  pattern); each new slide flows through detection, extraction, classification, and a heatmap write (the
  7.1 chain, which contains 3.0 and 6.A inside it), while pathologists open results as they land (the
  viewer pattern). A live hospital day is 7.5, and 7.4b's visibility question is what lets a viewer open a
  result the moment it is written.
- **Research lab building or evaluating models:** pull public cohorts from object storage (1.7), catalog
  the archive (2.0), detect tissue (3.0), convert if using the GPU read path (4.D), extract embeddings
  once with a foundation model (6.A), then train and retrain classifiers on those embeddings for weeks
  (6.B.3, whose real-world day-to-day read pattern is what 6.B.2 measures at controlled scale). A busy
  shared cluster afternoon looks like 6.C.
- **Platform team sizing storage for either of the above:** run 1.0 for ceilings, 4.C to check the
  GPU-direct read path, and 2.0 for the metadata floor, then read the two sequences above against those
  numbers.
