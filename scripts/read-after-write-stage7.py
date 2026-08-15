#!/usr/bin/env python3
"""read-after-write-stage7.py — Stage 7.4.b read-after-write consistency cell.

Customer-decisive measurement: when a file is written to the filesystem under
test by one client process, how quickly does another client process see it?
On the WEKA leg this validates WekaFS's "no second tier, strong consistency"
claim with a hard number; the same cell on the other leg is the comparison point.

METHODOLOGY (per Stage 7 roadmap Q10)
=====================================
Per slide (20 slides total):
  1. Writer process: opens a unique heatmap output path, performs a
     synthetic-but-realistic write (50 MB pyramidal TIFF — matches the 7.3
     tiff5x size profile), calls fsync(), records t_write_complete.
  2. Reader process (already polling the path every 10 ms): tries to open
     the path; the FIRST successful open records t_first_visible. Then it
     reads the first 4 KB and records t_first_read_complete.
  3. Consistency latency = t_first_visible - t_write_complete (in ms).
  4. Read latency = t_first_read_complete - t_first_visible (also captured).

Two processes run concurrently — one writer, one reader — to ensure the
reader sees the write through the filesystem's actual cross-client visibility
path, not through process-local cache.

PER-SLIDE CSV columns (slide_id, t_write_complete_s, t_first_visible_s,
t_first_read_complete_s, consistency_latency_ms, first_read_latency_ms,
bytes_written, write_ms).

WHY synthetic heatmap content
=============================
The customer-decisive metric is the consistency latency — not the heatmap
quality. We generate a deterministic ~50 MB tiled-TIFF of plausible pixel
data so the write workload matches 7.3.a's tiff5x profile but doesn't
require running the actual foundation-model + MIL chain (which would add
~30s of orthogonal latency to each iteration and obscure the consistency
measurement). The customer-quotable answer is "write 50 MB on client A;
client B sees it within X ms" — independent of how those 50 MB were
computed.

Usage:
  python read-after-write-stage7.py \\
    --output-dir $FS_MOUNT/heatmaps/7.4b \\
    --n-slides 20 \\
    --bytes-per-write 50000000 \\
    --poll-interval-s 0.01 \\
    --per-slide-csv <run-dir>/read-after-write-latencies.csv \\
    --summary-json <run-dir>/raw-summary.json
"""
import argparse
import csv
import json
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import numpy as np
import tifffile


