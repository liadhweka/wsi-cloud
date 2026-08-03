#!/usr/bin/env python3
"""extract-tiles-to-hdf5.py — Stage 4.A per-slide tile pre-extraction.

Reads CLAM tile-coord HDF5s from Stage 3.0, opens each slide via OpenSlide,
reads each (x, y) coord at the coord's (patch_level, patch_size) and resizes to a
256×256 RGB tile at 20× (CAM16 native level 1; BRCA 512px@40×→256), JPEG-encodes
the tile (production-realistic), and writes a per-slide output HDF5 containing:
  - dataset 'tiles_jpeg': variable-length uint8 byte strings (one JPEG per tile)
  - dataset 'coords': (N_tiles, 2) int64 — same coords as input
  - attrs: slide_id, tile_size, level, n_tiles, jpeg_quality, source_svs

Concurrency via multiprocessing.Pool at the per-slide level (now possible after
the /dev/shm chmod fix from Stage 2 pre-flight).

Usage:
    extract-tiles-to-hdf5.py \
        --concurrency N \
        --svs-dir /mnt/liad/data/<dataset>/ \
        --coords-dir /mnt/liad/tissue-detection/3.0/<dataset>/n64/patches/ \
        --output-dir /mnt/liad/patches/4.A/<dataset>/n<N>/ \
        --latency-csv /tmp/.../<dataset>-n<N>-latencies.csv

Per-slide failures recorded in the latency CSV's `error` column but don't abort
the run — Stage 4.A's benchmark goal is full-dataset throughput, not error-out.
"""
import argparse
import io
import json
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import h5py
import numpy as np
import openslide
from PIL import Image


TILE_SIZE = 256
LEVEL = 0
JPEG_QUALITY = 85


def find_slide(svs_dir, slide_id):
    """Locate the .svs or .tif file for a given slide_id under svs_dir.

    BRCA layout: <svs_dir>/<gdc-uuid>/<slide_id>.svs (nested per-slide subdir).
    CAMELYON16 layout: <svs_dir>/<slide_id>.tif (flat).
    """
    # CAMELYON16 flat
    for ext in (".tif", ".svs"):
        flat = Path(svs_dir) / f"{slide_id}{ext}"
        if flat.exists():
            return flat
    # BRCA nested
    for sub in Path(svs_dir).iterdir():
        if sub.is_dir():
            for ext in (".svs", ".tif"):
                cand = sub / f"{slide_id}{ext}"
                if cand.exists():
                    return cand
    return None


