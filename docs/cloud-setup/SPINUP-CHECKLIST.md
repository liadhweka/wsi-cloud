# Spin-up checklist — what to tell your senior technical colleague

Everything that must be decided or provisioned when standing up **Leg A (WEKA on AWS)**, in the order
it comes up. One or two lines each, with the reason — the reason matters, because several of these are
cheap now and expensive later.

> **The compute instance is `g6e.24xlarge`.** It is the single largest held-constant variable and must be
> identical in both legs. It carries a **pre-committed revisit trigger** — recorded in advance so the call is
> not made later under sunk cost; the trigger and its consequences are **D10** in
> [`STAGES.md`](../STAGES.md).

> **How this file relates to [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md).** This one is **what to
> decide, and why** — hand it to whoever provisions. That one is the do-every-time procedure. Where a fact
> appears in both, **this file is the authority for the reasoning and that file for the procedure**; fix the
> reason here and the steps there, not the other way round.

---

## A. Lead-time items — raise these first, they can block day one

1. **Region — pick one, put everything in it.** The EC2 instance, the WEKA backends, the S3 bucket, and
   (later) the FSx for Lustre file system must all share a region and ideally an AZ; cross-AZ/region adds
   latency and transfer cost and would silently contaminate the comparison.
   *Decided:* **`ap-northeast-2`**, on g6e capacity — which outranks every tiebreaker, including the
   CAMELYON open-data bucket's home region (`s3://camelyon-dataset` in `us-west-2`, CC0,
   [AWS Open Data](https://registry.opendata.aws/camelyon/)).

2. **g6e service quota — request headroom now.** The "Running On-Demand G and VT instances" quota is
   counted in **vCPUs**: `g6e.12xlarge` = 48, `g6e.24xlarge` = 96, `g6e.48xlarge` = 192. We need **96**;
   ask for **192** so an upgrade to 48xlarge later isn't gated on a quota ticket.

---

## B. The compute instance

2b. ⚠ **The AMI must be PINNED.** The client builds on **Amazon Linux 2023**, and
    `scripts/bootstrap-instance.sh` installs the NVIDIA driver, CUDA and the GDS stack unattended at first
    boot — so the image needs no pre-baked GPU stack, but the exact AMI must be pinned and recorded: `kernel`, `driver_version` and `cuda_version` are held-constant fields
    in the cross-leg contract, so **Leg B must rebuild from the same image** or the comparison is invalid.
    "Latest" is not a pin — a newer base image silently changes the kernel and the driver.

3. **Instance type: `g6e.24xlarge`** — 96 vCPU, 768 GiB RAM, 4× NVIDIA L40S (178 GiB GPU memory),
   **200 Gbps** network (2 network cards), 2× 1900 GB local NVMe. This is the *client* in both legs; it
   must be identical across Leg A and Leg B or the comparison isn't valid.

4. **Launch it EFA-capable, even though Leg A doesn't use EFA.** WEKA runs DPDK over ENA, but Leg B's
   FSx-Lustre needs EFA both for GPUDirect Storage and to escape the **per-client-per-file-server bandwidth
   cap** that applies without it — a cap that would break the "Lustre at maximum" fairness basis invisibly.
   The instance must be the same one in both legs, so EFA capability has to be there from the start.
   *Fetch the current cap figure from
   [FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html) when
   sizing — per-client caps change.*

5. **EFA security group rule.** EFA requires a security group with a *self-referencing* rule allowing all
   traffic inbound and outbound within the group; set it up now so Leg B isn't blocked on a networking
   change months later.

6. **Local NVMe is ephemeral — it dies with the instance.** The 2× 1900 GB instance store is fast scratch
   only (conda envs, staging, in-flight telemetry); nothing that matters may live there at teardown.

6b. ⚠ **Size the root EBS volume ≥100 GB.** A 48 GB root filled mid-leg: per-cell raw telemetry accumulates
    locally between S3 syncs, the WEKA client's traces grow tens of GB under sustained load, and the HF model
    cache defaults onto it — and a full root volume aborts a running sweep (it did). The interim mitigations
    (telemetry relocation to scratch, trace-retention cap, cache symlink — tracker D-35) work, but sizing the
    volume properly removes the failure mode instead of managing it.

---

## C. S3 durable store + IAM

7. **One private S3 bucket, same region.** This is where raw telemetry and the datasets live so a teardown
   loses nothing — without it, tearing down the instance and cluster destroys every run's raw time series,
   which the project's recording rules forbid. Plan for ~2–3 TB.

8. **Bucket settings: accept the defaults.** Block All Public Access **on**, versioning **off** (telemetry
   is write-once — versioning doubles cost for no benefit; git already holds the small text artifacts),
   default SSE-S3 encryption, S3 Standard storage class.

9. **IAM instance profile attached at launch — not access keys.** Scope it to this one bucket:
   `s3:ListBucket` on the bucket ARN plus `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on
   `<bucket>/*`. A role means no credentials on disk and `aws s3 sync` picks it up automatically;
   attaching at launch is cleaner than retrofitting.

10. **Bucket layout** (the benchmark scripts will expect this):
    ```
    s3://<bucket>/datasets/tcga-brca/         # downloaded once from GDC, reused by both legs
    s3://<bucket>/datasets/camelyon16/        # mirror of the open-data pull
    s3://<bucket>/runs/<leg>/<run-dir>/raw/   # heavy telemetry, synced during and after each run
    s3://<bucket>/env-contracts/              # env-contract-leg-{weka,lustre}.json
    ```

---

## D. The WEKA cluster (Leg A)

These five are decided at creation time and are expensive to change, so capture the values as you set them.

11. **Backend instance type + count.** Size so the cluster comfortably clears **~25 GB/s** to a single
    client (the 200 Gbps instance ceiling) — WEKA must not be the constraint, or a measured difference is
    a sizing artifact rather than a behavioral finding. Note this roughly doubles the backend count vs a
    100 Gbps client.

12. **Usable capacity: ~20–25 TB.** Covers the datasets (~1.8 TB), the 20× raw-TIFF artifact (~7 TB at
    full cohort), extracted features, heatmaps, and fio scratch, with headroom.

    ⚠ **Two of those are sized by cache, not by convenience, so treat them as capacity inputs rather than
    scratch** — both must exceed **the larger of the two filesystems' server-side caches** to read genuinely
    cold (**D13**), and both are *retained* rather than written-and-deleted per cell:
    - the **Stage-1.0 read corpus** (the ceilings every "% of ceiling" divides by), and
    - the **Stage 6.B synthetic corpus** (see 13b).

    So the cache figures in 13b are not bookkeeping — they set a floor under this line item. Confirm the
    total still fits once both are computed, and note that on FSx capacity is simultaneously a performance
    knob (**D7**), so raising capacity to fit them also changes what is being measured.

13. **Protection / erasure-coding scheme — write down whatever you choose.** The cross-source recording
    canary validates wire-level traffic against application-level throughput using the write
    amplification the EC scheme implies, so the scheme is a required input to verifying that every run is
    physically consistent.

13b. **Also record the backends' aggregate RAM.** Server-side cache determines how large the Stage 6.B
    synthetic corpus must be to read genuinely cold — the corpus has to exceed the client's page cache
    *plus* the larger of the two filesystems' server caches, so that **one identical corpus definition serves
    both legs** rather than a per-leg size that would break the held-constant contract. Nothing to decide now;
    just capture the number, because it is the only input that could push the corpus past the planned
    capacity. (The open-items memory, the 6.B corpus-sizing item; rationale in
    [`STAGES.md`](../STAGES.md) **D13**.)

14. **Client networking mode: DPDK (performance-optimized), not UDP.** DPDK is WEKA's fast path and gives
    the client kernel-bypass; UDP mode trades throughput for CPU and would understate WEKA. **This is a
    precondition, not a preference** (**D16**): if DPDK cannot be brought up, the instruction everywhere is
    *stop and report immediately* — before mounting and before any cell — because a UDP mount produces a
    complete, plausible dataset for a transport we decided not to measure.

15. **Same VPC, subnet, and AZ as the g6e instance.** Keeps the client-to-backend path short and free, and
    keeps Leg A's topology reproducible for Leg B.

---

## E. Before any teardown

**See [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md)** — the do-every-time checklist for both halves
(teardown *and* rebuild), plus `scripts/teardown-preflight.sh`, which verifies nothing is lost and prints
**GO / NO-GO** before you destroy anything.

*The teardown steps live in exactly one place, deliberately — a checklist that exists in two will drift, and
the half someone follows will be the stale one. Point here; do not copy them back.*
