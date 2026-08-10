#!/usr/bin/env python3
"""read-feature-files-stage6b.py — Stage 6.B.2 file-IO stress sweep reader.

Multi-process worker pool that reads .pt feature files from a synthetic corpus
according to a specified access pattern. Times each file-load via wallclock,
samples per-file latencies into a CSV.

Access patterns:
  random            : pick a file uniformly at random per iteration (production
                      MIL-DataLoader pattern; no replacement within per-worker LRU)
  batched-shuffled  : per-worker shuffle of the file list, walk in shuffle order
                      (epoch-style MIL training pattern)
  sequential        : walk the file list in directory order (best-case for any
                      storage's prefetch / sequential heuristic — sets a ceiling)

Time-bounded: 5 min ramp + 10 min steady (defaults).

Per-file-load latency CSV columns (sampled 1-in-K):
  worker_id, time_since_start_s, file_idx_in_corpus, file_size_bytes,
  load_latency_ms, pattern, dtype_inferred

Cold-cache: optionally discard wekafs page cache for the corpus directory at
start (via cucim.clara.filesystem.discard_page_cache). Default: cold start.

Multi-process via multiprocessing.Pool (fork start method; no CUDA in parent).
Each worker reads independently; no coordination across workers — this matches
the production MIL training pattern where N DataLoader workers pull files in
parallel.

Per-worker behavior:
  - load_corpus_index: scan corpus dir for .pt files (one-shot at startup)
  - In loop until deadline:
    - pick next file by pattern
    - torch.load(path) (deserializes pickle; this includes the IO time + pickle
      CPU time; that's the production workload — DataLoader → torch.load is the
      pattern)
    - record per-load wallclock; periodic sample to latency CSV
  - At end: return per-worker aggregate (n_loaded_total, n_loaded_steady,
    bytes_steady, errors)

Usage (typically invoked by sweep-stage6b-stress.sh):
  read-feature-files-stage6b.py \\
    --corpus-dir $FS_MOUNT/features-6.B-synthetic/syn-N10000-sz50MB-fp32 \\
    --pattern random \\
    --n-processes 64 \\
    --runtime 600 --ramp 300 \\
    --latency-csv <run-dir>/per-file-latencies.csv \\
    --summary-json <run-dir>/file-io-summary.json \\
    --seed 42
"""
import argparse
import csv
import glob
import json
import os
import random
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import torch


def _discard_in_child(dir_path):
    """Runs in a throwaway process: import cucim, discard, exit."""
    try:
        from cucim.clara import filesystem as cucim_fs
        cucim_fs.discard_page_cache(dir_path)
    except Exception as e:                      # noqa: BLE001 - report, never mask
        print(f"[discard] discard_page_cache failed: {e}", file=sys.stderr, flush=True)
        raise SystemExit(1)


def discard_page_cache_once(corpus_dir):
    """Drop the client page cache for `corpus_dir` ONCE, before any reader runs.

    Returns True if the discard is believed to have succeeded.

    WHY A SEPARATE CHILD RATHER THAN THE PARENT: this module is deliberately
    CUDA-free in the parent (fork start method), and the discard helper lives in
    cucim, whose import pulls in the CUDA stack. Doing it in a short-lived child
    keeps that guarantee intact while still completing the drop before the pool
    is created.

    WHY BEFORE THE POOL AT ALL: a drop issued from inside a pool worker races
    every other worker. They are already reading by then, so the cache is
    already warm when it fires and the eviction lands in the middle of their
    measurement -- the worst of both, since the cell is neither cold nor clean.

    This clears the CLIENT page cache only. It says nothing about the
    filesystem's server-side cache, which is the other half of the cold-state
    question (see RUNBOOK.md for what each clearing step does and does not
    reach, and D13 for how a cell's cache regime is established).
    """
    from multiprocessing import Process
    p = Process(target=_discard_in_child, args=(str(corpus_dir),))
    p.start()
    p.join()
    if p.exitcode != 0:
        print(f"[reader] page-cache discard did NOT succeed (exit {p.exitcode}); "
              f"this cell is NOT cold -- record it as such rather than labelling it cold",
              file=sys.stderr, flush=True)
        return False
    return True


