#!/usr/bin/env python3
"""generate-synthetic-features-stage6b.py — Stage 6.B.1 synthetic .pt corpus generator.

Generates synthetic per-slide feature .pt files at production-scale corpus sizes
+ file-size distribution + bit-widths. Each .pt file mimics the structure that
the real 6.A extractor produces but with random tensor content — the IO PATTERN
is what matters for the Phase 2 metadata-stress story, not embedding values.

Per-file structure (matches 6.A extractor output schema):
  torch.save({
      'slide_id': str,            # synthetic name (e.g., 'syn-N10000-sz50MB-fp32-00001')
      'model': str,               # 'synthetic-${size_MB}MB-${dtype}'
      'embedding_dim': int,       # derived from file_size + n_tiles
      'n_tiles': int,             # computed from target file size
      'coords': torch.LongTensor, # synthetic (x, y) pairs (random)
      'features': torch.Tensor,   # the actual feature payload (random values, target dtype)
  }, path)

Target file sizes computed assuming embedding_dim=1280 (Virchow2-class):
  file_size_MB → n_tiles ≈ (file_size_MB * 1024 * 1024) / (1280 * dtype_bytes)
  At FP32 (4 bytes/elt): 5MB→1024 tiles, 10MB→2048, 50MB→10240, 200MB→40960
  At FP16 (2 bytes/elt): file is half the size, OR n_tiles doubled for same file size.

WHY synthetic (not real 6.A output):
  6.A produces at most 1131 real .pt files (full BRCA). 6.B.2 needs corpora up to
  100K files to characterize production-scale metadata-stress. Synthetic gives
  controlled scale + controlled file-size distribution + controlled bit-width.
  The IO pattern (random small-file reads + pickle deserialization) is identical
  to real feature files; only the tensor values differ.

WHY corpus sizes {1K, 10K, 30K, 100K}:
  - 1K   ≈ small per-cancer-type research dataset
  - 10K  ≈ TCGA single cancer type (BRCA-scale)
  - 30K  ≈ TCGA-pan-cancer ≈ Mahmood Lab UNI-pretraining size
  - 100K ≈ research-lab feature library across multiple projects / multi-mag

WHY file sizes {5, 10, 50, 200} MB:
  - 5MB   = small-tissue slide (needle biopsy, few hundred tiles)
  - 10MB  = small slide
  - 50MB  = production-typical (production research labs report ~50MB avg per slide)
  - 200MB = large-tissue / high-magnification slide

WHY parallel generation via multiprocessing.Pool:
  100K × 50 MB = 5 TB; single-process write of random tensors would take hours.
  Parallel generation across 16+ processes saturates wekafs write bandwidth.

Output path convention:
  $FS_MOUNT/features-6.B-synthetic/N${count}-sz${size_MB}MB-${dtype}/
    └── syn-N${count}-sz${size_MB}MB-${dtype}-00000.pt
    └── syn-N${count}-sz${size_MB}MB-${dtype}-00001.pt
    └── ... (count files total)

Usage:
  # Generate one corpus
  generate-synthetic-features-stage6b.py \\
    --count 10000 --file-size-mb 50 --dtype fp32 \\
    --output-base $FS_MOUNT/features-6.B-synthetic \\
    --n-workers 16

  # Generate the standard 6.B corpus matrix (see "STANDARD_CORPORA" below)
  generate-synthetic-features-stage6b.py --standard-suite \\
    --output-base $FS_MOUNT/features-6.B-synthetic
"""
import argparse
import json
import os
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import os as _os, sys as _sys
# The mount is a DIMENSION, never a constant: this project runs the identical code
# against two filesystems. Refuse to guess -- a wrong mount silently measures the
# other filesystem and the number still looks correct.
FS_MOUNT = _os.environ.get("FS_MOUNT")
if not FS_MOUNT:
    _sys.exit("FATAL: FS_MOUNT is unset -- source env.sh "
              "(see docs/NAMING-AND-VARIABLES.md).")

import numpy as np
import torch



EMBED_DIM = 1280  # Virchow2-class; production-typical
DTYPE_BYTES = {"fp32": 4, "fp16": 2}
DTYPE_TORCH = {"fp32": torch.float32, "fp16": torch.float16}


