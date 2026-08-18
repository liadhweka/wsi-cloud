#!/usr/bin/env python3
"""read-tiles-kvikio.py — Stage 4.C reader: kvikIO + raw TIFF + (optional) GDS.

Two methodology modes, mirroring NVIDIA's gds_whole_slide reference + Stage 4.B's
random-tile pattern.

  --mode faithful : Sequential full-pyramid-level-0 read of each subset slide.
                    Modeled on NVIDIA's demo_implementation.read_tiled() in
                    cucim/examples/python/gds_whole_slide/demo_implementation.py.
                    Iterates page.dataoffsets in order, async-pread n_buffer at a
                    time into pre-allocated CuPy buffers. Cold cache discarded
                    between slides via cucim.clara.filesystem.discard_page_cache.
                    Per-slide wallclock + aggregate-cell statistics.

  --mode random   : Random tile-byte-range reads from CLAM coord pools mapped to
                    raw-TIFF tile grid. Apples-to-apples with Stage 4.B's
                    read-tiles-onthefly.py but using kvikIO instead of cuCIM.
                    Time-based (runtime + ramp), LRU(8) slide-handle cache,
                    per-tile latency sampled.

WHY two modes under one script:
  - 4.C.1 (faithful) lifts NVIDIA's exact benchmark onto the filesystem under test for direct
    comparison to their published GDS-vs-POSIX speedup pattern (the blog's
    "11.8× with GDS" framing).
  - 4.C.2 (random) measures the same access pattern Stage 4.B characterized
    (random tile reads from a coord pool) but via the GPU-direct path, giving
    apples-to-apples comparison vs 4.B's cuCIM CPU batched winner.

WHY 4096-byte aligned reads (NVIDIA's _get_aligned_read_props helper):
  - cuFile silently falls back to a broken POSIX path on unaligned offsets
    (errno EBADF), which surfaces as "Operation not permitted" at the Python
    layer. NVIDIA's reference code handles this; we must too.

WHY the system libcufile via LD_PRELOAD:
  - The conda env bundles its own libcufile, which is not matched to the
    kernel's nvidia-fs module. Caller must LD_PRELOAD the system libcufile
    matched to the loaded nvidia-fs (the wrapper script handles this via
    $LIBCUFILE_PRELOAD).

WHY per-process CUFILE_ENV_PATH_JSON:
  - The cuFile config is per-instance, per-leg state. Caller provides this
    leg's config via env var without touching system files.

WHY compat_mode flag exposed as a sweep axis:
  - Every Stage 4.C cell measures BOTH GDS-on (kvikio.CompatMode.OFF) and
    POSIX-compat (kvikio.CompatMode.ON) so we directly characterize the GDS
    speedup on the filesystem under test at every config.

Required environment (caller / wrapper script's responsibility):
  CONDA_PREFIX=$CONDA_ENVS_DIR/$CONDA_ENV_MAIN
  LD_PRELOAD=$LIBCUFILE_PRELOAD          # the SYSTEM libcufile matched to nvidia-fs
  CUFILE_ENV_PATH_JSON=${CUFILE_ENV_PATH_JSON}

Usage (4.C.1 faithful):
  $0 \
    --mode faithful \
    --rawtiff-dir $FS_MOUNT/data/tcga-brca-rawtiff \
    --manifest scripts/manifests/tcga-brca-stage4a-subset.tsv \
    --compat-mode off --n-buffer 256 --num-threads 16 \
    --level 0 \
    --summary-json /tmp/cell-summary.json

Usage (4.C.2 random):
  $0 \
    --mode random \
    --rawtiff-dir $FS_MOUNT/data/tcga-brca-rawtiff \
    --coords-dir $FS_MOUNT/tissue-detection/3.0/tcga-brca/n64/patches \
    --manifest scripts/manifests/tcga-brca-stage4a-subset.tsv \
    --compat-mode off --n-buffer 256 --num-threads 16 \
    --runtime 60 --ramp 10 \
    --latency-csv /tmp/per-tile-latencies.csv \
    --summary-json /tmp/cell-summary.json
"""
import argparse
import json

# Same-directory import: cuFile path accounting (D-6/D8) — a config flag is not
# proof of which path a read took, so every cell records the byte split.
sys_path_note = None
from wsi_cufile_accounting import PathAccounting
import os
import random
import sys
import time
from collections import OrderedDict
from pathlib import Path

