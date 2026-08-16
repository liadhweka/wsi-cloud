#!/usr/bin/env python3
"""probe-gds-phase0.py — the recorded D8 Phase-0 determination read (one process).

Settles "does WEKA-on-AWS do true GDS?" EMPIRICALLY: a known-good kvikIO read
off the mount with the mode FORCED explicitly (never AUTO — path accounting has
three layers, and AUTO can serve reads via kvikio's POSIX path without ever
entering cuFile), with cuFile's own GPU-direct-vs-bounced byte split recorded
via wsi_cufile_accounting. A configuration flag is not proof of behaviour (D8).

The KVIKIO_COMPAT_MODE environment variable must be set by the caller BEFORE
this interpreter starts (kvikio reads it at import); this script then ASSERTS
kvikio's resolved mode matches --kvikio-compat and refuses on mismatch — a
determination cell whose mode silently differed determines nothing.

A cuFile-layer failure (e.g. strict allow_compat_mode=false refusing on a
non-GDS transport) is a DETERMINATION RESULT, not a probe failure: it is
recorded in the summary and the probe exits 0. The probe exits non-zero only
when it cannot determine (mode mismatch, no accounting, unexpected errors).
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

from wsi_cufile_accounting import PathAccounting

CHUNK = 4 * 1024 * 1024  # 4 MiB, a multiple of the 4096-byte GDS alignment


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--kvikio-compat", required=True, choices=["on", "off"])
    ap.add_argument("--summary-json", required=True)
    a = ap.parse_args()

    want_env = "ON" if a.kvikio_compat == "on" else "OFF"
    if os.environ.get("KVIKIO_COMPAT_MODE", "").upper() != want_env:
        print(f"probe-gds-phase0: REFUSING — KVIKIO_COMPAT_MODE={os.environ.get('KVIKIO_COMPAT_MODE')!r} "
              f"but --kvikio-compat={a.kvikio_compat}; the mode must be forced in the env before "
              "the interpreter starts, or kvikio resolves its own", file=sys.stderr)
        return 2

    import cupy
    import kvikio

    acct = PathAccounting(requested_compat_mode=a.kvikio_compat)
    resolved = acct.resolved.lower()
    # kvikio reports the resolved mode as OFF/ON/AUTO (CompatMode enum name on
    # 26.04; older builds may yield a bool or the bare enum int) — accept any
    # spelling that unambiguously matches the request, refuse everything else.
    ok = (resolved in ("off", "false", "0") if a.kvikio_compat == "off"
          else resolved in ("on", "true", "1"))
    if not ok:
        print(f"probe-gds-phase0: REFUSING — requested compat={a.kvikio_compat} but kvikio "
              f"resolved {acct.resolved!r}; a determination cell whose mode differed determines "
              "nothing", file=sys.stderr)
        return 2

    path = Path(a.file)
    size = path.stat().st_size
    n_chunks = size // CHUNK
    if n_chunks < 1:
        print(f"probe-gds-phase0: test file {path} smaller than one {CHUNK}-byte chunk", file=sys.stderr)
        return 2

    buf = cupy.empty(CHUNK, dtype=cupy.uint8)
    total = 0
    err = None
    t0 = time.monotonic()
    try:
        with kvikio.CuFile(str(path), "r") as f:
            for i in range(n_chunks):
                got = f.pread(buf, CHUNK, file_offset=i * CHUNK).get()
                total += int(got)
    except Exception as e:  # noqa: BLE001 — the failure IS the determination evidence
        err = f"{e.__class__.__name__}: {e}"
    elapsed = time.monotonic() - t0

    summary = {
        "cell": "d8-phase0-determination",
        "file": str(path),
        "file_bytes": size,
        "bytes_read": total,
        "elapsed_s": round(elapsed, 3),
        "gib_per_s": round(total / elapsed / 2**30, 3) if elapsed > 0 and total else None,
        "read_error": err,
        "cufile_env_path_json": os.environ.get("CUFILE_ENV_PATH_JSON"),
        "ld_preload": os.environ.get("LD_PRELOAD"),
        "path_accounting": acct.finish(total),
    }
    Path(a.summary_json).write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))

    pa = summary["path_accounting"]
    if pa["gds_engaged"] in ("unknown-accounting-off", "unknown-format-changed"):
        print("probe-gds-phase0: UNDETERMINED — nvidia-fs accounting unavailable; fix the "
              "counters and re-run (a present-but-zero split must never read as 'no GDS')",
              file=sys.stderr)
        return 3
    if err and total == 0:
        print(f"probe-gds-phase0: determination = the cuFile layer REFUSED under this config "
              f"({err}) — recorded as evidence, not a probe failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
