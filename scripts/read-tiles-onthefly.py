#!/usr/bin/env python3
"""read-tiles-onthefly.py — Stage 4.B on-the-fly tile reader (CPU backends).

Time-based random-tile-read benchmark. Two backends:
  - openslide: per-tile `slide.read_region(...)` via openslide-python, multiprocessing.Pool of N processes
  - cucim:     batched `ci.read_region(locations_list, batch_size, num_workers, ...)` via cucim 26.02 CPU path

Worker pattern (both backends):
  - LRU cache of `lru_size` open slide handles per worker
  - At each iteration: with probability `p_new_slide`, evict LRU + open a new slide; else pick a cached slide
  - Sample `batch_size` random tile locations within the chosen slide (from CLAM coord HDF5)
  - openslide: read each tile individually, time each one
  - cucim: pass the batch to cuCIM's batched API, time the whole batch, divide by batch size for per-tile

Runs for `runtime + ramp` seconds. Only counts tiles read after `ramp` seconds elapsed (steady-state).

Output:
  - per-tile latency CSV (1-in-N sampled): timestamp,worker_id,slide_id,backend,per_tile_us,batch_size
  - summary JSON to stdout '=== summary ===' block, parseable by the aggregator

Usage:
  read-tiles-onthefly.py \
    --backend openslide \
    --n-processes 16 \
    --svs-dir $FS_MOUNT/data/tcga-brca \
    --coords-dir $FS_MOUNT/tissue-detection/3.0/tcga-brca/n64/patches \
    --runtime 60 --ramp 10 \
    --latency-csv /tmp/stage4b-tcga-brca-openslide-N16-latencies.csv \
    --seed 42

  read-tiles-onthefly.py \
    --backend cucim \
    --n-processes 4 --num-workers 16 --batch-size 4 \
    [same other args]
"""
import argparse
import glob
import json
import os
import random
import sys
import time
from collections import OrderedDict
from multiprocessing import Pool
from pathlib import Path


TILE_SIZE = 256  # output tile footprint at 20× (px); also the block unit for the cuCIM batch-locality sort
# Read level/size now come per-dataset from the CLAM coord HDF5 attrs (20× contract):
#   CAM16 → patch_level=1, patch_size=256 (native 20×); BRCA → patch_level=0, patch_size=512 (read 512px@40×).
# 4.B measures read+decode of the 20× tile's backing data; results are discarded after timing (no resize).
P_NEW_SLIDE = 0.125  # probability per iteration of evicting LRU and opening a new slide


_SLIDE_PATH_INDEX = {}   # svs_dir -> {slide_id: Path}


def build_slide_path_index(svs_dir):
    """Scan `svs_dir` ONCE and return {slide_id: path}. Cached per directory.

    WHY THIS IS NOT DONE LAZILY PER LOOKUP: this resolution sits on the
    cache-miss branch of 4.B's timed loop, which fires on roughly one iteration
    in eight (P_NEW_SLIDE). Resolving by walking the corpus each time -- a full
    `iterdir()` over ~1100 slide directories plus a per-directory `exists()`
    probe -- put a directory scan INSIDE the measurement window, so 4.B was
    partly measuring metadata traversal of the corpus rather than the tile-read
    path it exists to measure. The cost is not incidental: it is a metadata
    workload, on the axis where the two filesystems differ most, contaminating
    the read cell that is supposed to isolate the data path.

    Resolution order matches the original probe order exactly, so which file
    wins for a given slide_id is unchanged: flat `.tif`, then flat `.svs`, then
    per-subdirectory `.svs`, then `.tif` (`setdefault` = first writer wins).

    Build this BEFORE the timed window opens -- see the callers.
    """
    key = str(svs_dir)
    cached = _SLIDE_PATH_INDEX.get(key)
    if cached is not None:
        return cached
    root = Path(svs_dir)
    index = {}
    for ext in (".tif", ".svs"):
        for p in root.glob(f"*{ext}"):
            index.setdefault(p.stem, p)
    for sub in sorted(root.iterdir()):
        if sub.is_dir():
            for ext in (".svs", ".tif"):
                for p in sub.glob(f"*{ext}"):
                    index.setdefault(p.stem, p)
    _SLIDE_PATH_INDEX[key] = index
    return index


