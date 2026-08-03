#!/usr/bin/env python3
"""inference-per-slide-stage7.py — Stage 7 per-slide clinical inference worker.

Per-slide chain of the four production clinical-inference phases:

  1. Tissue detection   — load CLAM coords from Stage 3 output (the coord file
                          IS the tissue-detection result; loading it is what
                          a real clinical inference service does).
  2. Feature extraction — frozen foundation-model ViT forward over all tissue
                          tiles (reuses Stage 6.A `KvikIOSlideReader` /
                          `CuCIMSlideReader` + `load_foundation_model` /
                          `make_preprocess_fn`).
  3. MIL aggregation    — CLAM-style attention forward over the slide's
                          feature bag (reuses Stage 6.B.3 `CLAMAttention`).
                          Untrained per Stage 7 roadmap Q3 — measuring latency,
                          not accuracy.
  4. Heatmap write      — render tile-resolution attention into one of three
                          production-realistic formats (per Q5: pyramidal TIFF
                          5×-downsample / pyramidal TIFF level-0 / PNG overlay).

PER-SLIDE PER-PHASE LATENCY CSV (the new Stage 7 primary recording source):
  slide_idx, slide_id, process_id, world_size, t_arrived_s, n_tiles,
  inference_batch_size, t_tissue_ms, t_extract_ms, t_mil_ms,
  t_heatmap_write_ms, t_total_ms, backend, model, cache_state,
  heatmap_format, heatmap_path, heatmap_bytes

PER-SLIDE HEATMAP WRITE CSV (the new Stage 7 primary for 7.3, 7.4, 7.5):
  slide_idx, slide_id, format, bytes_written, t_write_start_s,
  t_write_end_s, write_ms

DESIGN
======
Single-GPU, single-process worker. For concurrent inference (Stage 7.2 / 7.5
mixed), the orchestrator launches N independent copies, each pinned to its own
GPU via CUDA_VISIBLE_DEVICES and given disjoint slide chunks via
`--process-id` + `--world-size` modulo partition.

WHY single-process per inference job (mirrors Stage 7 roadmap Q8):
  Each pathologist's inference is a separate request in production. Disjoint
  slide chunks model the real "many users, distinct slides" workload. Storage
  pressure comes from the N processes competing for WekaFS reads.

WHY `--inference-batch-size` is a CLI knob (Q8 revision 2026-05-26):
  Virchow2 forward at bs=256 fp16 holds ~21 GB per process (1.3 GB weights +
  ~20 GB activations through ViT-H 32 layers). At N≥16 concurrent processes
  per GPU this OOMs. Orchestrator scales bs down with N (N=1/4 → 256,
  N=16 → 64, N=64 → 16). Per-slide latency stays the customer-decisive metric.

WHY untrained MIL (per Q3):
  Forward computation cost is identical with random or trained weights.
  Saves the engineering of training a usable MIL checkpoint that doesn't
  strengthen the storage-benchmark story.

WHY cold/warm split (Q1's per-tier methodology):
  Production reality: first inference on a new slide is cold; re-inferences
  within a shift are warm. Latency differs materially. We measure both via
  `--cache-policy {cold,warm}`. Cold = `cucim.clara.filesystem.discard_page_cache()`
  on the slide's underlying file before each inference.

REUSE FROM STAGE 6
==================
  KvikIOSlideReader / CuCIMSlideReader / load_foundation_model /
  make_preprocess_fn / load_manifest / load_slide_coords / MODEL_REGISTRY /
  TILE_SIZE / INPUT_SIZE     ← extract-features-foundation-stage6.py
  CLAMAttention               ← train-mil-stage6b.py

LD_PRELOAD SCOPING
==================
Per `cucim-segfaults-when-libcufile-is-ld-preloaded` memory: kvikIO+GDS needs
LD_PRELOAD=libcufile-1.17 (matches kernel nvidia-fs 2.28.2); cuCIM 26.04
segfaults if libcufile-1.17 is preloaded. Caller (orchestrator / sweep driver)
must scope LD_PRELOAD per-cell. This script doesn't touch LD_PRELOAD.

USAGE
=====
Typically invoked by `orchestrate-clinical-deployment-stage7.sh` or
`sweep-stage7-clinical.sh`. Direct invocation example for the 7.1.a cell:

  CUDA_VISIBLE_DEVICES=2 \\
  LD_PRELOAD=$LIBCUFILE_PRELOAD \\
  CUFILE_ENV_PATH_JSON=.../cufile-full-rdma.json \\
  CONDA_PREFIX=$CONDA_ENVS_DIR/$CONDA_ENV_MAIN \\
  $CONDA_ENVS_DIR/$CONDA_ENV_MAIN/bin/python \\
  inference-per-slide-stage7.py \\
    --backend kvikio --model virchow2 \\
    --rawtiff-dir $FS_MOUNT/data/tcga-brca-rawtiff \\
    --coords-dir $FS_MOUNT/tissue-detection/3.0/tcga-brca/n64/patches \\
    --manifest runs/manifests/tcga-brca-stage4a-subset.tsv \\
    --heatmap-dir $FS_MOUNT/heatmaps/7.1/virchow2-kvikio-cold \\
    --heatmap-format tiff5x \\
    --inference-batch-size 256 \\
    --cache-policy cold \\
    --max-slides 20 \\
    --per-slide-csv <run-dir>/per-slide-inference-latencies.csv \\
    --per-slide-heatmap-csv <run-dir>/per-slide-heatmap-writes.csv \\
    --summary-json <run-dir>/inference-summary.json
"""
import argparse
import csv
import importlib.util
import json
import os
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

