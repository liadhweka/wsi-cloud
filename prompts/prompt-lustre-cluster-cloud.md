# Task prompt — stand up and mount FSx for Lustre for this leg

You are Claude Code on the project's AWS GPU instance, **rebuilt for Leg B**. This is a **self-contained
storage-provisioning task**: take an FSx for Lustre file system and leave this instance with a healthy,
**EFA-mounted** Lustre filesystem plus every provisioning fact recorded. **You are not benchmarking here** — the
WSI pipeline is irrelevant to this task and you do not need to read it.

> **This walk is BAKED: `scripts/wsi-lustre-phase2.sh`** (validated by the 2026-08 gated walk; transcript in
> `runs/2026-08-20-lustre-efa-walk-transcript.md`). On a rebuild, bootstrap arms it as a per-boot systemd
> oneshot (`wsi-lustre-phase2.service`) — the normal path is that the filesystem is already mounted with
> counter-proven EFA before any session starts. **This prompt is the manual fallback and the validation
> reference**: run it (a) when the baked script fails, (b) after any AMI/kernel/client change — the bake is
> only as valid as the environment it was walked on — or (c) when AWS's procedure changes. What remains
> session work even on the baked path: the cost + ceiling values (human-ratified, dated), the environment
> contract write/verify, and the decision register.

**You will run this again** on every rebuild, so keep it repeatable: record commands and outputs rather than
carrying judgements in your head.

---

## Read this first — two ways this task fails silently

Both **produce perfectly plausible numbers while invalidating the comparison** — nothing errors, nothing looks
wrong, and the damage is invisible until someone asks what was actually measured. That is why this is a prompt
with hard gates rather than a checklist.

**1. Mounting over TCP instead of EFA.** Enabling EFA on the instance, requesting EFA on the file system, and
installing the *generic* EC2 EFA software does **not** configure the *Lustre client* to use EFA. Without the
FSx-specific client configuration the mount quietly uses TCP — forfeiting the escape
from the per-client-per-file-server bandwidth cap. This project's fairness basis is "Lustre provisioned at
maximum capability"; a TCP mount breaks that promise while still producing numbers. **Step 5 is a hard gate.**
Tracked as deferred item `D-16`.

**2. Changing the kernel.** `kernel` is a `MUST_MATCH` field in the cross-leg environment contract. The
documented Lustre client install can pull a newer kernel, and any OS upgrade can move it too — so the Leg-B
procedure can invalidate the very comparison the contract protects. **Step 4 must not run before the kernel
question is settled with the human.** Tracked as `D-17`.