def find_slide(svs_dir, slide_id):
    """O(1) lookup against the prebuilt index. No filesystem access."""
    return build_slide_path_index(svs_dir).get(slide_id)


def _load_one_coord_h5(h5_path):
    """Worker for parallel coord-HDF5 load."""
    import h5py
    slide_id = Path(h5_path).stem
    with h5py.File(h5_path, "r") as f:
        coords = f["coords"][()]
    if coords.shape[0] == 0:
        return None
    return (slide_id, coords)


def _coord_pool_provenance(coords_dir):
    """Identity of the coord set a cached pool must match to be reusable.

    Cheap stats over the coord HDF5s: which directory, how many files, and the
    newest mtime. Stage 3 rewrites its coord HDF5s destructively on every re-run
    (sweep-stage3-tissue-detection.sh removes the cell's save dir first), so a
    regenerated coord set -- or a different magnification contract, which changes
    both the coords and their count -- moves at least one of these.
    """
    h5_files = sorted(Path(coords_dir).glob("*.h5"))
    prov = {
        "coords_dir": str(Path(coords_dir).resolve()),
        "n_h5_files": len(h5_files),
        "newest_h5_mtime_ns": max((p.stat().st_mtime_ns for p in h5_files), default=0),
    }
    return prov, h5_files


def load_coord_pool(coords_dir, pickle_cache_path=None, n_load_workers=32):
    """Returns (pool, provenance): list of (slide_id, coords_array) pairs, plus the
    identity of the coord set it came from.

    A cached pool is reused ONLY if the provenance stored inside it matches the
    current coords dir. Trusting the cache file's existence is the silent-wrong-number
    case: the cache is keyed on dataset name alone and persists across sweeps, so
    after a Stage 3 re-run or a magnification-contract change every 4.B cell would
    read tiles at the OLD coordinates while the run's note names the current coords
    dir. If the slide files still exist those reads all succeed and NOTHING reports a
    problem -- errors stays 0, n_slides_in_pool and n_tiles_in_pool look plausible --
    and 4.B characterises the working-set-vs-cache crossover for a working set that no
    longer corresponds to anything on disk. The coord HDF5s are the source of truth,
    so any mismatch (or an unreadable / pre-provenance cache) rebuilds rather than
    aborts.

    The stats and the rebuild both happen here in the parent, BEFORE the timed window
    opens -- see the callers -- so validating costs the measurement nothing.
    """
    import pickle
    prov, h5_files = _coord_pool_provenance(coords_dir)

    if pickle_cache_path and Path(pickle_cache_path).exists():
        try:
            with open(pickle_cache_path, "rb") as f:
                cached = pickle.load(f)
        except Exception as e:
            cached, reason = None, f"unreadable: {e}"
        if isinstance(cached, dict) and "pool" in cached:
            if cached.get("provenance") == prov:
                return cached["pool"], dict(prov, cache="reused")
            reason = f"provenance mismatch: cached={cached.get('provenance')}"
        elif cached is not None:
            reason = "no stored provenance (written before the cache was validated)"
        print(f"[reader] IGNORING coord-pool cache {pickle_cache_path} -- {reason}; "
              f"current={prov}. Rebuilding from {coords_dir}", flush=True)

    if not h5_files:
        return [], dict(prov, cache="no-coord-h5-files")

    # Parallel load via Pool
    with Pool(processes=min(n_load_workers, len(h5_files))) as p:
        results = p.map(_load_one_coord_h5, [str(h) for h in h5_files])
    pool = [r for r in results if r is not None]

    if pickle_cache_path:
        Path(pickle_cache_path).parent.mkdir(parents=True, exist_ok=True)
        with open(pickle_cache_path, "wb") as f:
            pickle.dump({"provenance": prov, "pool": pool},
                        f, protocol=pickle.HIGHEST_PROTOCOL)
    return pool, dict(prov, cache="rebuilt")