import cupy as cp
import h5py
import kvikio
import kvikio.defaults
import numpy as np
from cucim.clara import filesystem as cucim_fs
from tifffile import TiffFile


# -----------------------------------------------------------------------------
# NVIDIA's alignment helper, lifted verbatim from demo_implementation.py.
# WHY: cuFile requires 4096-byte aligned offsets and sizes. Random tile offsets
# in TIFF files are not naturally aligned. This rounds offsets down and bytecounts
# up; we then trim the buffer to retrieve the actual tile data.
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
# Common kvikIO setup. Establishes the global defaults that every cell uses.
# Reports back to caller via stderr for the run-dir 0_README to capture.
# -----------------------------------------------------------------------------
def setup_kvikio(compat_mode_str, num_threads, task_size_bytes=None):
    """Set kvikio defaults and return the loaded libcufile path for traceability."""
    mode_map = {"off": kvikio.CompatMode.OFF, "on": kvikio.CompatMode.ON, "auto": kvikio.CompatMode.AUTO}
    if compat_mode_str.lower() not in mode_map:
        raise SystemExit(f"--compat-mode must be one of {list(mode_map)}, got {compat_mode_str!r}")
    kvikio.defaults.set("compat_mode", mode_map[compat_mode_str.lower()])
    kvikio.defaults.set("num_threads", int(num_threads))
    if task_size_bytes is not None:
        kvikio.defaults.set("task_size", int(task_size_bytes))

    libcufile_path = None
    with open(f"/proc/{os.getpid()}/maps") as f:
        for line in f:
            if "libcufile.so" in line:
                libcufile_path = line.strip().split()[-1]
                break

    print(
        f"[kvikio] version={kvikio.__version__} "
        f"compat_mode={kvikio.defaults.get('compat_mode')} "
        f"num_threads={kvikio.defaults.get('num_threads')} "
        f"task_size={kvikio.defaults.get('task_size')} "
        f"libcufile={libcufile_path} "
        f"CUFILE_ENV_PATH_JSON={os.environ.get('CUFILE_ENV_PATH_JSON', '<unset>')}",
        file=sys.stderr,
    )
    return libcufile_path


# -----------------------------------------------------------------------------
# Manifest loading. Stage 4.A subset manifests have a 5-line header (commented
# metadata + "slide_id" column header on line 5), then slide IDs.
# -----------------------------------------------------------------------------
def load_manifest(path):
    slide_ids = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#") or ln == "slide_id":
                continue
            slide_ids.append(ln)
    return slide_ids


def find_rawtiff(rawtiff_dir, slide_id):
    p = Path(rawtiff_dir) / f"{slide_id}.tiff"
    if p.exists():
        return p
    return None


# -----------------------------------------------------------------------------
# Mode 1: faithful — sequential full-pyramid-level-0 read per slide.
# Reads the entire chosen pyramid level into GPU memory by iterating through
# page.dataoffsets in order, async-pread'ing n_buffer at a time.
# WHY this matches NVIDIA's benchmark: their read_tiled() iterates the same way,
# so each filesystem is measured absorbing the same published blueprint.
# -----------------------------------------------------------------------------
def faithful_read_slide(fh, page, n_buffer, buffers):
    """Read all tiles in `page` via async pread+pipelining. Returns bytes_read."""
    offsets = np.asarray(page.dataoffsets, dtype=np.int64)
    bytecounts = np.asarray(page.databytecounts, dtype=np.int64)
    n_tiles = len(offsets)

    rounded_offs, rounded_bcs, _buf_offs = aligned_read_props(offsets, bytecounts)
    # In uncompressed TIFF, all tile bytecounts are equal — but we use max to size buffers.
    max_buf_size = int(rounded_bcs.max())
    # If our buffers are too small, the caller should have pre-checked.
    if buffers[0].size < max_buf_size:
        raise RuntimeError(
            f"tile buffers too small: have {buffers[0].size}, need {max_buf_size}"
        )

    futures = []
    for i in range(n_tiles):
        off = int(rounded_offs[i])
        bc = int(rounded_bcs[i])
        buf = buffers[i % n_buffer]
        fut = fh.pread(buf[:bc], file_offset=off)
        futures.append(fut)
        if len(futures) >= n_buffer:
            for f in futures:
                f.get()
            futures = []
    for f in futures:
        f.get()
    return int(rounded_bcs.sum())  # bytes actually transferred (aligned size)