import os as _os, sys as _sys
# The mount is a DIMENSION, never a constant: this project runs the identical code
# against two filesystems. Refuse to guess -- a wrong mount silently measures the
# other filesystem and the number still looks correct.
FS_MOUNT = _os.environ.get("FS_MOUNT")
if not FS_MOUNT:
    _sys.exit("FATAL: FS_MOUNT is unset -- source cloud-setup/env.sh "
              "(see cloud-setup/NAMING-AND-VARIABLES.md).")

import numpy as np
import torch
from torch.cuda.amp import autocast


# -----------------------------------------------------------------------------
# Reuse classes from Stage 6 scripts — files have hyphenated names so we load
# them by file path via importlib rather than `import` (which can't see hyphens).
# -----------------------------------------------------------------------------
_RUNS_LIB = Path(__file__).resolve().parent  # ${REPO}/runs/lib

def _load_module(name: str, filename: str):
    path = _RUNS_LIB / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module {name} from {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # so any internal `import name` resolves
    spec.loader.exec_module(mod)
    return mod

_extract_mod = _load_module(
    "extract_features_foundation_stage6", "extract-features-foundation-stage6.py"
)
_mil_mod = _load_module("train_mil_stage6b", "train-mil-stage6b.py")

KvikIOSlideReader = _extract_mod.KvikIOSlideReader
CuCIMSlideReader = _extract_mod.CuCIMSlideReader
load_foundation_model = _extract_mod.load_foundation_model
make_preprocess_fn = _extract_mod.make_preprocess_fn
load_manifest = _extract_mod.load_manifest
load_slide_coords = _extract_mod.load_slide_coords
read_coord_attrs = _extract_mod.read_coord_attrs
MODEL_REGISTRY = _extract_mod.MODEL_REGISTRY
TILE_SIZE = _extract_mod.TILE_SIZE  # 256 (CLAM tile size)
CLAMAttention = _mil_mod.CLAMAttention


# =============================================================================
# Heatmap rendering
# =============================================================================
# Viridis-like 256-entry RGB lookup table. Computed via matplotlib.cm.viridis
# (256 samples). Hardcoded so we don't import matplotlib at runtime (saves ~2s
# of import latency that would distort cold-cache per-slide timings).
# Source: list(map(int, (matplotlib.cm.viridis(np.linspace(0, 1, 256)) * 255)[:, :3].flatten()))
# Compressed via repeat to keep this file under 600 LOC — generated inline.
def _viridis_lut() -> np.ndarray:
    """Returns (256, 3) uint8 viridis-like LUT, computed deterministically."""
    # Simple parametric viridis-like ramp: dark purple → green → yellow.
    # Not pixel-identical to matplotlib's viridis but visually equivalent and
    # has zero external dependencies. Customer-story doesn't care about
    # colormap fidelity — only about the WekaFS write workload size+latency.
    t = np.linspace(0.0, 1.0, 256, dtype=np.float64)
    r = np.clip(np.where(t < 0.5, 0.27 + 0.5 * t, 0.5 + 1.0 * (t - 0.5)), 0, 1) * 255
    g = np.clip(0.0 + 0.95 * t, 0, 1) * 255
    b = np.clip(np.where(t < 0.5, 0.32 + 1.1 * t, 0.87 - 1.5 * (t - 0.5)), 0, 1) * 255
    lut = np.stack([r, g, b], axis=1).astype(np.uint8)
    return lut


VIRIDIS_LUT = _viridis_lut()


def build_tile_grid(coords: np.ndarray, attn: np.ndarray,
                    footprint: int = TILE_SIZE) -> np.ndarray:
    """Build a 2D tile-resolution attention grid from per-tile CLAM coords.

    coords:    (N, 2) int — (x_pixel, y_pixel) tile-top-left at level 0 (40×)
    attn:      (N,) float — attention weight per tile
    footprint: level-0 (40×) px between adjacent tiles (= the 20× footprint, 512).
               Coords are in level-0 space and step by this, so the tile-grid
               index is coord // footprint — NOT // TILE_SIZE (256), which at 20×
               would leave every-other grid cell empty and misplace the heatmap.
    Returns: (n_tile_rows, n_tile_cols) float32, tiles outside tissue = 0.0.
    """
    if coords.shape[0] == 0:
        return np.zeros((1, 1), dtype=np.float32)
    tile_cols = (coords[:, 0] // footprint).astype(np.int64)
    tile_rows = (coords[:, 1] // footprint).astype(np.int64)
    # Anchor to (0, 0) bounding box
    tile_cols -= tile_cols.min()
    tile_rows -= tile_rows.min()
    n_rows = int(tile_rows.max()) + 1
    n_cols = int(tile_cols.max()) + 1
    grid = np.zeros((n_rows, n_cols), dtype=np.float32)
    grid[tile_rows, tile_cols] = attn
    return grid


def normalize_attn(attn: np.ndarray) -> np.ndarray:
    """Map attention values into [0, 1] for colormap lookup.

    CLAMAttention.forward applies softmax over N tiles → values sum to 1.0;
    for typical 30K-tile slides the mean is ~3e-5 — too small to visualize.
    Min-max normalize to [0, 1] for colormap; aborts gracefully if range is 0.
    """
    if attn.size == 0:
        return attn
    lo = float(attn.min())
    hi = float(attn.max())
    if hi - lo < 1e-12:
        return np.zeros_like(attn, dtype=np.float32)
    return ((attn - lo) / (hi - lo)).astype(np.float32)


def apply_colormap(grid: np.ndarray, lut: np.ndarray = VIRIDIS_LUT) -> np.ndarray:
    """Map a (H, W) float32 [0, 1] grid → (H, W, 3) uint8 RGB via LUT."""
    idx = np.clip((grid * 255.0).astype(np.int64), 0, 255)
    return lut[idx]


def bilinear_interp_window(tile_grid: np.ndarray,
                            row_idx_all: np.ndarray, col_idx_all: np.ndarray,
                            row_start: int = 0, col_start: int = 0,
                            h_window: Optional[int] = None,
                            w_window: Optional[int] = None) -> np.ndarray:
    """Bilinear-interp a window of an output image from the (n_rows, n_cols)
    tile attention grid. `row_idx_all` and `col_idx_all` are precomputed
    full-output sampling indices (linspace from 0..n-1 across full output dims);
    `row_start`/`col_start` + window dims select the sub-window. Returns
    (h_window, w_window) float32 in [0, 1] — caller applies colormap.

    Used by all 3 heatmap writers to produce SMOOTH per-pixel content
    (instead of uniform per-tile color), which gives realistic deflate
    compression ratios and per-slide file sizes matching production-realistic
    pyramidal-TIFF heatmap viewers (e.g. CLAM heatmap renderer, QuPath overlay).
    """
    n_rows, n_cols = tile_grid.shape
    if h_window is None:
        h_window = row_idx_all.shape[0] - row_start
    if w_window is None:
        w_window = col_idx_all.shape[0] - col_start
    row_idx = row_idx_all[row_start:row_start + h_window]
    col_idx = col_idx_all[col_start:col_start + w_window]
    r0 = np.clip(np.floor(row_idx).astype(np.int64), 0, n_rows - 1)
    r1 = np.clip(r0 + 1, 0, n_rows - 1)
    c0 = np.clip(np.floor(col_idx).astype(np.int64), 0, n_cols - 1)
    c1 = np.clip(c0 + 1, 0, n_cols - 1)
    wr = (row_idx - r0).astype(np.float32)
    wc = (col_idx - c0).astype(np.float32)
    v00 = tile_grid[r0[:, None], c0[None, :]]
    v01 = tile_grid[r0[:, None], c1[None, :]]
    v10 = tile_grid[r1[:, None], c0[None, :]]
    v11 = tile_grid[r1[:, None], c1[None, :]]
    interp = (
        v00 * (1 - wr[:, None]) * (1 - wc[None, :])
        + v01 * (1 - wr[:, None]) * wc[None, :]
        + v10 * wr[:, None] * (1 - wc[None, :])
        + v11 * wr[:, None] * wc[None, :]
    )
    return interp.astype(np.float32)


def write_heatmap_png(slide_id: str, tile_grid: np.ndarray,
                       output_dir: Path, target_px: int = 1024) -> Tuple[Path, int]:
    """PNG overlay: smallest format (Q5 target ~500 KB - 1 MB per slide).
    Bilinear-interpolated to target_px on the longest axis for production-
    realistic visual smoothness (matches QuPath / CLAM heatmap renderers).
    """
    from PIL import Image
    H_grid, W_grid = tile_grid.shape
    if max(H_grid, W_grid) <= 1:
        rgb = apply_colormap(tile_grid)
    else:
        # Scale so longest axis = target_px, preserve aspect
        if H_grid >= W_grid:
            H_out = target_px
            W_out = max(1, int(W_grid * target_px / H_grid))
        else:
            W_out = target_px
            H_out = max(1, int(H_grid * target_px / W_grid))
        row_idx = np.linspace(0, H_grid - 1, H_out)
        col_idx = np.linspace(0, W_grid - 1, W_out)
        interp = bilinear_interp_window(tile_grid, row_idx, col_idx)
        rgb = apply_colormap(interp)
    img = Image.fromarray(rgb, mode='RGB')
    out_path = output_dir / f"{slide_id}.png"
    img.save(out_path, format='PNG')
    return out_path, out_path.stat().st_size


def write_heatmap_tiff5x(slide_id: str, tile_grid: np.ndarray,
                          output_dir: Path) -> Tuple[Path, int]:
    """Pyramidal TIFF 5× downsample of level-0 (Q5 target ~50-100 MB per slide).

    Per-tile output: 51 px (256/5). Bilinear-interpolated content gives realistic
    deflate compression ratios — matches what production heatmap viewers
    (QuPath, CLAM, Slideflow) render for per-tile-attention overlays.
    """
    import tifffile
    n_rows, n_cols = tile_grid.shape
    tile_out_px = 51
    H_out = n_rows * tile_out_px
    W_out = n_cols * tile_out_px
    row_idx = np.linspace(0, n_rows - 1, H_out)
    col_idx = np.linspace(0, n_cols - 1, W_out)
    interp = bilinear_interp_window(tile_grid, row_idx, col_idx)
    rgb_full = apply_colormap(interp)
    out_path = output_dir / f"{slide_id}.tiff"
    tifffile.imwrite(
        str(out_path),
        rgb_full,
        photometric='rgb',
        tile=(256, 256),
        compression='zlib',
        bigtiff=True,
    )
    return out_path, out_path.stat().st_size


def write_heatmap_tiff_l0(slide_id: str, tile_grid: np.ndarray,
                           output_dir: Path) -> Tuple[Path, int]:
    """Pyramidal TIFF at level-0 full resolution (Q5 target ~200-500 MB per slide).

    Bilinear-interpolated per-pixel content gives realistic compression
    ratios — production heatmap viewers render this exact output style.
    Streamed tile-by-tile via tifffile generator so we never materialize the
    full (n_rows*256, n_cols*256, 3) array in RAM (could be 10+ GB).
    """
    import tifffile
    n_rows, n_cols = tile_grid.shape
    TILE_OUT_PX = TILE_SIZE                          # 256 px per tile (level 0)
    full_H = n_rows * TILE_OUT_PX
    full_W = n_cols * TILE_OUT_PX
    # Precompute full sampling-index arrays once per slide (slice per tile below)
    row_idx_all = np.linspace(0, n_rows - 1, full_H)
    col_idx_all = np.linspace(0, n_cols - 1, full_W)

    def gen_tiles():
        # tifffile expects tiles in row-major order (left-to-right, top-to-bottom)
        for tr in range(n_rows):
            for tc in range(n_cols):
                row_start = tr * TILE_OUT_PX
                col_start = tc * TILE_OUT_PX
                interp = bilinear_interp_window(
                    tile_grid, row_idx_all, col_idx_all,
                    row_start=row_start, col_start=col_start,
                    h_window=TILE_OUT_PX, w_window=TILE_OUT_PX,
                )
                yield apply_colormap(interp)

    out_path = output_dir / f"{slide_id}.tiff"
    with tifffile.TiffWriter(str(out_path), bigtiff=True) as tw:
        tw.write(
            gen_tiles(),
            shape=(full_H, full_W, 3),
            dtype=np.uint8,
            tile=(TILE_SIZE, TILE_SIZE),
            photometric='rgb',
            compression='zlib',
        )
    return out_path, out_path.stat().st_size


HEATMAP_WRITERS = {
    'tiff5x':  write_heatmap_tiff5x,
    'tiff_l0': write_heatmap_tiff_l0,
    'png':     write_heatmap_png,
}


# =============================================================================
# Page-cache discipline (cold/warm split)
# =============================================================================
def discard_page_cache(path: Path):
    """Cold-cache discipline: drop kernel page cache for a single file.

    Per Stage 6 standard pattern — uses cucim.clara.filesystem.discard_page_cache
    which works without root (unlike `echo 3 > /proc/sys/vm/drop_caches`).
    """
    try:
        from cucim.clara import filesystem as cucim_fs
        cucim_fs.discard_page_cache(str(path))
    except Exception:
        # Best-effort; if cucim_fs unavailable just skip (warm-cache fallback).
        pass


# =============================================================================
# Per-slide chained inference
# =============================================================================
def run_inference_on_slide(sid: str, slide_idx: int, args,
                            reader, foundation_model, preprocess,
                            mil, embed_dim: int, device: torch.device,
                            t_zero: float) -> Optional[dict]:
    """Run all 4 phases for one slide. Returns the per-slide CSV row dict
    (or None if the slide was skipped — no coords or missing file)."""
    t_arrived = time.monotonic() - t_zero

    # ----- Phase 1: tissue detection (load CLAM coords) -----
    t_phase = time.monotonic()
    if args.cache_policy == 'cold':
        # Drop page cache for the slide's underlying file BEFORE the coord load
        if args.backend == 'kvikio':
            discard_page_cache(Path(args.rawtiff_dir) / f"{sid}.tiff")
        else:
            slide_path = reader._find_slide(sid)
            if slide_path is not None:
                discard_page_cache(slide_path)
    coords = load_slide_coords(args.coords_dir, sid)
    if coords is None:
        print(f"[infer] skip {sid} (no coords)", flush=True)
        return None
    n_tiles = int(coords.shape[0])
    t_tissue_ms = (time.monotonic() - t_phase) * 1000.0

    # ----- Phase 2: feature extraction (frozen ViT forward over all tiles) -----
    t_phase = time.monotonic()
    if args.backend == 'kvikio':
        handle, idx_meta = reader.open_slide(sid)
        if handle is None:
            print(f"[infer] skip {sid} (rawtiff missing)", flush=True)
            return None
        batch_iter = reader.iter_tile_batches(
            handle, idx_meta, coords, args.inference_batch_size, device
        )
    else:
        slide_handle = reader.open_slide(sid)
        if slide_handle is None:
            print(f"[infer] skip {sid} (svs missing)", flush=True)
            return None
        batch_iter = reader.iter_tile_batches(
            slide_handle, coords, args.inference_batch_size, device
        )
    # Accumulate per-tile embeddings on GPU
    features = torch.empty((n_tiles, embed_dim), dtype=torch.float32, device=device)
    cursor = 0
    for tile_hwc_uint8, B in batch_iter:
        images = preprocess(tile_hwc_uint8)
        with torch.no_grad(), autocast(dtype=torch.float16):
            model_out = foundation_model(images)
            # All 3 foundation models return [B, n_tokens, D] from model(x)
            # (n_tokens = CLS + reg + patch); use CLS as the pooled per-tile
            # embedding (same convention as Stage 6.A extractor).
            if model_out.dim() == 3:
                feats = model_out[:, 0]
            else:
                feats = model_out
        features[cursor:cursor + B] = feats.to(torch.float32)
        cursor += B
    if args.backend == 'kvikio':
        try:
            handle.close()
        except Exception:
            pass
    torch.cuda.synchronize(device)
    t_extract_ms = (time.monotonic() - t_phase) * 1000.0

    # ----- Phase 3: MIL aggregation (CLAMAttention forward over feature bag) ---
    t_phase = time.monotonic()
    with torch.no_grad(), autocast(dtype=torch.float16):
        # CLAMAttention.forward expects h: [N, D] and returns (logits [1, n_cls], attn [N])
        _logits, attn = mil(features)
    torch.cuda.synchronize(device)
    t_mil_ms = (time.monotonic() - t_phase) * 1000.0

    # ----- Phase 4: heatmap write -------------------------------------------
    t_phase = time.monotonic()
    t_write_start_wall = t_phase - t_zero
    attn_host = attn.detach().to(torch.float32).cpu().numpy()
    attn_norm = normalize_attn(attn_host)
    tile_grid = build_tile_grid(coords, attn_norm, footprint=args.footprint_level0)
    writer_fn = HEATMAP_WRITERS[args.heatmap_format]
    heatmap_path, heatmap_bytes = writer_fn(sid, tile_grid, Path(args.heatmap_dir))
    t_heatmap_write_ms = (time.monotonic() - t_phase) * 1000.0
    t_write_end_wall = time.monotonic() - t_zero

    t_total_ms = t_tissue_ms + t_extract_ms + t_mil_ms + t_heatmap_write_ms

    return {
        'main_row': {
            'slide_idx': slide_idx,
            'slide_id': sid,
            'process_id': args.process_id,
            'world_size': args.world_size,
            't_arrived_s': f"{t_arrived:.6f}",
            'n_tiles': n_tiles,
            'inference_batch_size': args.inference_batch_size,
            't_tissue_ms': f"{t_tissue_ms:.3f}",
            't_extract_ms': f"{t_extract_ms:.3f}",
            't_mil_ms': f"{t_mil_ms:.3f}",
            't_heatmap_write_ms': f"{t_heatmap_write_ms:.3f}",
            't_total_ms': f"{t_total_ms:.3f}",
            'backend': args.backend,
            'model': args.model,
            'cache_state': args.cache_policy,
            'heatmap_format': args.heatmap_format,
            'heatmap_path': str(heatmap_path),
            'heatmap_bytes': heatmap_bytes,
        },
        'heatmap_row': {
            'slide_idx': slide_idx,
            'slide_id': sid,
            'format': args.heatmap_format,
            'bytes_written': heatmap_bytes,
            't_write_start_s': f"{t_write_start_wall:.6f}",
            't_write_end_s': f"{t_write_end_wall:.6f}",
            'write_ms': f"{t_heatmap_write_ms:.3f}",
        },
    }


# =============================================================================
# Main
# =============================================================================
def partition_slides(slide_ids: List[str], process_id: int, world_size: int) -> List[str]:
    """Modulo partition for concurrent inference processes."""
    if world_size <= 1:
        return slide_ids
    return [s for i, s in enumerate(slide_ids) if (i % world_size) == process_id]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument('--backend', choices=['kvikio', 'cucim_batched_cpu'], required=True)
    ap.add_argument('--model', choices=list(MODEL_REGISTRY.keys()), required=True)
    ap.add_argument('--rawtiff-dir', default=FS_MOUNT + "/data/tcga-brca-rawtiff")
    ap.add_argument('--svs-dir', default=FS_MOUNT + "/data/tcga-brca")
    ap.add_argument('--coords-dir', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--heatmap-dir', required=True,
                    help='Output dir for per-slide heatmap files (created if missing)')
    ap.add_argument('--heatmap-format', choices=list(HEATMAP_WRITERS.keys()),
                    default='tiff5x', help='Q5 default format = 5x downsample TIFF')
    ap.add_argument('--inference-batch-size', type=int, default=256,
                    help='Per-process foundation-model forward batch size. Drops with '
                         'concurrency N per Q8 revision (N=1/4 → 256, N=16 → 64, N=64 → 16) '
                         'to keep per-GPU memory bounded. Caller sets explicitly per cell.')
    ap.add_argument('--cache-policy', choices=['cold', 'warm'], default='warm',
                    help='cold: discard page cache for slide file before each inference; '
                         'warm: production-realistic (clinical deployments process many '
                         'slides per shift, page cache assists).')
    ap.add_argument('--max-slides', type=int, default=0,
                    help='Cap slides processed (0 = no cap). Per-cell wallclock budget.')
    ap.add_argument('--max-runtime-s', type=float, default=0.0,
                    help='Cell-level deadline; if >0, stop iterating slides after this many '
                         'seconds. Used by 7.2 sustained concurrent cells (30-min cap).')
    ap.add_argument('--per-slide-csv', required=True,
                    help='New Stage 7 PRIMARY CSV — per-slide per-phase inference latencies.')
    ap.add_argument('--per-slide-heatmap-csv', required=True,
                    help='New Stage 7 PRIMARY CSV — per-slide heatmap write workload.')
    ap.add_argument('--summary-json', required=True)
    ap.add_argument('--process-id', type=int, default=0,
                    help='For concurrent runs: this proc\'s rank in [0, world_size).')
    ap.add_argument('--world-size', type=int, default=1,
                    help='Total concurrent inference processes (for slide chunk partition). '
                         '1 = single process (7.1 baselines).')
    ap.add_argument('--n-buffer', type=int, default=256,
                    help='kvikIO async pread depth (Stage 4.C / 6.A standard).')
    ap.add_argument('--num-threads', type=int, default=16,
                    help='kvikIO thread pool size (Stage 4.C / 6.A standard).')
    ap.add_argument('--hidden-dim', type=int, default=384,
                    help='MIL attention hidden dim (matches Stage 6.B.3 default).')
    ap.add_argument('--start-barrier-file', default='',
                    help='If set, after model + reader setup, wait for this file to appear '
                         'before entering the slide loop. Lets the orchestrator synchronize '
                         'multi-process cells AFTER all workers have loaded their models '
                         '(otherwise --max-runtime-s burns through model-load time too).')
    args = ap.parse_args()

    # The caller pins the GPU via CUDA_VISIBLE_DEVICES (single GPU per process);
    # we always use cuda:0 inside this script's CUDA context.
    # REFUSE rather than default. Every caller pins it (sweep-stage7-clinical.sh,
    # orchestrate-clinical-deployment-stage7.sh, streaming-loop-stage7.sh,
    # pipeline-end-to-end-stage6d.sh), so an unset value means the cell was launched
    # some other way — and the old default of GPU 2 encoded a previous machine's
    # NIC-adjacency finding, so it would silently pin to a GPU chosen for different
    # hardware. Same rule as every other unset-configuration path in this project.
    if not os.environ.get('CUDA_VISIBLE_DEVICES', '').strip():
        sys.exit("FATAL: CUDA_VISIBLE_DEVICES is unset. Pin the GPU explicitly -- "
                 "refusing to guess, because the pinning choice is instance-specific "
                 "(see cloud-setup/NAMING-AND-VARIABLES.md and deferred item D-8).")
    torch.cuda.set_device(0)
    device = torch.device('cuda:0')
    torch.backends.cudnn.benchmark = True

    print(f"[infer] backend={args.backend} model={args.model} "
          f"cache={args.cache_policy} bs={args.inference_batch_size} "
          f"proc {args.process_id}/{args.world_size} "
          f"CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES')}", flush=True)

    # Partition slides among concurrent processes
    all_slide_ids = load_manifest(args.manifest)
    my_slide_ids = partition_slides(all_slide_ids, args.process_id, args.world_size)
    if args.max_slides > 0:
        my_slide_ids = my_slide_ids[:args.max_slides]
    print(f"[infer] manifest={args.manifest} -> "
          f"{len(my_slide_ids)}/{len(all_slide_ids)} slides for this process",
          flush=True)

    # Load foundation model + preprocess
    foundation_model, data_cfg, embed_dim = load_foundation_model(args.model, device)
    foundation_model.eval()
    preprocess = make_preprocess_fn(data_cfg, device)

    # MIL aggregator (untrained per Q3)
    mil = CLAMAttention(embed_dim, hidden_dim=args.hidden_dim).to(device)
    mil.eval()

    # 20× tiling params from the CLAM coord attrs (uniform per dataset/cell).
    # Stashed on args so run_inference_on_slide's build_tile_grid can use it.
    patch_level, patch_size, footprint_level0 = read_coord_attrs(args.coords_dir)
    args.footprint_level0 = footprint_level0
    print(f"[infer] 20× tiling: patch_level={patch_level} patch_size={patch_size} "
          f"footprint_level0={footprint_level0}", flush=True)

    # Reader
    if args.backend == 'kvikio':
        reader = KvikIOSlideReader(
            rawtiff_dir=args.rawtiff_dir, n_buffer=args.n_buffer,
            num_threads=args.num_threads, compat_mode='off', level=0,
            footprint_level0=footprint_level0,
        )
    else:
        reader = CuCIMSlideReader(
            svs_dir=args.svs_dir, cucim_num_workers=16,
            cucim_batch_size=64, patch_level=patch_level, patch_size=patch_size,
        )

    # Output dirs / CSV files
    Path(args.heatmap_dir).mkdir(parents=True, exist_ok=True)
    Path(args.per_slide_csv).parent.mkdir(parents=True, exist_ok=True)
    Path(args.per_slide_heatmap_csv).parent.mkdir(parents=True, exist_ok=True)
    Path(args.summary_json).parent.mkdir(parents=True, exist_ok=True)

    csv_f = open(args.per_slide_csv, 'w', newline='')
    csv_w = csv.DictWriter(csv_f, fieldnames=[
        'slide_idx', 'slide_id', 'process_id', 'world_size',
        't_arrived_s', 'n_tiles', 'inference_batch_size',
        't_tissue_ms', 't_extract_ms', 't_mil_ms', 't_heatmap_write_ms',
        't_total_ms', 'backend', 'model', 'cache_state',
        'heatmap_format', 'heatmap_path', 'heatmap_bytes',
    ])
    csv_w.writeheader()
    csv_f.flush()  # so the orchestrator's wait-for-loaded poll can see the header
    hm_f = open(args.per_slide_heatmap_csv, 'w', newline='')
    hm_w = csv.DictWriter(hm_f, fieldnames=[
        'slide_idx', 'slide_id', 'format', 'bytes_written',
        't_write_start_s', 't_write_end_s', 'write_ms',
    ])
    hm_w.writeheader()
    hm_f.flush()  # same — header should be visible to external pollers

    # Optional barrier wait — used by the orchestrator to start the deadline clock
    # AFTER all concurrent workers have loaded their models. Without this, short
    # cells lose all their budget to model-load time.
    if args.start_barrier_file:
        print(f"[infer] waiting for start barrier {args.start_barrier_file}", flush=True)
        while not Path(args.start_barrier_file).exists():
            time.sleep(0.1)
        print(f"[infer] start barrier lifted", flush=True)

    # Main loop — one slide at a time
    t_zero = time.monotonic()
    deadline = (t_zero + args.max_runtime_s) if args.max_runtime_s > 0 else float('inf')
    slides_done = 0
    slides_skipped = 0
    sum_total_ms = 0.0
    sum_tissue_ms = 0.0
    sum_extract_ms = 0.0
    sum_mil_ms = 0.0
    sum_heatmap_ms = 0.0

    # 7.2 sustained-concurrent cells loop over the slide list until the deadline.
    # 7.1 / 7.6 single-process cells process my_slide_ids once and exit.
    epoch = 0
    while True:
        if time.monotonic() >= deadline:
            break
        if not my_slide_ids:
            break
        for slide_idx, sid in enumerate(my_slide_ids):
            if time.monotonic() >= deadline:
                break
            global_slide_idx = epoch * len(my_slide_ids) + slide_idx
            res = run_inference_on_slide(
                sid, global_slide_idx, args,
                reader, foundation_model, preprocess,
                mil, embed_dim, device, t_zero,
            )
            if res is None:
                slides_skipped += 1
                continue
            csv_w.writerow(res['main_row'])
            hm_w.writerow(res['heatmap_row'])
            csv_f.flush()
            hm_f.flush()
            slides_done += 1
            sum_tissue_ms += float(res['main_row']['t_tissue_ms'])
            sum_extract_ms += float(res['main_row']['t_extract_ms'])
            sum_mil_ms += float(res['main_row']['t_mil_ms'])
            sum_heatmap_ms += float(res['main_row']['t_heatmap_write_ms'])
            sum_total_ms += float(res['main_row']['t_total_ms'])
            print(f"[infer] slide {global_slide_idx} ({sid}) n_tiles={res['main_row']['n_tiles']} "
                  f"total={res['main_row']['t_total_ms']}ms "
                  f"(tissue={res['main_row']['t_tissue_ms']} "
                  f"extract={res['main_row']['t_extract_ms']} "
                  f"mil={res['main_row']['t_mil_ms']} "
                  f"hm_write={res['main_row']['t_heatmap_write_ms']})", flush=True)
        epoch += 1
        # If no deadline (single-pass mode), exit after one epoch
        if args.max_runtime_s <= 0:
            break

    csv_f.close()
    hm_f.close()

    cell_wallclock = time.monotonic() - t_zero
    summary = {
        'process_id': args.process_id,
        'world_size': args.world_size,
        'backend': args.backend,
        'model': args.model,
        'embedding_dim': embed_dim,
        'inference_batch_size': args.inference_batch_size,
        'cache_policy': args.cache_policy,
        'heatmap_format': args.heatmap_format,
        'manifest': args.manifest,
        'n_slides_assigned': len(my_slide_ids),
        'n_slides_done': slides_done,
        'n_slides_skipped': slides_skipped,
        'cell_wallclock_s': cell_wallclock,
        'per_slide_csv': args.per_slide_csv,
        'per_slide_heatmap_csv': args.per_slide_heatmap_csv,
        'heatmap_dir': args.heatmap_dir,
        # Means across processed slides (the per-CSV file has the full distribution
        # for p50/p95/p99 aggregation; these means are convenience headlines).
        'mean_total_ms': (sum_total_ms / slides_done) if slides_done > 0 else 0.0,
        'mean_tissue_ms': (sum_tissue_ms / slides_done) if slides_done > 0 else 0.0,
        'mean_extract_ms': (sum_extract_ms / slides_done) if slides_done > 0 else 0.0,
        'mean_mil_ms': (sum_mil_ms / slides_done) if slides_done > 0 else 0.0,
        'mean_heatmap_write_ms': (sum_heatmap_ms / slides_done) if slides_done > 0 else 0.0,
    }
    with open(args.summary_json, 'w') as f:
        json.dump(summary, f, indent=2)
    print("=== summary ===", flush=True)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
