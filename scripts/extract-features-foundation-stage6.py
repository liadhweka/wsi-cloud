#!/usr/bin/env python3
"""extract-features-foundation-stage6.py — Stage 6.A foundation-model frozen-eval feature extractor.

For each slide in the dataset, extract ALL tissue-tile feature embeddings via a frozen
foundation-model ViT (UNI2-h / Virchow2 / GigaPath) and write a per-slide `.pt` file to
the filesystem under test. This is the 2024–2026 production WSI research workload — feed every tile in
every slide through a frozen foundation model once.

Pluggable along two axes (mirrors Stage 5's design):
  --backend kvikio              : kvikIO+GDS+raw-TIFF (Stage 4.C / 5.A winner, GPU-direct)
  --backend cucim_batched_cpu   : cuCIM CPU batched API (Stage 4.B Tier 3 peak: nw=16, bs=64)

  --model virchow2              : Paige Virchow2 (ViT-H/14, 1280-dim, Apache 2.0)
  --model gigapath              : MSR GigaPath tile encoder (ViT-G/14, 1536-dim, Apache 2.0)
  --model uni2-h                : Mahmood Lab UNI2-h (ViT-H/14, 1536-dim, CC-BY-NC-ND 4.0)
                                  Internal use unrestricted; cells are tagged PENDING-APPROVAL
                                  and stay internal-only until approval (see Stage 6 roadmap).

DESIGN
======
Single in-process reader per DDP rank (NOT PyTorch DataLoader workers). Each rank
processes a disjoint slide subset (modulo partition by rank). Each rank iterates its
slides in order; for each slide, it iterates the slide's tiles in CLAM coord order
batch-by-batch, runs the frozen ViT, accumulates per-tile embeddings, and writes the
per-slide `.pt` file when the slide's tiles are exhausted.

WHY single in-process reader per rank
  Same rationale as Stage 5: kvikIO+GDS's internal n_buffer=256 async pread already
  provides the parallelism; cuCIM batched CPU has its own num_workers=16 C++ threads.
  Forking PyTorch DataLoader workers would force `spawn` start method + split CuFile
  handles. Reusing Stage 4.C/4.B reader logic directly minimizes engineering risk.

WHY mp.spawn (not torchrun)
  torchrun's c10d rendezvous binds its TCP store to whatever socket.gethostname()
  resolves to. Where that resolves via /etc/hosts to an address not bound to any local
  interface, the store fails with "No route to host" — a machine-dependent failure, so
  assume it is possible on any new instance. mp.spawn + explicit MASTER_ADDR=127.0.0.1
  sidesteps the entire rendezvous machinery for single-host DDP.

WHY torch.cuda.synchronize() + CUDA events per step
  Per-step timing must be accurate: the per-extraction-step CSV is this stage's PRIMARY
  headline source, so a timing artifact there propagates into the comparison.
  CUDA events record per-phase stream time without forcing host syncs between phases;
  a single sync at end of step flushes events for reading.

WHY 4096-byte aligned reads (kvikIO backend only)
  cuFile silently falls back to a broken POSIX path on unaligned offsets — surfaces
  as "Operation not permitted" at the Python layer. NVIDIA's reference handles this
  via `aligned_read_props()` (verbatim from cucim's gds_whole_slide example).

WHY per-cell LD_PRELOAD scoping (mentioned for caller; this script doesn't set it)
  Per `docs/RUNBOOK.md` (mixed-backend sweeps): kvikIO+GDS cells must run under
  LD_PRELOAD of the system libcufile ($LIBCUFILE_PRELOAD, matched to the loaded
  nvidia-fs module), but cuCIM has segfaulted inside `slide.read_region()` under a
  mismatched preload (ABI clash). Sweep driver must set LD_PRELOAD per-cell
  (kvikio cells = set; cucim cells = unset).

Per-extraction-step CSV columns (rank 0 only writes):
  step_idx, phase, t_step_start_s, t_step_end_s, step_duration_ms,
  t_dataload_ms, t_forward_ms, samples_per_step, slide_id_in_step

Per-slide CSV columns (each rank appends; main-process post-merge sorts):
  slide_id, rank_handled, world_size, n_tiles, t_start_s, t_end_s,
  wallclock_s, tiles_per_sec_slide, embedding_dim

Usage (launched by sweep driver per cell):
  python extract-features-foundation-stage6.py \\
    --backend kvikio --world-size 4 --model virchow2 \\
    --rawtiff-dir $FS_MOUNT/data/tcga-brca-rawtiff \\
    --coords-dir $FS_MOUNT/tissue-detection/3.0/tcga-brca/n64/patches \\
    --manifest scripts/manifests/tcga-brca-stage4a-subset.tsv \\
    --output-dir $FS_MOUNT/features/6.A/virchow2/tcga-brca-subset \\
    --batch-size 256 \\
    --extraction-steps-csv <run-dir>/extraction-steps.csv \\
    --per-slide-csv <run-dir>/per-slide.csv \\
    --summary-json <run-dir>/extraction-summary.json
"""
import argparse
import csv
import json
import os
import socket
import sys
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple

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
import torch.multiprocessing as mp
from torch.cuda.amp import autocast


TILE_SIZE = 256       # CLAM coord tile size, matches Stage 4/5 convention
INPUT_SIZE = 224      # All three foundation models are 224x224 input
ALIGNMENT = 4096      # cuFile alignment requirement


# =============================================================================
# Model registry
# =============================================================================
@dataclass
class ModelSpec:
    """Per-foundation-model loading + preprocessing metadata.

    Each foundation model has its own quirks in the timm.create_model() call:
      - Virchow2 needs SwiGLU MLP layer + SiLU activation (per Paige's model card).
      - UNI2-h needs LayerScale init_values + dynamic_img_size (per Mahmood Lab).
      - GigaPath tile encoder is standard ViT-G/14, no extras.
    The extra_create_kwargs field captures these; the loader function resolves them.
    """
    hub_id: str
    embed_dim: int
    extra_create_kwargs: dict = field(default_factory=dict)
    # Some models need string-to-class resolution at load time (e.g. 'SwiGLUPacked'
    # → timm.layers.SwiGLUPacked). The loader handles these via a resolution table.
    needs_swiglu: bool = False