def mode_faithful(args):
    setup_kvikio(args.compat_mode, args.num_threads, args.task_size)
    acct = PathAccounting(requested_compat_mode=args.compat_mode)
    slide_ids = load_manifest(args.manifest)
    print(f"[faithful] manifest has {len(slide_ids)} slides", file=sys.stderr)

    # Pre-allocate tile buffers ONCE (reused across all slides). For raw TIFF
    # at tile_size=256×256, every slide has the same per-tile byte size, so this
    # is safe. We size to the maximum aligned bytecount = 256×256×3 + 4096 alignment.
    # (We size with a generous margin and re-check per slide.)
    BUF_SIZE_MAX = 256 * 256 * 3 + 4096  # ≈ 201,856
    tile_buffers = [cp.empty(BUF_SIZE_MAX, dtype=cp.uint8) for _ in range(args.n_buffer)]

    if args.preregister:
        for b in tile_buffers:
            kvikio.memory_register(b)

    per_slide = []
    cell_t0 = time.monotonic()
    n_skipped_missing = 0
    n_skipped_timecap = 0
    n_discard_attempted = 0
    n_discard_failed = 0

    # WHY --max-duration: at slow configs (e.g. n_buffer=1 + POSIX-compat) reading
    # the full 50-slide BRCA subset could take many hours (extrapolating from
    # pre-flight: ~0.16 GB/s × 1.08 TB ≈ 2 hr per cell). Capping cell wallclock
    # at --max-duration gives a partial-but-statistically-valid sample (per-slide
    # tps/GBps numbers from the slides that DID complete are valid measurements).
    # Default 600s = 10 min, more than enough for the GDS-on cells (~5 min for
    # all 50 slides at peak) and bounded for the worst-case POSIX-low-n_buffer.
    deadline = cell_t0 + args.max_duration if args.max_duration else None

    for slide_id in slide_ids:
        if deadline is not None and time.monotonic() >= deadline:
            n_skipped_timecap += 1
            continue
        path = find_rawtiff(args.rawtiff_dir, slide_id)
        if path is None:
            n_skipped_missing += 1
            print(f"[faithful] SKIP-MISSING: {slide_id} not found at {args.rawtiff_dir}", file=sys.stderr)
            continue

        # Cold cache between slides — critical for any cell quoted as a COLD read.
        # The result is RECORDED, not assumed: cuCIM reports a failed discard by
        # RETURNING False rather than raising (docs.rapids.ai/api/cucim/stable/api/
        # — "Returns: True if succeed, False otherwise"), so discarding the return
        # value leaves a slide that was read WARM inside a cell whose recorded note
        # calls it cold, with nothing in the output able to tell them apart
        # (thesis §11.5 — a cache state asserted rather than recorded).
        if not args.warm_cache:
            n_discard_attempted += 1
            if not cucim_fs.discard_page_cache(str(path)):
                n_discard_failed += 1
                print(f"[faithful] DISCARD-FAILED: {slide_id} — read WARM, not cold",
                      file=sys.stderr)

        with TiffFile(str(path)) as tif:
            if args.level >= len(tif.pages):
                print(f"[faithful] SKIP: {slide_id} has {len(tif.pages)} pages, requested level={args.level}", file=sys.stderr)
                continue
            page = tif.pages[args.level]
            n_tiles = len(page.dataoffsets)
            tile_bytes = int(page.databytecounts[0]) if n_tiles else 0

        fh = kvikio.CuFile(str(path), "r")
        t0 = time.monotonic()
        try:
            with TiffFile(str(path)) as tif:
                page = tif.pages[args.level]
                bytes_transferred = faithful_read_slide(fh, page, args.n_buffer, tile_buffers)
        finally:
            fh.close()
        elapsed = time.monotonic() - t0

        per_slide.append({
            "slide_id": slide_id,
            "level": args.level,
            "n_tiles": n_tiles,
            "tile_bytes_useful": tile_bytes,
            "bytes_aligned_transferred": bytes_transferred,
            "wallclock_s": elapsed,
            "tiles_per_sec": n_tiles / elapsed if elapsed > 0 else 0.0,
            "gbps_aligned": bytes_transferred / elapsed / 1e9 if elapsed > 0 else 0.0,
        })
        print(
            f"[faithful] {slide_id}: {n_tiles} tiles in {elapsed*1000:.1f} ms "
            f"= {per_slide[-1]['tiles_per_sec']:.0f} tiles/sec, "
            f"{per_slide[-1]['gbps_aligned']:.2f} GB/s",
            file=sys.stderr,
        )

    cell_wall = time.monotonic() - cell_t0

    if args.preregister:
        for b in tile_buffers:
            kvikio.memory_deregister(b)

    # Aggregate
    total_tiles = sum(s["n_tiles"] for s in per_slide)
    total_bytes = sum(s["bytes_aligned_transferred"] for s in per_slide)
    total_slide_wall = sum(s["wallclock_s"] for s in per_slide)
    summary = {
        "mode": "faithful",
        "compat_mode": args.compat_mode,
        "n_buffer": args.n_buffer,
        "num_threads": args.num_threads,
        "task_size": args.task_size or kvikio.defaults.get("task_size"),
        "preregister": args.preregister,
        "level": args.level,
        "manifest": args.manifest,
        "rawtiff_dir": args.rawtiff_dir,
        "n_slides_attempted": len(slide_ids),
        "n_slides_read": len(per_slide),
        "n_slides_missing": n_skipped_missing,
        "n_slides_skipped_timecap": n_skipped_timecap,
        "max_duration_s": args.max_duration,
        # Cache state: what was REQUESTED (the --warm-cache flag) and what the
        # discard ACHIEVED. Without the achieved half, a cell that never dropped
        # a single page still reports as the cold arm of the 4.C matrix, and the
        # compat=on / compat=off arms have different page-cache behaviour, so the
        # matrix could not be corrected for it after the fact.
        "warm_cache_requested": bool(args.warm_cache),
        "n_page_cache_discards_attempted": n_discard_attempted,
        "n_page_cache_discards_failed": n_discard_failed,
        # The D13 reconciler's field (wsi_agg_helper.py cache): null = not
        # attempted (warm cell); false = any discard FAILED, which CONTRADICTS
        # a cold declaration rather than footnoting it.
        "client_page_cache_discarded": (None if args.warm_cache or n_discard_attempted == 0
                                        else n_discard_failed == 0),
        # Client page cache only. Neither filesystem's server-side cache is
        # addressed by this discard and the per-filesystem cold mechanism is still
        # open (A.5 / D13), so the end-to-end cold state is stated as unknown
        # EXPLICITLY rather than left to be inferred from a missing field.
        "cache_state_achieved": "unknown",
        "total_tiles": total_tiles,
        "total_bytes_aligned": total_bytes,
        # D-6/D8: the recorded GPU-direct-vs-bounced byte split — the achieved
        # path, distinct from compat_mode above (the request). Under
        # multi-process cells the nvidia-fs delta is device-global, so the
        # per-process split is an upper bound; the cell-level split comes from
        # the wrapper's recorded nvidia-fs timeline.
        "path_accounting": acct.finish(total_bytes),
        "cell_wallclock_s": cell_wall,
        "sum_slide_wallclock_s": total_slide_wall,
        "tiles_per_sec_cell": total_tiles / cell_wall if cell_wall > 0 else 0.0,
        "gbps_cell": total_bytes / cell_wall / 1e9 if cell_wall > 0 else 0.0,
        "per_slide": per_slide,
    }

    # Emit summary block on stdout so record-run.sh / aggregator can parse it.
    print("=== summary ===")
    print(json.dumps(summary, indent=2))
    if args.summary_json:
        with open(args.summary_json, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"[faithful] summary written to {args.summary_json}", file=sys.stderr)

    return summary


