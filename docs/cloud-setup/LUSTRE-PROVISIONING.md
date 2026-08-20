# Leg B (FSx for Lustre) — provisioning reasoning, decision register, manual fallback

The mount is **automated**: terraform creates the file system, the bootstrap arms
`wsi-lustre-phase2.service`, and the baked `scripts/wsi-lustre-phase2.sh` (tracker entry has the full
stage map) configures EFA, enforces the D16 gate, and mounts with a counter-proof — per boot, idempotent.
The 2026-08-20 gated walk validated every step; its verbatim record is
`runs/2026-08-20-lustre-efa-walk-transcript.md`. What stays session work: cost/ceiling values
(human-ratified, dated), the environment contract, and this register.

## The two silent failure modes the automation exists to prevent

Both produce perfectly plausible numbers while invalidating the comparison:

1. **Mounting over TCP instead of EFA.** An EFA-enabled file system mounts and runs happily over tcp — the
   MGS NID in the device string is `@tcp` *by design* — forfeiting the escape from the 5 Gbps
   per-client-per-OSS cap while looking healthy. So the transport is proven, never configured-and-assumed:
   `lnetctl net show` must list an `efa` net AND a direct-I/O write must move the efa net's `send_count`
   (~1 RPC/MiB) with tcp near-flat. Phase-2 unmounts and fails loudly otherwise; mounting over TCP anyway is
   a human decision, in writing (**D16**).
2. **Moving a MUST_MATCH field.** The kernel cannot move on the validated path (AL2023 ships the Lustre
   modules — including `kefalnd`, the EFA LND — in the kernel; `lustre-client` is userspace-only from the
   base repo), and phase-2 asserts `uname -r` unchanged across the install as the tripwire. The AMI pin and
   the NVIDIA-stack pin gap are tracked at `D-17` in the script tracker.

## Decision register (ratified 2026-08-20 — whitepaper-bound)

One entry per live decision — what, why, sources. Overwrite entries when a decision changes; never log history.

- **L1 — Transport: EFA, proven by LNet counters, never by configuration.** `FS_TRANSPORT=efa` is written
  only after a direct-I/O write moves the efa net's `send_count` (~1 RPC/MiB) with tcp near-flat. *Why:* an
  EFA-enabled FS mounts and runs happily over tcp (the MGS NID is `@tcp`), producing plausible numbers for a
  transport the project refuses to measure (**D16**); a flag is not proof of behaviour. *Source:* the walk
  transcript; `docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html`.
- **L2 — Stripe layout: the AWS default 4-component PFL, unmodified**
  (`[0,100M)c1 · [100M,10G)c8 · [10G,100G)c16 · [100G,EOF)c32 · stripe_size 1M`; 6 OSTs cap effective stripe
  at 6). *Why:* the vendor's tuned default on a max-tier file system is the most defensible "as provisioned at
  maximum" configuration (**D7**) — deviating in either direction invites the you-tuned-it objection; WSI
  slides (0.5–4 GiB) land in the 8-stripe component and spread across all 6 OSTs. The D12 consistency relation
  derives from the recorded layout verbatim. *Source:* `docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html` (striping).
- **L3 — LNet/module config: AWS's official configure-efa bundle, vendored and sha-pinned.** tcp + efa nets,
  UDSP preferring efa, `peer_credits 32`, `ksocklnd credits=2560`, `ptlrpcd_per_cpt_max=32` (its CPU-scaled
  values for 96 vCPU), boot re-arm via its systemd oneshot. *Why:* the vendor's own supported path is the
  citable fairness basis and carries the reboot re-arm the unattended-overnight rule requires; vendoring pins
  exactly what the walk validated. *Source:* `scripts/vendor/configure-efa-fsx-lustre-client/VENDORED.md`.
