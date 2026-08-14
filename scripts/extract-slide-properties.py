#!/usr/bin/env python3
"""extract-slide-properties.py — bulk OpenSlide property extraction with timing.

The Stage 2.0 workhorse: opens each WSI in a manifest via openslide-python,
extracts slide.properties + derived fields (level_count, level_dimensions,
level_downsamples), writes one JSON sidecar per slide, captures per-slide
elapsed time to a CSV, and prints a structured summary line on stdout.

Usage:
    extract-slide-properties.py \
        --concurrency N \
        --output-dir DIR \
        --manifest FILE \
        --latency-csv FILE

Concurrency is via multiprocessing.Pool(processes=N) — persistent workers,
so per-slide Python startup is amortized. imap_unordered streams results as
workers complete (good for fault isolation + flat throughput).

Per-slide failures (corrupt files, OpenSlide format errors) are recorded
in the latency CSV's `error` column but don't abort the run — Stage 2's
benchmark goal is to characterize the WHOLE-DATASET cataloging workload,
not to error-out on the first bad slide. Failure count appears in the
summary; exit code is 0 only if all slides succeeded.

Per CLAUDE.md docs-citation rule:
    openslide-python: github.com/openslide/openslide-python
    libopenslide:     openslide.org
(versions per the pinned env specs in scripts/env-specs/)
"""
import argparse
import json
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import openslide


def extract_one(args):
    """Worker function — runs in a Pool process. Returns (slide_id, elapsed_seconds, error_or_None)."""
    slide_path, output_dir = args
    slide_id = Path(slide_path).stem
    out_path = Path(output_dir) / f"{slide_id}.json"
    t_start = time.monotonic()
    try:
        slide = openslide.OpenSlide(slide_path)
        props = dict(slide.properties)
        props["__source_path__"] = str(slide_path)
        props["__level_count__"] = slide.level_count
        props["__level_dimensions__"] = list(slide.level_dimensions)
        props["__level_downsamples__"] = list(slide.level_downsamples)
        slide.close()
        with out_path.open("w") as f:
            json.dump(props, f, indent=2)
        elapsed = time.monotonic() - t_start
        return slide_id, elapsed, None
    except Exception as e:
        elapsed = time.monotonic() - t_start
        return slide_id, elapsed, str(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--concurrency", type=int, required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--manifest", required=True,
                    help="File listing one slide path per line")
    ap.add_argument("--latency-csv", required=True,
                    help="Path to write per-slide timings (slide_id, elapsed_seconds, error)")
    args = ap.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with open(args.manifest) as f:
        slides = [line.strip() for line in f if line.strip()]

    print(f"[extract] dataset_size: {len(slides)} slides", flush=True)
    print(f"[extract] concurrency:  {args.concurrency}", flush=True)
    print(f"[extract] output_dir:   {output_dir}", flush=True)
    print(f"[extract] starting",     flush=True)

    work = [(s, str(output_dir)) for s in slides]

    successes = 0
    failures = 0
    t_start = time.monotonic()
    with open(args.latency_csv, "w") as csvf:
        csvf.write("slide_id,elapsed_seconds,error\n")
        with Pool(processes=args.concurrency) as pool:
            for slide_id, elapsed, err in pool.imap_unordered(extract_one, work):
                # CSV-safe error field: strip newlines and commas
                err_field = "" if err is None else err.replace(",", ";").replace("\n", " ")
                csvf.write(f"{slide_id},{elapsed:.6f},{err_field}\n")
                if err is None:
                    successes += 1
                else:
                    failures += 1
                    print(f"[extract] FAIL {slide_id}: {err}", flush=True)
    t_total = time.monotonic() - t_start

    # Rate is over slides that actually produced a JSON sidecar, NOT the manifest
    # length. A failure returns early from extract_one (the open never completes),
    # so counting the whole manifest inflates the rate twice over: the numerator
    # includes work never done and the denominator is the shorter wallclock the
    # failures caused. A partially failing cell would then publish a HIGHER
    # slides/sec than a fully succeeding one — the headline Stage 2 number
    # ("cataloged N slides at concurrency n") reading better the more it broke.
    # Matches aggregate-stage3-tissue-detection.py, which derives its rate from
    # the artifacts produced (slides_with_h5) rather than the manifest.
    rate = successes / t_total if t_total > 0 else 0.0
    p_lat_mean = None
    p_lat_p99 = None
    # Quick latency stats from the CSV we just wrote (saves the aggregator a re-read for the cmd.log line)
    try:
        latencies = []
        with open(args.latency_csv) as f:
            next(f)  # header
            for line in f:
                parts = line.rstrip("\n").split(",")
                if len(parts) >= 2:
                    try:
                        latencies.append(float(parts[1]))
                    except ValueError:
                        pass
        if latencies:
            latencies.sort()
            n = len(latencies)
            p_lat_mean = sum(latencies) / n
            p_lat_p99 = latencies[min(int(n * 0.99), n - 1)]
    except Exception:
        pass

    print(f"=== summary ===", flush=True)
    print(f"slides_total:           {len(slides)}", flush=True)
    print(f"slides_success:         {successes}", flush=True)
    print(f"slides_failed:          {failures}", flush=True)
    print(f"total_seconds:          {t_total:.3f}", flush=True)
    print(f"slides_per_second:      {rate:.2f}", flush=True)
    print(f"concurrency:            {args.concurrency}", flush=True)
    if p_lat_mean is not None:
        print(f"per_slide_lat_mean_ms:  {p_lat_mean*1000:.2f}", flush=True)
    if p_lat_p99 is not None:
        print(f"per_slide_lat_p99_ms:   {p_lat_p99*1000:.2f}", flush=True)

    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