MODEL_REGISTRY: Dict[str, ModelSpec] = {
    'virchow2': ModelSpec(
        hub_id='paige-ai/Virchow2',
        embed_dim=1280,
        extra_create_kwargs={},  # mlp/act layers resolved via needs_swiglu flag
        needs_swiglu=True,
    ),
    'gigapath': ModelSpec(
        hub_id='prov-gigapath/prov-gigapath',
        embed_dim=1536,
        extra_create_kwargs={},
        needs_swiglu=False,
    ),
    'uni2-h': ModelSpec(
        hub_id='MahmoodLab/UNI2-h',
        embed_dim=1536,
        # Per the UNI2-h HF model card canonical loader
        # (https://huggingface.co/MahmoodLab/UNI2-h):
        # UNI2-h is a customized vit_giant_patch14_224 with embed_dim=1536,
        # depth=24, num_heads=24, 8 register tokens, no class token in posemb,
        # SwiGLU MLP + SiLU act. All these kwargs must be passed explicitly —
        # timm's hf-hub auto-load otherwise picks ViT-G's defaults and the
        # checkpoint posemb resample fails ([1, 15, 15, -1] vs 391680 actual).
        # needs_swiglu=True triggers mlp_layer=SwiGLUPacked + act_layer=SiLU
        # via the same hook Virchow2 uses.
        extra_create_kwargs={
            'img_size': 224,
            'patch_size': 14,
            'depth': 24,
            'num_heads': 24,
            'init_values': 1e-5,
            'embed_dim': 1536,
            'mlp_ratio': 2.66667 * 2,
            'num_classes': 0,
            'no_embed_class': True,
            'reg_tokens': 8,
            'dynamic_img_size': True,
        },
        needs_swiglu=True,
    ),
}


def load_foundation_model(model_name: str, device: torch.device):
    """Load a frozen foundation model + return (model_eval, data_config, embed_dim).

    The data_config dict (from timm.data.resolve_data_config) carries the model's
    own normalization mean/std/input_size — we use those rather than hardcoding,
    so each model's preprocess matches its training distribution exactly.
    """
    import timm
    if model_name not in MODEL_REGISTRY:
        raise ValueError(f"unknown --model {model_name!r}; known: {list(MODEL_REGISTRY)}")
    spec = MODEL_REGISTRY[model_name]

    kwargs = dict(spec.extra_create_kwargs)
    if spec.needs_swiglu:
        from timm.layers import SwiGLUPacked
        kwargs['mlp_layer'] = SwiGLUPacked
        kwargs['act_layer'] = torch.nn.SiLU

    print(f"[model] loading hf-hub:{spec.hub_id} via timm (kwargs={list(kwargs.keys())})", file=sys.stderr, flush=True)
    model = timm.create_model(f"hf-hub:{spec.hub_id}", pretrained=True, **kwargs)
    model.eval()
    # Foundation-model output is the last-hidden-state pooled embedding. timm's ViT
    # forward returns the pooled token by default for classification heads; we use
    # forward_features then pool, OR rely on the model's built-in `forward(x)` returning
    # the pooled embed when num_classes=0. Most foundation-model checkpoints on HF
    # already set num_classes=0 so model(x) returns [B, embed_dim] directly.
    # We don't strip the head here; we rely on the model card's published loading
    # pattern producing the pooled embedding output via model(x).

    # Resolve data config: input_size, normalization mean/std, interpolation
    data_cfg = timm.data.resolve_data_config({}, model=model)
    print(f"[model] resolved data_cfg: input_size={data_cfg.get('input_size')} "
          f"mean={data_cfg.get('mean')} std={data_cfg.get('std')}", file=sys.stderr, flush=True)

    model = model.to(device, memory_format=torch.channels_last)
    return model, data_cfg, spec.embed_dim


