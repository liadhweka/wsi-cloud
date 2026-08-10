#!/usr/bin/env python3
"""train-resnet50-stage5.py — Stage 5 PyTorch DDP trainer fed by WekaFS storage.

Backends (pluggable, one per DDP rank — single Python process per rank):
  --backend kvikio              : kvikIO+GDS+raw-TIFF (Stage 4.C random-mode logic)
  --backend cucim_batched_cpu   : cuCIM CPU batched API (Stage 4.B Tier 3 peak: nw=16, bs=64)

DESIGN — single in-process reader per DDP rank, NOT PyTorch DataLoader workers:
  kvikIO+GDS's internal async pread + n_buffer pipelining already provides the
  parallelism that Stage 4.C measured at 4.89 GB/s single-process. cuCIM batched
  CPU has its own num_workers=16 internal C++ threads. Wrapping either in
  multiprocessing-forked PyTorch DataLoader workers would force `spawn` start
  method (CUDA context fork issues), split CuFile handles across processes, and
  add coordination overhead — for no measurable supply-side gain.

  This reuses the validated Stage 4.C / 4.B reader code directly, making the
  storage-path measurement as direct as possible. Per Stage-5-Training.md
  decision Q4 (locked 2026-05-16).

WHY 4096-byte aligned reads:
  cuFile silently falls back to a broken POSIX path on unaligned offsets, which
  surfaces as "Operation not permitted" at the Python layer. NVIDIA's reference
  code handles this; we do too via `aligned_read_props()` (lifted verbatim from
  cucim/examples/python/gds_whole_slide/demo_implementation.py).

WHY torch.cuda.synchronize() per step:
  Required for accurate per-phase timing (data load, forward, backward, opt).
  Adds ~1 sync per step (sub-ms on A100); marginal vs ~50 ms step time.
  DDP backward already has an implicit sync via AllReduce, so the actual
  marginal cost is only the data-load + forward phases.

Per-step CSV (rank 0 only): step_idx, t_step_start_s, t_step_end_s,
step_duration_ms, t_dataload_ms, t_forward_ms, t_backward_ms, t_optimizer_ms,
samples_per_step (= batch_size, host-local), loss.

The per-step CSV is the PRIMARY headline source for Stage 5 (per CLAUDE.md
recording philosophy + Stage-5-Training.md). The aggregator pairs it with
weka-stats.csv / RDMA / nvidia-smi / sar-cpu for cross-source validation.

Usage (launched by sweep driver via torchrun --nproc_per_node=$N):
  torchrun --nproc_per_node=$N $0 \\
    --backend kvikio \\
    --rawtiff-dir $FS_MOUNT/data/tcga-brca-rawtiff \\
    --coords-dir $FS_MOUNT/tissue-detection/3.0/tcga-brca/n64/patches \\
    --manifest scripts/manifests/tcga-brca-stage4a-subset.tsv \\
    --batch-size 256 --ramp 300 --runtime 1200 \\
    --training-steps-csv <run-dir>/training-steps.csv \\
    --summary-json <run-dir>/training-summary.json
"""
import argparse
import csv
import json
import os
import random
import sys
import time
from collections import OrderedDict
from pathlib import Path

import os as _os, sys as _sys
# The mount is a DIMENSION, never a constant: this project runs the identical code
# against two filesystems. Refuse to guess -- a wrong mount silently measures the
# other filesystem and the number still looks correct.
FS_MOUNT = _os.environ.get("FS_MOUNT")
if not FS_MOUNT:
    _sys.exit("FATAL: FS_MOUNT is unset -- source env.sh "
              "(see docs/NAMING-AND-VARIABLES.md).")

import cupy as cp
import h5py
import numpy as np
import torch
import torch.distributed as dist
import torch.nn as nn
from torch.cuda.amp import GradScaler, autocast
from torch.nn.parallel import DistributedDataParallel as DDP
from torchvision.models import resnet50


TILE_SIZE = 256