# -----------------------------------------------------------------------------
# Mode 2: random — random tile-byte-range reads from CLAM coord pool.
# Mirrors Stage 4.B's read-tiles-onthefly.py but with kvikIO instead of cuCIM.
# Maps CLAM (x, y) pixel coords → raw-TIFF tile grid → file byte-range.
# -----------------------------------------------------------------------------
def build_random_coord_pool(coords_dir, manifest_slide_ids):
    """Returns a list of (slide_id, [coord_index_list]) for slides in the manifest."""
    pool = []
    for sid in manifest_slide_ids:
        h5_path = Path(coords_dir) / f"{sid}.h5"
        if not h5_path.exists():
            continue
        with h5py.File(h5_path, "r") as f:
            coords = f["coords"][()]
        if coords.shape[0] == 0:
            continue
        pool.append((sid, coords))
    return pool


def load_tiff_index(path, level):
    """Read tile-grid metadata + offsets once per slide; cache the arrays."""
    with TiffFile(str(path)) as tif:
        if level >= len(tif.pages):
            return None
        page = tif.pages[level]
        offsets = np.asarray(page.dataoffsets, dtype=np.int64)
        bytecounts = np.asarray(page.databytecounts, dtype=np.int64)
        return {
            "shape": page.shape,                # (height, width, channels)
            "tile_height": page.tilelength,
            "tile_width": page.tilewidth,
            "n_tiles_per_row": (page.shape[1] + page.tilewidth - 1) // page.tilewidth,
            "n_tiles_per_col": (page.shape[0] + page.tilelength - 1) // page.tilelength,
            "offsets": offsets,
            "bytecounts": bytecounts,
        }


