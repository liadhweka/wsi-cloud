#!/usr/bin/env python3
"""convert-rawtiff-20x.py — Stage 4.C / 6.A prep: SVS/.tif → 20× uncompressed
tiled raw TIFF for the kvikIO+GDS path (the "Option B" 20× artifact).

Produces a SINGLE-LEVEL, 256×256-tiled, uncompressed (compression=None), RGB
uint8 TIFF whose level-0 IS the 20× image — so kvikIO reads level-0 byte-ranges
directly as 256px@20× tiles, and CLAM coords (level-0/40× px, stepping by 512)
map to a tile index via coord // 512.

WHY a custom writer instead of `cucim convert`: cucim convert always treats the
SVS's OpenSlide level 0 (= 40× base) as the output level-0 (it has no --mag /
--level flag — verified against cucim 26.4.0 cli.py + the 2026-06-17 tooling
research), so it can only emit a 40× raw-TIFF. We need a true 20× artifact:
~4× smaller, ~4× faster downstream, and it is what a 20× GPU-direct customer
actually stores. The throughput a storage benchmark measures is identical to
reading the matching level of a 40× file, but the file size / layout / total
bytes — which a storage benchmark also cares about — are the real 20× ones.

Per-dataset 20× read (the SAME contract the SVS readers use — see SCRIPT-TRACKER
"20× coord-space contract"):
  - CAMELYON16 (.tif): --read-level 1 --read-size 256  (native 20× level, no resize)
  - TCGA-BRCA  (.svs): --read-level 0 --read-size 512  (read 512px@40× → resize 256 = 20×)
For both, footprint = read_size * level_downsample(read_level) = 512 level-0 px
per output tile, so the output 20× grid is dense from origin (0, 0) and matches
the CLAM coord grid exactly (coord // 512 == output tile index).

Output tile bytes = 256*256*3 = 196608 (uncompressed), uniform across tiles →
kvikIO 4096-aligned byte-range reads work exactly as in the Stage 4.C reader.

Resampling: PIL BOX (area-average) for the 512→256 downsample, matching the GPU
`interpolate(mode="area")` the cuCIM on-the-fly readers use — so the kvikIO
raw-TIFF tiles and the cuCIM on-the-fly tiles are the same pixels, keeping the
two backends apples-to-apples.

Usage:
  convert-rawtiff-20x.py --src slide.svs --dst out.tiff --read-level 0 --read-size 512
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np
import openslide
import tifffile
from PIL import Image


OUT_TILE = 256  # output (20×) tile size in px


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="source WSI (.svs / .tif)")
    ap.add_argument("--dst", required=True, help="output 20× raw TIFF path")
    ap.add_argument("--read-level", type=int, required=True,
                    help="OpenSlide pyramid level to read (CAM16: 1 = native 20×; BRCA: 0 = 40×)")
    ap.add_argument("--read-size", type=int, required=True,
                    help="read tile size in read-level px (CAM16: 256; BRCA: 512 → resized to 256)")
    ap.add_argument("--tile", type=int, default=OUT_TILE,
                    help="output (20×) tile size px (default 256)")
    args = ap.parse_args()

    slide = openslide.OpenSlide(args.src)
    if args.read_level >= slide.level_count:
        print(f"[convert] FATAL: {args.src} has {slide.level_count} levels, "
              f"requested read-level {args.read_level}", file=sys.stderr)
        sys.exit(2)

    W0, H0 = slide.level_dimensions[0]
    ds = float(slide.level_downsamples[args.read_level])
    # level-0 (40×) px spanned by one output tile (= the CLAM coord footprint, 512).
    footprint = int(round(args.read_size * ds))

    # Fail-loud magnification guard (Option A defense-in-depth): the output tile MUST
    # be 20× (mpp≈0.5). effective_out_mpp = base_mpp * level_downsample[read_level] *
    # (read_size/tile). A 40×-base slide read 512@L0→256 gives 0.5; a 20×-base slide
    # read the same way gives 1.0 (=10×). Refuse rather than silently mis-tile — the
    # full-BRCA cohort is pre-filtered to 40×-mpp slides, so this should never fire.
    base_mpp = slide.properties.get("openslide.mpp-x")
    try:
        eff_mpp = float(base_mpp) * ds * (args.read_size / args.tile)
    except (TypeError, ValueError):
        slide.close()
        print(f"[convert] FATAL: {args.src} has no openslide.mpp-x — cannot verify it is a "
              f"40×-base slide; refusing (the 20× cohort expects uniform 40× base).", file=sys.stderr)
        sys.exit(3)
    if not (0.4 <= eff_mpp <= 0.65):
        slide.close()
        print(f"[convert] FATAL: {args.src}: read-level={args.read_level} read-size={args.read_size} "
              f"→ effective output mpp={eff_mpp:.3f} (not ~0.5 = 20×; base mpp={base_mpp}). This slide's "
              f"magnification doesn't match the 20× read params — refusing to silently mis-tile. "
              f"Exclude it from the cohort (it isn't in the 40×-mpp manifest).", file=sys.stderr)
        sys.exit(3)

    n_cols = math.ceil(W0 / footprint)
    n_rows = math.ceil(H0 / footprint)
    out_W = n_cols * args.tile
    out_H = n_rows * args.tile
    print(f"[convert] {Path(args.src).name}: level0={W0}x{H0} read-level={args.read_level} "
          f"read-size={args.read_size} ds={ds:.3f} footprint={footprint} "
          f"grid={n_cols}x{n_rows} out={out_W}x{out_H}", file=sys.stderr, flush=True)

    def gen_tiles():
        # tifffile writes tiles row-major (left→right, top→bottom).
        for tr in range(n_rows):
            for tc in range(n_cols):
                # OpenSlide read_region: location ALWAYS in level-0 px, size in read-level px.
                loc = (tc * footprint, tr * footprint)
                region = slide.read_region(loc, args.read_level,
                                           (args.read_size, args.read_size)).convert("RGB")
                if args.read_size != args.tile:
                    region = region.resize((args.tile, args.tile), Image.BOX)
                yield np.asarray(region, dtype=np.uint8)

    with tifffile.TiffWriter(args.dst, bigtiff=True) as tw:
        tw.write(
            gen_tiles(),
            shape=(out_H, out_W, 3),
            dtype=np.uint8,
            tile=(args.tile, args.tile),
            photometric="rgb",
            compression=None,   # uncompressed RAW for kvikIO byte-range reads
        )
    slide.close()
    print(f"[convert] wrote {args.dst} ({out_W}x{out_H}, {n_rows * n_cols} tiles)",
          file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
