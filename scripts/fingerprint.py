#!/usr/bin/env python3
"""fingerprint.py — cross-leg artifact fingerprints: capture + compare (D-24 / register D19).

The four storage-independent integrity gates (RUNBOOK.md) are computed and
compared MECHANICALLY — a declared gate no code implements reads as covered.
Fingerprints land in runs/.leg-state/<leg>/fingerprints/<class>.json
(git-tracked, so Leg B compares against Leg A's committed capture) and a
compare mismatch is fail-loud: it invalidates downstream comparison.

Classes (definitions ratified in STAGES.md D19):
  dataset-bytes  sorted (relpath, size, md5-TCGA / size-only-CAM16) -> one
                 SHA-256 over the list + counts + total bytes. md5s come from
                 the GDC manifest — the same values the 1.7 hydration verifier
                 checked per file against the local bytes — re-emitted
                 comparably, not re-hashed (re-hashing 1.8 TiB per capture
                 would cost hours to restate a verification already recorded).
  coords-3.0     per slide: coord count + SHA-256 of the raw coords ARRAY
                 contents (dtype recorded; the array, not the HDF5 container,
                 whose bytes can differ while the coordinates are identical).
                 Catches a missing slide and a shifted grid alike.
  rawtiff-4d     per slide: output byte count + tile-grid dimensions (plus
                 image + tile dims, which the grid derives from — a tile-size
                 drift is a converter-version change worth failing on).
                 Slides enumerated from the D5 cohort + CAM16 subset manifests;
                 a missing artifact refuses rather than fingerprinting a
                 partial cohort.
  features-6a    per (model, dataset): file count, per-slide tile count,
                 tensor shape + dtype — deliberately never tensor values.

Usage:
  fingerprint.py capture <class>            (needs env.sh sourced: FS_MOUNT, LEG)
  fingerprint.py compare <a.json> <b.json>  (exit non-zero on ANY mismatch)

Run with the MAIN env's interpreter (h5py lives there).
"""
import hashlib
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"fingerprint: {name} is unset — source env.sh")
    return v