# -----------------------------------------------------------------------------
# NVIDIA's alignment helper, lifted verbatim from demo_implementation.py.
# WHY: cuFile requires 4096-byte aligned offsets and sizes; random tile offsets
# in raw TIFF are not naturally aligned.
# -----------------------------------------------------------------------------
def aligned_read_props(offsets, bytecounts, alignment=4096):
    offsets = np.asarray(offsets, dtype=np.int64)
    bytecounts = np.asarray(bytecounts, dtype=np.int64)
    rounded_offsets = (offsets // alignment) * alignment
    buffer_offsets = offsets - rounded_offsets
    rounded_bytecounts = buffer_offsets + bytecounts
    rounded_bytecounts = np.ceil(rounded_bytecounts / alignment).astype(np.int64) * alignment
    return rounded_offsets, rounded_bytecounts, buffer_offsets


# -----------------------------------------------------------------------------
# Manifest loading. Stage 4.A subset format: 4 comment lines + "slide_id" header
# + 50 slide IDs.
# -----------------------------------------------------------------------------
def load_manifest(path):
    out = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#") or ln == "slide_id":
                continue
            out.append(ln)
    return out


def build_coord_pool(coords_dir, slide_ids):
    """Returns list of (slide_id, coords_array)."""
    pool = []
    for sid in slide_ids:
        h5_path = Path(coords_dir) / f"{sid}.h5"
        if not h5_path.exists():
            continue
        with h5py.File(h5_path, "r") as f:
            coords = f["coords"][()]
        if coords.shape[0] == 0:
            continue
        pool.append((sid, coords))
    return pool


def synthetic_labels(coords_array_batch):
    """Deterministic 2-class label from coord position.

    Label = (x_pixel // 128 + y_pixel // 128) % 2. Gives the optimizer something
    to compute. No expectation of convergence — we measure throughput, not accuracy.
    """
    xs = coords_array_batch[:, 0].astype(np.int64) // 128
    ys = coords_array_batch[:, 1].astype(np.int64) // 128
    return (xs + ys) % 2


# =============================================================================
# Backend 1: kvikIO + GDS + raw-TIFF reader
# =============================================================================
class KvikIOReader:
    """In-process kvikIO+GDS reader. Stage 4.C random-mode logic adapted for batches.

    Holds LRU(lru_size) of {kvikIO.CuFile handle, tiff index meta} per slide.
    fetch_batch(B) issues B aligned async preads, drains them, copies tile data
    into a single [B, 3, 256, 256] uint8 GPU tensor.
    """

    def __init__(self, rawtiff_dir, coords_dir, slide_ids, lru_size, seed,
                 n_buffer, num_threads, compat_mode="off", level=0,
                 footprint_level0=TILE_SIZE):
        import kvikio
        import kvikio.defaults
        from cucim.clara import filesystem as cucim_fs

        # Configure kvikIO defaults
        mode_map = {"off": kvikio.CompatMode.OFF, "on": kvikio.CompatMode.ON, "auto": kvikio.CompatMode.AUTO}
        kvikio.defaults.set("compat_mode", mode_map[compat_mode])
        kvikio.defaults.set("num_threads", int(num_threads))

        self._kvikio = kvikio
        self._cucim_fs = cucim_fs

        self.rawtiff_dir = Path(rawtiff_dir)
        self.coord_pool = build_coord_pool(coords_dir, slide_ids)
        if not self.coord_pool:
            raise RuntimeError(f"empty coord pool for {coords_dir}")

        self.lru_size = lru_size
        self.rng = random.Random(seed)
        self.n_buffer = n_buffer
        self.level = level
        # 20×: raw-TIFF is 20×/256-tiled (Option B); CLAM coords are level-0 (40×)
        # px stepping by footprint_level0 (512). coord→tile = coord // footprint.
        self.footprint_level0 = footprint_level0
        self.cache = OrderedDict()  # slide_id -> {handle, idx_meta, path}

        # Cold-cache discipline: discard page cache on the first LRU-fill slides.
        for sid, _ in self.coord_pool[:lru_size]:
            p = self.rawtiff_dir / f"{sid}.tiff"
            if p.exists():
                try:
                    cucim_fs.discard_page_cache(str(p))
                except Exception:
                    pass

        # Sample one slide to learn tile_bytes (uniform across uncompressed TIFF).
        sid0 = self.coord_pool[0][0]
        meta0 = self._load_tiff_index(self.rawtiff_dir / f"{sid0}.tiff")
        if meta0 is None:
            raise RuntimeError(f"could not load tiff index for {sid0}")
        # uncompressed RGB tile = tile_height * tile_width * 3 bytes
        self.tile_bytes = int(meta0["tile_height"]) * int(meta0["tile_width"]) * 3
        # Aligned bytecount per tile is tile_bytes rounded up to 4096 + up to 4095 of preceding pad.
        # Worst case: buffer_offset=4095 + tile_bytes; round up to 4096.
        self.slot_bytes = int(np.ceil((self.tile_bytes + 4096) / 4096) * 4096)

    def _load_tiff_index(self, path):
        from tifffile import TiffFile
        with TiffFile(str(path)) as tif:
            if self.level >= len(tif.pages):
                return None
            page = tif.pages[self.level]
            return {
                "shape": page.shape,
                "tile_height": page.tilelength,
                "tile_width": page.tilewidth,
                "n_tiles_per_row": (page.shape[1] + page.tilewidth - 1) // page.tilewidth,
                "n_tiles_per_col": (page.shape[0] + page.tilelength - 1) // page.tilelength,
                "offsets": np.asarray(page.dataoffsets, dtype=np.int64),
                "bytecounts": np.asarray(page.databytecounts, dtype=np.int64),
            }

    def _get_slide(self, slide_id):
        if slide_id in self.cache:
            self.cache.move_to_end(slide_id)
            return self.cache[slide_id]
        if len(self.cache) >= self.lru_size:
            _, evicted = self.cache.popitem(last=False)
            try:
                evicted["handle"].close()
            except Exception:
                pass
        path = self.rawtiff_dir / f"{slide_id}.tiff"
        if not path.exists():
            return None
        idx = self._load_tiff_index(path)
        if idx is None:
            return None
        handle = self._kvikio.CuFile(str(path), "r")
        entry = {"handle": handle, "idx_meta": idx, "path": path}
        self.cache[slide_id] = entry
        return entry

    def _pixel_to_tile_index(self, x_pixel, y_pixel, idx_meta):
        # 20×: divide level-0 (40×) coords by footprint_level0 (512), not raw
        # tile_width/height (256) — raw-TIFF is 20×/256-tiled (Option B).
        tc = max(0, min(int(x_pixel) // self.footprint_level0, idx_meta["n_tiles_per_row"] - 1))
        tr = max(0, min(int(y_pixel) // self.footprint_level0, idx_meta["n_tiles_per_col"] - 1))
        return tr * idx_meta["n_tiles_per_row"] + tc

    def fetch_batch(self, batch_size, device):
        """Returns (images [B, 3, 256, 256] float on GPU, labels [B] int64 on GPU)."""
        coord_pool = self.coord_pool
        picks = []  # (slide, file_offset, bytecount, x_pixel, y_pixel)
        for _ in range(batch_size):
            sid, coords = self.rng.choice(coord_pool)
            slide = self._get_slide(sid)
            if slide is None:
                continue
            row = coords[self.rng.randrange(coords.shape[0])]
            x_px, y_px = int(row[0]), int(row[1])
            tile_idx = self._pixel_to_tile_index(x_px, y_px, slide["idx_meta"])
            off = int(slide["idx_meta"]["offsets"][tile_idx])
            bc = int(slide["idx_meta"]["bytecounts"][tile_idx])
            picks.append((slide["handle"], off, bc, x_px, y_px))

        if len(picks) < batch_size:
            # Pad by repeating the first pick (rare; only if all LRU slides missing)
            while len(picks) < batch_size and picks:
                picks.append(picks[0])

        # Compute aligned offsets for all picks at once
        raw_offsets = np.asarray([p[1] for p in picks], dtype=np.int64)
        raw_bcs = np.asarray([p[2] for p in picks], dtype=np.int64)
        rounded_offs, rounded_bcs, buf_offs = aligned_read_props(raw_offsets, raw_bcs)
        max_slot = int(rounded_bcs.max())
        # Allocate one contiguous GPU buffer for all batch reads
        raw_buf = cp.empty(batch_size * max_slot, dtype=cp.uint8)

        # Issue all preads
        futures = []
        for i, (handle, _, _, _, _) in enumerate(picks):
            slot_start = i * max_slot
            slot_len = int(rounded_bcs[i])
            slot_view = raw_buf[slot_start : slot_start + slot_len]
            fut = handle.pread(slot_view, file_offset=int(rounded_offs[i]))
            futures.append(fut)

        # Drain
        for f in futures:
            f.get()

        # Extract tile data from each slot into a contiguous [B, H, W, 3] tensor.
        # tile_bytes is uniform per backend instance; alignment offset varies per tile.
        out_hwc = torch.empty((batch_size, TILE_SIZE, TILE_SIZE, 3), dtype=torch.uint8, device=device)
        out_cp_flat = cp.from_dlpack(torch.utils.dlpack.to_dlpack(out_hwc)).reshape(batch_size, -1)
        for i in range(batch_size):
            start = i * max_slot + int(buf_offs[i])
            out_cp_flat[i, : self.tile_bytes] = raw_buf[start : start + self.tile_bytes]

        # NHWC uint8 -> NCHW float, normalized
        images = out_hwc.permute(0, 3, 1, 2).contiguous().to(torch.float32) / 255.0

        # Synthetic labels
        coords_arr = np.asarray([(p[3], p[4]) for p in picks], dtype=np.int64)
        labels_np = synthetic_labels(coords_arr).astype(np.int64)
        labels = torch.from_numpy(labels_np).to(device, non_blocking=True)

        return images, labels

    def close(self):
        for entry in self.cache.values():
            try:
                entry["handle"].close()
            except Exception:
                pass
        self.cache.clear()


# =============================================================================
# Backend 2: cuCIM CPU batched reader (Stage 4.B Tier 3 peak config)
# =============================================================================
class CuCIMBatchedCPUReader:
    """In-process cuCIM CPU batched reader. Stage 4.B Tier 3 peak config: nw=16, bs=64.

    cuCIM's batched API does its own num_workers internal C++ threading. We invoke
    it from the main DDP-rank process, get the batched output back as host-memory
    tile data, convert to numpy → torch → upload to GPU as one batch.

    NOTE: Stage 4.B Tier 3 measured nw=16, bs=64 as the peak config for cuCIM
    batched CPU. Our DDP-trainer batch size (e.g. 256) may exceed bs=64; we issue
    multiple internal cuCIM read_region calls per DDP step to assemble the full
    batch. This matches what a production DataLoader would do.
    """

    def __init__(self, svs_dir, coords_dir, slide_ids, lru_size, seed,
                 cucim_num_workers=16, cucim_batch_size=64,
                 patch_level=0, patch_size=TILE_SIZE):
        from cucim.clara import CuImage

        # cuCIM in-process cache for decoded tiles (per-process, 512 MB).
        CuImage.cache("per_process", memory_capacity=512)
        self._CuImage = CuImage

        self.svs_dir = Path(svs_dir)
        self.coord_pool = build_coord_pool(coords_dir, slide_ids)
        if not self.coord_pool:
            raise RuntimeError(f"empty coord pool for {coords_dir}")

        self.lru_size = lru_size
        self.rng = random.Random(seed)
        self.cucim_num_workers = cucim_num_workers
        self.cucim_batch_size = cucim_batch_size
        # 20×: read at (patch_level, patch_size); resize to 256 (CAM16 256 no-op;
        # BRCA 512px@40×→256). Coords are level-0 refs (location unchanged).
        self.patch_level = patch_level
        self.patch_size = patch_size
        self.cache = OrderedDict()  # slide_id -> CuImage

    def _find_slide(self, slide_id):
        for ext in (".svs", ".tif"):
            flat = self.svs_dir / f"{slide_id}{ext}"
            if flat.exists():
                return flat
        # Try subdir nesting (TCGA-BRCA uses per-slide subdirs)
        for sub in self.svs_dir.iterdir():
            if sub.is_dir():
                for ext in (".svs", ".tif"):
                    cand = sub / f"{slide_id}{ext}"
                    if cand.exists():
                        return cand
        return None

    def _get_slide(self, slide_id):
        if slide_id in self.cache:
            self.cache.move_to_end(slide_id)
            return self.cache[slide_id]
        if len(self.cache) >= self.lru_size:
            _, evicted = self.cache.popitem(last=False)
            try:
                evicted.close()
            except Exception:
                pass
        path = self._find_slide(slide_id)
        if path is None:
            return None
        try:
            slide = self._CuImage(str(path))
        except Exception:
            return None
        self.cache[slide_id] = slide
        return slide

    def fetch_batch(self, batch_size, device):
        """Assemble batch_size tiles via internal cuCIM batched calls of size cucim_batch_size each."""
        images_chunks = []
        coords_collected = []  # for synthetic labels

        remaining = batch_size
        while remaining > 0:
            sid, coords = self.rng.choice(self.coord_pool)
            slide = self._get_slide(sid)
            if slide is None:
                continue
            n = min(self.cucim_batch_size, remaining)
            if coords.shape[0] < n:
                picks = [int(self.rng.randint(0, coords.shape[0] - 1)) for _ in range(n)]
            else:
                picks = self.rng.sample(range(coords.shape[0]), n)
            # Sort within batch for cuCIM nvjpeg locality (Stage 4.B 6× discovery).
            picks.sort(key=lambda i: (int(coords[i, 1]) // TILE_SIZE, int(coords[i, 0]) // TILE_SIZE))
            locs = [(int(coords[i, 0]), int(coords[i, 1])) for i in picks]
            for x, y in locs:
                coords_collected.append((x, y))
            try:
                gen = slide.read_region(
                    locs, (self.patch_size, self.patch_size), level=self.patch_level,
                    batch_size=n, num_workers=self.cucim_num_workers,
                    prefetch_factor=2, device="cpu",
                )
                for batch in gen:
                    # batch is a CuImage holding the decoded tiles in CPU memory.
                    # Convert to numpy view; shape is (n, H, W, 3) for batched.
                    arr = np.asarray(batch)  # (n, 256, 256, 3) uint8
                    images_chunks.append(arr)
                    break  # one yield per batched call
            except Exception:
                # Skip this slide on read failure (rare)
                continue
            remaining -= n

        # Concatenate host-side
        host = np.concatenate(images_chunks, axis=0)[:batch_size]  # (B, ps, ps, 3) uint8
        # Upload to GPU + permute to NCHW float
        out_hwc = torch.from_numpy(host).to(device, non_blocking=True)
        out_nchw = out_hwc.permute(0, 3, 1, 2).contiguous().to(torch.float32)
        # 20×: resize patch_size→256 on GPU (area downsample 512→256 for BRCA;
        # no-op for CAM16's native 256). Matches the 6.A cuCIM path.
        if self.patch_size != TILE_SIZE:
            out_nchw = torch.nn.functional.interpolate(out_nchw, size=(TILE_SIZE, TILE_SIZE), mode="area")
        images = out_nchw / 255.0

        labels_np = synthetic_labels(np.asarray(coords_collected[:batch_size], dtype=np.int64)).astype(np.int64)
        labels = torch.from_numpy(labels_np).to(device, non_blocking=True)
        return images, labels

    def close(self):
        for s in self.cache.values():
            try:
                s.close()
            except Exception:
                pass
        self.cache.clear()


def read_coord_attrs(coords_dir):
    """Read the CLAM 20× tiling params from the first non-empty coord HDF5.
    Returns (patch_level, patch_size, footprint_level0); footprint_level0 =
    patch_size * level-0-downsample = coord spacing in level-0 (40×) px (512 at
    20×). CAM16 → (1, 256, 512); BRCA → (0, 512, 512). (Local copy — train is
    standalone; mirrors extract-features-foundation-stage6.read_coord_attrs.)"""
    import h5py
    for h5_path in sorted(Path(coords_dir).glob("*.h5")):
        with h5py.File(h5_path, "r") as f:
            a = f["coords"].attrs
            pl = int(a.get("patch_level", 0))
            ps = int(a.get("patch_size", TILE_SIZE))
            ds = a.get("downsample", [1.0, 1.0])
            ds0 = float(ds[0]) if hasattr(ds, "__len__") else float(ds)
        return pl, ps, int(round(ps * ds0))
    return 0, TILE_SIZE, TILE_SIZE


# =============================================================================
# Training loop
# =============================================================================
def make_reader(args, slide_ids, rank):
    patch_level, patch_size, footprint_level0 = read_coord_attrs(args.coords_dir)
    if args.backend == "kvikio":
        return KvikIOReader(
            rawtiff_dir=args.rawtiff_dir,
            coords_dir=args.coords_dir,
            slide_ids=slide_ids,
            lru_size=args.lru_size,
            seed=args.seed + rank,
            n_buffer=args.n_buffer,
            num_threads=args.num_threads,
            compat_mode=args.compat_mode,
            level=0,
            footprint_level0=footprint_level0,
        )
    elif args.backend == "cucim_batched_cpu":
        return CuCIMBatchedCPUReader(
            svs_dir=args.svs_dir,
            coords_dir=args.coords_dir,
            slide_ids=slide_ids,
            lru_size=args.lru_size,
            seed=args.seed + rank,
            cucim_num_workers=16,
            cucim_batch_size=64,
            patch_level=patch_level,
            patch_size=patch_size,
        )
    else:
        raise SystemExit(f"unknown --backend {args.backend!r}")


def worker(local_rank, world_size, args, master_port):
    """Per-rank training entry. Called once per DDP rank (rank=local_rank for single-host).

    NOTE: we bypass torchrun entirely. Its c10d rendezvous binds a TCP store to
    whatever socket.gethostname() resolves to; on a host where that name resolves
    via /etc/hosts to an address not bound to any local interface, the store fails
    with "No route to host". That depends on the machine's hostname and interface
    layout, so it must be assumed possible on any new instance rather than
    re-diagnosed. torch.multiprocessing.spawn + explicit MASTER_ADDR=127.0.0.1
    sidesteps the rendezvous machinery entirely for single-host DDP.
    """
    rank = local_rank
    os.environ["RANK"] = str(rank)
    os.environ["WORLD_SIZE"] = str(world_size)
    os.environ["LOCAL_RANK"] = str(local_rank)
    os.environ["MASTER_ADDR"] = "127.0.0.1"
    os.environ["MASTER_PORT"] = str(master_port)

    if world_size > 1:
        dist.init_process_group(backend="nccl", rank=rank, world_size=world_size,
                                init_method=f"tcp://127.0.0.1:{master_port}")
    torch.cuda.set_device(local_rank)
    device = torch.device(f"cuda:{local_rank}")

    # Standard PyTorch production optimizations. Without these the trainer runs
    # ~4-5× slower than cudnn-optimal, which understates the storage demand a
    # production WSI training pipeline would generate.
    #   - cudnn.benchmark: autotunes the convolution algorithm for our fixed
    #     (B=256, C=3, H=256, W=256) input shape after the first few steps.
    #   - channels_last: NHWC memory layout — required for the A100 to use
    #     Tensor Cores efficiently for FP16 conv. Standard in NVIDIA / MONAI
    #     reference WSI training pipelines.
    torch.backends.cudnn.benchmark = True

    if rank == 0:
        print(f"[trainer] backend={args.backend} world_size={world_size} batch_size={args.batch_size}", flush=True)
        print(f"[trainer] ramp={args.ramp}s steady={args.runtime}s lru={args.lru_size}", flush=True)
        if args.backend == "kvikio":
            print(f"[trainer] kvikIO n_buffer={args.n_buffer} num_threads={args.num_threads}", flush=True)
        print(f"[trainer] training-steps CSV → {args.training_steps_csv}", flush=True)

    # Build reader (per rank)
    slide_ids = load_manifest(args.manifest)
    reader = make_reader(args, slide_ids, rank)
    if rank == 0:
        print(f"[trainer] reader ready: {len(slide_ids)} slides in manifest, "
              f"{len(reader.coord_pool)} in pool", flush=True)

    # Build model
    model = resnet50(weights=None)
    # Replace 1000-class head with 2-class binary head (matches synthetic label).
    model.fc = nn.Linear(model.fc.in_features, 2)
    model = model.to(device, memory_format=torch.channels_last)
    if world_size > 1:
        model = DDP(model, device_ids=[local_rank], output_device=local_rank)

    optimizer = torch.optim.SGD(
        model.parameters(), lr=args.lr, momentum=args.momentum, weight_decay=args.weight_decay
    )
    scaler = GradScaler()
    criterion = nn.CrossEntropyLoss()

    # Per-step CSV (rank 0 only)
    csv_file = None
    csv_writer = None
    if rank == 0:
        Path(args.training_steps_csv).parent.mkdir(parents=True, exist_ok=True)
        csv_file = open(args.training_steps_csv, "w", newline="")
        csv_writer = csv.DictWriter(csv_file, fieldnames=[
            "step_idx", "phase", "t_step_start_s", "t_step_end_s",
            "step_duration_ms", "t_dataload_ms", "t_forward_ms",
            "t_backward_ms", "t_optimizer_ms",
            "samples_per_step_per_rank", "world_size", "loss",
        ])
        csv_writer.writeheader()

    # Training loop with explicit phase timing via torch.cuda.synchronize() + time.monotonic()
    t_zero = time.monotonic()
    t_ramp_end = t_zero + args.ramp
    t_end = t_zero + args.ramp + args.runtime

    step_idx = 0
    steady_samples = 0
    steady_loss_sum = 0.0
    steady_steps = 0

    if world_size > 1:
        # Make sure all ranks reach the loop together so the steady-state window
        # starts roughly at the same moment across ranks.
        dist.barrier()
        t_zero = time.monotonic()
        t_ramp_end = t_zero + args.ramp
        t_end = t_zero + args.ramp + args.runtime

    # Pre-allocate CUDA events for per-phase timing. CUDA events record stream
    # time without forcing host-side synchronization between phases, so the
    # GPU can keep its kernel queue full (no per-phase serialization overhead).
    # We sync once at end of step to flush events for reading.
    ev_start = torch.cuda.Event(enable_timing=True)
    ev_after_dataload = torch.cuda.Event(enable_timing=True)
    ev_after_forward = torch.cuda.Event(enable_timing=True)
    ev_after_backward = torch.cuda.Event(enable_timing=True)
    ev_after_optimizer = torch.cuda.Event(enable_timing=True)

    while True:
        t_step_start = time.monotonic()
        if t_step_start >= t_end:
            break
        phase = "ramp" if t_step_start < t_ramp_end else "steady"

        ev_start.record()

        # 1. Data load (kvikIO+GDS or cuCIM batched CPU). Returns NCHW float on GPU.
        # Convert to channels_last in-place for the model's expected layout.
        images, labels = reader.fetch_batch(args.batch_size, device)
        images = images.to(memory_format=torch.channels_last)
        ev_after_dataload.record()

        # 2. Forward (AMP FP16 autocast)
        optimizer.zero_grad(set_to_none=True)
        with autocast(dtype=torch.float16):
            logits = model(images)
            loss = criterion(logits, labels)
        ev_after_forward.record()

        # 3. Backward (DDP AllReduce hides inside .backward() for world_size > 1)
        scaler.scale(loss).backward()
        ev_after_backward.record()

        # 4. Optimizer step
        scaler.step(optimizer)
        scaler.update()
        ev_after_optimizer.record()

        # Single end-of-step sync to flush events. This also gives us an accurate
        # wallclock step_duration. The end-of-step sync is implicit anyway via
        # loss.item() below, but explicit makes the timing intent clear.
        torch.cuda.synchronize(device)
        t_step_end = time.monotonic()

        # Read per-phase GPU stream time from CUDA events (in ms)
        dl_ms = ev_start.elapsed_time(ev_after_dataload)
        fw_ms = ev_after_dataload.elapsed_time(ev_after_forward)
        bw_ms = ev_after_forward.elapsed_time(ev_after_backward)
        opt_ms = ev_after_backward.elapsed_time(ev_after_optimizer)

        if rank == 0:
            csv_writer.writerow({
                "step_idx": step_idx,
                "phase": phase,
                "t_step_start_s": f"{t_step_start - t_zero:.6f}",
                "t_step_end_s": f"{t_step_end - t_zero:.6f}",
                "step_duration_ms": f"{(t_step_end - t_step_start) * 1000:.3f}",
                "t_dataload_ms": f"{dl_ms:.3f}",
                "t_forward_ms": f"{fw_ms:.3f}",
                "t_backward_ms": f"{bw_ms:.3f}",
                "t_optimizer_ms": f"{opt_ms:.3f}",
                "samples_per_step_per_rank": args.batch_size,
                "world_size": world_size,
                "loss": f"{loss.item():.6f}",
            })
            # Periodic flush so a watcher can tail the CSV.
            if step_idx % 50 == 0:
                csv_file.flush()
                print(f"[trainer] step={step_idx} phase={phase} "
                      f"step_ms={(t_step_end - t_step_start)*1000:.1f} "
                      f"dl_ms={dl_ms:.1f} fw_ms={fw_ms:.1f} "
                      f"bw_ms={bw_ms:.1f} opt_ms={opt_ms:.1f} "
                      f"loss={loss.item():.4f}", flush=True)

        if phase == "steady":
            steady_samples += args.batch_size  # per-rank
            steady_loss_sum += loss.item()
            steady_steps += 1

        step_idx += 1

    # Cleanup
    reader.close()
    if rank == 0:
        csv_file.flush()
        csv_file.close()

    # Aggregate samples/sec across ranks
    if world_size > 1:
        local = torch.tensor([float(steady_samples), float(steady_steps)], device=device)
        dist.all_reduce(local, op=dist.ReduceOp.SUM)
        global_samples = float(local[0].item())
        global_steps = float(local[1].item())  # sum of per-rank step counts (each rank ran ~same #steps)
    else:
        global_samples = float(steady_samples)
        global_steps = float(steady_steps)

    steady_window_s = float(args.runtime)
    # The cross-rank step counts are roughly equal (DDP barriers on each backward),
    # so "global_steps / world_size" approximates the per-rank step count.
    per_rank_steps = global_steps / max(world_size, 1)
    samples_per_sec_aggregate = global_samples / steady_window_s

    if rank == 0:
        summary = {
            "backend": args.backend,
            "world_size": world_size,
            "batch_size_per_rank": args.batch_size,
            "effective_batch_size": args.batch_size * world_size,
            "ramp_s": args.ramp,
            "runtime_s": args.runtime,
            "steady_steps_total_across_ranks": global_steps,
            "steady_steps_per_rank": per_rank_steps,
            "steady_samples_total": global_samples,
            "samples_per_sec_aggregate": samples_per_sec_aggregate,
            "samples_per_sec_per_rank": samples_per_sec_aggregate / max(world_size, 1),
            "training_steps_csv": args.training_steps_csv,
        }
        print(f"=== summary ===", flush=True)
        print(json.dumps(summary, indent=2), flush=True)
        if args.summary_json:
            with open(args.summary_json, "w") as f:
                json.dump(summary, f, indent=2)

    if world_size > 1:
        dist.destroy_process_group()


def _pick_free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", choices=["kvikio", "cucim_batched_cpu"], required=True)
    ap.add_argument("--world-size", type=int, default=1,
                    help="Number of DDP ranks (= GPUs). Trainer launches itself via "
                         "torch.multiprocessing.spawn — no torchrun needed.")
    ap.add_argument("--rawtiff-dir", default=FS_MOUNT + "/data/tcga-brca-rawtiff")
    ap.add_argument("--svs-dir", default=FS_MOUNT + "/data/tcga-brca")
    ap.add_argument("--coords-dir", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--batch-size", type=int, default=256, help="Per-rank batch size")
    ap.add_argument("--ramp", type=int, default=300, help="Seconds of ramp before counting steady-state")
    ap.add_argument("--runtime", type=int, default=1200, help="Seconds of steady-state runtime")
    ap.add_argument("--training-steps-csv", required=True, help="Output per-step CSV (rank 0 only writes)")
    ap.add_argument("--summary-json", help="Optional aggregate summary JSON path")
    ap.add_argument("--lru-size", type=int, default=64)
    ap.add_argument("--n-buffer", type=int, default=256, help="kvikIO async pread pipelining depth")
    ap.add_argument("--num-threads", type=int, default=16, help="kvikIO internal thread pool size")
    ap.add_argument("--compat-mode", choices=["off", "on", "auto"], default="off",
                    help="kvikIO compat_mode for the kvikio backend: off (GDS), on (POSIX bounce), "
                         "auto (kvikIO decides). Default 'off' is what 5.A's cells run in; the "
                         "mode-controlled paired cell (STAGES.md) is requested by passing this "
                         "explicitly. REQUESTED, not proven — the per-cell cuFile path accounting "
                         "settles which path actually ran.")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--lr", type=float, default=0.01)
    ap.add_argument("--momentum", type=float, default=0.9)
    ap.add_argument("--weight-decay", type=float, default=1e-4)
    args = ap.parse_args()

    world_size = args.world_size
    if world_size <= 0:
        raise SystemExit("--world-size must be >= 1")

    master_port = _pick_free_port()
    print(f"[trainer] launching world_size={world_size} master_port={master_port} "
          f"CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>')}",
          flush=True)

    if world_size == 1:
        worker(0, 1, args, master_port)
    else:
        import torch.multiprocessing as mp
        # 'spawn' (not 'fork') is required for CUDA: forked processes inherit
        # a CUDA context from the parent which causes init failures on the
        # second-and-later workers. spawn starts fresh Python interpreters.
        mp.spawn(worker, args=(world_size, args, master_port), nprocs=world_size, join=True)


if __name__ == "__main__":
    main()
