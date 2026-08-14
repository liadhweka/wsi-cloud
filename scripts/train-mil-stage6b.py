#!/usr/bin/env python3
"""train-mil-stage6b.py — Stage 6.B.3 attention-MIL classifier trainer (canonical CLAM bs=1).

Reads real 6.A foundation-model features (per-slide .pt files containing
[N_tiles, D] tensors) and trains a CLAM-style attention-MIL classifier head
on synthetic slide-level labels. Customer-facing context: this validates the
Phase 2 metadata-stress workload in its production training context.

CLAM-MIL architecture (per Lu et al. 2021 + Mahmood Lab CLAM reference impl):
  - per-tile feature [D] → linear → tanh + linear → sigmoid → element-wise product
  - attention head linear → softmax across tiles → attention weights [N_tiles]
  - weighted sum across tiles → slide-level feature [D]
  - linear classifier → 2-way logits (binary classification)

CANONICAL CLAM CONVENTION (architecture revised 2026-05-25 after first 6.B.3 sweep
OOM'd at bs>=16): batch_size=1, one slide per forward step, no padding.
`collate_MIL` returns the single slide's [N, D] feature tensor unchanged. Model
forward takes h:[N, D] (2D, single-bag) and produces logits:[1, n_classes].
This matches `dataset_modules/dataset_generic.py` + `utils/utils.py` (`collate_MIL`)
+ `models/model_clam.py` (`CLAM_SB.forward`) at github.com/mahmoodlab/CLAM. Storage
concurrency comes from DataLoader's `num_workers` (each prefetches one slide); the
customer-quotable IO axis is num_workers, NOT batch_size.

Training: single-GPU (MIL aggregator is tiny — Linear(D, 384) × 2 + small head + classifier).
AMP autocast fp16 for the attention head + classifier; cross-entropy loss against
synthetic binary labels (slide_id md5 hash → label).

DataLoader: torch.utils.data.DataLoader with N workers, bs=1, persistent_workers.
Each worker reads .pt files via torch.load() — this is the IO pattern Stage 6.B.3
measures. Worker count is the customer-quotable axis.

Optional `--max-tiles-per-slide` fallback for outlier slides: random subsample at
__getitem__ (Tellez et al. 2024 arXiv:2403.05351). Not needed at bs=1 for our
N_tiles distribution (max ~127K × 1280 fp32 = 0.65 GiB input + ~2.5 GiB with
autograd), but available as a safety knob.

Per-step CSV columns (mirrors Stage 5):
  step_idx, phase, t_step_start_s, t_step_end_s, step_duration_ms,
  t_dataload_ms, t_forward_ms, t_backward_ms, t_optimizer_ms,
  samples_per_step (=1 at canonical CLAM bs=1), num_workers, loss, n_tiles

Usage (typically invoked by sweep-stage6b-mil.sh):
  train-mil-stage6b.py \\
    --features-dir $FS_MOUNT/features/6.A/virchow2/brca_full \\
    --num-workers 4 \\
    --ramp 300 --runtime 900 \\
    --embedding-dim 1280 \\
    --training-steps-csv <run-dir>/training-steps.csv \\
    --summary-json <run-dir>/training-summary.json
"""
import argparse
import csv
import glob
import json
import os
import sys
import time
import hashlib
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.cuda.amp import GradScaler, autocast
from torch.utils.data import DataLoader, Dataset


class MILFeatureDataset(Dataset):
    """Loads per-slide .pt files (from Stage 6.A extractor output) on-the-fly.

    Each .pt has {'features': [N_tiles, D], 'coords': [N_tiles, 2], 'slide_id': str, ...}.
    Returns (features [N_tiles, D], label int) per slide.
    """
    def __init__(self, features_dir, embedding_dim, max_tiles_per_slide=None):
        self.files = sorted(glob.glob(os.path.join(features_dir, "*.pt")))
        if not self.files:
            raise RuntimeError(f"no .pt files in {features_dir}")
        self.embedding_dim = embedding_dim
        self.max_tiles_per_slide = max_tiles_per_slide

    def __len__(self):
        return len(self.files)

    def __getitem__(self, idx):
        path = self.files[idx]
        payload = torch.load(path, weights_only=False)
        feats = payload["features"]  # [N_tiles, D]
        slide_id = payload.get("slide_id", Path(path).stem)
        if feats.dtype != torch.float32:
            feats = feats.to(torch.float32)
        # Optional cap on tile count (avoids memory blowups on giant slides)
        if self.max_tiles_per_slide and feats.shape[0] > self.max_tiles_per_slide:
            idx_perm = torch.randperm(feats.shape[0])[:self.max_tiles_per_slide]
            feats = feats[idx_perm]
        # Synthetic binary label: hash slide_id to {0, 1}
        h = int(hashlib.md5(slide_id.encode()).hexdigest(), 16)
        label = h % 2
        return feats, label, slide_id