def coord_footprint_level0(coords_dir):
    """Level-0 (40×) px between adjacent CLAM tiles = patch_size * level-0
    downsample (512 at 20× for both datasets). This is the coord→tile divisor
    for the 20×/256-tiled raw-TIFF (Option B), replacing the old tile_width(256).
    Reads the first coord HDF5's attrs (uniform per dataset)."""
    for h5_path in sorted(Path(coords_dir).glob("*.h5")):
        with h5py.File(h5_path, "r") as f:
            a = f["coords"].attrs
            ps = int(a.get("patch_size", 256))
            ds = a.get("downsample", [1.0, 1.0])
            ds0 = float(ds[0]) if hasattr(ds, "__len__") else float(ds)
        return int(round(ps * ds0))
    return 256


def pixel_to_tile_index(x_pixel, y_pixel, idx_meta, footprint_level0):
    """Map a CLAM (x_pixel, y_pixel) level-0 (40×) coord to a raw-TIFF tile index.
    20×: divide by footprint_level0 (512, = the coord spacing in level-0 px), NOT
    the raw-TIFF tile_width (256) — the raw-TIFF is 20×/256-tiled (Option B)."""
    tile_col = int(x_pixel) // footprint_level0
    tile_row = int(y_pixel) // footprint_level0
    # Clamp to valid range
    tile_col = max(0, min(tile_col, idx_meta["n_tiles_per_row"] - 1))
    tile_row = max(0, min(tile_row, idx_meta["n_tiles_per_col"] - 1))
    return tile_row * idx_meta["n_tiles_per_row"] + tile_col


