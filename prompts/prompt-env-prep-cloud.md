# Task prompt — prepare a fresh cloud GPU instance's system stack + local scratch

You are Claude Code on a **brand-new AWS GPU instance**, working in the freshly cloned project repo. This is
a **one-off system-prep task that runs before the main project setup.** Your job: get the hardware and
software stack ready for a **GPUDirect-Storage + PyTorch/cuCIM/kvikIO + network-filesystem** benchmark,
provision the local NVMe scratch, and **report back**.

**Do NOT** build the project environments, download datasets, or run any benchmark — those come next, driven
by `prompts/handoff-cloud.md`.

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

**This project compares two filesystems** — WEKA (Leg A) and FSx for Lustre (Leg B) — one leg at a time, on
an identically rebuilt instance. So the stack you prepare must serve **both**, whichever filesystem this
rebuild will mount.

**GPUDirect Storage is in scope and is NOT optional.** You need the GDS stack present and working because:
- the Lustre leg uses **true GDS over EFA**, and
- the WEKA leg runs the **same cuFile code path** — expected to be compat mode, which is settled empirically
  in the benchmark session and not here — and needs `libcufile` either way.

So: verify the whole GDS stack, even if the filesystem this rebuild mounts may not use the direct path.

## Do these, in order

0. **Reconcile `env.sh` against what the instance actually is** — first, because everything downstream trusts
   these values and one of them is a `MUST_MATCH` contract field.

   The human typed `INSTANCE_ID`, `AMI_ID`, `INSTANCE_TYPE`, `AWS_REGION` and `AWS_AZ` into `env.sh` by hand
   when they created it from `env.example.sh`. Re-derive all five from instance metadata — reuse the `imds()`
   helper already in `scripts/env-contract.py` rather than writing another `curl` block — and **compare**:

   - **Agreement** → say so, and move on.
   - **Disagreement** → the metadata wins; **write the metadata value into `env.sh`** and report both values.
     *Why this matters more than a typo:* `ami_id` and `instance_type` are held-constant contract fields, and
     the contract is built from `env.sh`. A wrong value there would be written into Leg A's contract *and*
     compared against itself in Leg B's verify — it would match, and the mismatch it exists to catch would be
     invisible. A region/AZ disagreement is different in kind: it means the instance is not where it was meant
     to be, which is a **stop-and-tell-the-human** finding, not an edit.
   - **IMDS unreachable** → report that plainly and leave `env.sh` alone. Do not guess.

   `S3_BUCKET` is the one value metadata cannot supply. Confirm it is set and reachable (that is item 9).

1. **GPU + driver + CUDA.** `nvidia-smi` — record **GPU model, count, memory**, driver and CUDA versions. If
   the driver is missing, **stop and report**: installing a GPU driver on a bare instance is a reboot-class
   task for the human.
