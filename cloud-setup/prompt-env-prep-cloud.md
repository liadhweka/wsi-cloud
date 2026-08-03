# Task prompt — prepare a fresh cloud GPU instance's system stack + local scratch

You are Claude Code on a **brand-new AWS GPU instance**, working in the freshly cloned project repo. This is
a **one-off system-prep task that runs before the main project setup.** Your job: get the hardware and
software stack ready for a **GPUDirect-Storage + PyTorch/cuCIM/kvikIO + network-filesystem** benchmark,
provision the local NVMe scratch, and **report back**.

**Do NOT** build the project environments, download datasets, or run any benchmark — those come next, driven
by `cloud-setup/handoff-cloud.md`.

## Rules you operate under

- **Verify before you change anything.** Read-only check first, always.
- **Ask before any destructive operation** — especially formatting disks — and before large installs, stating
  exactly what will happen and what would be lost.
- **Reference official docs, not memory,** for every command, flag, and version: the NVIDIA GPUDirect Storage
  install guide, NVIDIA driver/CUDA docs, AWS EC2 / EFA docs, and the storage vendors' own documentation.
  **Cloud specs and package names change** — fetch, don't recall. Doc-fetching is standing-approved.
- **Install what installs cleanly; flag what needs the human or a reboot.** Kernel-module and networking
  changes usually need both.
- **Fail loud.** If you cannot verify something worked, say so plainly rather than reporting success.

## Context you need

**This project compares two filesystems** — WEKA (Leg A, now) and FSx for Lustre (Leg B, later) — on this
same instance. So the stack you prepare must serve **both**, even though only WEKA is mounted today.

**GPUDirect Storage is in scope and is NOT optional.** An earlier version of this plan dropped GDS; it was
reinstated. You need the GDS stack present and working because:
- The Lustre leg uses **true GDS over EFA**, and
- the WEKA leg still runs the **same cuFile code path in compat mode**, which needs `libcufile` regardless.

So: verify the whole GDS stack now, even if this instance's current mount may not use the direct path.

## Do these, in order

1. **GPU + driver + CUDA.** `nvidia-smi` — record **GPU model, count, memory**, driver and CUDA versions. If
   the driver is missing, **stop and report**: installing a GPU driver on a bare instance is a reboot-class
   task for the human.
2. **CUDA toolkit + GDS tools + `libcufile`.** Locate `gdscheck` and `gdsio` (typically under the CUDA
   install's `gds/tools/`, often **not** on `$PATH`) and `libcufile.so.*` — record the version. If absent,
   note what needs installing and cite the NVIDIA GDS install guide.
3. **GDS kernel path.** `nvidia-fs` module version and whether the GPU peer-memory module is loaded. Record
   both versions and **whether they are matched to each other** — a mismatch is a known source of subtle
   failures. Load or install if cleanly possible; **flag anything needing a module build or reboot.**
4. **Networking.** Record **which network interfaces exist, their types, and their link rates**; whether
   **EFA** is present and its driver/libfabric versions; and all interface addresses (you will need them for
   the cuFile configuration later). **EFA matters even though Leg A does not use it** — Leg B requires it, and
   it must be working on this instance.
5. **System tools** (ask before installing): `git build-essential tmux rsync curl jq sysstat fio fpart
   fpsync`. `sysstat` provides the `sar` tooling the recorder uses.
6. **Local NVMe scratch at `/data/local-nvme`.** This is fast scratch for the Python environments, dataset
   staging, and in-flight telemetry. Inspect with `lsblk`. Identify the instance's local NVMe devices and
   propose a layout — RAID-0 across them if there are several, otherwise a single filesystem. **This ERASES
   those devices: show the human exactly which devices, confirm they are empty and unused, and get an
   explicit OK before any array creation or `mkfs`.** Then format, mount at `/data/local-nvme` with
   `noatime,nofail`, persist in `/etc/fstab`, and chown to the benchmark user. Create subdirs:
   `conda-envs/ fpsync-source/ staging/ runs/`. **Verify free space of at least ~2 TB.**
   > ⚠ **Instance store is ephemeral** — it dies with the instance, including between legs. Nothing that
   > matters may live here. Say this in your report so it is not forgotten later.
7. **Miniforge** → install to `/data/local-nvme/miniforge`, keeping it off the OS disk. **Do not build the
   project environments yet** — the handoff does that from `cloud-setup/env-specs/`.
8. **OS hygiene.** Ensure `/dev/shm` is mode **1777** (a more restrictive mode silently breaks Python
   multiprocessing later, which is hard to diagnose from the symptom). Note free space on `/`.
9. **AWS access sanity.** Confirm the instance can reach its S3 bucket **via the IAM instance profile, not
   credentials on disk** — a read and a small write. This is the durable store the whole project depends on;
   if it does not work, everything downstream silently has nowhere safe to land.

## Report back (then stop)

1. **A component table:** GPU/driver/CUDA · CUDA-toolkit + GDS tools · `nvidia-fs` + peer-memory module ·
   networking incl. EFA · system tools · local NVMe · miniforge · `/dev/shm` · S3 access →
   **present? / version / installed-now / MISSING → needs human**.
2. **The hardware topology summary** — GPU↔NUMA↔NIC affinity, NUMA nodes and core counts, and interface link
   rates. **Capture this clearly**: the project handoff uses it to derive GPU pinning and concurrency ranges,
   and those values must not be guessed.
3. **The `/data/local-nvme` layout and free space.**
4. **Whether the GDS stack is functional**, with the evidence you used — and note explicitly that whether
   *true* GDS is achievable on the currently mounted filesystem is an **empirical question for the benchmark
   session**, not something to conclude here from a configuration flag.
5. **A ready / not-ready verdict** plus a numbered list of anything the human still needs to resolve, each
   with a recommendation.

Then **stop.** The human continues with `cloud-setup/NEW-CLOUD-SETUP.md` (restore memories, HF login, mount
the filesystem) and then pastes the project handoff.