def sha(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def capture_dataset_bytes(fs_mount):
    entries = []
    # TCGA: manifest md5 + local size (each md5 was verified against the local
    # file by the 1.7 hydration verifier; basis recorded below).
    man = REPO / "scripts" / "manifests" / "tcga-brca-full.tsv"
    root = Path(fs_mount) / "data" / "tcga-brca"
    for line in man.read_text().splitlines()[1:]:
        _id, fname, md5, size, _state = line.split("\t")
        p = root / fname
        if not p.is_file():
            sys.exit(f"fingerprint: MISSING dataset file {p} — refuse to fingerprint a partial corpus")
        entries.append((f"tcga-brca/{fname}", p.stat().st_size, md5))
    # CAM16: size-only, basis stated (manifest carries multipart ETags, not md5s).
    man = REPO / "scripts" / "manifests" / "camelyon16-full.tsv"
    root = Path(fs_mount) / "data" / "camelyon16"
    for line in man.read_text().splitlines()[1:]:
        key, size, _etag = line.split("\t")
        rel = key[len("CAMELYON16/"):]
        if not rel or key.endswith("/"):
            continue
        p = root / rel
        if not p.is_file():
            sys.exit(f"fingerprint: MISSING dataset file {p} — refuse to fingerprint a partial corpus")
        entries.append((f"camelyon16/{rel}", p.stat().st_size, None))
    entries.sort()
    return {
        "class": "dataset-bytes",
        "basis": ("TCGA md5s from the GDC manifest, per-file-verified against local bytes by the 1.7 "
                  "hydration verifier; CAM16 size-only (manifest carries multipart ETags; the S3->S3 "
                  "staging copy was checksummed by S3 end-to-end)"),
        "file_count": len(entries),
        "total_bytes": sum(e[1] for e in entries),
        "list_sha256": sha(entries),
    }


def capture_coords(fs_mount):
    import h5py
    import numpy as np
    out = {"class": "coords-3.0", "datasets": {}}
    for ds in ("tcga-brca", "camelyon16"):
        pdir = Path(fs_mount) / "tissue-detection" / "3.0" / ds / "n64" / "patches"
        slides = {}
        for f in sorted(pdir.glob("*.h5")):
            with h5py.File(f, "r") as h:
                arr = np.ascontiguousarray(h["coords"][:])
            slides[f.stem] = {
                "count": int(arr.shape[0]),
                "dtype": str(arr.dtype),
                "sha256": hashlib.sha256(arr.tobytes()).hexdigest(),
            }
        if not slides:
            sys.exit(f"fingerprint: no coords h5 under {pdir} — run 3.0 first")
        out["datasets"][ds] = {
            "basis": "n64 coords dir (the one downstream stages consume)",
            "slide_count": len(slides),
            "total_coords": sum(s["count"] for s in slides.values()),
            "aggregate_sha256": sha(sorted((k, v["count"], v["sha256"]) for k, v in slides.items())),
            "slides": slides,
        }
    return out


def _manifest_ids(path):
    # Comment-aware, matching the converter: the cohort manifest carries a
    # comment header AND commented excluded-slide IDs at its tail.
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s and not s.startswith("#") and s != "slide_id":
            yield s


def capture_rawtiff(fs_mount):
    import tifffile
    out = {"class": "rawtiff-4d", "datasets": {}}
    specs = [
        ("tcga-brca", REPO / "scripts" / "manifests" / "tcga-brca-full40x-stage4a-format.tsv",
         Path(fs_mount) / "data" / "tcga-brca-rawtiff"),
        ("camelyon16", REPO / "scripts" / "manifests" / "camelyon16-stage4a-subset.tsv",
         Path(fs_mount) / "data" / "camelyon16-rawtiff"),
    ]
    for ds, manifest, root in specs:
        slides = {}
        for sid in _manifest_ids(manifest):
            p = root / f"{sid}.tiff"
            if not p.is_file() or p.stat().st_size == 0:
                sys.exit(f"fingerprint: MISSING/empty raw-TIFF {p} — refuse to fingerprint a partial artifact")
            with tifffile.TiffFile(p) as t:
                pg = t.pages[0]
                w, h = int(pg.imagewidth), int(pg.imagelength)
                tw, th = int(pg.tilewidth), int(pg.tilelength)
            slides[sid] = {
                "bytes": p.stat().st_size,
                "width": w, "height": h,
                "tile_w": tw, "tile_h": th,
                "grid_x": -(-w // tw), "grid_y": -(-h // th),
            }
        if not slides:
            sys.exit(f"fingerprint: no manifest ids for {ds} — nothing to fingerprint")
        out["datasets"][ds] = {
            "basis": "per-slide output byte count + tile-grid dimensions (D19: pixel content follows "
                     "from source bytes + converter commit; count + grid catch every truncation or "
                     "mis-magnification failure mode at a fraction of the read cost)",
            "slide_count": len(slides),
            "total_bytes": sum(s["bytes"] for s in slides.values()),
            "aggregate_sha256": sha(sorted(
                (k, v["bytes"], v["grid_x"], v["grid_y"]) for k, v in slides.items())),
            "slides": slides,
        }
    return out


def capture_features(fs_mount):
    import torch
    out = {"class": "features-6a", "groups": {}}
    # The model set is a held-constant contract input; the dataset tags are the
    # three 6.A tiers' output dirs. Slides enumerate from the same manifests the
    # extraction cells consumed — a missing .pt refuses rather than
    # fingerprinting a partial corpus.
    manifests = {
        "brca50": REPO / "scripts" / "manifests" / "tcga-brca-stage4a-subset.tsv",
        "brca_full": REPO / "scripts" / "manifests" / "tcga-brca-full40x-stage4a-format.tsv",
        "cam16": REPO / "scripts" / "manifests" / "camelyon16-stage4a-subset.tsv",
    }
    for model in ("virchow2", "gigapath", "uni2-h"):
        for ds, manifest in manifests.items():
            root = Path(fs_mount) / "features" / "6.A" / model / ds
            slides = {}
            for sid in _manifest_ids(manifest):
                p = root / f"{sid}.pt"
                if not p.is_file() or p.stat().st_size == 0:
                    sys.exit(f"fingerprint: MISSING/empty feature file {p} — refuse to fingerprint a partial corpus")
                try:
                    obj = torch.load(p, map_location="cpu", weights_only=True, mmap=True)
                except (TypeError, RuntimeError):
                    obj = torch.load(p, map_location="cpu", weights_only=True)
                feats, coords, n_tiles = obj["features"], obj["coords"], int(obj["n_tiles"])
                # Internal consistency: the header count and both tensors must
                # agree, or the file is corrupt in a way downstream cannot see.
                if not (feats.shape[0] == coords.shape[0] == n_tiles):
                    sys.exit(f"fingerprint: INTERNAL MISMATCH in {p}: n_tiles={n_tiles}, "
                             f"features={tuple(feats.shape)}, coords={tuple(coords.shape)}")
                slides[sid] = {
                    "n_tiles": n_tiles,
                    "feat_shape": list(feats.shape),
                    "feat_dtype": str(feats.dtype),
                    "coords_shape": list(coords.shape),
                    "coords_dtype": str(coords.dtype),
                }
            if not slides:
                sys.exit(f"fingerprint: no manifest ids for {model}/{ds} — nothing to fingerprint")
            dims = {s["feat_shape"][1] for s in slides.values()}
            if len(dims) != 1:
                sys.exit(f"fingerprint: {model}/{ds} carries mixed embedding dims {sorted(dims)}")
            out["groups"][f"{model}/{ds}"] = {
                "basis": "per (model, dataset): file count, per-slide tile count, tensor shape + dtype — "
                         "never tensor values (D19: GPU reduction order breaks bitwise equality; shapes "
                         "are the storage-independent invariant)",
                "file_count": len(slides),
                "total_tiles": sum(s["n_tiles"] for s in slides.values()),
                "embedding_dim": dims.pop(),
                "aggregate_sha256": sha(sorted(
                    (k, v["n_tiles"], v["feat_shape"][1], v["feat_dtype"]) for k, v in slides.items())),
                "slides": slides,
            }
    return out


def capture(cls):
    fs_mount, leg = env("FS_MOUNT"), env("LEG")
    fn = {"dataset-bytes": capture_dataset_bytes, "coords-3.0": capture_coords,
          "rawtiff-4d": capture_rawtiff, "features-6a": capture_features}.get(cls)
    if fn is None:
        sys.exit(f"fingerprint: unknown class {cls!r}")
    data = fn(fs_mount)
    data["leg"] = leg
    out = REPO / "runs" / ".leg-state" / leg / "fingerprints" / f"{cls}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    view = {k: v for k, v in data.items() if k not in ("datasets", "groups")}
    for grp_key in ("datasets", "groups"):
        for ds, d in data.get(grp_key, {}).items():
            view[ds] = {k: v for k, v in d.items() if k != "slides"}
    print(json.dumps(view, indent=2, sort_keys=True))
    print(f"fingerprint: wrote {out}")
    return 0


def compare(a_path, b_path):
    a, b = json.loads(Path(a_path).read_text()), json.loads(Path(b_path).read_text())
    if a.get("class") != b.get("class"):
        sys.exit(f"fingerprint: class mismatch {a.get('class')!r} vs {b.get('class')!r}")
    bad = 0

    def walk(x, y, path=""):
        nonlocal bad
        if isinstance(x, dict) and isinstance(y, dict):
            for k in sorted(set(x) | set(y)):
                if k in ("leg", "basis"):
                    continue  # expected to differ / descriptive
                if k not in x or k not in y:
                    print(f"MISMATCH {path}/{k}: present only in {'B' if k in y else 'A'}")
                    bad += 1
                else:
                    walk(x[k], y[k], f"{path}/{k}")
        elif x != y:
            print(f"MISMATCH {path}: {x!r} vs {y!r}")
            bad += 1

    walk(a, b)
    if bad:
        print(f"\nfingerprint compare: FAILED — {bad} mismatch(es). The two legs did not process "
              "identical inputs; downstream comparison is INVALID until explained (RUNBOOK gates).",
              file=sys.stderr)
        return 1
    print("fingerprint compare: MATCH — storage-independent artifacts identical across the two captures.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "capture":
        sys.exit(capture(sys.argv[2]))
    if len(sys.argv) == 4 and sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3]))
    print(__doc__, file=sys.stderr)
    sys.exit(2)