- **L4 — Client tunables: AWS's documented set for a >64-vCPU / >64-GiB client, exactly and only.**
  `ldlm lru_max_age=600000`, `lru_size=100×nCPU`, `osc max_rpcs_in_flight=32`, `mdc max_rpcs_in_flight=64`,
  `mdc max_mod_rpcs_in_flight=50`, `llite statahead_max=512`, `statahead_agl=1`, `statahead_xattr=1`;
  persisted by `wsi-lustre-tuning.service`. *Why:* skipping the vendor's recommendations understates Lustre
  (**D7**/`D-11`); going beyond them stops being citable as "the vendor's configuration."
  *Source:* `docs.aws.amazon.com/fsx/latest/LustreGuide/performance-tips.html` (fetched 2026-08-20).
- **L5 — Per-client ceiling: 700 Gbps vendor-documented, with the 200 Gbps instance line rate named as the
  binding bound in the basis string.** *Why:* the naming-doc rule records the documented per-client cap where
  one exists (FSx documents 700 Gbps over EFA); the physically binding bound on this client is the g6e.24xlarge
  line rate, which equals Leg A's recorded ceiling — the basis carries both so "measured vs ceiling" stays
  honest in the whitepaper. *Sources:* `docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html`;
  `docs.aws.amazon.com/ec2/latest/instancetypes/ac.html`.
- **L6 — Cost basis: FS rate from the official Price List file, metadata IOPS billed above the capacity-based
  default.** `FS_USD_PER_HR` = 28,800 GiB × $0.673/GB-mo + (48,000 − 12,000 included) × $0.062/IOPS-mo, ÷730 h
  = **$29.6088/hr** (Seoul, checked 2026-08-20); `SOFTWARE_USD_PER_HR=0` — the FSx rate is software-inclusive
  (no software/license SKU exists for Lustre in the AmazonFSx price list); EFA carries no charge (no SKU).
  *Why the included-IOPS reading:* the pricing page's "included based on storage capacity" plus the performance
  page's "pay for IOPS above the default"; 28,800 GiB sits in the 12,000-included bracket. **Standing check
  (open-items memory):** verify against the first invoice; if all 48,000 bill, the rate is $30.6279/hr —
  correct the value, dated, as a provisioning-cost event.
  *Source:* `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonFSx/current/ap-northeast-2/index.json`.
- **L7 — EFA interface count.** g6e.24xlarge has 2 network cards, **each documented at 200 Gbps baseline and
  peak** — one EFA interface already reaches the full instance line rate, so a second adds no *documented*
  headroom; AWS's own configurator treats 2-per-multi-card as its default posture and handles either count
  (with 2 it also applies its documented CPT/CPU-partition options — LNet work partitioning, no cores reserved
  from applications: `FS_CLIENT_RESERVED_CORES=none` holds). The count is a launch-time terraform property;
  changing it mid-leg costs an instance stop. Whichever count the current terraform launched is recorded by
  the walk/rebuild evidence; a plateau below expectation with the efa net unsaturated during calibration makes
  the second interface the first candidate — a ratified provisioning event, not silent tuning.
  *Sources:* `aws ec2 describe-instance-types g6e.24xlarge` (NetworkCards, 2026-08-20);
  `docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html` (interface table).

## Manual fallback — when the baked path fails

Run the stages of `scripts/wsi-lustre-phase2.sh` by hand in order (`--dry-run` prints every command); its
gates are the law: no efa net in `lnetctl net show` → no mount, no fallback; counter-proof fails → unmount.
Triage starts at `journalctl -u wsi-lustre-phase2.service`. If AWS's procedure has moved on from the vendored
bundle (`scripts/vendor/.../VENDORED.md` holds the sha): fetch the current
`configure-efa-clients.html` + `install-lustre-client.html`, re-walk the gates with human approval per step,
re-vendor, re-bake — and record what differed here and in the transcript convention
(`runs/<date>-lustre-efa-walk-transcript.md`). Fetch docs, never run remembered commands — including these.