def _load_one(args_tuple):
    """Worker function (one process). Reads files per pattern until deadline."""
    (worker_id, file_list, pattern, runtime, ramp, seed,
     latency_sample_rate, lru_size, discard_cache) = args_tuple

    # NOTE: the page-cache discard does NOT happen here. It is performed once,
    # in a throwaway child of the parent, BEFORE this pool exists -- see
    # discard_page_cache_once(). Dropping it from inside worker 0 meant every
    # other worker had already started reading and warming the cache, so the
    # cell was neither cold nor undisturbed: the drop landed mid-flight and
    # evicted data the other workers were actively measuring against.
    rng = random.Random(seed + worker_id)
    t_start = time.monotonic()
    t_steady_start = t_start + ramp
    deadline = t_start + ramp + runtime

    n_files = len(file_list)
    if n_files == 0:
        return {"worker_id": worker_id, "error": "empty file list"}

    # Pattern-specific iteration order setup
    if pattern == "sequential":
        order = list(range(n_files))
    elif pattern == "batched-shuffled":
        order = list(range(n_files))
        rng.shuffle(order)
    elif pattern == "random":
        order = None  # picked on the fly per iter
    else:
        raise ValueError(f"unknown pattern: {pattern}")

    # LRU-like recent-files set: avoid re-reading the same file within a small
    # window (matches production DataLoader's worker_lru semantics)
    recent = []
    n_loaded_total = 0
    n_loaded_steady = 0
    bytes_steady = 0
    errors = 0
    latency_samples = []  # (ts, file_idx, size_bytes, latency_ms, dtype_inferred)
    sample_counter = 0
    order_cursor = 0

    while time.monotonic() < deadline:
        # Pick the next file by pattern
        if pattern == "random":
            attempts = 0
            while True:
                idx = rng.randrange(n_files)
                if idx not in recent or attempts >= lru_size:
                    break
                attempts += 1
            recent.append(idx)
            if len(recent) > lru_size:
                recent.pop(0)
        else:
            # sequential or batched-shuffled
            idx = order[order_cursor % n_files]
            order_cursor += 1
            # For batched-shuffled, reshuffle when we complete a pass
            if pattern == "batched-shuffled" and order_cursor % n_files == 0:
                rng.shuffle(order)

        path = file_list[idx]
        t0 = time.monotonic()
        try:
            payload = torch.load(path, weights_only=False)
            # Touch the features tensor to ensure pickle deserialization completed
            # (torch.load may lazy-load; force materialization for accurate timing)
            _ = payload["features"].shape
            dtype = str(payload["features"].dtype).split(".")[-1] if "features" in payload else "?"
        except Exception:
            errors += 1
            continue
        t1 = time.monotonic()
        per_load_ms = (t1 - t0) * 1000.0

        try:
            size_bytes = os.path.getsize(path)
        except OSError:
            size_bytes = 0

        now = time.monotonic()
        n_loaded_total += 1
        if now >= t_steady_start:
            n_loaded_steady += 1
            bytes_steady += size_bytes
            sample_counter += 1
            if sample_counter % latency_sample_rate == 0:
                latency_samples.append((now - t_start, idx, size_bytes, per_load_ms, dtype))

    return {
        "worker_id": worker_id,
        "n_loaded_total": n_loaded_total,
        "n_loaded_steady": n_loaded_steady,
        "bytes_steady": bytes_steady,
        "errors": errors,
        "latency_samples": latency_samples,
        "elapsed_s": time.monotonic() - t_start,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus-dir", required=True,
                    help="Directory of .pt files (typically a 6.B.1 synthetic corpus)")
    ap.add_argument("--pattern", required=True,
                    choices=["random", "batched-shuffled", "sequential"])
    ap.add_argument("--n-processes", type=int, required=True,
                    help="Concurrent worker count")
    ap.add_argument("--runtime", type=float, default=600.0,
                    help="Steady-state seconds (default 600 = 10 min)")
    ap.add_argument("--ramp", type=float, default=300.0,
                    help="Ramp-up seconds before steady (default 300 = 5 min)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--latency-sample-rate", type=int, default=10,
                    help="Sample 1-in-N per-worker file-load latencies")
    ap.add_argument("--latency-csv", required=True,
                    help="Output CSV for sampled per-file latencies")
    ap.add_argument("--summary-json", required=True,
                    help="Output summary JSON")
    ap.add_argument("--lru-size", type=int, default=16,
                    help="Random pattern: per-worker LRU window to avoid immediate re-reads")
    ap.add_argument("--no-discard-cache", action="store_true",
                    help="Skip cucim discard_page_cache at start (default: discard for cold)")
    args = ap.parse_args()

    print(f"[reader] corpus_dir={args.corpus_dir}", flush=True)
    print(f"[reader] pattern={args.pattern} n_processes={args.n_processes} "
          f"ramp={args.ramp}s steady={args.runtime}s lru={args.lru_size}", flush=True)

    file_list = sorted(glob.glob(os.path.join(args.corpus_dir, "*.pt")))
    n_files = len(file_list)
    if n_files == 0:
        raise SystemExit(f"no .pt files found in {args.corpus_dir}")
    print(f"[reader] {n_files} files in corpus", flush=True)

    Path(args.latency_csv).parent.mkdir(parents=True, exist_ok=True)
    Path(args.summary_json).parent.mkdir(parents=True, exist_ok=True)

    worker_args = [(i, file_list, args.pattern, args.runtime, args.ramp,
                    args.seed, args.latency_sample_rate, args.lru_size,
                    not args.no_discard_cache)
                   for i in range(args.n_processes)]

    # Cold state is established ONCE, before any worker exists. Recorded as
    # achieved rather than asserted (D13) -- a cell whose discard failed is a
    # warm cell that must be labelled warm, not a cold cell with a caveat.
    cache_discarded = None
    if not args.no_discard_cache:
        cache_discarded = discard_page_cache_once(Path(file_list[0]).parent)

    print(f"[reader] spawning {args.n_processes} workers...", flush=True)
    t0 = time.monotonic()
    with Pool(processes=args.n_processes) as p:
        results = p.map(_load_one, worker_args)
    wall = time.monotonic() - t0
    print(f"[reader] all workers returned after {wall:.1f}s", flush=True)

    # Aggregate
    tot_loaded = sum(r["n_loaded_total"] for r in results)
    steady_loaded = sum(r["n_loaded_steady"] for r in results)
    bytes_steady = sum(r["bytes_steady"] for r in results)
    errors = sum(r["errors"] for r in results)

    # Write latency CSV
    with open(args.latency_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["worker_id", "time_since_start_s", "file_idx_in_corpus",
                    "file_size_bytes", "load_latency_ms", "pattern", "dtype_inferred"])
        for r in results:
            for ts, idx, sz, lat_ms, dt in r["latency_samples"]:
                w.writerow([r["worker_id"], f"{ts:.6f}", idx, sz, f"{lat_ms:.3f}",
                            args.pattern, dt])

    # Compute latency stats from samples
    all_lats = [s[3] for r in results for s in r["latency_samples"]]
    all_lats.sort()
    def pct(p):
        if not all_lats:
            return None
        k = max(0, min(len(all_lats) - 1, int(round((p / 100.0) * (len(all_lats) - 1)))))
        return all_lats[k]

    steady_window = args.runtime
    summary = {
        "corpus_dir": args.corpus_dir,
        "n_files_in_corpus": n_files,
        "pattern": args.pattern,
        "n_processes": args.n_processes,
        # Cache state ACHIEVED, not requested (D13). null = discard not attempted;
        # false = attempted and failed, so the cell is warm and must be read as
        # warm. Client page cache only -- the server side is not addressed here.
        "client_page_cache_discarded": cache_discarded,
        "ramp_s": args.ramp,
        "runtime_s": args.runtime,
        "wall_seconds_total": wall,
        "n_files_loaded_total": tot_loaded,
        "n_files_loaded_steady": steady_loaded,
        "bytes_steady": bytes_steady,
        "files_per_sec_steady_aggregate": steady_loaded / steady_window if steady_window > 0 else 0.0,
        "MiBps_steady_aggregate": (bytes_steady / 1024 / 1024) / steady_window if steady_window > 0 else 0.0,
        "errors": errors,
        "lat_samples_n": len(all_lats),
        "lat_mean_ms": (sum(all_lats) / len(all_lats)) if all_lats else None,
        "lat_p50_ms": pct(50),
        "lat_p95_ms": pct(95),
        "lat_p99_ms": pct(99),
        "lat_max_ms": all_lats[-1] if all_lats else None,
    }
    with open(args.summary_json, "w") as f:
        json.dump(summary, f, indent=2)

    print("=== summary ===")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