def read_coord_attrs(coords_dir):
    """Read CLAM (patch_level, patch_size) from the first non-empty coord HDF5.
    Uniform per dataset (cells are single-dataset), so one read describes the cell.
    20× contract: CAM16 → (1, 256) native 20×; BRCA → (0, 512) read 512px@40×."""
    import h5py
    for h5_path in sorted(Path(coords_dir).glob("*.h5")):
        with h5py.File(h5_path, "r") as f:
            pl = int(f["coords"].attrs.get("patch_level", 0))
            ps = int(f["coords"].attrs.get("patch_size", TILE_SIZE))
        return pl, ps
    return 0, TILE_SIZE


def worker_openslide(args):
    (worker_id, svs_dir, slide_index, runtime, ramp,
     lru_size, batch_size, seed, latency_sample_rate,
     patch_level, patch_size) = args
    import openslide
    rng = random.Random(seed + worker_id)
    cache = OrderedDict()  # slide_id -> OpenSlide handle

    # Resolve every slide path BEFORE the clock starts. This is the one-off
    # corpus scan; leaving it to the first cache miss would put it inside the
    # timed window, which is the defect this exists to avoid.
    build_slide_path_index(svs_dir)

    # Each worker computes its OWN deadline from when it starts (after fork + import overhead)
    t_start = time.monotonic()
    t_steady_start = t_start + ramp
    deadline = t_start + ramp + runtime
    tiles_total = 0
    tiles_steady = 0
    latency_samples = []  # (timestamp_offset_s, slide_id, per_tile_us, batch_size_used)
    slide_reads = {}
    cache_hits = 0
    cache_misses = 0
    errors = 0
    sample_counter = 0

    while time.monotonic() < deadline:
        # pick slide
        if cache and rng.random() > P_NEW_SLIDE:
            slide_id = rng.choice(list(cache.keys()))
            cache.move_to_end(slide_id)
            cache_hits += 1
            slide = cache[slide_id]
            slide_idx_entry = slide_index[slide_id]
        else:
            cache_misses += 1
            slide_id, coords = rng.choice(slide_index["__list__"])
            if slide_id not in cache:
                path = find_slide(svs_dir, slide_id)
                if path is None:
                    errors += 1
                    continue
                try:
                    slide = openslide.OpenSlide(str(path))
                except Exception:
                    errors += 1
                    continue
                cache[slide_id] = slide
                if len(cache) > lru_size:
                    evicted_id, evicted_slide = cache.popitem(last=False)
                    try: evicted_slide.close()
                    except Exception: pass
                slide_idx_entry = (slide_id, coords)
            else:
                slide = cache[slide_id]
                cache.move_to_end(slide_id)
                slide_idx_entry = slide_index[slide_id]

        # pick batch_size coords from this slide
        coords = slide_idx_entry[1]
        if coords.shape[0] < batch_size:
            picks = [int(rng.randint(0, coords.shape[0] - 1)) for _ in range(batch_size)]
        else:
            picks = rng.sample(range(coords.shape[0]), batch_size)

        # read each tile individually
        for i in picks:
            x, y = int(coords[i, 0]), int(coords[i, 1])
            t0 = time.monotonic()
            try:
                slide.read_region((x, y), patch_level, (patch_size, patch_size))
            except Exception:
                errors += 1
                continue
            t1 = time.monotonic()
            per_tile_us = (t1 - t0) * 1e6
            now = time.monotonic()
            tiles_total += 1
            if now >= t_steady_start:
                tiles_steady += 1
                slide_reads[slide_id] = slide_reads.get(slide_id, 0) + 1
                sample_counter += 1
                if sample_counter % latency_sample_rate == 0:
                    latency_samples.append((now - t_start, slide_id, per_tile_us, 1))
            if now >= deadline: break
        if time.monotonic() >= deadline: break

    # Close all cached slides
    for s in cache.values():
        try: s.close()
        except Exception: pass

    return {
        "worker_id": worker_id,
        "tiles_total": tiles_total,
        "tiles_steady": tiles_steady,
        "errors": errors,
        "cache_hits": cache_hits,
        "cache_misses": cache_misses,
        "slide_reads": slide_reads,
        "latency_samples": latency_samples,
        "elapsed_s": time.monotonic() - t_start,
    }


