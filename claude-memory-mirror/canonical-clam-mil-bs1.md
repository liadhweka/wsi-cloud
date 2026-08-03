---
name: canonical-clam-mil-bs1
description: "CLAM-style attention-MIL training MUST use batch_size=1 + collate_MIL (concat one slide's [N_tiles, D] tensor), never a padded [B, max_N, D] batch (which OOMs on wide WSI bag-size distributions). Storage concurrency comes from DataLoader num_workers, not batch_size. Verified against mahmoodlab/CLAM."
metadata:
  node_type: memory
  type: project
---

When training a CLAM-style attention-MIL classifier on per-slide foundation-model features, the trainer
MUST use `batch_size=1` with a `collate_MIL` that returns one slide's `[N_tiles, D]` tensor unchanged;
the model forward takes 2-D `[N, D]` and emits `[1, n_classes]`.

**Storage concurrency is driven by `DataLoader.num_workers`, not `batch_size`** — sweep `num_workers`
for the I/O axis. This is the load-bearing point for a storage benchmark: `num_workers` is the knob that
varies concurrent read pressure on the filesystem, and it is one of the axes where two filesystems are
most likely to diverge.

**Why:** the non-canonical padded `[B, max_N, D]` design OOMs — padding to the batch's largest slide
inflates input memory by (max bag size × B), and WSI bag-size distributions are wide. Verified against
`github.com/mahmoodlab/CLAM`: `utils/utils.py` `get_split_loader`/`collate_MIL` always set
`batch_size=1`; `models/model_clam.py` `CLAM_SB.forward(h, ...)` takes 2-D input. **Don't reintroduce
padded-batch MIL.** Optional per-slide tile cap for regularisation if a config gets memory-stressed:
Tellez et al. 2024 (`arXiv:2403.05351`), citable budget 1024.

Magnification-independent (holds at 20× or 40×) and filesystem-independent — the same trainer runs
unchanged on both legs, which is what makes it a valid comparison cell. The ResNet-50 DDP training stage
is a different model class and is not affected.

Related: `[[uni2h-conditional-use-status]]`, `[[weka-vs-lustre-cloud-project]]`.
