# GDS / cuFile tuning checklist — the kvikIO path (Stages 4.C / 5.A / 6.A / 7)

> ## ⏳ PENDING RETARGET — DO NOT FOLLOW AS WRITTEN
>
> **This checklist describes a previous, on-premises environment** (a different mount path, an
> InfiniBand fabric, and one filesystem). It is carried forward because the **procedure** — verify
> the path works, measure, then tune against measured throughput — is sound and doc-grounded. The
> **values are not.**
>
> **Rewriting this for the cloud environment is deferred work `D-10`** (see `../../SCRIPT-TRACKER.md`
> and the `cloud-session-open-items` memory). The rewrite must:
>
> 1. **Re-derive every address, path, and version** on the real instance — nothing here is portable.
> 2. **Add a Lustre-over-EFA section.** This project runs the kvikIO path on **both** filesystems
>    (`D8`), so the checklist needs a per-filesystem branch: EFA-enabled FSx for the true-GDS path, and
>    the WEKA client's own transport for the other leg.
> 3. **Treat "is GDS actually active?" as an empirical question per cell.** A compat-mode setting being
>    enabled does **not** tell you which path a read took — verify with `gdscheck` *and* the recorded
>    cuFile GPU-direct-vs-bounced byte accounting, which is a mandatory per-cell source (`D-6`).
> 4. **Keep `LD_PRELOAD` scoped per cell** — cuCIM segfaults when a newer libcufile is preloaded over
>    its bundled one, and nearly every sweep here mixes kvikIO and cuCIM cells.
>
> Original header, for provenance: doc-grounded against the NVIDIA GPUDirect Storage configuration
> guide plus the storage vendor's networking/GDS documentation. Companion to
> `cufile-full-rdma.template.json` (same dir).

## TL;DR — the config as previously tuned (values pending re-derivation)
Our cuFile config carries the **3 WEKA-essential deltas** vs the NVIDIA default
(`allow_compat_mode: true`, the client's IB NIC IPs in `rdma_dev_addr_list`,
`rdma_dynamic_routing: true`); **everything else is at NVIDIA's recommended defaults.**
NVIDIA: *"the default settings work very well across a variety of IO loads… use the
default values unless your storage vendor has a specific recommendation."* WEKA's docs
prescribe nothing beyond the essentials. **So: instantiate the proven config → measure →
tune the candidate knobs ONLY if measured throughput is below the healthy per-client
ceiling.** Do not tune blind.

## Step 1 — host-side prereqs (verify with `gdscheck -p`; these survive a cluster-only reinstall)
- `gdscheck -p` shows: **GDS 1.17.x / nvidia_fs 2.28**, `WekaFS : nvidia_peermem`,
  `Userspace RDMA : Supported`, `Mellanox PeerDirect : Enabled`, rdma library Loaded,
  `rdma_device_status Up`. (gdscheck at `/usr/local/cuda-12.6/gds/tools/gdscheck`.)
- `LD_PRELOAD=/usr/local/cuda-13.2/targets/x86_64-linux/lib/libcufile.so.1.17.0` present
  (must match the kernel `nvidia_fs 2.28`).
- conda env `wsi-cucim-2604` imports `kvikio`/`cupy` with `CONDA_PREFIX` exported.
- `/dev/shm` is mode 1777 (see the env-check note — unrelated to GDS but gates the readers' multiprocessing).

## Step 2 — instantiate `cufile.json` from the template
1. Copy `cufile-full-rdma.template.json` → the `CUFILE_ENV_PATH_JSON` target
   (`~/wsi-debug/p1-gdsio/cufile-full-rdma.json`).
2. **Re-derive + fill `rdma_dev_addr_list`** (BOTH `properties.*` and `fs.weka.*`) = the
   **A100 client's own IB NIC IPs** (the `.102`-style addresses across the IB subnets —
   NOT the backend IPs). Source, in order of preference:
   - the post-reinstall system `/etc/cufile.json` if WEKA repopulated it, or
   - `ip -o -4 addr show` on the client's IB interfaces, or
   - the WEKA client network config.
   These are host-side and *likely unchanged* by a cluster-only reinstall — but **verify**.
3. Confirm the 3 essentials are set: `allow_compat_mode:true`, `rdma_dynamic_routing:true`,
   `rdma_dev_addr_list` fully populated (not the stock 1-of-N).
4. Sanity: `gdscheck -p` now reflects the populated config; a tiny kvikIO read returns data
   (not EBADF — would indicate unaligned/compat-fallback misconfig).

## Step 3 — baseline measurement (defaults)
- Recorded GDS read: `scripts/fe-core-kvikio.sh <label>` (kvikIO N=8) and/or `fe-core-fio.sh`.
- **Primary = WEKA-side Read + RDMA rcv**; run the cross-source canary (rcv ≈ read, ~1×).
  Compare to the **healthy per-client ceiling** (from Phase 0 / the team's expectation —
  never the discredited ~5.5 / ~13 GB/s).
- If baseline ≈ healthy ceiling → **done, leave defaults.** If below → Step 4.

## Step 4 — conditional tuning (ONLY if Step 3 is below the healthy target)
Sweep **one knob at a time**, re-measure each, keep what helps / revert what doesn't:

| knob (`cufile.json`) | default | try | why / when |
|---|---|---|---|
| `execution.max_io_queue_depth` | 128 | 256, 512 | reader issues `n_buffer=256` async preads/batch; 128 can throttle. **Try first.** |
| `execution.max_io_threads` | 4 | 8, 16 | drain many concurrent ~192 KB pread completions faster (multi-GPU) |
| `execution.min_io_threshold_size_kb` | 8192 | 1024, 256 | **4.C.1 faithful only** (large sequential reads) — lets cuFile split them. No effect on random 192 KB tiles. |
| `properties.max_device_pinned_mem_size_kb` | 33554432 | 67108864 | only if pinning errors at very high `n_buffer` × N_GPU |

Leave at defaults (NVIDIA-recommended, irrelevant to our 192 KB IO): `use_poll_mode` (false —
poll only helps sub-4 KB), `max_direct_io_size_kb` (16384), `max_request_parallelism` (4).
Record every cell via `record-run.sh` so the helpful knob is reproducible vs the baseline.

## Sources
- NVIDIA GPUDirect Storage configuration guide (cufile.json parameters): https://docs.nvidia.com/gpudirect-storage/configuration-guide/index.html
- WEKA networking / GDS: https://docs.weka.io/weka-system-overview/networking-in-wekaio