def collate_MIL(batch):
    """Canonical CLAM bs=1 collate: unwrap the single (feats, label, slide_id) item.

    Mirrors `collate_MIL` in mahmoodlab/CLAM utils/utils.py — at batch_size=1
    we just return one slide's tensor [N, D] unchanged, alongside a 1-element
    label tensor and the slide_id string.

    Output:
      features:    [N, D] float32 (single bag, variable N per slide)
      label:       [1] int64
      slide_id:    str
    """
    assert len(batch) == 1, "Stage 6.B.3 trainer is canonical CLAM bs=1 only"
    feats, label_int, slide_id = batch[0]
    return feats, torch.tensor([label_int], dtype=torch.int64), slide_id


class CLAMAttention(nn.Module):
    """CLAM-style gated attention pooler + binary classifier (canonical bs=1)."""
    def __init__(self, embed_dim: int, hidden_dim: int = 384, n_classes: int = 2,
                 dropout: float = 0.25):
        super().__init__()
        self.attention_V = nn.Sequential(
            nn.Linear(embed_dim, hidden_dim), nn.Tanh(), nn.Dropout(dropout)
        )
        self.attention_U = nn.Sequential(
            nn.Linear(embed_dim, hidden_dim), nn.Sigmoid(), nn.Dropout(dropout)
        )
        self.attention_head = nn.Linear(hidden_dim, 1)
        self.classifier = nn.Linear(embed_dim, n_classes)

    def forward(self, h):
        # h: [N, D] single bag (canonical CLAM convention)
        V = self.attention_V(h)                              # [N, H]
        U = self.attention_U(h)                              # [N, H]
        A = self.attention_head(V * U).squeeze(-1)           # [N]
        attn = F.softmax(A, dim=0)                           # [N]
        slide_repr = (attn.unsqueeze(-1) * h).sum(dim=0, keepdim=True)  # [1, D]
        logits = self.classifier(slide_repr)                 # [1, n_classes]
        return logits, attn


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--features-dir", required=True,
                    help="Directory of per-slide .pt files (Stage 6.A output)")
    ap.add_argument("--embedding-dim", type=int, required=True,
                    help="Per-tile embedding dim (1280 Virchow2, 1536 UNI2-h/GigaPath)")
    ap.add_argument("--num-workers", type=int, default=4,
                    help="DataLoader workers — the customer-quotable IO concurrency axis. "
                         "bs is locked to 1 (canonical CLAM); num_workers drives storage pressure.")
    ap.add_argument("--ramp", type=float, default=300.0)
    ap.add_argument("--runtime", type=float, default=900.0)
    ap.add_argument("--training-steps-csv", required=True)
    ap.add_argument("--summary-json", required=True)
    ap.add_argument("--gpu", type=int, default=0)
    ap.add_argument("--max-tiles-per-slide", type=int, default=0,
                    help="Optional Tellez-2024 random subsample per epoch "
                         "(arXiv:2403.05351, 1024 budget is the cited default). "
                         "Default 0 = no cap; fits GPU memory at canonical bs=1 even on max-tile slides.")
    ap.add_argument("--hidden-dim", type=int, default=384)
    ap.add_argument("--lr", type=float, default=1e-4)
    args = ap.parse_args()

    torch.cuda.set_device(args.gpu)
    device = torch.device(f"cuda:{args.gpu}")
    torch.backends.cudnn.benchmark = True

    print(f"[mil] features_dir={args.features_dir}", flush=True)
    print(f"[mil] embed_dim={args.embedding_dim} canonical-CLAM bs=1 "
          f"num_workers={args.num_workers}", flush=True)
    print(f"[mil] ramp={args.ramp}s steady={args.runtime}s", flush=True)

    dataset = MILFeatureDataset(args.features_dir, args.embedding_dim,
                                 max_tiles_per_slide=args.max_tiles_per_slide or None)
    print(f"[mil] dataset: {len(dataset)} slides", flush=True)

    loader = DataLoader(
        dataset, batch_size=1, shuffle=True,
        num_workers=args.num_workers, collate_fn=collate_MIL,
        pin_memory=True, persistent_workers=(args.num_workers > 0),
        drop_last=False,
    )

    model = CLAMAttention(args.embedding_dim, hidden_dim=args.hidden_dim).to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    scaler = GradScaler()
    criterion = nn.CrossEntropyLoss()

    # CSV setup
    Path(args.training_steps_csv).parent.mkdir(parents=True, exist_ok=True)
    csv_file = open(args.training_steps_csv, "w", newline="")
    csv_writer = csv.DictWriter(csv_file, fieldnames=[
        "step_idx", "phase", "t_step_start_s", "t_step_end_s",
        "step_duration_ms", "t_dataload_ms", "t_forward_ms",
        "t_backward_ms", "t_optimizer_ms",
        "samples_per_step", "num_workers", "loss", "n_tiles_in_step",
    ])
    csv_writer.writeheader()

    # CUDA events for timing
    ev_start = torch.cuda.Event(enable_timing=True)
    ev_after_dataload = torch.cuda.Event(enable_timing=True)
    ev_after_forward = torch.cuda.Event(enable_timing=True)
    ev_after_backward = torch.cuda.Event(enable_timing=True)
    ev_after_optim = torch.cuda.Event(enable_timing=True)

    t_zero = time.monotonic()
    t_ramp_end = t_zero + args.ramp
    t_end = t_zero + args.ramp + args.runtime

    step_idx = 0
    steady_slides = 0
    steady_tiles = 0
    steady_steps = 0

    # Iterate the loader in an infinite epoch loop
    data_iter = iter(loader)
    while time.monotonic() < t_end:
        ev_start.record()
        try:
            batch = next(data_iter)
        except StopIteration:
            data_iter = iter(loader)
            batch = next(data_iter)
        features, labels, _slide_id = batch
        features = features.to(device, non_blocking=True)  # [N, D]
        labels = labels.to(device, non_blocking=True)       # [1]
        ev_after_dataload.record()

        n_tiles_in_step = features.shape[0]
        t_step_start_wall = time.monotonic()
        phase = "ramp" if t_step_start_wall < t_ramp_end else "steady"

        optimizer.zero_grad(set_to_none=True)
        with autocast(dtype=torch.float16):
            logits, _attn = model(features)
            loss = criterion(logits, labels)
        ev_after_forward.record()

        scaler.scale(loss).backward()
        ev_after_backward.record()

        scaler.step(optimizer)
        scaler.update()
        ev_after_optim.record()

        torch.cuda.synchronize(device)
        t_step_end_wall = time.monotonic()

        dl_ms = ev_start.elapsed_time(ev_after_dataload)
        fw_ms = ev_after_dataload.elapsed_time(ev_after_forward)
        bw_ms = ev_after_forward.elapsed_time(ev_after_backward)
        opt_ms = ev_after_backward.elapsed_time(ev_after_optim)

        csv_writer.writerow({
            "step_idx": step_idx, "phase": phase,
            "t_step_start_s": f"{t_step_start_wall - t_zero:.6f}",
            "t_step_end_s": f"{t_step_end_wall - t_zero:.6f}",
            "step_duration_ms": f"{(t_step_end_wall - t_step_start_wall) * 1000:.3f}",
            "t_dataload_ms": f"{dl_ms:.3f}",
            "t_forward_ms": f"{fw_ms:.3f}",
            "t_backward_ms": f"{bw_ms:.3f}",
            "t_optimizer_ms": f"{opt_ms:.3f}",
            "samples_per_step": 1,
            "num_workers": args.num_workers,
            "loss": f"{loss.item():.6f}",
            "n_tiles_in_step": n_tiles_in_step,
        })
        if step_idx % 50 == 0:
            csv_file.flush()
            print(f"[mil] step={step_idx} phase={phase} n_tiles={n_tiles_in_step} "
                  f"step_ms={(t_step_end_wall - t_step_start_wall)*1000:.1f} "
                  f"dl={dl_ms:.1f} fw={fw_ms:.1f} bw={bw_ms:.1f} opt={opt_ms:.1f} "
                  f"loss={loss.item():.4f}", flush=True)

        if phase == "steady":
            steady_slides += 1
            steady_tiles += n_tiles_in_step
            steady_steps += 1
        step_idx += 1

    csv_file.close()
    slides_per_sec = steady_slides / args.runtime if args.runtime > 0 else 0.0
    tiles_per_sec = steady_tiles / args.runtime if args.runtime > 0 else 0.0
    summary = {
        "features_dir": args.features_dir,
        "embedding_dim": args.embedding_dim,
        "batch_size": 1,  # canonical CLAM
        "num_workers": args.num_workers,
        "ramp_s": args.ramp,
        "runtime_s": args.runtime,
        "n_slides_in_corpus": len(dataset),
        "total_steady_steps": steady_steps,
        "total_steady_slides": steady_slides,
        "total_steady_tiles": steady_tiles,
        "slides_per_sec_steady": slides_per_sec,
        "tiles_per_sec_steady": tiles_per_sec,
        "samples_per_sec_steady": slides_per_sec,  # alias for aggregator compat (samples == slides at bs=1)
        "max_tiles_per_slide_cap": args.max_tiles_per_slide or None,
        "training_steps_csv": args.training_steps_csv,
    }
    with open(args.summary_json, "w") as f:
        json.dump(summary, f, indent=2)
    print("=== summary ===")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