# Standard 6.B corpus matrix — what gets generated under --standard-suite.
# Per disk budget in Stage-6-Feature-Extraction.md 6.B.1:
#   Saturation: N=10K × sz=50MB × {fp32, fp16} = 0.5 TB + 0.25 TB = 0.75 TB
#   Production: N=100K × sz=50MB × fp32 only    = 5 TB
#   File-size sensitivity: N=30K × sz∈{5,10,50} MB × fp32 = ~2 TB
# Total disk budget: ~13.75 TB (under 21 TB free post-Stage-6.A; revised 2026-05-25)
# 200 MB tier restored 2026-05-25 (Q3 revision): real Stage 6.A features at full
# BRCA cluster around 150-250 MB per slide for ViT-H/G foundation models.
STANDARD_CORPORA = [
    # Saturation tier (the main concurrency × pattern sweep target)
    {"count": 10000, "file_size_mb": 50, "dtype": "fp32"},
    {"count": 10000, "file_size_mb": 50, "dtype": "fp16"},
    # Production-scale (the 100K-file headline cell)
    {"count": 100000, "file_size_mb": 50, "dtype": "fp32"},
    # File-size sensitivity (fixed N=30K, vary file size)
    # 200 MB tier added 2026-05-25 to match real Stage 6.A feature-size distribution.
    {"count": 30000, "file_size_mb": 5,   "dtype": "fp32"},
    {"count": 30000, "file_size_mb": 10,  "dtype": "fp32"},
    {"count": 30000, "file_size_mb": 50,  "dtype": "fp32"},
    {"count": 30000, "file_size_mb": 200, "dtype": "fp32"},
]


