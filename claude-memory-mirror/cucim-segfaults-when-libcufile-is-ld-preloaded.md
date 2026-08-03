---
name: cucim-segfaults-when-libcufile-is-ld-preloaded
description: "Durable gotcha for any sweep mixing kvikIO and cuCIM cells: cuCIM segfaults inside read_region() when a libcufile newer than its bundled one is LD_PRELOAD'd (ABI clash). Fix is to scope LD_PRELOAD per-cell. Exact versions are era-specific — re-verify on the cloud stack; the pattern is what's durable."
metadata:
  node_type: memory
  type: project
---

kvikIO/cuFile performs best with the *system* `libcufile` matched to the kernel `nvidia-fs` module,
which typically means `LD_PRELOAD`-ing it over the older copy a cuCIM conda env bundles. But **cuCIM's
`read_region()` links libcufile internally even with `device='cpu'`**, and an ABI mismatch between the
preloaded and bundled versions **segfaults inside the first cuCIM read**.

**Fix — scope `LD_PRELOAD` per cell, never per sweep:** set it only on kvikIO cells, unset on cuCIM
cells (pattern: `preload=""; [ "$backend" = kvikio ] && preload="$LIBCUFILE_SYSTEM"`). This project's
measurement matrix runs kvikIO *and* plain-POSIX/cuCIM backends on both filesystems, so essentially
every sweep is a mixed sweep — the trap is live, not hypothetical.

**Symptom if forgotten:** the reader initialises cleanly, then segfaults on the first
`slide.read_region(...)`. Easy to misdiagnose as an `mp.spawn` or cuCIM bug rather than a preload
problem.

**Versions:** originally confirmed with cuCIM 26.04 (bundled libcufile 1.14.1) against system libcufile
1.17.0 / nvidia-fs 2.28.2. **Those numbers are not facts about the cloud environment** — re-derive the
installed versions there and re-verify. The durable part is the *pattern*: bundled-vs-system libcufile
skew breaks cuCIM under preload, so scope it per-cell regardless of version.

Related: `[[cucim-read-region-device-cuda-non-viable-for-random-tile-reads]]`,
`[[weka-vs-lustre-cloud-project]]`.
