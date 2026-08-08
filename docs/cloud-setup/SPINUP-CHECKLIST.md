# Spin-up checklist — what to tell your senior technical colleague

Everything that must be decided or provisioned when standing up **Leg A (WEKA on AWS)**, in the order
it comes up. One or two lines each, with the reason — the reason matters, because several of these are
cheap now and expensive later.

> **Instance size is `g6e.24xlarge` (subject to change)** — `g6e.48xlarge` is the upgrade (8× L40S,
> 400 Gbps) and `g6e.12xlarge` the budget floor (100 Gbps). Nothing here is locked; see
> `../runs/STAGES.md` decision log for the revisit trigger.

> **How this file relates to [`NEW-CLOUD-SETUP.md`](NEW-CLOUD-SETUP.md).** This one is **what to decide, and
> why** — hand it to whoever provisions. That one is **how to do it**, click by click, in order. Where a fact
> appears in both, **this file is the authority for the reasoning and that file for the procedure**; fix the
> reason here and the steps there, not the other way round.

---

## A. Lead-time items — raise these first, they can block day one

1. **Region — pick one, put everything in it.** The EC2 instance, the WEKA backends, the S3 bucket, and
   (later) the FSx for Lustre file system must all share a region and ideally an AZ; cross-AZ/region adds
   latency and transfer cost and would silently contaminate the comparison.
   *Tiebreaker only:* `us-west-2`, because the CAMELYON dataset is hosted there
   (`s3://camelyon-dataset`, CC0, [AWS Open Data](https://registry.opendata.aws/camelyon/)) — but g6e
   capacity and your company's standard region outrank that.

2. **g6e service quota — request headroom now.** The "Running On-Demand G and VT instances" quota is
   counted in **vCPUs**: `g6e.12xlarge` = 48, `g6e.24xlarge` = 96, `g6e.48xlarge` = 192. We need **96**;
   ask for **192** so an upgrade to 48xlarge later isn't gated on a quota ticket.

---

## B. The compute instance

2b. ⚠ **The AMI must already carry the GPU stack — and it must be PINNED.** A stock Ubuntu image ships no
    NVIDIA driver, no CUDA toolkit, no `nvidia-fs` and no `libcufile`, and this project deliberately does not
    automate installing a GPU driver (it is a reboot-class task). Launching plain Ubuntu therefore stalls the
    setup before any software work can begin. Use a GPU-bearing image — e.g. the current *AWS Deep Learning
    Base GPU AMI* on Ubuntu — and **confirm the exact name in the console**, because the variants change.
    *Then record the AMI ID:* `kernel`, `driver_version` and `cuda_version` are held-constant fields in the
    cross-leg contract, so **Leg B must rebuild from the same image** or the comparison is invalid. This is
    still an **open decision** — `C10` in the `cloud-session-open-items` memory.

3. **Instance type: `g6e.24xlarge`** — 96 vCPU, 768 GiB RAM, 4× NVIDIA L40S (178 GiB GPU memory),
   **200 Gbps** network (2 network cards), 2× 1900 GB local NVMe. This is the *client* in both legs; it
   must be identical across Leg A and Leg B or the comparison isn't valid.

4. **Launch it EFA-capable, even though Leg A doesn't use EFA.** WEKA runs DPDK over ENA, but Leg B's
   FSx-Lustre needs EFA for GPUDirect Storage and to escape a 5 Gbps-per-OSS cap — and the instance must
   be the same one in both legs, so EFA capability has to be there from the start.

5. **EFA security group rule.** EFA requires a security group with a *self-referencing* rule allowing all
   traffic inbound and outbound within the group; set it up now so Leg B isn't blocked on a networking
   change months later.

6. **Local NVMe is ephemeral — it dies with the instance.** The 2× 1900 GB instance store is fast scratch
   only (conda envs, staging, in-flight telemetry); nothing that matters may live there at teardown.

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

13. **Protection / erasure-coding scheme — write down whatever you choose.** The cross-source recording
    canary validates wire-level traffic against application-level throughput using the write
    amplification the EC scheme implies, so the scheme is a required input to verifying that every run is
    physically consistent.

13b. **Also record the backends' aggregate RAM.** Server-side cache determines how large the Stage 6.B
    synthetic corpus must be to read genuinely cold — the corpus has to exceed the client's page cache
    *plus* the larger of the two filesystems' server caches. Nothing to decide now; just capture the number,
    because it is the only input that could push the corpus past the planned capacity.

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
(teardown *and* rebuild), plus `runs/lib/teardown-preflight.sh`, which verifies nothing is lost and prints
**GO / NO-GO** before you destroy anything.

*The steps used to be duplicated here. They are not any more, deliberately — a teardown checklist that exists
in two places will drift, and the half you follow will be the stale one.*