def n_tiles_for_target_file_size(file_size_mb: int, dtype: str) -> int:
    """Compute n_tiles so the resulting .pt is approximately file_size_mb MB.

    Total file size ≈ features (n_tiles × embed_dim × dtype_bytes) +
                       coords (n_tiles × 2 × 8) +
                       per-file metadata overhead (~1 KB)
    Solve for n_tiles. Features dominate; we tune to features = file_size_mb MB.
    """
    target_bytes = file_size_mb * 1024 * 1024
    bytes_per_tile = EMBED_DIM * DTYPE_BYTES[dtype] + 2 * 8  # features + coords
    n = max(1, target_bytes // bytes_per_tile)
    return int(n)


def gen_one_file(args_tuple):
    """Worker function. Generates one synthetic .pt file."""
    (output_dir, file_idx, n_tiles, embed_dim, dtype, name_prefix) = args_tuple
    t0 = time.monotonic()

    # Synthetic features: random gaussian, normalized to roughly unit-scale to
    # match the distribution of real ViT embeddings (post-norm pooled embeddings
    # are typically ~unit-norm).
    rng = np.random.default_rng(seed=file_idx)  # deterministic per-file
    if dtype == "fp32":
        feats_np = rng.standard_normal((n_tiles, embed_dim), dtype=np.float32)
    else:  # fp16
        feats_np = rng.standard_normal((n_tiles, embed_dim), dtype=np.float32).astype(np.float16)

    # Synthetic coords: random pixel positions in a 100K × 100K virtual slide
    coords_np = rng.integers(low=0, high=100000, size=(n_tiles, 2), dtype=np.int64)

    feats = torch.from_numpy(feats_np)
    coords = torch.from_numpy(coords_np)

    slide_id = f"{name_prefix}-{file_idx:06d}"
    payload = {
        "slide_id": slide_id,
        "model": f"synthetic-{name_prefix}",
        "embedding_dim": embed_dim,
        "n_tiles": n_tiles,
        "coords": coords,
        "features": feats,
    }
    out_path = Path(output_dir) / f"{slide_id}.pt"
    # Write to .partial, rename only on success. torch.save writes in place, so a kill
    # or an ENOSPC part-way through leaves a truncated file AT THE FINAL NAME — which
    # the idempotency scan then counts as present on every later run, so the corpus
    # stays short and partly corrupt forever. The 6.B reader registers such a file as
    # one more `errors += 1` against no threshold, and corpus size is precisely the
    # parameter that must exceed both filesystems' caches: a corpus silently 30% short
    # measures cache. Same partial-then-rename pattern as the Tier-2 converter.
    partial_path = Path(str(out_path) + ".partial")
    torch.save(payload, partial_path)
    os.replace(partial_path, out_path)
    t1 = time.monotonic()
    return {
        "file_idx": file_idx,
        "path": str(out_path),
        "wallclock_s": t1 - t0,
        "file_size_bytes": out_path.stat().st_size,
    }


def scan_corpus(output_dir: Path, min_file_bytes: int) -> dict:
    """One stat pass over the corpus dir: which files are COMPLETE, and what is
    actually on disk right now.

    A .pt counts as present only at >= min_file_bytes. Membership by filename alone
    treats a truncated file as done, so a corpus that lost files to a kill or an
    ENOSPC stays short across every later run — and the shortfall is otherwise
    invisible, because nothing else reports the corpus's real file count and byte
    total (the generator's own counters are scoped to the run that wrote them).
    """
    complete, n_files, total_bytes, n_incomplete = set(), 0, 0, 0
    for p in output_dir.glob("*.pt"):
        size = p.stat().st_size
        n_files += 1
        total_bytes += size
        if size >= min_file_bytes:
            complete.add(p.stem)
        else:
            n_incomplete += 1
    return {"complete_stems": complete, "n_files_in_corpus": n_files,
            "corpus_bytes_on_disk": total_bytes, "n_incomplete_files": n_incomplete}


def generate_corpus(count: int, file_size_mb: int, dtype: str,
                    output_base: str, n_workers: int) -> dict:
    """Generate one corpus directory."""
    n_tiles = n_tiles_for_target_file_size(file_size_mb, dtype)
    name_prefix = f"syn-N{count}-sz{file_size_mb}MB-{dtype}"
    output_dir = Path(output_base) / name_prefix
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"[corpus] {name_prefix}: n_tiles={n_tiles} embed_dim={EMBED_DIM} "
          f"(target file size {file_size_mb} MB; {count} files; "
          f"total ~{count * file_size_mb / 1024:.1f} TB)", flush=True)

    # Floor for a complete file: the two tensors' raw bytes. torch.save adds pickle +
    # zip-container overhead on top, so a complete file is always larger and a
    # truncated one is smaller. Deriving the floor rather than comparing against a
    # sibling keeps the check honest when every file in the dir is a stub.
    min_file_bytes = n_tiles * (EMBED_DIM * DTYPE_BYTES[dtype] + 2 * 8)

    # Check for existing files (idempotency) — by completeness, not by name
    scan = scan_corpus(output_dir, min_file_bytes)
    existing = scan["complete_stems"]
    if scan["n_incomplete_files"]:
        print(f"[corpus] {name_prefix}: {scan['n_incomplete_files']} file(s) below the "
              f"{min_file_bytes}-byte floor — regenerating them", flush=True)
    to_generate = [i for i in range(count) if f"{name_prefix}-{i:06d}" not in existing]
    if len(to_generate) < count:
        print(f"[corpus] {len(to_generate)}/{count} files to generate "
              f"({count - len(to_generate)} already complete)", flush=True)
    if not to_generate:
        print(f"[corpus] {name_prefix}: corpus complete; nothing to do "
              f"({scan['n_files_in_corpus']} files, "
              f"{scan['corpus_bytes_on_disk'] / 1024**4:.2f} TiB on disk)", flush=True)
        return {
            "name": name_prefix, "count": count, "file_size_mb": file_size_mb,
            "dtype": dtype, "n_tiles_per_file": n_tiles,
            "output_dir": str(output_dir), "n_generated_this_run": 0,
            "n_existing_skipped": count, "wallclock_s": 0.0,
            "mean_file_size_mb": 0.0, "total_bytes_written": 0,
            "min_file_bytes": min_file_bytes,
            "n_files_in_corpus": scan["n_files_in_corpus"],
            "corpus_bytes_on_disk": scan["corpus_bytes_on_disk"],
            "n_incomplete_files": scan["n_incomplete_files"],
            # Every expected file is complete; any leftover stub in the dir still
            # counts against the corpus, because the 6.B reader will read it.
            "corpus_complete": scan["n_incomplete_files"] == 0,
        }

    work_args = [(str(output_dir), i, n_tiles, EMBED_DIM, dtype, name_prefix)
                 for i in to_generate]

    t0 = time.monotonic()
    with Pool(processes=n_workers) as p:
        results = []
        for i, r in enumerate(p.imap_unordered(gen_one_file, work_args, chunksize=10)):
            results.append(r)
            if (i + 1) % 100 == 0 or (i + 1) == len(to_generate):
                elapsed = time.monotonic() - t0
                rate = (i + 1) / elapsed if elapsed > 0 else 0.0
                eta = (len(to_generate) - (i + 1)) / rate if rate > 0 else 0.0
                print(f"[corpus] {name_prefix}: {i+1}/{len(to_generate)} done "
                      f"({rate:.1f} files/sec; ETA {eta:.0f}s)", flush=True)
    wallclock = time.monotonic() - t0

    sizes = [r["file_size_bytes"] for r in results]
    print(f"[corpus] {name_prefix}: DONE. {len(results)} files in {wallclock:.1f}s "
          f"({len(results) / wallclock:.1f} files/sec write rate). "
          f"Mean file size {np.mean(sizes) / 1024 / 1024:.2f} MB", flush=True)

    # Re-scan: the counters above describe THIS run, not the corpus. What the 6.B
    # cells actually read is whatever is on disk now, and a corpus short of `count`
    # measures a working set smaller than the one the cell claims — the cache-vs-
    # storage question 6.B exists to answer. Report it, per run, either way.
    final = scan_corpus(output_dir, min_file_bytes)
    corpus_complete = (final["n_files_in_corpus"] >= count
                       and final["n_incomplete_files"] == 0)
    print(f"[corpus] {name_prefix}: on disk {final['n_files_in_corpus']}/{count} files, "
          f"{final['corpus_bytes_on_disk'] / 1024**4:.2f} TiB"
          + ("" if corpus_complete else
             f" — INCOMPLETE ({final['n_incomplete_files']} short file(s)); "
             f"cells run against this corpus do NOT have the working set they claim"),
          flush=True)

    return {
        "name": name_prefix,
        "count": count,
        "file_size_mb": file_size_mb,
        "dtype": dtype,
        "n_tiles_per_file": n_tiles,
        "output_dir": str(output_dir),
        "n_generated_this_run": len(results),
        "n_existing_skipped": count - len(to_generate),
        "wallclock_s": wallclock,
        "mean_file_size_mb": float(np.mean(sizes) / 1024 / 1024) if sizes else 0.0,
        "total_bytes_written": int(sum(sizes)),
        "min_file_bytes": min_file_bytes,
        "n_files_in_corpus": final["n_files_in_corpus"],
        "corpus_bytes_on_disk": final["corpus_bytes_on_disk"],
        "n_incomplete_files": final["n_incomplete_files"],
        "corpus_complete": corpus_complete,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--output-base", default=FS_MOUNT + "/features-6.B-synthetic",
                    help="Root directory for synthetic corpora")
    ap.add_argument("--standard-suite", action="store_true",
                    help="Generate the standard 6.B corpus matrix (see STANDARD_CORPORA in script)")
    ap.add_argument("--count", type=int, help="Files in one corpus (without --standard-suite)")
    ap.add_argument("--file-size-mb", type=int, help="Target file size in MB")
    ap.add_argument("--dtype", choices=list(DTYPE_BYTES), help="Feature dtype")
    ap.add_argument("--n-workers", type=int, default=16,
                    help="Parallel generation workers")
    ap.add_argument("--summary-json", help="Write summary of all corpora to this path")
    args = ap.parse_args()

    if args.standard_suite:
        corpora = STANDARD_CORPORA
    else:
        if not (args.count and args.file_size_mb and args.dtype):
            ap.error("without --standard-suite, must provide --count, --file-size-mb, --dtype")
        corpora = [{"count": args.count, "file_size_mb": args.file_size_mb, "dtype": args.dtype}]

    print(f"[gen] generating {len(corpora)} corpus(es) under {args.output_base}", flush=True)
    print(f"[gen] n_workers={args.n_workers}", flush=True)
    total_t0 = time.monotonic()

    summaries = []
    for c in corpora:
        s = generate_corpus(c["count"], c["file_size_mb"], c["dtype"],
                            args.output_base, args.n_workers)
        summaries.append(s)

    total_wall = time.monotonic() - total_t0
    print(f"[gen] ALL corpora done in {total_wall:.1f}s "
          f"(~{total_wall / 60:.1f} min)", flush=True)

    if args.summary_json:
        with open(args.summary_json, "w") as f:
            json.dump({
                "corpora": summaries,
                "total_wallclock_s": total_wall,
                "output_base": args.output_base,
            }, f, indent=2)

    print("=== summary ===")
    print(json.dumps({"corpora": summaries, "total_wallclock_s": total_wall}, indent=2))


if __name__ == "__main__":
    main()