**3. "Latest" resolving silently under the AMI and the driver (learned on Leg A, 2026-08-15).** Two places
pick "latest" unless explicitly stopped, and both feed `MUST_MATCH` fields:
- **The client AMI.** The terraform module's `client_instance_ami_id` defaults to `null` = *the newest
  Amazon Linux 2023 at apply time* — Leg A ran unpinned for its first build and the AMI was only discovered
  from the instance's own metadata afterwards. It is now pinned in the terraform
  (`client_instance_ami_id = "ami-00f6db7984ad32b20"`, Leg A's image). **Before the Leg-B apply: confirm
  the pin is still present in the tfvars, and that the AMI still exists in the region** (`aws ec2
  describe-images --image-ids ...`) — AWS deprecates images over months, and a silently-dropped pin
  re-resolves to a newer AMI whose kernel fails the contract for a reason nobody chose. (Backend/FSx have
  no equivalent concern: Leg B has no WEKA backends, and backend fields are `MAY_DIFFER` by design.)
- **The NVIDIA stack.** The bootstrap installs the driver via unpinned `dnf install nvidia-driver`, so
  `DRIVER_VERSION` / `NVIDIA_FS_VERSION` can drift between legs even on the identical AMI. Before the
  Leg-B rebuild: pin the packages to Leg A's contract-recorded versions, or knowingly accept the contract
  verify as the tripwire (a firing = stop and decide, per `D-17`).

None of these is a reason to avoid the work. All are reasons to check, record, and surface.

---

## What only the human can do

- **Create the FSx file system** — via `terraform apply` on their machine, before your session starts
  (Step 2 is verification only). If you find no file system, that is a stop-and-report, never a
  create-it-yourself. It remains a paid resource with
  configuration that *is* the experiment; `aws fsx create-file-system` is on the ask list, so you may propose
  and execute it but never unilaterally.
- **Decide the kernel policy** (Step 4).
- **Approve every `sudo`, install, mount and reboot.**
- **Destroy anything.** Deleting the previous leg's filesystem is deliberately theirs.

## Rules you operate under

- **Verify before you change anything.** Read-only first, always.
- **Ask before every mutating step**, stating what will happen and what would be lost. Here that means: creating
  the file system, `sudo` anything, the EFA and Lustre client installs, both reboots, and the mount.
- **Reference official docs, not recall** — `docs.aws.amazon.com` for FSx/EFA and `doc.lustre.org` for Lustre
  itself. **The FSx client tooling and package names change**; fetch the current pages rather than trusting the
  commands quoted here. Doc-fetching is standing-approved.
- **Fail loud**, and never invent a value for `env.sh`.

---

## Step 1 — Orient, and prove the contract before spending anything

```bash
source env.sh
echo "$LEG $FS_MOUNT"                       # must be lustre and the Lustre mount path
uname -r                                    # note this NOW, before any install
findmnt "$FS_MOUNT" || echo "not mounted yet (expected)"
```

**Verify comparability against Leg A first** — before provisioning anything, because a mismatch found now costs
nothing and a mismatch found later costs the leg:

```bash
aws s3 cp "s3://$S3_BUCKET/env-contracts/env-contract-leg-weka.json" /tmp/
scripts/env-contract.py verify --against /tmp/env-contract-leg-weka.json --leg lustre
```

It separates **VIOLATION** (a held-constant field differs — the comparison is invalid) from **differs as
expected** (the filesystem fields, which are the variable under test), and it fails on *unverifiable* fields too,
because a null cannot be shown to have matched.

**Expect violations at this point** for anything not yet provisioned or installed — that is normal this early.
What matters is that `instance_type`, `aws_region`, `ami_id` and `kernel` (`aws_az` is MAY_DIFFER by design
— the concurrent-legs reclassification, `STAGES.md` **D6**; each leg is intra-AZ beside its filesystem) already match. **If the AMI
or kernel differs from Leg A, stop and surface it** — that is `D-17`, and it is cheaper to rebuild the instance
now than to discover it after a week of cells.

## Step 2 — The file system *(terraform-owned — you verify and record, never create)*

The file system is created by the human's `terraform apply` (their `~/terraform/lustre`) **before this
session exists** — creation moved out of this prompt (ratified 2026-08-18) so mid-leg rebuilds are
repeatable; Leg A needed one. Your job is the half that matters scientifically: **prove the live file
system matches the ratified spec below, and record it.** `FSX_ID` / `FSX_DNS_NAME` / `FSX_MOUNT_NAME`
arrive in `/etc/wsi-bootstrap.conf` from terraform — never retype them.

```bash
aws fsx describe-file-systems --file-system-ids "$FSX_ID" --region ap-northeast-2 \
  --query 'FileSystems[0].[Lifecycle,StorageCapacity,LustreConfiguration.DeploymentType,LustreConfiguration.PerUnitStorageThroughput,LustreConfiguration.EfaEnabled,LustreConfiguration.MetadataConfiguration]'
```

Assert, refusing loudly on any mismatch (a wrong filesystem measured correctly is still the wrong
experiment): `AVAILABLE`; `PERSISTENT_2`; `1000` MB/s/TiB; `EfaEnabled=true`; capacity `28800` (EFA+P2-1000+SSD moves in 4800-GiB steps — the API rejects anything else); metadata
`USER_PROVISIONED` at the ratified IOPS (placeholder 48,000 — verified against Leg A's measured metadata
peaks before this leg's metadata-heavy stages, per the stage-lag rule; if raised, that is a **recorded,
human-ratified provisioning event**, priced into `FS_USD_PER_HR`). Record everything into env.sh and the
environment contract, then treat the table below as the verification checklist it now is:

The configuration below **is** the experiment — this side is deliberately provisioned at maximum capability, so
under-configuring it is as damaging as under-configuring the other leg. Every value has a reason:

| Setting | Value | Why |
|---|---|---|
| Deployment type | **Persistent 2** | The generation where metadata performance is provisioned independently of capacity |
| Throughput per unit of storage | **1000 MB/s/TiB** — the top SSD tier | Deliberately its best configuration |
| Storage capacity | **≥ 25 TiB** | At 1000 MB/s/TiB this is where disk throughput reaches the client's ~25 GB/s ceiling; below it the file system is the constraint and any delta is a sizing artifact |
| Metadata IOPS | **User-provisioned, high** | Persistent 2 provisions metadata independently of capacity, so leaving it at the default would under-provision the metadata path while the data path runs at maximum (**D7**) |
| VPC / subnet / security group | **same as this instance**, `wsi-bench-sg` | Cross-AZ traffic would contaminate the comparison |
| EFA | **Enabled** | Removes a hard per-client-per-file-server cap — the load-bearing reason on this client class (true GDS is out of reach on g6e per the documented client constraint, STAGES.md **D8**; expect compat mode, verified per cell) |

**Prefer the CLI if the human agrees**, and say why when you propose it: `aws fsx create-file-system` records the
exact parameters in your transcript, which is precisely what the fairness basis has to be able to evidence
later. Fetch the current parameter names from the AWS CLI reference — do not reconstruct them from this table.

Creation takes roughly ten minutes. **Record `FSX_TIER`, `FSX_CAPACITY_TIB`, `FSX_METADATA_IOPS`,
`FSX_EFA_ENABLED` into `env.sh` yourself** once it reports available.

**Also record the documented per-client throughput ceiling, dated like a price (D7):** fetch the per-client
throughput figure for this tier from the same AWS FSx performance page D7 cites, and set
`FS_PER_CLIENT_CEILING_GBPS`, `FS_PER_CLIENT_CEILING_BASIS` (`"vendor-documented: <url>"`), and
`CEILING_CHECKED_UTC` in `env.sh`. The environment contract carries all three, so every result on this leg is
quotable as *measured versus documented per-client ceiling* — a single client cannot drive the aggregate
maximum, and this is what makes that a table instead of an objection.

## Step 3 — EFA driver on the instance *(read-only on the validated path)*

**The kernel Lustre data path does not use userspace libfabric** — the LND is `kefalnd`, a kernel module
talking to the `efa` kernel driver directly. AWS's own FSx install script gates on `modinfo efa` ≥ **2.12.1**
and installs nothing when the in-kernel driver satisfies it (AL2023 ships it in-kernel). So on this AMI the
step is a verification, not an install — and `fi_info`/the generic EFA installer/the Yama sysctl are for
userspace consumers (MPI/NCCL), not for this mount:

```bash
modinfo efa | grep ^version          # must exist and be >= 2.12.1
ls /sys/class/infiniband/            # must show an efa_* device (else the ENI is missing — terraform, not client)
```

**If either fails, STOP AND REPORT** — that is AMI/kernel drift (`D-17` tripwire) or a launch-time EFA-ENI
omission; no client-side install fixes the second one.

## Step 4 — Lustre client *(ask first; userspace-only on AL2023 — no kernel risk on the validated path)*

**On AL2023 the Lustre kernel modules ship IN the kernel package** (`staging/lustrefsx`: `lustre.ko`,
`ksocklnd`, and critically **`kefalnd`, Amazon's EFA LND**), and `lustre-client` in the **base repo** is pure
userspace (`lfs`, `lctl`, `lnetctl`, `mount.lustre`). There is **no FSx repo to add on AL2023** (that
procedure is for RHEL/Rocky/CentOS/Ubuntu), no kmod install, no reboot — and therefore no kernel decision:
the kernel-pin option holds by construction. Verify, then install:

```bash
modinfo kefalnd | head -3          # the EFA LND must exist for the RUNNING kernel — AWS's own support gate
sudo dnf install -y lustre-client  # userspace only; record the exact NVR
uname -r                           # MUST equal Step 1's value — any change is a D-17 stop
lfs --version                      # must be >= 2.15 (metadata-IOPS client requirement)
```

> **If `kefalnd` is absent for the running kernel**, the AMI or kernel drifted from the validated one — that
> is a `D-17` stop with the human, never a silent kernel upgrade. (The old trap — client packages pulling a
> kernel — can only return if the install stops being userspace-only; the `uname -r` compare is the tripwire.)

## Step 5 — Configure the Lustre client for EFA — THE GATE *(ask first)*

**This is the step whose absence silently invalidates Leg B.** AWS ships an FSx-Lustre-specific EFA client
configuration; nothing in Steps 3–4 does it.

**The validated procedure is AWS's official bundle, VENDORED at
`scripts/vendor/configure-efa-fsx-lustre-client/`** (sha-pinned; provenance in its `VENDORED.md`; upstream:
the "Configuring EFA clients" page's `configure-efa-fsx-lustre-client.zip`). `sudo ./setup.sh` from that
directory: writes the modprobe tunables (`ksocklnd credits`, `ptlrpcd_per_cpt_max`, CPU-scaled), loads
`lnet`/`kefalnd`/`ksocklnd`, configures **both** a `tcp` and an `efa` LNet net, sets a UDSP rule preferring
EFA, and installs `configure-efa-fsx-lustre-client.service` — the systemd oneshot that re-arms all of it on
every boot. Never pass `--optimized-for-gds` (P5/P6-only per the docs; this client is g6e — **D8**). If AWS's
page has moved on from the vendored sha, fetch the current bundle, re-walk this gate, and re-vendor. Then:

```bash
sudo lnetctl net show          # must list an `efa` net, not only `tcp`
```

### Hard gate: if it shows only `tcp` — STOP IMMEDIATELY AND REPORT

**Stop here, at this step.** Do not continue to Step 6 — **do not mount at all** — and do not let a benchmark
cell run. Report at once: what you ran, the exact output, which AWS page you followed, and where the procedure
diverged from it. **Then wait for the human.**

*Why not "mount over TCP and flag it in the report":* a TCP mount works. It produces a complete, believable set
of numbers for a transport this project explicitly decided not to measure (**D16**), while forfeiting
Storage *and* the escape from the per-client-per-file-server bandwidth cap — so it breaks the "Lustre at
maximum" fairness basis (**D7**) invisibly. Flagging it afterwards does not undo the wallclock, the money, or a
results tree whose provenance now has to be argued about. Mounting over TCP anyway is a **human decision, in
writing, with the reason recorded.**

Record what you did and what `lnetctl net show` printed — the next rebuild needs it, and so does the writeup.

## Step 6 — Mount *(ask first)*

**The device string stays `@tcp:/<mountname>` even on an EFA-enabled file system** — that is the MGS NID
(the management server speaks tcp); LNet peer discovery plus Step 5's UDSP rule route the **data** over EFA.
Do not "fix" the mount string to `@efa`, and do not read the transport off the mount string in either
direction — **the proof is LNet evidence**: after mounting, the OSS peers must show `@efa` NIDs
(`sudo lnetctl peer show`), and a direct-I/O `dd` must move the **efa** net's `send_count` (one RPC per MiB),
with tcp near-flat (`sudo lnetctl net show -v 4`). A mount that passes data over tcp despite an efa net being
up is the D16 silent failure — unmount and stop.

```bash
sudo mkdir -p "$FS_MOUNT"
sudo mount -t lustre -o relatime,flock "$FSX_DNS_NAME@tcp:/$FSX_MOUNT_NAME" "$FS_MOUNT"
sudo chown "$USER:$USER" "$FS_MOUNT"
mkdir -p "$FS_MOUNT/data"
```

For boot persistence use the fstab shape from the vendored bundle's README —
`…@tcp:/<mountname> <mnt> lustre defaults,relatime,flock,_netdev,x-systemd.automount,x-systemd.requires=configure-efa-fsx-lustre-client.service,x-systemd.after=configure-efa-fsx-lustre-client.service 0 0`
— the systemd dependencies keep the automount from racing the EFA configuration.

Then verify and capture the stripe layout:

```bash
findmnt "$FS_MOUNT"
lfs df -h "$FS_MOUNT"              # storage and metadata targets
lfs getstripe -d "$FS_MOUNT"       # the default layout — RECORD THIS
dd if=/dev/zero of="$FS_MOUNT/testfile" bs=1M count=1000 oflag=direct
rm "$FS_MOUNT/testfile"
```

**`lfs getstripe -d` output goes into `LUSTRE_STRIPE_LAYOUT`.** It is required, not decorative: the per-sweep
consistency check derives this filesystem's expected wire-vs-application relation from the actual stripe layout,
exactly as the other leg's derives from its protection scheme. **The relation must be derived per filesystem and
never ported across** (`D-5`).

## Step 7 — Tuning is part of the fairness basis, not an optimisation *(ratified; see the register below)*

Leaving Lustre untuned would **understate** it and break the "provisioned at maximum" promise as surely as a TCP
mount would (`D-11`). The ratified client configuration is **AWS's own documented set for this client class**
(register entries L3–L4 below); the baked phase-2 applies it and installs `wsi-lustre-tuning.service` for
persistence, because `lctl set_param` does not survive reboot. Any tuning **beyond** the vendor-documented set
is a new methodology decision: propose it with sources, get it ratified, update register entry L4, and re-run
every cell measured under the old values.

## Leg-B provisioning decision register (ratified 2026-08-20 — whitepaper-bound)

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
  derives from the recorded layout verbatim. *Source:* `…/LustreGuide/performance.html` (striping).
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
  *Source:* `…/LustreGuide/performance-tips.html` (fetched 2026-08-20).
- **L5 — Per-client ceiling: 700 Gbps vendor-documented, with the 200 Gbps instance line rate named as the
  binding bound in the basis string.** *Why:* the naming-doc rule records the documented per-client cap where
  one exists (FSx documents 700 Gbps over EFA); the physically binding bound on this client is the g6e.24xlarge
  line rate, which equals Leg A's recorded ceiling — the basis carries both so "measured vs ceiling" stays
  honest in the whitepaper. *Sources:* `…/LustreGuide/performance.html`; `docs.aws.amazon.com/ec2/latest/instancetypes/ac.html`.
- **L6 — Cost basis: FS rate from the official Price List file, metadata IOPS billed above the capacity-based
  default.** `FS_USD_PER_HR` = 28,800 GiB × $0.673/GB-mo + (48,000 − 12,000 included) × $0.062/IOPS-mo, ÷730 h
  = **$29.6088/hr** (Seoul, checked 2026-08-20); `SOFTWARE_USD_PER_HR=0` — the FSx rate is software-inclusive
  (no software/license SKU exists for Lustre in the AmazonFSx price list); EFA carries no charge (no SKU).
  *Why the included-IOPS reading:* the pricing page's "included based on storage capacity" plus the performance
  page's "pay for IOPS above the default"; 28,800 GiB sits in the 12,000-included bracket. **Standing check:**
  verify against the first invoice; if all 48,000 bill, the rate is $30.6279/hr — correct the value, dated, as
  a provisioning-cost event. *Source:* `pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonFSx/current/ap-northeast-2/index.json`.
- **L7 — One EFA interface, deliberately.** g6e.24xlarge has 2 network cards but **each card is documented at
  200 Gbps baseline and peak** — one EFA interface on card 0 already reaches the full instance line rate, so a
  second interface adds no documented headroom (`MaximumEfaInterfaces: 2` remains available). *Standing
  trigger:* if this leg's knee/peak calibration plateaus below expectation with the efa net unsaturated,
  attaching the second interface (instance stop required) is the first candidate — a ratified provisioning
  event, not silent tuning. *Source:* `aws ec2 describe-instance-types g6e.24xlarge` (NetworkCards, 2026-08-20).

## Step 8 — Complete the configuration and re-verify

Write into `env.sh` **yourself**: `FSX_TIER`, `FSX_CAPACITY_TIB`, `FSX_METADATA_IOPS`,
`FSX_EFA_ENABLED`, `LUSTRE_STRIPE_LAYOUT`, and confirm `LEG=lustre` so `FS_MOUNT` resolves to the Lustre mount.

**Also `FS_TRANSPORT`** — `efa` or `tcp`, **from `lnetctl net show`, not from the fact that you installed
something.** `run-leg.sh` refuses to start the leg when it is unset, and refuses `tcp` without a written waiver
(**D16**). If you reached Step 5's gate and it showed only `tcp`, you should not be at this step at all.

```bash
source env.sh
./env.sh --check
scripts/env-contract.py verify --against /tmp/env-contract-leg-weka.json --leg lustre
```

**Now the contract verify must come back clean on every held-constant field.** Anything still violating or
unverifiable is a blocker for the first measured cell, not a footnote — resolve it or surface it.

## Step 9 — Report back, then stop

1. **A table of what exists now:** file system id, tier, capacity, provisioned metadata IOPS, EFA state; mount
   point and type; the stripe layout; the Lustre and kernel versions.
2. **Evidence the client is on EFA** — the `lnetctl net show` output, not an inference from having installed
   something.
3. **The kernel decision**, what `uname -r` says now versus Leg A's contract value, and who approved it.
4. **Every value you wrote into `env.sh`**, and every one left blank with the reason.
5. **The `dd`, `--check` and `env-contract.py verify` outputs**, verbatim.
6. **Any tuning applied**, with the source for each value.
7. **A ready / not-ready verdict** plus a numbered list of anything outstanding, each with a recommendation.
8. **Anything that differed from this document** — command names, package names, the EFA configuration
   procedure. You will run this again; leaving the prompt wrong wastes that run.

Then **stop.** Benchmarking is a separate handoff (`prompts/handoff-cloud.md`) with its own gates, including
a blocker gate that must be reported before the first measured cell.
