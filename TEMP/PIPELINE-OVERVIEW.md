# The benchmark pipeline, step by step

*Transient TEMP/ note for humans. The authoritative methodology lives in `PROJECT-THESIS.md`,
`docs/STAGES.md`, and the stage roadmaps.*

The workload is a digital pathology pipeline. A whole-slide image (WSI) is a gigapixel microscope scan of a
tissue sample, stored as a compressed pyramidal file of roughly 0.5 to 4 GB. The pipeline turns raw slides
into AI predictions, and each step has a different I/O personality. Every step runs identically on both
filesystems (WEKA and FSx for Lustre), only the mount changes, and every cell runs through a recording
wrapper (`record-run.sh`) that captures application, filesystem, and wire telemetry plus cost inputs.
Steps below are in per-leg run order.

**1.0: Synthetic ceilings.** Establish the best the storage path can deliver, so every later number can be
quoted as a percentage of a matching ceiling.
- 1.0a: sequential write sweep with fio (O_DIRECT, libaio) across block sizes and job counts.
- 1.0r: stage two read corpora sized past the server-side caches, then evict them, so the read sweeps are
  genuinely cold.
- 1.0b: sequential read sweep over that corpus, one pass per cell.
- 1.0c: random write IOPS sweep.
- 1.0d: random read IOPS sweep; each cell reads a disjoint region exactly once so no cache can serve it.

**1.7: Hydration.** Copy the two public datasets from S3 onto the filesystem with `aws s3 sync` at four
concurrency levels, md5-verified per file. TCGA-BRCA is about 1,100 breast-cancer slides, CAMELYON16 is
lymph-node slides from a different scanner vendor. This is both the ingest measurement and the staging step.

**3.0: Tissue detection.** Most of a slide is empty glass. CLAM, an open-source pathology tool built on
OpenSlide, finds the tissue and writes one HDF5 per slide listing the coordinates of every 256-pixel tile
worth reading. Everything downstream reads slides through these lists. CPU-heavy, storage-light.

**4: Patching.** Three strategies for getting tiles off disk, plus the conversion that enables the GPU path.
- 4.D: convert slides into "raw TIFF", a single-level uncompressed tiled file where tile N is a fixed byte
  range, so a GPU can fetch tiles with no decoder. Written with tifffile; about 5.9 TB of sequential writes.
- 4.C: kvikIO/cuFile reads those tile byte ranges straight into GPU memory, in both cuFile modes, with
  per-cell accounting of which path every byte actually took.
- 4.B: read tiles from the original compressed slides on CPU, OpenSlide one tile per call versus cuCIM
  batched. This is the access pattern a training job generates naturally.
- 4.A: pre-extract everything once, JPEG-encode each tile, and pack one HDF5 per slide with h5py. The
  convert-once strategy baseline.

**5: Training.** Real ResNet-50 training with PyTorch DDP on 1, 2, and 4 GPUs, per-step timing splitting
data-loading from compute, so we see whether a training loop can consume what storage delivers. 5.A feeds
from the kvikIO raw-TIFF path, 5.B from cuCIM on the original slides.

**6.A: Foundation-model feature extraction.** The modern production workload. A frozen foundation model, a
large pretrained vision transformer (Virchow2, GigaPath, UNI2-h, via PyTorch and Hugging Face), converts
each tile into a vector; the output is one `.pt` tensor file per slide, roughly 50 to 70 MB. Tier 1 sweeps
3 models x 1/2/4 GPUs x both read paths on 50 slides. Tier 3 repeats the peak cells on CAMELYON16 as a
cross-vendor format check. Tier 2 runs the full 1,064-slide cohort: the raw TIFF does not fit at once, so
it converts a 200-slide chunk, extracts with all three models, deletes the chunk, and repeats.

**6.B: Small-file and metadata stress.** The downstream-training pattern that pegs legacy NAS metadata
servers.
- 6.B.3: a small attention classifier (MIL, the canonical CLAM design) trains on the real feature files,
  one slide per step; storage concurrency comes from DataLoader workers each prefetching one file.
- 6.B.1: generate a synthetic `.pt` corpus, about 5.8 TB, including one 3.0 TiB corpus deliberately larger
  than client RAM plus the bigger server cache, so its reads must hit storage.
- 6.B.2: multiprocess readers `torch.load` files at up to 256-way concurrency, in random, shuffled, and
  sequential patterns, across file sizes and FP32/FP16. Many small files and metadata ops, not bandwidth.

**6.C: Concurrent multi-workload.** Four real workloads on one namespace at once: ingest (fpsync bulk
copy), extraction (the 6.A pattern), MIL training (6.B.3 at its measured knee), and a viewer (fio 4K random
reads, standing in for a pathologist panning and zooming). Measured as how much of its solo speed each
workload keeps: solos, pairs, triples, all four, then all four sustained for 4 hours.

**2.0: Cataloging.** Open every slide and read its metadata properties with OpenSlide at rising
concurrency, cold versus warm cache. Pure metadata stress; cells finish in seconds.

**7: Clinical inference.** Deployment-shaped: latency, not throughput.
- 7.1: one slide at a time through the full chain (detect, extract, classify, write a heatmap image marking
  suspicious regions, via tifffile/Pillow), cold and warm, reported as seconds per slide with a per-phase
  split.
- 7.2: the same worker at 1, 4, 16, and 64 concurrent processes; the p99-under-load SLA number.
- 7.3: heatmap writing in three formats spanning roughly 10x in output size.
- 7.4a: a synthetic scanner emits one slide per minute through the loop; end-to-end arrival-to-visible time.
- 7.4b: one process writes heatmap-sized files (write to temp name, fsync, rename) while another polls
  every 1 ms for the file to appear; read-after-write visibility.
- 7.5: the clinical mix (inference, ingest, heatmap viewing, slide viewing) for 30 minutes, then 4 hours.
- 7.6: repeat the 7.2 configuration on CAMELYON16.

**1.5: Bulk copy.** fpsync parallel copy of the corpus from local NVMe into the filesystem, the
scanner-to-storage write path with real files. **1.6: Mixed ingest and read.** Fixed-rate ingest running
under a fio random-read grid: can clinicians read while a scanner feeds?

**6.D: End-to-end.** No new run; the measured per-phase wallclocks compose arithmetically.

**Stability canaries (C0 to C8).** One fixed fio cell plus one create/stat/unlink metadata cell, repeated at
nine points across the leg; their spread is the noise band any cross-filesystem delta must clear.
