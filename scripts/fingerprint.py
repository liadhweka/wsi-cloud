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
  rawtiff-4d     per slide: output byte count + tile-grid dimensions.
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


def capture(cls):
    fs_mount, leg = env("FS_MOUNT"), env("LEG")
    fn = {"dataset-bytes": capture_dataset_bytes, "coords-3.0": capture_coords}.get(cls)
    if fn is None:
        # rawtiff-4d / features-6a: built when their artifacts first exist — a
        # fingerprint format designed against imagined output gets rewritten (D-24).
        sys.exit(f"fingerprint: class {cls!r} not implemented yet — build it against the real artifact "
                 "when 4.D / 6.A first produce output (D-24)")
    data = fn(fs_mount)
    data["leg"] = leg
    out = REPO / "runs" / ".leg-state" / leg / "fingerprints" / f"{cls}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    view = {k: v for k, v in data.items() if k != "datasets"}
    for ds, d in data.get("datasets", {}).items():
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