def extract_one(args):
    """Worker: extract all tiles for one slide.

    Returns (slide_id, n_tiles, elapsed_seconds, output_bytes, error_or_None).
    """
    coords_h5_path, svs_dir, output_dir = args
    slide_id = Path(coords_h5_path).stem
    out_h5_path = Path(output_dir) / f"{slide_id}.h5"
    t_start = time.monotonic()
    try:
        # Locate the slide file
        svs_path = find_slide(svs_dir, slide_id)
        if svs_path is None:
            return slide_id, 0, time.monotonic() - t_start, 0, f"slide_file_not_found"

        # Read coords from CLAM HDF5
        with h5py.File(coords_h5_path, "r") as f:
            coords = f["coords"][()]
            patch_level = int(f["coords"].attrs.get("patch_level", 0))
            patch_size_in = int(f["coords"].attrs.get("patch_size", TILE_SIZE))

        n_tiles = int(coords.shape[0])
        if n_tiles == 0:
            # No tissue contours → no tiles. Write empty output for completeness.
            with h5py.File(out_h5_path, "w") as f:
                vlen_bytes = h5py.special_dtype(vlen=np.dtype("uint8"))
                f.create_dataset("tiles_jpeg", (0,), dtype=vlen_bytes)
                f.create_dataset("coords", data=coords)
                f.attrs["slide_id"] = slide_id
                f.attrs["tile_size"] = TILE_SIZE
                f.attrs["level"] = patch_level
                f.attrs["n_tiles"] = 0
                f.attrs["jpeg_quality"] = JPEG_QUALITY
                f.attrs["source_svs"] = str(svs_path)
            return slide_id, 0, time.monotonic() - t_start, out_h5_path.stat().st_size, None

        # Open slide + extract + JPEG-encode
        slide = openslide.OpenSlide(str(svs_path))
        jpeg_blobs = []
        for x, y in coords:
            # 20× tile: read at the CLAM coord's (patch_level, patch_size), then
            # resize to the uniform 256px@20× output. CAM16: patch_level=1,
            # patch_size=256 (native 20× — resize is a no-op). BRCA: patch_level=0,
            # patch_size=512 (40×) → resize to 256 = 20×. Coords are level-0 refs,
            # so the location arg is unchanged. This is exactly CLAM custom_downsample
            # / Trident --mag 20 done in-process.
            region = slide.read_region((int(x), int(y)), patch_level, (patch_size_in, patch_size_in))
            rgb = region.convert("RGB")
            if patch_size_in != TILE_SIZE:
                rgb = rgb.resize((TILE_SIZE, TILE_SIZE), Image.BILINEAR)
            buf = io.BytesIO()
            rgb.save(buf, format="JPEG", quality=JPEG_QUALITY)
            jpeg_blobs.append(np.frombuffer(buf.getvalue(), dtype=np.uint8))
        slide.close()

        # Write HDF5 with variable-length JPEG bytes
        vlen_bytes = h5py.special_dtype(vlen=np.dtype("uint8"))
        with h5py.File(out_h5_path, "w") as f:
            tiles_ds = f.create_dataset("tiles_jpeg", (n_tiles,), dtype=vlen_bytes)
            for i, blob in enumerate(jpeg_blobs):
                tiles_ds[i] = blob
            f.create_dataset("coords", data=coords)
            f.attrs["slide_id"] = slide_id
            f.attrs["tile_size"] = TILE_SIZE
            f.attrs["level"] = patch_level
            f.attrs["n_tiles"] = n_tiles
            f.attrs["jpeg_quality"] = JPEG_QUALITY
            f.attrs["source_svs"] = str(svs_path)
            f.attrs["clam_patch_level"] = patch_level
            f.attrs["clam_patch_size"] = patch_size_in

        elapsed = time.monotonic() - t_start
        out_bytes = out_h5_path.stat().st_size
        return slide_id, n_tiles, elapsed, out_bytes, None

    except Exception as e:
        elapsed = time.monotonic() - t_start
        return slide_id, 0, elapsed, 0, f"{type(e).__name__}: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--concurrency", type=int, required=True)
    ap.add_argument("--svs-dir", required=True,
                    help="Dataset dir containing .svs / .tif files")
    ap.add_argument("--coords-dir", required=True,
                    help="Dir of per-slide CLAM coord HDF5s (Stage 3.0 patches/)")
    ap.add_argument("--output-dir", required=True,
                    help="Output dir for per-slide tile HDF5s")
    ap.add_argument("--latency-csv", required=True)
    ap.add_argument("--manifest", default=None,
                    help="Optional TSV with 'slide_id' header column. If set, "
                         "filter coord files to only those slide_ids. Lines "
                         "starting with '#' are skipped.")
    args = ap.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    all_coord_files = sorted(Path(args.coords_dir).glob("*.h5"))
    if args.manifest:
        wanted = set()
        with open(args.manifest) as mf:
            for line in mf:
                line = line.strip()
                if not line or line.startswith("#") or line == "slide_id":
                    continue
                wanted.add(line.split("\t")[0])
        coord_files = [p for p in all_coord_files if p.stem in wanted]
        if not coord_files:
            print(f"[extract] FATAL: manifest filter selected 0 of "
                  f"{len(all_coord_files)} coord files", flush=True)
            sys.exit(2)
        missing = wanted - {p.stem for p in coord_files}
        print(f"[extract] manifest filter: {len(coord_files)} of "
              f"{len(all_coord_files)} slides selected from {args.manifest}",
              flush=True)
        if missing:
            print(f"[extract] WARN: {len(missing)} manifest slide_ids had no "
                  f"matching coord file (e.g. {sorted(missing)[:3]})", flush=True)
    else:
        coord_files = all_coord_files
    print(f"[extract] coord_files: {len(coord_files)} slides", flush=True)
    print(f"[extract] concurrency: {args.concurrency}", flush=True)
    print(f"[extract] svs_dir:     {args.svs_dir}", flush=True)
    print(f"[extract] output_dir:  {output_dir}", flush=True)
    print(f"[extract] starting", flush=True)

    work = [(str(p), args.svs_dir, str(output_dir)) for p in coord_files]

    successes = failures = 0
    total_tiles = 0
    total_bytes = 0
    t_start = time.monotonic()
    with open(args.latency_csv, "w") as csvf:
        csvf.write("slide_id,n_tiles,elapsed_seconds,output_bytes,error\n")
        with Pool(processes=args.concurrency) as pool:
            for slide_id, n_tiles, elapsed, out_bytes, err in pool.imap_unordered(extract_one, work):
                err_field = "" if err is None else err.replace(",", ";").replace("\n", " ")
                csvf.write(f"{slide_id},{n_tiles},{elapsed:.6f},{out_bytes},{err_field}\n")
                if err is None:
                    successes += 1
                    total_tiles += n_tiles
                    total_bytes += out_bytes
                else:
                    failures += 1
                    print(f"[extract] FAIL {slide_id}: {err}", flush=True)
    t_total = time.monotonic() - t_start

    rate_slides = len(coord_files) / t_total if t_total > 0 else 0.0
    rate_tiles = total_tiles / t_total if t_total > 0 else 0.0
    rate_bytes = total_bytes / t_total if t_total > 0 else 0.0

    print(f"=== summary ===", flush=True)
    print(f"slides_total:      {len(coord_files)}", flush=True)
    print(f"slides_success:    {successes}", flush=True)
    print(f"slides_failed:     {failures}", flush=True)
    print(f"total_tiles:       {total_tiles}", flush=True)
    print(f"total_bytes:       {total_bytes}", flush=True)
    print(f"total_seconds:     {t_total:.3f}", flush=True)
    print(f"slides_per_second: {rate_slides:.3f}", flush=True)
    print(f"tiles_per_second:  {rate_tiles:.0f}", flush=True)
    print(f"bytes_per_second:  {rate_bytes:.0f}", flush=True)
    print(f"concurrency:       {args.concurrency}", flush=True)

    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
