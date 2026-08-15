#!/usr/bin/env python3
"""wsi_cufile_accounting.py — per-cell cuFile path accounting (D-6 / D8).

A configuration flag is not proof of behaviour: a kvikIO cell must RECORD which
path its bytes actually took. Path accounting has THREE layers (established on
this stack, 2026-08-15):

  layer 1  kvikio's own compat mode — ON (or AUTO resolving on) serves reads
           through kvikio's POSIX path WITHOUT ever entering cuFile: nvidia-fs
           and cuFile see nothing, correctly.
  layer 2  cuFile compat/bounce — kvikio compat OFF calls the cuFile API, whose
           own config decides GDS vs an internal POSIX bounce buffer.
  layer 3  nvidia-fs — counts ONLY true GPU-direct I/O. Its counters default
           OFF; an all-zero split with accounting off reads as "no GPU-direct
           traffic" instead of "accounting was off", so that state is reported
           as UNKNOWN-ACCOUNTING-OFF, never as zero.

Usage (inside a kvikIO reader, one accounting object per process):
    acct = PathAccounting(requested_compat_mode="off")   # after kvikio setup
    ... reads ...
    summary["path_accounting"] = acct.finish(total_bytes_read)

The record-run wrapper independently captures the verbatim 1 Hz
/proc/driver/nvidia-fs/stats timeline; this module supplies the per-process
byte split and the layer verdict. Stdlib only (kvikio imported lazily).
"""

import re
from pathlib import Path

_NVFS_STATS = Path("/proc/driver/nvidia-fs/stats")


def nvfs_snapshot():
    """Parse /proc/driver/nvidia-fs/stats (NVFS statistics ver 4.0 format).

    Returns dict with: available, stats_enabled, read_mib, write_mib,
    read_n, write_n, shadow_buffer_mib, raw versions. Field names verified on
    the live enabled stack (n=/ok=/err=/readMiB=... lines); a format change
    yields available=True with missing keys rather than a wrong number.
    """
    out = {"available": _NVFS_STATS.exists()}
    if not out["available"]:
        return out
    text = _NVFS_STATS.read_text()
    m = re.search(r"IO stats: (Enabled|Disabled)", text)
    out["stats_enabled"] = bool(m and m.group(1) == "Enabled")
    m = re.search(r"Active Shadow-Buffer \(MiB\):\s*(\d+)", text)
    out["shadow_buffer_mib"] = int(m.group(1)) if m else None
    m = re.search(r"NVFS statistics\(ver:\s*([\d.]+)\)", text)
    out["nvfs_stats_ver"] = m.group(1) if m else None
    for direction, key in (("Reads", "read"), ("Writes", "write")):
        n = re.search(rf"^{direction}\s*:\s*n=(\d+)", text, re.M)
        mib = re.search(rf"^{direction}\s*:.*?\b{'read' if key == 'read' else 'write'}MiB=(\d+)", text, re.M)
        out[f"{key}_n"] = int(n.group(1)) if n else None
        out[f"{key}_mib"] = int(mib.group(1)) if mib else None
    return out


def kvikio_resolved_compat_mode():
    """kvikio's compat setting as kvikio itself resolves it, best effort."""
    try:
        import kvikio.defaults
        try:
            v = kvikio.defaults.get("compat_mode")
        except Exception:
            v = kvikio.defaults.compat_mode()
        return str(v)
    except Exception as e:  # noqa: BLE001 — record the failure, never guess
        return f"unresolvable ({e.__class__.__name__})"


class PathAccounting:
    """Snapshot nvidia-fs at construction; finish() computes the byte split."""

    def __init__(self, requested_compat_mode):
        self.requested = str(requested_compat_mode)
        self.resolved = kvikio_resolved_compat_mode()
        self.start = nvfs_snapshot()

    def finish(self, app_bytes_read):
        end = nvfs_snapshot()
        rec = {
            "kvikio_compat_mode_requested": self.requested,
            "kvikio_compat_mode_resolved": self.resolved,
            "nvfs_available": end.get("available", False),
            "nvfs_stats_enabled": end.get("stats_enabled"),
            "app_bytes_read": int(app_bytes_read),
            "shadow_buffer_mib_seen": max(
                (v for v in (self.start.get("shadow_buffer_mib"), end.get("shadow_buffer_mib"))
                 if v is not None), default=None),
            "basis": ("gds_bytes = nvidia-fs readMiB delta (layer 3, true GPU-direct only); "
                      "bounced_or_posix_bytes = app - gds (cuFile bounce or kvikio posix; "
                      "the kvikio compat fields say which layer)"),
        }
        if not end.get("available") or not end.get("stats_enabled"):
            # The standing constraint: a present-but-all-zero split with the
            # accounting off must never read as "no GPU-direct traffic".
            rec["gds_bytes"] = None
            rec["bounced_or_posix_bytes"] = None
            rec["gds_engaged"] = "unknown-accounting-off"
            return rec
        s_mib, e_mib = self.start.get("read_mib"), end.get("read_mib")
        if s_mib is None or e_mib is None:
            rec["gds_bytes"] = None
            rec["bounced_or_posix_bytes"] = None
            rec["gds_engaged"] = "unknown-format-changed"
            return rec
        gds = max(0, e_mib - s_mib) * 1024 * 1024
        rec["gds_bytes"] = gds
        rec["bounced_or_posix_bytes"] = max(0, int(app_bytes_read) - gds)
        if app_bytes_read <= 0:
            rec["gds_engaged"] = "no-reads"
        elif gds >= 0.9 * app_bytes_read:
            rec["gds_engaged"] = "gds"
        elif gds > 0:
            rec["gds_engaged"] = "partial"
        else:
            rec["gds_engaged"] = "none"
        return rec


if __name__ == "__main__":
    import json
    print(json.dumps(nvfs_snapshot(), indent=2))
    print("kvikio resolved compat:", kvikio_resolved_compat_mode())
