#!/usr/bin/env python3
"""build-tcga-manifest.py — fetch a gdc-client manifest from the GDC API.

Reusable across stages 1.1, 1.2, 1.3, etc. Output is a 5-column TSV in the
gdc-client manifest format (id / filename / md5 / size / state), consumed by
prefetch-datasets-to-s3.sh via the GDC data API.

Usage:
    build-tcga-manifest.py \\
        --project TCGA-BRCA \\
        --experimental-strategy 'Diagnostic Slide' \\
        --data-format SVS \\
        --sample-size 50 \\
        --random-seed 42 \\
        --output scripts/manifests/tcga-brca-pilot.tsv

Stdlib only. The API call uses urllib (not curl), so it doesn't need
Bash(curl:*) permission.
"""
import argparse
import json
import os
import random
import sys
import urllib.parse
import urllib.request
from pathlib import Path


GDC_API = "https://api.gdc.cancer.gov/files"


def query_gdc(project, experimental_strategy, data_format, page_size=5000):
    """Fetch ALL files matching the filter as JSON. Returns a list of dicts."""
    filters = {
        "op": "and",
        "content": [
            {"op": "in", "content": {"field": "cases.project.project_id", "value": [project]}},
            {"op": "in", "content": {"field": "experimental_strategy", "value": [experimental_strategy]}},
            {"op": "in", "content": {"field": "data_format", "value": [data_format]}},
        ],
    }
    params = {
        "filters": json.dumps(filters),
        "fields": "file_id,file_name,md5sum,file_size,state",
        "format": "json",
        "size": str(page_size),
    }
    url = f"{GDC_API}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = json.loads(resp.read())
    hits = body.get("data", {}).get("hits", [])
    pagination = body.get("data", {}).get("pagination", {})
    print(f"GDC returned {len(hits)} hits (pagination total: {pagination.get('total')})", file=sys.stderr)
    return hits


def write_manifest(hits, out_path: Path):
    """Write a gdc-client manifest TSV: id, filename, md5, size, state."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        f.write("id\tfilename\tmd5\tsize\tstate\n")
        for h in hits:
            f.write(f"{h['file_id']}\t{h['file_name']}\t{h.get('md5sum','')}\t{h.get('file_size','')}\t{h.get('state','')}\n")
    print(f"wrote {out_path} ({len(hits)} entries)", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, help="e.g. TCGA-BRCA")
    ap.add_argument("--experimental-strategy", required=True, help="e.g. 'Diagnostic Slide'")
    ap.add_argument("--data-format", required=True, help="e.g. SVS")
    ap.add_argument("--sample-size", type=int, default=0,
                    help="random subset size; 0 means take all matching")
    ap.add_argument("--random-seed", type=int, default=42,
                    help="seed for reproducible random sampling")
    ap.add_argument("--output", required=True, help="output manifest TSV path")
    args = ap.parse_args()

    hits = query_gdc(args.project, args.experimental_strategy, args.data_format)
    if not hits:
        print("no hits — check filter values", file=sys.stderr)
        sys.exit(1)

    # Filter to only "released" state (defensive — controlled-access slides shouldn't appear here anyway)
    released = [h for h in hits if h.get("state") == "released"]
    print(f"  {len(released)}/{len(hits)} are released-state", file=sys.stderr)

    if args.sample_size > 0 and args.sample_size < len(released):
        rng = random.Random(args.random_seed)
        released = rng.sample(released, args.sample_size)
        print(f"  sampled {args.sample_size} (seed={args.random_seed})", file=sys.stderr)

    # Sort by file_name for human-readable manifest
    released.sort(key=lambda h: h["file_name"])

    total_bytes = sum(int(h.get("file_size", 0)) for h in released)
    print(f"  total size: {total_bytes:,} bytes ({total_bytes/1024**3:.1f} GiB)", file=sys.stderr)

    write_manifest(released, Path(args.output))


if __name__ == "__main__":
    main()