2. **CUDA toolkit + GDS tools + `libcufile`.** Locate `gdscheck` and `gdsio` (typically under the CUDA
   install's `gds/tools/`, often **not** on `$PATH`) and `libcufile.so.*` — record the version. If absent,
   note what needs installing and cite the NVIDIA GDS install guide.
   > **Report the full path of the system `libcufile`, not just its version — and write it into
   > `LIBCUFILE_PRELOAD` in `env.sh` yourself.** Every kvikIO sweep driver reads that variable and
   > **refuses to start without it**; a path from another machine makes `LD_PRELOAD` a silent no-op, so the
   > GPU-direct cells would run on the conda env's bundled copy and still report numbers. *Why you write it
   > rather than reporting it for the human to paste:* you derived the path on this machine seconds earlier,
   > and the transcription hop is the only place a stale path can enter. Prove the write — `env.sh --check`
   > only *warns* on this field, so quote `[ -f "$LIBCUFILE_PRELOAD" ]` and the non-null `libcufile_version`
   > that `scripts/env-contract.py write` derives from it.
3. **GDS kernel path.** `nvidia-fs` module version and whether the GPU peer-memory module is loaded. Record
   both versions and **whether they are matched to each other** — a mismatch is a known source of subtle
   failures. Load or install if cleanly possible; **flag anything needing a module build or reboot.**
4. **Networking.** Record **which network interfaces exist, their types, and their link rates**; whether
   **EFA** is present and its driver/libfabric versions; and all interface addresses (you will need them for
   the cuFile configuration later). **EFA matters even though Leg A does not use it** — Leg B requires it, and
   it must be working on this instance.
5. **System tools** (ask before installing): `git build-essential tmux rsync curl jq sysstat fio fpart`.
   `sysstat` provides the `sar` tooling the recorder uses. **`fpsync` ships inside the `fpart` package** —
   there is no separate `fpsync` package, so asking apt for one fails
   ([Ubuntu `fpart` file list](https://packages.ubuntu.com/jammy/amd64/fpart/filelist): `/usr/bin/fpart`,
   `/usr/bin/fpsync`). Confirm `fpsync --help` works after installing, since Stages 1.5/1.6/6.C need it.
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
   project environments yet** — the handoff does that from `scripts/env-specs/`.
8. **OS hygiene.** Ensure `/dev/shm` is mode **1777** (a more restrictive mode silently breaks Python
   multiprocessing later, which is hard to diagnose from the symptom). Note free space on `/`.
9. **AWS access sanity.** Confirm the instance can reach its S3 bucket **via the IAM instance profile, not
   credentials on disk** — a read and a small write. This is the durable store the whole project depends on;
   if it does not work, everything downstream silently has nowhere safe to land.
10. **The kernel, running vs pending.** `kernel` is a `MUST_MATCH` contract field, and the system update the
    human ran while preparing this instance can install a newer `linux-image` that is **staged but not yet
    booted** — so `uname -r` alone can report a kernel this instance will stop running at its next reboot,
    and there *are* later reboots.
    ```bash
    uname -r                                  # running
    ls -1 /boot/vmlinuz-* 2>/dev/null         # is a newer one staged?
    grep -h linux-image /var/log/apt/history.log 2>/dev/null | tail -5
    ```
    **Report running and pending separately.** If they differ, that is deferred item `D-17` firing early:
    surface it as a pause with the two options — reboot now and baseline the contract on the new kernel, or pin
    the current one — and a recommendation. Do not decide it yourself, and do not reboot without approval.

## Report back (then stop)

1. **A component table:** GPU/driver/CUDA · CUDA-toolkit + GDS tools · `nvidia-fs` + peer-memory module ·
   networking incl. EFA · system tools · local NVMe · miniforge · `/dev/shm` · S3 access ·
   **kernel (running / pending)** → **present? / version / installed-now / MISSING → needs human**.
2. **The hardware topology summary** — GPU↔NUMA↔NIC affinity, NUMA nodes and core counts, and interface link
   rates. **Capture this clearly**: the project handoff uses it to derive GPU pinning and concurrency ranges,
   and those values must not be guessed.
3. **The `/data/local-nvme` layout and free space.**
4. **Whether the GDS stack is functional**, with the evidence you used — and note explicitly that whether
   *true* GDS is achievable on the currently mounted filesystem is an **empirical question for the benchmark
   session**, not something to conclude here from a configuration flag.
5. **A ready / not-ready verdict** plus a numbered list of anything the human still needs to resolve, each
   with a recommendation.

Then **stop.** The human resumes `docs/cloud-setup/NEW-CLOUD-SETUP.md` at the filesystem-provisioning part —
provision this leg's filesystem, record its configuration, mount it, write the first environment contract —
and then pastes the project handoff, `prompts/handoff-cloud.md`. Restoring Claude's memories and obtaining the
Hugging Face token both come **before** this prompt; the `hf` CLI does not exist until the project handoff
builds the Python environments, so the human may still owe the actual login.

**Three things you must hand back explicitly, because later steps refuse to run without them:**
- the **full path of the system `libcufile`**, which **you** have written into `LIBCUFILE_PRELOAD` in
  `env.sh` (item 2) — every kvikIO sweep driver reads it and aborts if it is unset;
- the **GPU/NUMA/NIC topology map and core counts** → deferred items `D-8` and `D-9` are re-derived from it,
  and it must not be guessed;
- **every `env.sh` value you changed** in item 0, with the metadata value beside the typed one.