# =============================================================================
# NVIDIA aligned-read helper (verbatim from cucim/examples/python/gds_whole_slide/)
# WHY: cuFile requires 4096-byte aligned offsets and sizes.
# =============================================================================
def aligned_read_props(offsets, bytecounts, alignment=ALIGNMENT):
    offsets = np.asarray(offsets, dtype=np.int64)
    bytecounts = np.asarray(bytecounts, dtype=np.int64)
    rounded_offsets = (offsets // alignment) * alignment
    buffer_offsets = offsets - rounded_offsets
    rounded_bytecounts = buffer_offsets + bytecounts
    rounded_bytecounts = np.ceil(rounded_bytecounts / alignment).astype(np.int64) * alignment
    return rounded_offsets, rounded_bytecounts, buffer_offsets


# =============================================================================
# Manifest + coord pool helpers
# =============================================================================
def load_manifest(path: str) -> List[str]:
    """Stage 4.A subset format: 4 header lines + 'slide_id' header + slide IDs."""
    out = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#") or ln == "slide_id":
                continue
            out.append(ln)
    return out


def load_slide_coords(coords_dir: str, slide_id: str) -> Optional[np.ndarray]:
    """Returns the CLAM coord array for one slide, or None if missing/empty."""
    h5_path = Path(coords_dir) / f"{slide_id}.h5"
    if not h5_path.exists():
        return None
    with h5py.File(h5_path, "r") as f:
        coords = f["coords"][()]
    if coords.shape[0] == 0:
        return None
    return coords


def partition_slides_by_rank(slide_ids: List[str], rank: int, world_size: int) -> List[str]:
    """Modulo partition: rank i handles slides where idx % world_size == i.

    WHY modulo (not greedy size-aware): slide sizes vary 5–50× across the BRCA
    pool. Modulo gives statistically balanced load if slides are unsorted; greedy
    by size would give better worst-case balance but adds coordination complexity.
    For Stage 6.A we accept the modulo balance — cell-level wallclock is dominated
    by the slowest rank's slide list, which is acceptable for a single-pass workload.
    """
    return [s for i, s in enumerate(slide_ids) if (i % world_size) == rank]


# =============================================================================
# Tile preprocessing — 256 → 224 center crop + per-model normalize
# =============================================================================
def make_preprocess_fn(data_cfg: dict, device: torch.device):
    """Returns a function (tile_hwc_uint8 [B,256,256,3] on GPU) → (nchw_cl_float [B,3,224,224] channels_last).

    Per-model normalization comes from data_cfg (timm's resolved metadata for that model).
    Center-crop 256→224 is a fixed-offset slice on H,W (16:240).

    WHY do this on GPU (not host): each crop+normalize on host then upload would
    triple the host-→-GPU traffic. With kvikIO+GDS the tiles arrive on GPU; with
    cuCIM CPU batched they arrive on host but we upload as uint8 then crop+normalize
    on GPU. Either way, normalization stays on GPU.
    """
    mean = torch.tensor(data_cfg.get('mean', (0.485, 0.456, 0.406)), device=device,
                        dtype=torch.float32).view(1, 1, 1, 3)
    std = torch.tensor(data_cfg.get('std', (0.229, 0.224, 0.225)), device=device,
                       dtype=torch.float32).view(1, 1, 1, 3)
    # Center-crop offset: (TILE_SIZE - INPUT_SIZE) // 2 = (256 - 224) // 2 = 16
    crop_off = (TILE_SIZE - INPUT_SIZE) // 2

    def preprocess(tile_hwc_uint8: torch.Tensor) -> torch.Tensor:
        # tile_hwc_uint8: [B, 256, 256, 3] uint8 on GPU
        cropped = tile_hwc_uint8[:, crop_off:crop_off + INPUT_SIZE,
                                 crop_off:crop_off + INPUT_SIZE, :]
        # to float32, /255, normalize (broadcasts across the channel dim, NHWC)
        f = cropped.to(torch.float32) * (1.0 / 255.0)
        normalized = (f - mean) / std
        # NHWC view → NCHW via permute (no .contiguous needed; the NHWC strides
        # ARE the channels_last memory format for an NCHW shape).
        nchw_cl = normalized.permute(0, 3, 1, 2)
        return nchw_cl

    return preprocess


# =============================================================================
# Backend 1: kvikIO + GDS + raw-TIFF — single-slide iterator
# =============================================================================
class KvikIOSlideReader:
    """Reads ALL tiles of one slide in CLAM-coord order via kvikIO+GDS+raw-TIFF.

    Iterator yields successive batches of `batch_size` tiles as uint8 NHWC tensors
    on the GPU. Last batch may be smaller. Loops through all coords once, in order.

    For Stage 6 the goal is full-pass through the slide — we don't randomize. The
    reader holds an open kvikIO.CuFile handle per slide; caller closes via close().
    """
    def __init__(self, rawtiff_dir: str, n_buffer: int, num_threads: int,
                 compat_mode: str = "off", level: int = 0,
                 footprint_level0: int = TILE_SIZE):
        import kvikio
        import kvikio.defaults
        from cucim.clara import filesystem as cucim_fs
        from tifffile import TiffFile

        # Configure kvikIO defaults (Stage 4.C/5 pattern)
        mode_map = {"off": kvikio.CompatMode.OFF, "on": kvikio.CompatMode.ON,
                    "auto": kvikio.CompatMode.AUTO}
        if compat_mode not in mode_map:
            raise ValueError(f"compat_mode must be off|on|auto, got {compat_mode!r}")
        kvikio.defaults.set("compat_mode", mode_map[compat_mode])
        kvikio.defaults.set("num_threads", int(num_threads))

        self._kvikio = kvikio
        self._cucim_fs = cucim_fs
        self._TiffFile = TiffFile

        self.rawtiff_dir = Path(rawtiff_dir)
        self.n_buffer = n_buffer
        self.level = level
        # 20×: CLAM coords are level-0 (40×) px stepping by footprint_level0 (512);
        # the raw-TIFF is pre-materialized at 20×/256px tiles (Option B), so
        # coord→tile maps as coord // footprint_level0 (NOT // raw tile_width=256).
        self.footprint_level0 = footprint_level0

        # Pre-allocate one set of contiguous GPU buffers per batch. We allocate to
        # the worst-case aligned tile size: tile_bytes + ALIGNMENT.
        self.tile_bytes = TILE_SIZE * TILE_SIZE * 3
        self.slot_bytes = int(np.ceil((self.tile_bytes + ALIGNMENT) / ALIGNMENT) * ALIGNMENT)

        # Cold-cache accounting, surfaced in the cell summary. The discard below
        # is unconditional on this backend, so without a tally there is nothing
        # separating a cell that dropped every slide's cache from one where the
        # drop never worked — and both look identical in the results.
        self.n_discard_attempted = 0
        self.n_discard_failed = 0

    def open_slide(self, slide_id: str):
        """Returns (handle, idx_meta) for the slide, or (None, None) if missing."""
        path = self.rawtiff_dir / f"{slide_id}.tiff"
        if not path.exists():
            return None, None
        # Cold-cache discipline (matches Stage 4.C random reader). RECORDED, not
        # assumed: cuCIM signals a failed discard by RETURNING False rather than
        # raising (docs.rapids.ai/api/cucim/stable/api/ — "Returns: True if
        # succeed, False otherwise"), so a bare `except: pass` and an ignored
        # return value fail the same way — the slide is read WARM inside a cell
        # that claims cold, which is the cache state asserted-rather-than-recorded
        # that thesis §11.5 lists as invalidating.
        self.n_discard_attempted += 1
        try:
            discarded = bool(self._cucim_fs.discard_page_cache(str(path)))
        except Exception as e:                  # noqa: BLE001 - report, never mask
            print(f"[extractor] discard_page_cache({path}) raised: {e}",
                  file=sys.stderr, flush=True)
            discarded = False
        if not discarded:
            self.n_discard_failed += 1
            print(f"[extractor] DISCARD-FAILED: {path.name} — read WARM, not cold",
                  file=sys.stderr, flush=True)
        with self._TiffFile(str(path)) as tif:
            if self.level >= len(tif.pages):
                return None, None
            page = tif.pages[self.level]
            idx_meta = {
                "shape": page.shape,
                "tile_height": page.tilelength,
                "tile_width": page.tilewidth,
                "n_tiles_per_row": (page.shape[1] + page.tilewidth - 1) // page.tilewidth,
                "offsets": np.asarray(page.dataoffsets, dtype=np.int64),
                "bytecounts": np.asarray(page.databytecounts, dtype=np.int64),
            }
        handle = self._kvikio.CuFile(str(path), "r")
        return handle, idx_meta

    def pixel_to_tile_index(self, x_pixel: int, y_pixel: int, idx_meta: dict) -> int:
        # 20×: divide level-0 (40×) coords by the level-0 footprint (512), not the
        # raw-TIFF tile_width (256) — the raw-TIFF is 20×/256-tiled (Option B).
        tc = int(x_pixel) // self.footprint_level0
        tr = int(y_pixel) // self.footprint_level0
        # Clamp
        tc = max(0, min(tc, idx_meta["n_tiles_per_row"] - 1))
        n_rows = idx_meta["offsets"].size // idx_meta["n_tiles_per_row"]
        tr = max(0, min(tr, n_rows - 1))
        return tr * idx_meta["n_tiles_per_row"] + tc

    def iter_tile_batches(self, handle, idx_meta: dict, coords: np.ndarray,
                          batch_size: int, device: torch.device):
        """Yields successive (tile_hwc_uint8 [B,256,256,3] on GPU, n_tiles_in_batch).

        Iterates `coords` in given order, batching by `batch_size`. Performs aligned
        kvikIO async preads; drains them per batch.
        """
        n_total = coords.shape[0]
        # Pre-compute aligned offsets for all coords once (avoids per-batch numpy ops)
        all_tile_idxs = []
        for i in range(n_total):
            ti = self.pixel_to_tile_index(int(coords[i, 0]), int(coords[i, 1]), idx_meta)
            all_tile_idxs.append(ti)
        all_tile_idxs_np = np.asarray(all_tile_idxs, dtype=np.int64)
        all_offsets = idx_meta["offsets"][all_tile_idxs_np]
        all_bcs = idx_meta["bytecounts"][all_tile_idxs_np]
        rounded_offs, rounded_bcs, buf_offs = aligned_read_props(all_offsets, all_bcs)

        n_batches = (n_total + batch_size - 1) // batch_size
        for b_idx in range(n_batches):
            lo = b_idx * batch_size
            hi = min(lo + batch_size, n_total)
            B = hi - lo

            # Per-batch slice of pre-computed aligned offsets
            r_offs = rounded_offs[lo:hi]
            r_bcs = rounded_bcs[lo:hi]
            b_offs = buf_offs[lo:hi]
            max_slot = int(r_bcs.max())

            # Allocate batch buffer: one contiguous GPU region for all B tiles
            raw_buf = cp.empty(B * max_slot, dtype=cp.uint8)

            # Issue all preads
            futures = []
            for i in range(B):
                slot_start = i * max_slot
                slot_len = int(r_bcs[i])
                slot = raw_buf[slot_start: slot_start + slot_len]
                fut = handle.pread(slot, file_offset=int(r_offs[i]))
                futures.append(fut)

            # Drain
            for f in futures:
                f.get()

            # Extract tile data into a tight NHWC tensor on GPU (uint8)
            out_hwc = torch.empty((B, TILE_SIZE, TILE_SIZE, 3), dtype=torch.uint8, device=device)
            out_cp_flat = cp.from_dlpack(torch.utils.dlpack.to_dlpack(out_hwc)).reshape(B, -1)
            for i in range(B):
                start = i * max_slot + int(b_offs[i])
                out_cp_flat[i, : self.tile_bytes] = raw_buf[start: start + self.tile_bytes]

            yield out_hwc, B


# =============================================================================
# Backend 2: cuCIM CPU batched — single-slide iterator
# =============================================================================
class CuCIMSlideReader:
    """Reads ALL tiles of one slide in CLAM-coord order via cuCIM CPU batched API.

    Internal cuCIM threading: nw=16 num_workers, bs=64 cucim batch size (Stage 4.B
    Tier 3 peak config). Yields tiles in 64-tile sub-batches; caller assembles
    into the DDP-trainer batch_size by concatenating sub-batches.
    """
    def __init__(self, svs_dir: str, cucim_num_workers: int = 16,
                 cucim_batch_size: int = 64, patch_level: int = 0,
                 patch_size: int = TILE_SIZE):
        from cucim.clara import CuImage
        CuImage.cache("per_process", memory_capacity=512)
        self._CuImage = CuImage
        self.svs_dir = Path(svs_dir)
        self.cucim_num_workers = cucim_num_workers
        self.cucim_batch_size = cucim_batch_size
        # 20×: read at the CLAM coord's (patch_level, patch_size), then resize to
        # TILE_SIZE (256). CAM16 native level 1 (256, no-op); BRCA 512px@40×→256.
        self.patch_level = patch_level
        self.patch_size = patch_size

    def _find_slide(self, slide_id: str) -> Optional[Path]:
        for ext in (".svs", ".tif"):
            flat = self.svs_dir / f"{slide_id}{ext}"
            if flat.exists():
                return flat
        for sub in self.svs_dir.iterdir():
            if sub.is_dir():
                for ext in (".svs", ".tif"):
                    cand = sub / f"{slide_id}{ext}"
                    if cand.exists():
                        return cand
        return None

    def open_slide(self, slide_id: str):
        path = self._find_slide(slide_id)
        if path is None:
            return None
        try:
            return self._CuImage(str(path))
        except Exception:
            return None

    def iter_tile_batches(self, slide_handle, coords: np.ndarray,
                          batch_size: int, device: torch.device):
        """Yields successive (tile_hwc_uint8 [B,256,256,3] on GPU, n_tiles_in_batch).

        Internally calls cuCIM batched read with bs=cucim_batch_size, accumulates
        until batch_size is reached, uploads to GPU, yields.
        """
        n_total = coords.shape[0]
        # Sort coords within the slide for cuCIM nvjpeg-locality (Stage 4.B 6× discovery
        # for random reads — for sequential extraction in CLAM order this is already
        # locality-friendly, but we re-sort defensively).
        # Actually for extraction we want to preserve coord order so the output .pt's
        # row order matches the original coords. Don't sort.

        buffered_chunks: List[np.ndarray] = []
        buffered_count = 0

        cursor = 0
        while cursor < n_total:
            n_take = min(self.cucim_batch_size, n_total - cursor)
            locs = [(int(coords[cursor + i, 0]), int(coords[cursor + i, 1]))
                    for i in range(n_take)]
            try:
                gen = slide_handle.read_region(
                    locs, (self.patch_size, self.patch_size), level=self.patch_level,
                    batch_size=n_take, num_workers=self.cucim_num_workers,
                    prefetch_factor=2, device='cpu',
                )
                for batch in gen:
                    arr = np.asarray(batch)  # expect (n_take, 256, 256, 3) uint8 on host
                    # Defensive: cuCIM batched read_region collapses the leading
                    # batch dim when n_take==1 (returns (H,W,C) instead of
                    # (1,H,W,C)) — otherwise a mixed-ndim np.concatenate crash
                    # at the slide-tail edge. Normalize to 4D unconditionally.
                    if arr.ndim == 3:
                        arr = arr[None, ...]
                    buffered_chunks.append(arr)
                    buffered_count += n_take
                    break  # one yield per batched call
            except Exception as e:
                print(f"[cucim] read_region failed at cursor {cursor}: {e}",
                      file=sys.stderr, flush=True)
                # Skip this sub-batch
                cursor += n_take
                continue
            cursor += n_take

            # Yield whenever we've accumulated >= batch_size or hit the end
            if buffered_count >= batch_size or cursor >= n_total:
                host = np.concatenate(buffered_chunks, axis=0)
                if host.shape[0] > batch_size:
                    # split: yield batch_size, hold the remainder
                    remainder = host[batch_size:]
                    host = host[:batch_size]
                    buffered_chunks = [remainder]
                    buffered_count = remainder.shape[0]
                else:
                    buffered_chunks = []
                    buffered_count = 0
                out_hwc = torch.from_numpy(host).to(device, non_blocking=True)
                # 20×: tiles were read at patch_size; resize to 256px@20× on GPU
                # (area downsample 512→256 for BRCA; no-op for CAM16's native 256).
                if self.patch_size != TILE_SIZE:
                    t = out_hwc.permute(0, 3, 1, 2).float()
                    t = torch.nn.functional.interpolate(t, size=(TILE_SIZE, TILE_SIZE), mode="area")
                    out_hwc = t.round().clamp_(0, 255).to(torch.uint8).permute(0, 2, 3, 1).contiguous()
                yield out_hwc, host.shape[0]


def read_coord_attrs(coords_dir):
    """Read the CLAM 20× tiling params from the first non-empty coord HDF5.

    Uniform per dataset (cells are single-dataset). Returns
    (patch_level, patch_size, footprint_level0), where footprint_level0 =
    patch_size * level-0-downsample = the coord spacing in level-0 (40×) px
    (512 for both datasets at 20×). 20× contract: CAM16 → (1, 256, 512);
    BRCA → (0, 512, 512). footprint_level0 is the coord→tile divisor for the
    kvikIO raw-TIFF path; (patch_level, patch_size) drive the cuCIM SVS read.
    """
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
# Per-rank worker
# =============================================================================
def worker(local_rank: int, world_size: int, args, master_port: int):
    rank = local_rank
    os.environ["RANK"] = str(rank)
    os.environ["WORLD_SIZE"] = str(world_size)
    os.environ["LOCAL_RANK"] = str(local_rank)
    os.environ["MASTER_ADDR"] = "127.0.0.1"
    os.environ["MASTER_PORT"] = str(master_port)

    if world_size > 1:
        # NCCL default timeout is 10 min. End-of-extraction AllReduce (3-float
        # SUM, line ~787) is the only NCCL collective after the start barrier;
        # ranks reach it at different wallclocks because slide-tile-count
        # variance is high (CAM16 especially: tumor_NNN small, normal_NNN full).
        # 10 min isn't enough for a 30-min cell with one slow rank. Bump to 1 hr.
        dist.init_process_group(backend="nccl", rank=rank, world_size=world_size,
                                init_method=f"tcp://127.0.0.1:{master_port}",
                                timeout=timedelta(hours=1))
    torch.cuda.set_device(local_rank)
    device = torch.device(f"cuda:{local_rank}")
    torch.backends.cudnn.benchmark = True  # ResNet/ViT both benefit; same as Stage 5

    if rank == 0:
        print(f"[extractor] backend={args.backend} model={args.model} "
              f"world_size={world_size} batch_size={args.batch_size}", flush=True)
        print(f"[extractor] manifest={args.manifest}", flush=True)
        print(f"[extractor] output_dir={args.output_dir}", flush=True)

    # Load slide manifest + partition by rank
    all_slide_ids = load_manifest(args.manifest)
    my_slide_ids = partition_slides_by_rank(all_slide_ids, rank, world_size)
    if args.max_slides > 0:
        my_slide_ids = my_slide_ids[:args.max_slides]
        print(f"[extractor] rank={rank} --max-slides={args.max_slides}; capped to "
              f"{len(my_slide_ids)} slides (smoke mode)", file=sys.stderr, flush=True)
    print(f"[extractor] rank={rank} handles {len(my_slide_ids)}/{len(all_slide_ids)} slides",
          file=sys.stderr, flush=True)

    # Load model
    model, data_cfg, embed_dim = load_foundation_model(args.model, device)
    preprocess = make_preprocess_fn(data_cfg, device)

    # 20× tiling params from the CLAM coord attrs (uniform per dataset/cell).
    patch_level, patch_size, footprint_level0 = read_coord_attrs(args.coords_dir)
    if rank == 0:
        print(f"[extractor] 20× tiling: patch_level={patch_level} patch_size={patch_size} "
              f"footprint_level0={footprint_level0}", flush=True)

    # Reader
    if args.backend == "kvikio":
        reader = KvikIOSlideReader(
            rawtiff_dir=args.rawtiff_dir,
            n_buffer=args.n_buffer,
            num_threads=args.num_threads,
            compat_mode=args.compat_mode,
            level=0,
            footprint_level0=footprint_level0,
        )
    elif args.backend == "cucim_batched_cpu":
        reader = CuCIMSlideReader(
            svs_dir=args.svs_dir,
            cucim_num_workers=16,
            cucim_batch_size=64,
            patch_level=patch_level,
            patch_size=patch_size,
        )
    else:
        raise SystemExit(f"unknown --backend {args.backend!r}")

    # Ensure output dir exists
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Per-extraction-step CSV (rank 0 only writes)
    steps_csv_file = None
    steps_csv_writer = None
    if rank == 0:
        Path(args.extraction_steps_csv).parent.mkdir(parents=True, exist_ok=True)
        steps_csv_file = open(args.extraction_steps_csv, "w", newline="")
        steps_csv_writer = csv.DictWriter(steps_csv_file, fieldnames=[
            "step_idx", "phase", "t_step_start_s", "t_step_end_s",
            "step_duration_ms", "t_dataload_ms", "t_forward_ms",
            "samples_per_step", "slide_id_in_step", "world_size",
        ])
        steps_csv_writer.writeheader()

    # Per-slide CSV (each rank writes to a rank-local file; main merges post-spawn)
    per_slide_file = open(f"{args.per_slide_csv}.rank{rank}", "w", newline="")
    per_slide_writer = csv.DictWriter(per_slide_file, fieldnames=[
        "slide_id", "rank_handled", "world_size", "n_tiles", "t_start_s",
        "t_end_s", "wallclock_s", "tiles_per_sec_slide", "embedding_dim",
    ])
    per_slide_writer.writeheader()

    # CUDA events for per-step timing (Stage 5 pattern)
    ev_start = torch.cuda.Event(enable_timing=True)
    ev_after_dataload = torch.cuda.Event(enable_timing=True)
    ev_after_forward = torch.cuda.Event(enable_timing=True)

    # Sync ranks at start so cell wallclock is comparable
    if world_size > 1:
        dist.barrier()
    t_zero = time.monotonic()

    # Warmup-step accounting: first N steps include cudnn.benchmark autotune cost
    # (~10-20s based on Stage 5). We mark the first N_RAMP_STEPS as phase='ramp';
    # aggregator filters by phase=='steady'.
    N_RAMP_STEPS = 10

    step_idx = 0
    slides_done = 0
    slides_incomplete = 0   # slides refused because not every embedding row was filled
    total_tiles_steady = 0
    total_steps_steady = 0

    # Each skip cause is counted SEPARATELY because they mean opposite things.
    # `exists` is a resumed cell doing the right thing; `no_coords` and
    # `input_missing` mean this cell quietly extracted a reduced corpus and still
    # exits 0, with tiles_per_sec_aggregate_steady computed over that subset. One
    # shared `continue` with no counter made all four indistinguishable, and the
    # likeliest trigger is mundane: a re-run of Stage 3 rm -rf's the coords dir
    # that every Stage 4/5/6/7 cell reads, so an interrupted Stage 3 leaves the
    # downstream cells reading a corpus that is smaller than they claim.
    slides_skipped_exists = 0
    slides_skipped_no_coords = 0
    slides_skipped_input_missing = 0

    for sid in my_slide_ids:
        # Skip if output already exists (idempotency — useful if cell is re-run after partial failure)
        out_path = output_dir / f"{sid}.pt"
        if out_path.exists() and not args.force_reextract:
            slides_skipped_exists += 1
            print(f"[extractor] rank={rank} skip {sid} (exists)", file=sys.stderr, flush=True)
            continue

        coords = load_slide_coords(args.coords_dir, sid)
        if coords is None:
            slides_skipped_no_coords += 1
            print(f"[extractor] rank={rank} skip {sid} (no coords)", file=sys.stderr, flush=True)
            continue
        n_tiles = coords.shape[0]

        # Open slide
        if args.backend == "kvikio":
            handle, idx_meta = reader.open_slide(sid)
            if handle is None:
                slides_skipped_input_missing += 1
                print(f"[extractor] rank={rank} skip {sid} (rawtiff missing)", file=sys.stderr, flush=True)
                continue
        else:
            slide_handle = reader.open_slide(sid)
            if slide_handle is None:
                slides_skipped_input_missing += 1
                print(f"[extractor] rank={rank} skip {sid} (svs missing)", file=sys.stderr, flush=True)
                continue

        # Accumulator for this slide's embeddings (on GPU; downloaded to host at end)
        slide_embeddings = torch.empty((n_tiles, embed_dim), dtype=torch.float32, device=device)
        emb_cursor = 0
        slide_t_start = time.monotonic()

        # Iterate tile batches
        if args.backend == "kvikio":
            batch_iter = reader.iter_tile_batches(handle, idx_meta, coords, args.batch_size, device)
        else:
            batch_iter = reader.iter_tile_batches(slide_handle, coords, args.batch_size, device)

        for tile_hwc_uint8, B in batch_iter:
            t_step_start = time.monotonic()
            phase = "ramp" if step_idx < N_RAMP_STEPS else "steady"

            ev_start.record()

            # 1. Preprocess (center crop + normalize + permute to channels_last NCHW)
            #    Note: kvikIO backend produces uint8 NHWC on GPU directly; cuCIM
            #    backend uploaded uint8 NHWC; both call the same preprocess.
            images = preprocess(tile_hwc_uint8)
            ev_after_dataload.record()

            # 2. Frozen-eval forward
            #    All three foundation models (UNI2-h, Virchow2, GigaPath) return the
            #    full token sequence [B, n_tokens, D] from `model(x)` (n_tokens = 1 CLS
            #    + register_tokens + patch_tokens; e.g. Virchow2 = 1+4+256 = 261).
            #    We use the CLS token (position 0) as the per-tile embedding [B, D]
            #    for the storage-benchmark workload. This is the universally-defined
            #    pooled representation across ViT foundation models. Note: downstream
            #    tasks per published Paige Virchow2 protocol use cat(CLS, mean(patches))
            #    = 2*embed_dim; the storage-benchmark workload is bottlenecked on raw
            #    IO not on which pooling rule is applied, so CLS-only is sufficient
            #    and keeps per-slide .pt file sizes uniform per declared embed_dim.
            with torch.no_grad(), autocast(dtype=torch.float16):
                model_out = model(images)
                if model_out.dim() == 3:
                    feats = model_out[:, 0]   # CLS token: [B, D]
                else:
                    feats = model_out           # already pooled: [B, D]
            ev_after_forward.record()

            torch.cuda.synchronize(device)
            t_step_end = time.monotonic()

            # Read per-phase GPU stream time
            dl_ms = ev_start.elapsed_time(ev_after_dataload)
            fw_ms = ev_after_dataload.elapsed_time(ev_after_forward)

            # Accumulate embeddings (cast to FP32 from autocast FP16 output)
            slide_embeddings[emb_cursor: emb_cursor + B] = feats.to(torch.float32)
            emb_cursor += B

            if rank == 0:
                steps_csv_writer.writerow({
                    "step_idx": step_idx,
                    "phase": phase,
                    "t_step_start_s": f"{t_step_start - t_zero:.6f}",
                    "t_step_end_s": f"{t_step_end - t_zero:.6f}",
                    "step_duration_ms": f"{(t_step_end - t_step_start) * 1000:.3f}",
                    "t_dataload_ms": f"{dl_ms:.3f}",
                    "t_forward_ms": f"{fw_ms:.3f}",
                    "samples_per_step": B,
                    "slide_id_in_step": sid,
                    "world_size": world_size,
                })
                if step_idx % 50 == 0:
                    steps_csv_file.flush()
                    print(f"[extractor] step={step_idx} phase={phase} sid={sid} "
                          f"step_ms={(t_step_end - t_step_start)*1000:.1f} "
                          f"dl_ms={dl_ms:.1f} fw_ms={fw_ms:.1f}", flush=True)

            if phase == "steady":
                total_tiles_steady += B
                total_steps_steady += 1
            step_idx += 1

        # Close slide handles (kvikIO needs explicit close)
        if args.backend == "kvikio":
            try:
                handle.close()
            except Exception:
                pass

        slide_t_end = time.monotonic()
        slide_wallclock = slide_t_end - slide_t_start
        per_slide_writer.writerow({
            "slide_id": sid,
            "rank_handled": rank,
            "world_size": world_size,
            "n_tiles": n_tiles,
            "t_start_s": f"{slide_t_start - t_zero:.6f}",
            "t_end_s": f"{slide_t_end - t_zero:.6f}",
            "wallclock_s": f"{slide_wallclock:.3f}",
            "tiles_per_sec_slide": f"{n_tiles / slide_wallclock:.1f}" if slide_wallclock > 0 else "0",
            "embedding_dim": embed_dim,
        })
        per_slide_file.flush()

        # GUARD: every row must have been written before this is persisted.
        #
        # `slide_embeddings` is allocated with torch.empty, so any row the batch
        # loop did not reach still holds whatever was previously in that GPU
        # memory. Saving it would write uninitialised memory to disk as though
        # it were a feature vector, under a header claiming n_tiles real rows --
        # a file that loads cleanly, has the right shape and dtype, trains
        # without error, and is silently garbage in its tail. Nothing
        # downstream can detect that, which is why this is a refusal and not a
        # warning.
        if emb_cursor != n_tiles:
            slides_incomplete += 1
            print(f"[extractor] REFUSING TO SAVE {sid}: filled {emb_cursor}/{n_tiles} "
                  f"embedding rows. The remainder is uninitialised memory, so this "
                  f"slide is dropped rather than written. Cell is INCOMPLETE.",
                  file=sys.stderr, flush=True)
            continue

        # Save per-slide .pt
        # Download to host as FP32 (or FP16 if requested via --dtype-out)
        if args.dtype_out == "fp16":
            slide_embeddings = slide_embeddings.to(torch.float16)
        emb_host = slide_embeddings.cpu()
        torch.save({
            "slide_id": sid,
            "model": args.model,
            "embedding_dim": embed_dim,
            "n_tiles": n_tiles,
            "coords": torch.from_numpy(coords),
            "features": emb_host,
        }, out_path)
        slides_done += 1
        if rank == 0:
            print(f"[extractor] saved {out_path} "
                  f"({n_tiles} tiles, {slide_wallclock:.1f}s, "
                  f"{n_tiles / slide_wallclock:.0f} tiles/sec)", flush=True)

    # Per-rank close
    per_slide_file.close()
    if rank == 0:
        steps_csv_file.close()

    # Aggregate across ranks. Every per-rank counter that reaches the summary is
    # summed HERE — rank 0 writes the summary, so a counter left out of this
    # reduction would report rank 0's slice of the work as though it were the
    # whole cell. Named rather than positional so adding one can't silently
    # shift the meaning of the others.
    # getattr default 0: only the kvikIO reader discards page cache, and 0 is the
    # honest count for the cuCIM backend rather than a missing field.
    counter_names = ["tiles_steady", "steps_steady", "slides_done", "slides_incomplete",
                     "scheduled", "skipped_exists", "skipped_no_coords",
                     "skipped_input_missing", "discard_attempted", "discard_failed"]
    local_counts = [total_tiles_steady, total_steps_steady, slides_done, slides_incomplete,
                    len(my_slide_ids), slides_skipped_exists, slides_skipped_no_coords,
                    slides_skipped_input_missing,
                    getattr(reader, "n_discard_attempted", 0),
                    getattr(reader, "n_discard_failed", 0)]
    if world_size > 1:
        local = torch.tensor([float(x) for x in local_counts], device=device)
        dist.all_reduce(local, op=dist.ReduceOp.SUM)
        g = dict(zip(counter_names, [float(x.item()) for x in local]))
    else:
        g = dict(zip(counter_names, [float(x) for x in local_counts]))
    global_tiles_steady = g["tiles_steady"]
    global_steps_steady = g["steps_steady"]
    global_slides_done = int(g["slides_done"])
    global_slides_incomplete = int(g["slides_incomplete"])

    cell_wallclock = time.monotonic() - t_zero

    if rank == 0:
        # Merge per-rank per-slide CSVs into a single sorted file
        merged_rows = []
        for r in range(world_size):
            try:
                with open(f"{args.per_slide_csv}.rank{r}") as f:
                    rd = csv.DictReader(f)
                    for row in rd:
                        merged_rows.append(row)
            except FileNotFoundError:
                continue
        merged_rows.sort(key=lambda r: r["slide_id"])
        with open(args.per_slide_csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(merged_rows[0].keys())) if merged_rows else None
            if w:
                w.writeheader()
                for r in merged_rows:
                    w.writerow(r)
        # Cleanup per-rank files
        for r in range(world_size):
            try:
                os.unlink(f"{args.per_slide_csv}.rank{r}")
            except FileNotFoundError:
                pass

        summary = {
            "model": args.model,
            "model_hub_id": MODEL_REGISTRY[args.model].hub_id,
            "embedding_dim": embed_dim,
            "backend": args.backend,
            "world_size": world_size,
            "batch_size": args.batch_size,
            "n_slides_manifest": len(all_slide_ids),
            # What was actually SCHEDULED, after --max-slides truncated each rank's
            # list. n_slides_manifest is the manifest length even in smoke mode, so
            # on its own a 20-slide smoke run and a full production run produce
            # summaries that differ only in a number nobody reads as a mode flag.
            "n_slides_scheduled": int(g["scheduled"]),
            "max_slides": args.max_slides,
            "n_slides_extracted_total": global_slides_done,
            # The skip causes, counted separately — see the counter declarations
            # for why they must not be pooled. Non-zero no_coords / input_missing
            # means this cell extracted a REDUCED corpus and still exited 0.
            "n_slides_skipped_exists": int(g["skipped_exists"]),
            "n_slides_skipped_no_coords": int(g["skipped_no_coords"]),
            "n_slides_skipped_input_missing": int(g["skipped_input_missing"]),
            # Cache state ACHIEVED, not asserted. The kvikIO backend discards each
            # slide's page cache before opening it; the cuCIM backend has NO
            # discard mechanism at all, so attempted == 0 there and such a cell
            # must be read as WARM — cold cannot be inferred from the backend name.
            "n_page_cache_discards_attempted": int(g["discard_attempted"]),
            "n_page_cache_discards_failed": int(g["discard_failed"]),
            # Client page cache only; the server side and the per-filesystem cold
            # mechanism are open (A.5 / D13). Stated, not left to omission.
            "cache_state_achieved": "unknown",
            # Slides refused because not every embedding row was filled. Non-zero
            # means this cell did NOT produce the feature set it claims, and the
            # process exits non-zero so no driver can mark the step done.
            "n_slides_incomplete_refused": global_slides_incomplete,
            "total_tiles_steady_phase": global_tiles_steady,
            "total_steady_steps": global_steps_steady,
            "cell_wallclock_s": cell_wallclock,
            "tiles_per_sec_aggregate_steady": (global_tiles_steady / cell_wallclock
                                               if cell_wallclock > 0 else 0.0),
            "extraction_steps_csv": args.extraction_steps_csv,
            "per_slide_csv": args.per_slide_csv,
            "output_dir": args.output_dir,
            "n_ramp_steps_excluded": N_RAMP_STEPS,
            "dtype_out": args.dtype_out,
        }
        print(f"=== summary ===", flush=True)
        print(json.dumps(summary, indent=2), flush=True)
        if args.summary_json:
            with open(args.summary_json, "w") as f:
                json.dump(summary, f, indent=2)

    if world_size > 1:
        dist.destroy_process_group()

    # Exit non-zero if any slide was refused. Without this the driver sees a
    # clean exit and marks the step done, and the cell's own output count is the
    # only remaining evidence that features are missing -- which is exactly the
    # kind of failure that is invisible until someone goes looking.
    if global_slides_incomplete > 0:
        raise SystemExit(
            f"FATAL: {global_slides_incomplete} slide(s) refused for incomplete "
            f"embedding fill. This cell is INCOMPLETE -- do not use its features.")


def _pick_free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", choices=["kvikio", "cucim_batched_cpu"], required=True)
    ap.add_argument("--model", choices=list(MODEL_REGISTRY.keys()), required=True)
    ap.add_argument("--world-size", type=int, default=1,
                    help="DDP rank count (= GPU count). Trainer self-launches via mp.spawn.")
    ap.add_argument("--rawtiff-dir", default=FS_MOUNT + "/data/tcga-brca-rawtiff")
    ap.add_argument("--svs-dir", default=FS_MOUNT + "/data/tcga-brca")
    ap.add_argument("--coords-dir", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--output-dir", required=True,
                    help="Per-slide .pt output directory (created if missing)")
    ap.add_argument("--batch-size", type=int, default=256, help="Per-rank batch size")
    ap.add_argument("--extraction-steps-csv", required=True,
                    help="Per-step CSV (rank 0 writes)")
    ap.add_argument("--per-slide-csv", required=True,
                    help="Per-slide CSV (per-rank files merged post-spawn)")
    ap.add_argument("--summary-json", help="Optional aggregate summary JSON path")
    ap.add_argument("--n-buffer", type=int, default=256,
                    help="kvikIO async pread pipelining depth")
    ap.add_argument("--num-threads", type=int, default=16,
                    help="kvikIO internal thread pool size")
    ap.add_argument("--compat-mode", choices=["off", "on", "auto"], default="off",
                    help="kvikIO compat_mode for the kvikio backend: off (GDS), on (POSIX bounce), "
                         "auto (kvikIO decides). Default 'off' is what 6.A's cells run in; the "
                         "mode-controlled paired cell (STAGES.md) is requested by passing this "
                         "explicitly. REQUESTED, not proven — the per-cell cuFile path accounting "
                         "settles which path actually ran.")
    ap.add_argument("--dtype-out", choices=["fp32", "fp16"], default="fp32",
                    help="Per-slide .pt feature tensor dtype")
    ap.add_argument("--force-reextract", action="store_true",
                    help="Re-extract even if per-slide .pt already exists (default: skip)")
    ap.add_argument("--max-slides", type=int, default=0,
                    help="If >0, cap each rank's slide list to this many slides (smoke tests only)")
    args = ap.parse_args()

    world_size = args.world_size
    if world_size <= 0:
        raise SystemExit("--world-size must be >= 1")
    master_port = _pick_free_port()
    print(f"[extractor] launching world_size={world_size} master_port={master_port} "
          f"CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>')}",
          flush=True)

    if world_size == 1:
        worker(0, 1, args, master_port)
    else:
        mp.spawn(worker, args=(world_size, args, master_port), nprocs=world_size, join=True)


if __name__ == "__main__":
    main()