def worker_cucim(args):
    (worker_id, svs_dir, slide_index, runtime, ramp,
     lru_size, batch_size, num_workers, prefetch_factor,
     seed, latency_sample_rate, sort_batches,
     patch_level, patch_size) = args
    from cucim.clara import CuImage
    CuImage.cache("per_process", memory_capacity=512)
    rng = random.Random(seed + worker_id)
    cache = OrderedDict()  # slide_id -> CuImage handle

    # Resolve every slide path BEFORE the clock starts — see the OpenSlide
    # worker; the same contamination applies to this backend.
    build_slide_path_index(svs_dir)

    # Each worker computes its OWN deadline from when it starts (cuCIM import takes seconds)
    t_start = time.monotonic()
    t_steady_start = t_start + ramp
    deadline = t_start + ramp + runtime
    tiles_total = 0
    tiles_steady = 0
    latency_samples = []
    slide_reads = {}
    cache_hits = 0
    cache_misses = 0
    errors = 0
    sample_counter = 0

    while time.monotonic() < deadline:
        if cache and rng.random() > P_NEW_SLIDE:
            slide_id = rng.choice(list(cache.keys()))
            cache.move_to_end(slide_id)
            cache_hits += 1
            slide = cache[slide_id]
            coords = slide_index[slide_id][1]
        else:
            cache_misses += 1
            slide_id, coords = rng.choice(slide_index["__list__"])
            if slide_id not in cache:
                path = find_slide(svs_dir, slide_id)
                if path is None:
                    errors += 1
                    continue
                try:
                    slide = CuImage(str(path))
                except Exception:
                    errors += 1
                    continue
                cache[slide_id] = slide
                if len(cache) > lru_size:
                    evicted_id, evicted_slide = cache.popitem(last=False)
                    try: evicted_slide.close()
                    except Exception: pass
            else:
                slide = cache[slide_id]
                cache.move_to_end(slide_id)

        # pick batch_size random coords from this slide
        if coords.shape[0] < batch_size:
            picks = [int(rng.randint(0, coords.shape[0] - 1)) for _ in range(batch_size)]
        else:
            picks = rng.sample(range(coords.shape[0]), batch_size)
        locs = [(int(coords[i, 0]), int(coords[i, 1])) for i in picks]
        # If sort_batches: sort tile coords by (y_tile_idx, x_tile_idx) so cuCIM's
        # nvjpeg_processor sees a tight max_offset-min_offset span per call. This is
        # a ~6× speedup — preserves random sampling across batches while exploiting within-batch locality.
        if sort_batches:
            locs.sort(key=lambda p: (p[1] // patch_size, p[0] // patch_size))

        # batched cucim CPU read
        t0 = time.monotonic()
        try:
            gen = slide.read_region(locs, (patch_size, patch_size), level=patch_level,
                                    batch_size=batch_size, num_workers=num_workers,
                                    prefetch_factor=prefetch_factor, device='cpu')
            n = 0
            for batch in gen:
                # batch is a CuImage; we just count its tiles. Not converting to numpy
                # (we'd want to in production training but here we measure pure read+decode rate).
                n += batch_size if batch_size > 1 else 1
        except Exception as e:
            errors += 1
            continue
        t1 = time.monotonic()

        per_tile_us = ((t1 - t0) * 1e6) / max(n, 1)
        now = time.monotonic()
        tiles_total += n
        if now >= t_steady_start:
            tiles_steady += n
            slide_reads[slide_id] = slide_reads.get(slide_id, 0) + n
            sample_counter += 1
            if sample_counter % latency_sample_rate == 0:
                latency_samples.append((now - t_start, slide_id, per_tile_us, n))
        if now >= deadline: break

    for s in cache.values():
        try: s.close()
        except Exception: pass

    return {
        "worker_id": worker_id,
        "tiles_total": tiles_total,
        "tiles_steady": tiles_steady,
        "errors": errors,
        "cache_hits": cache_hits,
        "cache_misses": cache_misses,
        "slide_reads": slide_reads,
        "latency_samples": latency_samples,
        "elapsed_s": time.monotonic() - t_start,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True, choices=["openslide", "cucim"])
    ap.add_argument("--n-processes", type=int, required=True)
    ap.add_argument("--num-workers", type=int, default=16, help="cuCIM-only: internal C++ threads/process")
    ap.add_argument("--batch-size", type=int, default=4, help="cuCIM: batched API; OpenSlide: tiles per loop iter")
    ap.add_argument("--prefetch-factor", type=int, default=2, help="cuCIM-only")
    ap.add_argument("--svs-dir", required=True)
    ap.add_argument("--coords-dir", required=True)
    ap.add_argument("--runtime", type=float, default=60.0)
    ap.add_argument("--ramp", type=float, default=10.0)
    ap.add_argument("--lru-size", type=int, default=8)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--latency-sample-rate", type=int, default=100)
    ap.add_argument("--latency-csv", required=True)
    ap.add_argument("--summary-json", default=None)
    ap.add_argument("--coord-pool-pickle", default=None,
                    help="If set, pickle path to cache the coord pool. First call writes it; later calls re-load it (fast).")
    ap.add_argument("--sort-batches", action="store_true",
                    help="cuCIM-only: sort tile coords by (y_tile_idx, x_tile_idx) within each batch. "
                         "Empirically delivers ~6× speedup vs unsorted by keeping nvjpeg_processor's "
                         "max_offset-min_offset span tight per call.")
    args = ap.parse_args()

    print(f"[reader] backend={args.backend}", flush=True)
    print(f"[reader] n_processes={args.n_processes}", flush=True)
    if args.backend == "cucim":
        print(f"[reader] num_workers={args.num_workers}, batch_size={args.batch_size}, prefetch_factor={args.prefetch_factor}", flush=True)
    print(f"[reader] runtime={args.runtime}s, ramp={args.ramp}s, total_window={args.runtime + args.ramp}s", flush=True)
    print(f"[reader] svs_dir={args.svs_dir}", flush=True)
    print(f"[reader] coords_dir={args.coords_dir}", flush=True)

    # Load coord pool (parallel; cached via pickle if --coord-pool-pickle set)
    print(f"[reader] loading coord pool from {args.coords_dir}"
          + (f" (cache={args.coord_pool_pickle})" if args.coord_pool_pickle else ""), flush=True)
    t_load_start = time.monotonic()
    pool, pool_prov = load_coord_pool(args.coords_dir, pickle_cache_path=args.coord_pool_pickle)
    t_load = time.monotonic() - t_load_start
    n_slides = len(pool)
    n_tiles_total = sum(c.shape[0] for _, c in pool)
    print(f"[reader] loaded {n_slides} slides, {n_tiles_total} total tile coords, in {t_load:.2f}s "
          f"(pool cache: {pool_prov['cache']})", flush=True)

    # Build slide index (dict + list for sampling)
    slide_index = {slide_id: (slide_id, coords) for slide_id, coords in pool}
    slide_index["__list__"] = pool

    # 20× read params from the CLAM coord attrs (uniform per dataset). Tiles are
    # read at (patch_level, patch_size) — see read_coord_attrs / the 20× contract.
    patch_level, patch_size = read_coord_attrs(args.coords_dir)
    print(f"[reader] 20× read params: patch_level={patch_level}, patch_size={patch_size}", flush=True)

    if args.backend == "openslide":
        worker_args = [
            (i, args.svs_dir, slide_index, args.runtime, args.ramp,
             args.lru_size, args.batch_size, args.seed, args.latency_sample_rate,
             patch_level, patch_size)
            for i in range(args.n_processes)
        ]
        worker_fn = worker_openslide
    else:
        worker_args = [
            (i, args.svs_dir, slide_index, args.runtime, args.ramp,
             args.lru_size, args.batch_size, args.num_workers, args.prefetch_factor,
             args.seed, args.latency_sample_rate, args.sort_batches,
             patch_level, patch_size)
            for i in range(args.n_processes)
        ]
        worker_fn = worker_cucim

    print(f"[reader] spawning {args.n_processes} workers...", flush=True)
    t_run_start = time.monotonic()
    with Pool(processes=args.n_processes) as p:
        results = p.map(worker_fn, worker_args)
    t_run = time.monotonic() - t_run_start
    print(f"[reader] all workers returned after {t_run:.2f}s", flush=True)

    # Aggregate
    tiles_total = sum(r["tiles_total"] for r in results)
    tiles_steady = sum(r["tiles_steady"] for r in results)
    errors = sum(r["errors"] for r in results)
    cache_hits = sum(r["cache_hits"] for r in results)
    cache_misses = sum(r["cache_misses"] for r in results)

    # Write latency CSV
    with open(args.latency_csv, "w") as f:
        f.write("worker_id,time_since_start_s,slide_id,backend,per_tile_us,batch_size\n")
        for r in results:
            for ts, slide_id, per_tile_us, bs in r["latency_samples"]:
                f.write(f"{r['worker_id']},{ts:.6f},{slide_id},{args.backend},{per_tile_us:.2f},{bs}\n")

    # Per-slide aggregate read counts
    slide_total = {}
    for r in results:
        for sid, cnt in r["slide_reads"].items():
            slide_total[sid] = slide_total.get(sid, 0) + cnt

    steady_window_s = args.runtime  # nominal steady-state window
    tiles_per_sec_steady = tiles_steady / steady_window_s if steady_window_s > 0 else 0.0

    summary = {
        "backend": args.backend,
        "n_processes": args.n_processes,
        "num_workers": args.num_workers if args.backend == "cucim" else None,
        "batch_size": args.batch_size,
        "sort_batches": args.sort_batches if args.backend == "cucim" else None,
        "prefetch_factor": args.prefetch_factor if args.backend == "cucim" else None,
        "runtime": args.runtime,
        "ramp": args.ramp,
        "steady_window_s": steady_window_s,
        "n_slides_in_pool": n_slides,
        "n_tiles_in_pool": n_tiles_total,
        # Pool provenance: which coord set this cell's working set actually came from,
        # so a cell can be checked against the coords dir its note names rather than
        # trusting that the two agree.
        "coord_pool_source_dir": pool_prov["coords_dir"],
        "coord_pool_n_h5_files": pool_prov["n_h5_files"],
        "coord_pool_newest_h5_mtime_ns": pool_prov["newest_h5_mtime_ns"],
        "coord_pool_cache": pool_prov["cache"],
        "tiles_total": tiles_total,
        "tiles_steady": tiles_steady,
        "tiles_per_sec_steady": tiles_per_sec_steady,
        "errors": errors,
        "cache_hits": cache_hits,
        "cache_misses": cache_misses,
        "cache_hit_rate": cache_hits / (cache_hits + cache_misses + 1e-9),
        "unique_slides_read": len(slide_total),
        "wall_seconds": t_run,
    }

    print(f"=== summary ===", flush=True)
    for k, v in summary.items():
        print(f"{k}: {v}", flush=True)

    if args.summary_json:
        with open(args.summary_json, "w") as f:
            json.dump(summary, f, indent=2)

    sys.exit(0 if errors == 0 else 1)


if __name__ == "__main__":
    main()
