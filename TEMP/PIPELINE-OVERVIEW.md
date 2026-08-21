# WSI pipeline overview — one sentence per step, with the tools

*Transient TEMP/ note for humans (per TEMP/ rules: never authoritative — the methodology lives in
`PROJECT-THESIS.md`, `docs/STAGES.md`, and the stage roadmaps). Steps in per-leg run order; every step runs
identically on both legs, wrapped in `record-run.sh` (per-cell telemetry, canaries, cost inputs) with the
per-leg recorder set (`weka stats` / `lctl`+`lnetctl`, `sar`, `nvidia-smi`, nvidia-fs, netdev/RDMA counters).*

- **1.0a–d — synthetic ceilings:** `fio` (libaio, O_DIRECT) sweeps seq/random × read/write across block
  sizes and job counts to anchor every downstream "% of ceiling" denominator.
- **1.7 — S3→FS hydration:** `aws s3 sync` pulls the TCGA-BRCA + CAMELYON16 corpora onto the filesystem at
  four concurrency levels with per-file md5 verification — the head-to-head ingest cell.
- **3.0 — tissue detection:** **CLAM** (OpenSlide-backed, N parallel instances) segments tissue and writes
  each slide's 20× tile-coordinate HDF5, gating everything downstream.
- **4.D — 20× raw-TIFF conversion:** a **tifffile**-based converter (fail-loud mpp guard) writes
  single-level, 256-px-tiled, uncompressed 20× TIFFs that cuFile can read as raw byte ranges — itself a
  measured bulk-write workload.
- **4.A — pre-extract:** **OpenSlide** reads + JPEG-encodes tiles into per-slide HDF5 (**h5py**) — the
  pre-extract strategy baseline.
- **4.B — on-the-fly tile reads:** random tile reads via **OpenSlide** (per-tile) and **cuCIM** (batched
  CPU) worker pools — the access pattern training actually generates.
- **4.C — GPU-direct reads:** **kvikIO/cuFile** reads tile byte ranges from the raw-TIFF straight into GPU
  buffers, both cuFile modes (bounce vs POSIX), with the per-cell GPU-direct-vs-bounced byte split recorded
  from cuFile/nvidia-fs accounting.
- **5.A / 5.B — DDP training:** **PyTorch DDP ResNet-50** (AMP FP16, channels_last, CUDA-event timing) fed
  by the kvikIO reader (5.A) or cuCIM (5.B) at N ∈ {1,2,4} GPUs — does a real training loop consume what
  storage delivers.
- **6.A — foundation-model extraction:** frozen **Virchow2 / GigaPath / UNI2-h** ViTs (timm + Hugging Face,
  AMP FP16, DDP) embed every tile into per-slide `.pt` tensors — 50-slide scaling tier, full 1064-slide
  cohort (chunked convert→extract→delete), CAMELYON16 cross-check.
- **6.B.3 — MIL training:** canonical **CLAM-style gated-attention MIL** (PyTorch, `batch_size=1` +
  `collate_MIL`) trains on the real 6.A features, with DataLoader `num_workers` as the storage-concurrency
  axis.
- **6.B.1 — synthetic corpus generation:** a **PyTorch/NumPy generator** writes the ~5.8 TB `.pt` suite
  (including the 3.0 TiB past-cache cold corpus) — recorded as a sustained-write cell.
- **6.B.2 — small-file/metadata stress:** a **multiprocess `torch.load` reader** sweeps random /
  batched-shuffled / sequential small-file reads across concurrency, file size, and FP32/FP16 — the
  metadata-path stage, structurally non-bandwidth-bound.
- **6.C — concurrent multi-workload QoS:** a bash **orchestrator** runs ingest (**fpsync**) + extraction
  (the 6.A pattern) + MIL (6.B.3 at its measured knee) + viewer (**fio** 4K random) simultaneously,
  measuring each workload's retention against its own solo baseline, plus a 4 h endurance cell.
- **2.0 — cataloging:** an **OpenSlide** property extractor sweeps per-slide metadata reads across
  concurrency, cold vs warm — the pure metadata stage.
- **7.1–7.6 — clinical inference:** a per-slide worker chains detection → extraction → MIL → heatmap write
  (**tifffile**/**Pillow**, real attention weights) for solo latency (7.1), latency under N concurrent
  processes (7.2), heatmap-write characterisation (7.3), a streaming scanner loop + read-after-write
  visibility via an fsync-then-rename writer and 1 ms polling reader (7.4), the all-four-up clinical mix +
  4 h endurance (7.5), and the CAMELYON16 cross-check (7.6).
- **1.5 / 1.6 — bulk copy + mixed ingest:** **fpsync** bulk local-NVMe→filesystem copy, then fixed-rate
  ingest concurrent with a **fio** random-read grid — the scanner-feeding-while-clinicians-read state.
- **6.D — end-to-end bookend:** composed arithmetically from the measured per-phase wallclocks (no new
  cell is run).