def mode_random(args):
    setup_kvikio(args.compat_mode, args.num_threads, args.task_size)
    acct = PathAccounting(requested_compat_mode=args.compat_mode)
    slide_ids = load_manifest(args.manifest)
    print(f"[random] manifest has {len(slide_ids)} slides", file=sys.stderr)

    # Coord pool: list of (slide_id, coords_array). Per worker we'll randomly
    # pick a slide then a random coord.
    coord_pool = build_random_coord_pool(args.coords_dir, slide_ids)
    print(f"[random] coord pool: {len(coord_pool)} slides with non-empty CLAM coords", file=sys.stderr)
    if not coord_pool:
        raise SystemExit("[random] no slides in coord pool — aborting")
    # 20×: coord→tile divisor is the level-0 footprint (512), not the raw tile width.
    footprint_level0 = coord_footprint_level0(args.coords_dir)
    print(f"[random] 20× coord footprint_level0={footprint_level0} (coord→tile divisor)", file=sys.stderr)

    # Pre-allocate tile buffers (single-process for now; multi-process scaling
    # cells will be driven externally via the sweep script).
    BUF_SIZE_MAX = 256 * 256 * 3 + 4096
    tile_buffers = [cp.empty(BUF_SIZE_MAX, dtype=cp.uint8) for _ in range(args.n_buffer)]
    if args.preregister:
        for b in tile_buffers:
            kvikio.memory_register(b)

    rng = random.Random(args.seed)
    # LRU(N) handle + tiff-index cache. Reading TIFF index from disk is slow;
    # caching it matches what a production DataLoader would do.
    slide_cache = OrderedDict()  # slide_id -> {handle, idx_meta}
    LRU_SIZE = args.lru_size

    def get_slide(slide_id):
        if slide_id in slide_cache:
            slide_cache.move_to_end(slide_id)
            return slide_cache[slide_id]
        if len(slide_cache) >= LRU_SIZE:
            _, evicted = slide_cache.popitem(last=False)
            try:
                evicted["handle"].close()
            except Exception:
                pass
        path = find_rawtiff(args.rawtiff_dir, slide_id)
        if path is None:
            return None
        idx_meta = load_tiff_index(path, args.level)
        if idx_meta is None:
            return None
        handle = kvikio.CuFile(str(path), "r")
        entry = {"handle": handle, "idx_meta": idx_meta, "path": path}
        slide_cache[slide_id] = entry
        return entry

    n_discard_attempted = 0
    n_discard_failed = 0

    # Pre-discard caches on initial slides to ensure first iterations are cold.
    # (Subsequent same-slide reads will reuse the kernel page cache via warm
    # path; that's realistic for production DataLoaders too.)
    # RECORDED, not assumed — same reason as faithful mode: cuCIM signals failure
    # by returning False, so an ignored return value turns "cold on first LRU
    # fill" into a claim with no evidence behind it (thesis §11.5). It matters
    # more here than in faithful mode, because this loop is the ONLY cold step in
    # a cell that then re-reads the same LRU-resident slides for the full runtime.
    if not args.warm_cache:
        for sid, _coords in coord_pool[:LRU_SIZE]:
            path = find_rawtiff(args.rawtiff_dir, sid)
            if path is not None:
                n_discard_attempted += 1
                if not cucim_fs.discard_page_cache(str(path)):
                    n_discard_failed += 1
                    print(f"[random] DISCARD-FAILED: {sid} — entered the pool WARM",
                          file=sys.stderr)

    n_tiles_done_total = 0
    n_tiles_done_steady = 0
    bytes_steady = 0
    per_tile_latencies = []  # sampled 1-in-K
    LATENCY_SAMPLE_RATE = args.latency_sample_rate

    t_start = time.monotonic()
    t_steady_start = t_start + args.ramp
    t_end = t_start + args.ramp + args.runtime
    in_flight = []  # list of (fut, t_call_start, slide_id, tile_idx)

    while time.monotonic() < t_end:
        sid, coords = rng.choice(coord_pool)
        slide = get_slide(sid)
        if slide is None:
            continue
        # Pick a random coord, translate to tile index
        coord_row = coords[rng.randrange(coords.shape[0])]
        x_pixel, y_pixel = int(coord_row[0]), int(coord_row[1])
        tile_idx = pixel_to_tile_index(x_pixel, y_pixel, slide["idx_meta"], footprint_level0)

        # Aligned read
        off = int(slide["idx_meta"]["offsets"][tile_idx])
        bc = int(slide["idx_meta"]["bytecounts"][tile_idx])
        rounded_offs, rounded_bcs, _ = aligned_read_props([off], [bc])
        ro = int(rounded_offs[0])
        rbc = int(rounded_bcs[0])

        buf = tile_buffers[len(in_flight) % args.n_buffer]
        t_call = time.monotonic()
        fut = slide["handle"].pread(buf[:rbc], file_offset=ro)
        in_flight.append((fut, t_call, sid, tile_idx))

        if len(in_flight) >= args.n_buffer:
            # Per-tile latency is stamped INSIDE the drain, once each future has
            # actually returned. Sampling a single timestamp before the drain --
            # as this once did -- subtracts the submit time from a clock read
            # taken before any I/O had been waited on, so the recorded latency
            # EXCLUDED the I/O wait entirely. That is the headline latency of the
            # GPU-direct path, so the number was not merely optimistic: it
            # measured submit overhead and nothing else.
            #
            # What this measures: submit -> observed completion, which includes
            # queueing behind earlier futures in the same batch. For a pipelined
            # reader that is the honest customer-facing quantity; it is not the
            # isolated service time of one read, and must not be quoted as one.
            latencies_this_batch = []
            for f, tc, _sid_done, _tile_done in in_flight:
                f.get()
                latencies_this_batch.append(time.monotonic() - tc)
            now = time.monotonic()
            if now >= t_steady_start:
                # Count entire batch as steady-state tiles
                n_tiles_done_steady += len(in_flight)
                bytes_steady += sum(rbc for _ in in_flight)  # close enough — all same size for uncompressed raw TIFF
                # Sample per-tile latency
                for lat in latencies_this_batch:
                    if rng.random() < (1.0 / LATENCY_SAMPLE_RATE):
                        per_tile_latencies.append(lat)
            n_tiles_done_total += len(in_flight)
            in_flight = []

    # Drain remaining
    if in_flight:
        for f, _tc, _s, _t in in_flight:
            f.get()
        if time.monotonic() >= t_steady_start:
            n_tiles_done_steady += len(in_flight)
            bytes_steady += sum(BUF_SIZE_MAX for _ in in_flight)
        n_tiles_done_total += len(in_flight)

    t_total = time.monotonic() - t_start
    t_steady = max(0.0, t_total - args.ramp)

    if args.preregister:
        for b in tile_buffers:
            kvikio.memory_deregister(b)
    # Close handles
    for entry in slide_cache.values():
        try:
            entry["handle"].close()
        except Exception:
            pass

    # Per-tile latency stats
    if per_tile_latencies:
        lat_arr = np.asarray(per_tile_latencies)
        lat_stats = {
            "n_samples": int(lat_arr.size),
            "mean_ms": float(lat_arr.mean() * 1000),
            "p50_ms": float(np.percentile(lat_arr, 50) * 1000),
            "p95_ms": float(np.percentile(lat_arr, 95) * 1000),
            "p99_ms": float(np.percentile(lat_arr, 99) * 1000),
            "max_ms": float(lat_arr.max() * 1000),
        }
    else:
        lat_stats = {"n_samples": 0}

    summary = {
        "mode": "random",
        "compat_mode": args.compat_mode,
        "n_buffer": args.n_buffer,
        "num_threads": args.num_threads,
        "task_size": args.task_size or kvikio.defaults.get("task_size"),
        "preregister": args.preregister,
        "level": args.level,
        "runtime_s": args.runtime,
        "ramp_s": args.ramp,
        "lru_size": args.lru_size,
        "seed": args.seed,
        "manifest": args.manifest,
        "rawtiff_dir": args.rawtiff_dir,
        "coords_dir": args.coords_dir,
        # Cache state: REQUESTED (the --warm-cache flag) and what the pre-discard
        # ACHIEVED. attempted is bounded by the LRU fill, not the pool — a random
        # cell is cold only for its first pass over those slides, and reporting
        # both numbers is what keeps that legible instead of implied.
        "warm_cache_requested": bool(args.warm_cache),
        "n_page_cache_discards_attempted": n_discard_attempted,
        "n_page_cache_discards_failed": n_discard_failed,
        # The D13 reconciler's field (wsi_agg_helper.py cache): null = not
        # attempted (warm cell); false = any discard FAILED, which CONTRADICTS
        # a cold declaration rather than footnoting it.
        "client_page_cache_discarded": (None if args.warm_cache or n_discard_attempted == 0
                                        else n_discard_failed == 0),
        # Client page cache only; server-side cache and the per-filesystem cold
        # mechanism are open (A.5 / D13). Stated, not left to omission.
        "cache_state_achieved": "unknown",
        "n_slides_in_pool": len(coord_pool),
        "n_tiles_total": n_tiles_done_total,
        "n_tiles_steady": n_tiles_done_steady,
        "bytes_steady_aligned": bytes_steady,
        "wallclock_total_s": t_total,
        "wallclock_steady_s": t_steady,
        "tiles_per_sec_steady": n_tiles_done_steady / t_steady if t_steady > 0 else 0.0,
        "gbps_steady": bytes_steady / t_steady / 1e9 if t_steady > 0 else 0.0,
        "latency_stats_per_tile_batch": lat_stats,
        # D-6/D8: the achieved GPU-direct-vs-bounced byte split, distinct from
        # compat_mode above (the request). app bytes here are estimated for the
        # WHOLE window (the loop counts steady-window bytes; the nvidia-fs delta
        # spans ramp + steady, so the split is scaled by the tile ratio). Under
        # multi-process cells the nvidia-fs delta is device-global — the
        # per-process split is an upper bound; the cell-level split comes from
        # the wrapper's recorded nvidia-fs timeline.
        "path_accounting": acct.finish(
            int(bytes_steady * (n_tiles_done_total / n_tiles_done_steady))
            if n_tiles_done_steady else 0),
    }

    if args.latency_csv and per_tile_latencies:
        with open(args.latency_csv, "w") as f:
            f.write("per_tile_batch_latency_s\n")
            for l in per_tile_latencies:
                f.write(f"{l:.6f}\n")
        print(f"[random] {len(per_tile_latencies)} sampled latencies → {args.latency_csv}", file=sys.stderr)

    print("=== summary ===")
    print(json.dumps(summary, indent=2))
    if args.summary_json:
        with open(args.summary_json, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"[random] summary written to {args.summary_json}", file=sys.stderr)
    return summary


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["faithful", "random"], required=True,
                    help="faithful = sequential full-level read per slide (NVIDIA blog pattern); "
                         "random = random tile-byte-range reads from CLAM coord pool (apples-to-apples with Stage 4.B)")
    ap.add_argument("--rawtiff-dir", required=True, help="Directory containing per-slide raw TIFF files")
    ap.add_argument("--manifest", required=True, help="Slide-ID manifest TSV (Stage 4.A subset format)")
    ap.add_argument("--coords-dir", help="CLAM tile-coord HDF5 directory (random mode only)")
    ap.add_argument("--compat-mode", default="off", help="kvikio compat_mode: off (GDS), on (POSIX), auto")
    ap.add_argument("--n-buffer", type=int, default=64, help="Number of pre-allocated tile buffers (async pipelining depth)")
    ap.add_argument("--num-threads", type=int, default=16, help="kvikio internal thread pool size")
    ap.add_argument("--task-size", type=int, default=None,
                    help="kvikio task_size in bytes (chunks reads into pieces of this size). Default = kvikio's own default (4 MB).")
    ap.add_argument("--preregister", action="store_true", help="kvikio.memory_register the tile buffers up front")
    ap.add_argument("--level", type=int, default=0, help="Pyramid level to read (0 = highest resolution)")
    ap.add_argument("--warm-cache", action="store_true",
                    help="Do NOT discard page cache before reads (default: cold cache via cucim discard_page_cache)")
    ap.add_argument("--max-duration", type=int, default=600,
                    help="faithful mode: hard cap on per-cell wallclock in seconds (default 600 = 10 min). "
                         "Slides that did not start before the deadline are reported as n_slides_skipped_timecap. "
                         "WHY: at slow configs (low n_buffer + POSIX-compat), reading the full 50-slide subset "
                         "could take hours. Capping gives partial-but-valid data per slide for the slides that "
                         "did complete. Set to 0 to disable.")
    # random-mode only
    ap.add_argument("--runtime", type=int, default=60, help="random mode: steady-state runtime in seconds")
    ap.add_argument("--ramp", type=int, default=10, help="random mode: ramp-up seconds before counting tiles")
    ap.add_argument("--lru-size", type=int, default=64,
                    help="random mode: LRU slide-handle cache size per worker. WHY default 64: "
                         "the Stage 4.A subset pool is 50 slides; with LRU<pool_size, every "
                         "random.choice() risks a cache miss → kvikio.CuFile open + tifffile "
                         "index parse (~10-100 ms each); per-batch of 256 preads with 84%% miss "
                         "rate would dominate wallclock. Production DataLoaders pre-open all "
                         "training slides at process start; --lru-size 64 matches that.")
    ap.add_argument("--seed", type=int, default=42, help="random-tile sampling seed")
    ap.add_argument("--latency-sample-rate", type=int, default=100, help="random mode: sample 1-in-N per-batch latencies")
    ap.add_argument("--latency-csv", help="random mode: file to write sampled per-batch latencies")
    # both modes
    ap.add_argument("--summary-json", help="Path to write the per-cell summary JSON (also printed to stdout)")
    args = ap.parse_args()

    if args.mode == "random" and not args.coords_dir:
        ap.error("--coords-dir is required for --mode random")

    if args.mode == "faithful":
        mode_faithful(args)
    else:
        mode_random(args)


if __name__ == "__main__":
    main()