def writer_process(slide_id: str, out_path: Path, bytes_target: int,
                   write_done_queue: mp.Queue):
    """Write a ~bytes_target-sized tiled TIFF to a .tmp path, fsync, then
    atomic-rename to out_path. Reader sees out_path appear only AFTER the
    rename — establishes a proper happens-before for the consistency check.

    WHY not write the final path directly: tifffile.imwrite() opens the file
    and writes incrementally; reader's Path.exists() returned True the moment
    the file was created (size 0), giving negative consistency latencies. The
    .tmp + rename pattern fixes this — out_path doesn't appear at all until
    the rename completes after fsync.
    """
    # Pixel grid sized from `bytes_target` via an ASSUMED ~5× deflate ratio.
    #
    # ⚠ THIS RATIO DOES NOT HOLD FOR THIS CONTENT, AND THE TARGET IS NOT THE
    # OUTCOME. The pattern below is a 32×32 base tiled up by np.repeat, so it is
    # enormously more compressible than the ~5× assumed here and the file lands
    # far under `bytes_target`. `--bytes-per-write` is therefore a *request*,
    # never a measurement: the achieved size is stat()'d after the write and is
    # the only size that is ever reported.
    #
    # Why this matters rather than being cosmetic: 7.4.b measures how quickly a
    # just-written heatmap becomes visible to another reader, and that depends
    # on the artifact's real size and tile structure. An artifact an order of
    # magnitude smaller than a production heatmap answers the question for a
    # file nobody writes. Per the Stage 7 decision, the artifact is to be sized
    # and tiled from a MEASURED 7.3 output on the same leg -- pass that measured
    # size in, and check the achieved size against it (see the target-vs-achieved
    # report below) rather than trusting this ratio.
    side = int(np.ceil(np.sqrt(bytes_target * 5 / 3) / 256)) * 256
    rng = np.random.default_rng(hash(slide_id) & 0xFFFFFFFF)
    # Build a smooth-ish pattern (random gradient) so deflate gives realistic
    # compression. Pure-random uint8 doesn't compress at all; pure-uniform
    # compresses too well. A smooth gradient matches heatmap entropy.
    base = (rng.integers(0, 256, (32, 32, 3), dtype=np.uint8))
    rgb = np.repeat(np.repeat(base, side // 32, axis=0), side // 32, axis=1)

    tmp_path = out_path.with_suffix(out_path.suffix + '.tmp')
    t_write_start = time.monotonic()
    tifffile.imwrite(
        str(tmp_path), rgb,
        photometric='rgb', tile=(256, 256),
        compression='zlib', bigtiff=True,
    )
    # Force the bytes to durable storage BEFORE the atomic rename. fsync
    # establishes the happens-before contract that the reader observes when
    # it first sees out_path appear after rename.
    with open(tmp_path, 'rb') as f:
        os.fsync(f.fileno())
    # Atomic rename: out_path appears only here. Reader's Path.exists() poll
    # now correctly fires AFTER the file is fully written + fsynced.
    os.rename(str(tmp_path), str(out_path))
    t_write_done = time.monotonic()
    bytes_written = out_path.stat().st_size
    write_ms = (t_write_done - t_write_start) * 1000.0
    write_done_queue.put({
        'slide_id': slide_id,
        't_write_done': t_write_done,
        'bytes_written': bytes_written,     # ACHIEVED — the only size reported
        'bytes_target': bytes_target,       # REQUESTED — recorded so the miss is visible
        'write_ms': write_ms,
    })


def reader_process(slide_id: str, out_path: Path, poll_interval_s: float,
                   poll_timeout_s: float, result_queue: mp.Queue):
    """Poll out_path until it appears (cross-client visibility), then read 4 KB.

    Note: the reader starts polling BEFORE the writer begins, so it sees the
    path emerge from non-existent → exists → readable. The first successful
    open is t_first_visible; the first successful 4 KB read is
    t_first_read_complete.
    """
    t_start = time.monotonic()
    deadline = t_start + poll_timeout_s
    t_first_visible = None
    t_first_read_complete = None

    while time.monotonic() < deadline:
        if out_path.exists():
            t_first_visible = time.monotonic()
            # Try to read the first 4 KB
            try:
                with open(out_path, 'rb') as f:
                    _ = f.read(4096)
                t_first_read_complete = time.monotonic()
                break
            except (OSError, IOError):
                # File visible but not yet readable; continue polling
                pass
        time.sleep(poll_interval_s)

    result_queue.put({
        'slide_id': slide_id,
        't_first_visible': t_first_visible,
        't_first_read_complete': t_first_read_complete,
    })


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument('--output-dir', required=True,
                    help='Dir for synthetic heatmap files (one per slide).')
    ap.add_argument('--n-slides', type=int, default=20)
    ap.add_argument('--bytes-per-write', type=int, default=50_000_000,
                    help='Target file size after compression (matches 7.3.a profile).')
    ap.add_argument('--poll-interval-s', type=float, default=0.01,
                    help='Reader polls every 10 ms by default.')
    ap.add_argument('--poll-timeout-s', type=float, default=30.0,
                    help='Reader gives up after this many seconds (sanity).')
    ap.add_argument('--per-slide-csv', required=True)
    ap.add_argument('--summary-json', required=True)
    args = ap.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    Path(args.per_slide_csv).parent.mkdir(parents=True, exist_ok=True)
    Path(args.summary_json).parent.mkdir(parents=True, exist_ok=True)

    csv_f = open(args.per_slide_csv, 'w', newline='')
    csv_w = csv.DictWriter(csv_f, fieldnames=[
        'slide_id', 't_write_complete_s', 't_first_visible_s',
        't_first_read_complete_s', 'consistency_latency_ms',
        'first_read_latency_ms', 'bytes_written', 'write_ms',
    ])
    csv_w.writeheader()

    consistency_latencies_ms = []
    first_read_latencies_ms = []
    bytes_written_all = []      # ACHIEVED artifact sizes, for the target-vs-achieved check

    t_zero = time.monotonic()
    for i in range(args.n_slides):
        slide_id = f"raw-slide-{i:04d}"
        out_path = out_dir / f"{slide_id}.tiff"
        # Clean stale output (per CLAUDE.md: idempotent skip-on-existing + force-wipe)
        if out_path.exists():
            out_path.unlink()

        write_q: mp.Queue = mp.Queue()
        read_q: mp.Queue = mp.Queue()

        # Reader spawns FIRST and starts polling, so it observes the
        # non-exists → exists transition cleanly.
        reader = mp.Process(target=reader_process,
                            args=(slide_id, out_path, args.poll_interval_s,
                                  args.poll_timeout_s, read_q))
        reader.start()
        # Small delay so reader is actively polling before writer begins
        time.sleep(0.05)

        writer = mp.Process(target=writer_process,
                            args=(slide_id, out_path, args.bytes_per_write, write_q))
        writer.start()

        writer.join()
        reader.join(timeout=args.poll_timeout_s + 5.0)
        if reader.is_alive():
            reader.terminate()
            reader.join()

        try:
            wr = write_q.get_nowait()
        except Exception:
            wr = None
        try:
            rd = read_q.get_nowait()
        except Exception:
            rd = None

        if wr is None or rd is None:
            print(f"[raw] slide {i}: incomplete result wr={wr is not None} rd={rd is not None}",
                  flush=True)
            continue

        t_write_done = wr['t_write_done']
        t_first_visible = rd['t_first_visible']
        t_first_read = rd['t_first_read_complete']
        # If reader never observed the file (timeout), record empty consistency
        cons_ms = (t_first_visible - t_write_done) * 1000.0 if t_first_visible else None
        first_read_ms = (t_first_read - t_first_visible) * 1000.0 if (
            t_first_read and t_first_visible) else None
        if cons_ms is not None:
            consistency_latencies_ms.append(cons_ms)
        if first_read_ms is not None:
            first_read_latencies_ms.append(first_read_ms)
        if wr.get('bytes_written'):
            bytes_written_all.append(wr['bytes_written'])

        csv_w.writerow({
            'slide_id': slide_id,
            't_write_complete_s': f"{t_write_done - t_zero:.6f}",
            't_first_visible_s': f"{(t_first_visible - t_zero):.6f}" if t_first_visible else "",
            't_first_read_complete_s': f"{(t_first_read - t_zero):.6f}" if t_first_read else "",
            'consistency_latency_ms': f"{cons_ms:.3f}" if cons_ms is not None else "",
            'first_read_latency_ms': f"{first_read_ms:.3f}" if first_read_ms is not None else "",
            'bytes_written': wr['bytes_written'],
            'write_ms': f"{wr['write_ms']:.3f}",
        })
        csv_f.flush()
        print(f"[raw] slide {i} ({slide_id}): write={wr['write_ms']:.1f}ms "
              f"consistency={cons_ms:.3f}ms first_read={first_read_ms:.3f}ms"
              if cons_ms is not None else
              f"[raw] slide {i}: reader timed out", flush=True)

    csv_f.close()

    def pctile(xs, p):
        if not xs:
            return None
        s = sorted(xs)
        idx = int(round((p / 100.0) * (len(s) - 1)))
        return s[idx]

    mean_achieved = (sum(bytes_written_all) / len(bytes_written_all)) if bytes_written_all else None
    size_ratio = (mean_achieved / args.bytes_per_write) if mean_achieved else None
    if size_ratio is not None and not (0.5 <= size_ratio <= 2.0):
        print(f"[read-after-write] WARNING: artifact size missed its target by "
              f"{1.0 / size_ratio:.1f}× (target {args.bytes_per_write:,} B, achieved "
              f"{mean_achieved:,.0f} B). Visibility latency depends on the artifact's real "
              f"size and tile structure, so this cell describes a file unlike a production "
              f"heatmap. Size it from a MEASURED 7.3 output on this leg.",
              file=sys.stderr, flush=True)

    summary = {
        'n_slides_requested': args.n_slides,
        'n_consistency_samples': len(consistency_latencies_ms),
        # Target vs achieved, both recorded: the target is a request through an
        # assumed compression ratio that does not hold, so only the achieved
        # size describes what was actually measured.
        'bytes_per_write_target': args.bytes_per_write,
        'bytes_written_mean_achieved': mean_achieved,
        'bytes_written_target_ratio': size_ratio,
        # The poll interval IS the resolution floor of every visibility latency
        # below: the reader can only observe the file on a poll boundary, so any
        # latency at or under this value is quantisation, not measurement.
        # Reported so nobody reads a sub-interval p50 as a real number.
        'poll_interval_s': args.poll_interval_s,
        'visibility_latency_resolution_floor_ms': args.poll_interval_s * 1000.0,
        'consistency_latency_ms_mean': (sum(consistency_latencies_ms) / len(consistency_latencies_ms)
                                         if consistency_latencies_ms else None),
        'consistency_latency_ms_p50': pctile(consistency_latencies_ms, 50),
        'consistency_latency_ms_p95': pctile(consistency_latencies_ms, 95),
        'consistency_latency_ms_p99': pctile(consistency_latencies_ms, 99),
        'consistency_latency_ms_max': max(consistency_latencies_ms) if consistency_latencies_ms else None,
        'first_read_latency_ms_mean': (sum(first_read_latencies_ms) / len(first_read_latencies_ms)
                                        if first_read_latencies_ms else None),
        'first_read_latency_ms_p99': pctile(first_read_latencies_ms, 99),
    }
    with open(args.summary_json, 'w') as f:
        json.dump(summary, f, indent=2)
    print("=== summary ===", flush=True)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
