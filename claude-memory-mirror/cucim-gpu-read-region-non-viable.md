---
name: cucim-read-region-device-cuda-non-viable-for-random-tile-reads
description: "cuCIM read_region(device='cuda') is non-viable for random-tile WSI reads — a cuCIM-internal buffer-allocation bug plus pre-GA status. It is a library defect, filesystem-independent. The GPU-direct path is kvikIO + uncompressed raw TIFF + cuFile. Don't re-investigate this axis."
metadata:
  node_type: memory
  type: project
---

`cuCIM.read_region(device='cuda')` is not viable for random-tile reads: it is officially pre-GA upstream,
and cuCIM pre-allocates a single GPU buffer spanning the min→max tile offset per batched call
(`nvjpeg_processor.cpp`), which OOMs on scattered coordinates.

**This is a cuCIM library defect, not a property of any filesystem** — it will behave identically on
WEKA and on Lustre, so it is not a comparison axis and must never be reported as a storage finding for
either side. The open-source ecosystem (MONAI / Slideflow / CLAM / Trident) all use CPU per-tile reads
for the same reason.

**The GPU-direct path that does work is kvikIO + uncompressed raw TIFF + cuFile**, which this project
runs on both filesystems (true GDS on Lustre-over-EFA; compat-mode fallback expected on WEKA-over-ENA —
verified per cell, never assumed). **Don't re-investigate the cuCIM-GPU axis.**

*(Version-sensitive: the buffer-allocation behaviour was confirmed on cuCIM 26.04. Re-verify against
whatever version the cloud environment installs before treating it as current — but the conclusion has
held across releases and upstream still marks the API pre-GA.)*

Related: `[[cucim-segfaults-when-libcufile-is-ld-preloaded]]`, `[[weka-vs-lustre-cloud-project]]`.
