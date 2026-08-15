# Task prompt — stand up and mount FSx for Lustre for this leg

You are Claude Code on the project's AWS GPU instance, **rebuilt for Leg B**. This is a **self-contained
storage-provisioning task**: take an FSx for Lustre file system and leave this instance with a healthy,
**EFA-mounted** Lustre filesystem plus every provisioning fact recorded. **You are not benchmarking here** — the
WSI pipeline is irrelevant to this task and you do not need to read it.

**You will run this again** on every rebuild, so keep it repeatable: record commands and outputs rather than
carrying judgements in your head.

---

## Read this first — two ways this task fails silently

Both **produce perfectly plausible numbers while invalidating the comparison** — nothing errors, nothing looks
wrong, and the damage is invisible until someone asks what was actually measured. That is why this is a prompt
with hard gates rather than a checklist.

**1. Mounting over TCP instead of EFA.** Enabling EFA on the instance, requesting EFA on the file system, and
installing the *generic* EC2 EFA software does **not** configure the *Lustre client* to use EFA. Without the
FSx-specific client configuration the mount quietly uses TCP — forfeiting GPUDirect Storage **and** the escape
from the per-client-per-file-server bandwidth cap. This project's fairness basis is "Lustre provisioned at
maximum capability"; a TCP mount breaks that promise while still producing numbers. **Step 5 is a hard gate.**
Tracked as deferred item `D-16`.

**2. Changing the kernel.** `kernel` is a `MUST_MATCH` field in the cross-leg environment contract. The
documented Lustre client install can pull a newer kernel, and any OS upgrade can move it too — so the Leg-B
procedure can invalidate the very comparison the contract protects. **Step 4 must not run before the kernel
question is settled with the human.** Tracked as `D-17`.

Neither is a reason to avoid the work. Both are reasons to check, record, and surface.

---

## What only the human can do

- **Create the FSx file system** (Step 2) — or approve you doing it via the CLI. It is a paid resource with
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
What matters is that `instance_type`, `aws_region`, `aws_az`, `ami_id` and `kernel` already match. **If the AMI
or kernel differs from Leg A, stop and surface it** — that is `D-17`, and it is cheaper to rebuild the instance
now than to discover it after a week of cells.

## Step 2 — The file system *(human creates, or approves you creating)*

The configuration below **is** the experiment — this side is deliberately provisioned at maximum capability, so
under-configuring it is as damaging as under-configuring the other leg. Every value has a reason:

| Setting | Value | Why |
|---|---|---|
| Deployment type | **Persistent 2** | The generation where metadata performance is provisioned independently of capacity |
| Throughput per unit of storage | **1000 MB/s/TiB** — the top SSD tier | Deliberately its best configuration |
| Storage capacity | **≥ 25 TiB** | At 1000 MB/s/TiB this is where disk throughput reaches the client's ~25 GB/s ceiling; below it the file system is the constraint and any delta is a sizing artifact |
| Metadata IOPS | **User-provisioned, high** | Persistent 2 provisions metadata independently of capacity, so leaving it at the default would under-provision the metadata path while the data path runs at maximum (**D7**) |
| VPC / subnet / security group | **same as this instance**, `wsi-bench-sg` | Cross-AZ traffic would contaminate the comparison |
| EFA | **Enabled** | Prerequisite for GPUDirect Storage, and it removes a hard per-file-server cap |

**Prefer the CLI if the human agrees**, and say why when you propose it: `aws fsx create-file-system` records the
exact parameters in your transcript, which is precisely what the fairness basis has to be able to evidence
later. Fetch the current parameter names from the AWS CLI reference — do not reconstruct them from this table.

Creation takes roughly ten minutes. **Record `FSX_TIER`, `FSX_CAPACITY_TIB`, `FSX_METADATA_IOPS`,
`FSX_EFA_ENABLED` into `env.sh` yourself** once it reports available.

## Step 3 — EFA software on the instance *(ask first; reboots)*

Install the EC2 EFA software per AWS's current EFA getting-started guide, then verify the provider exists:

```bash
fi_info -p efa -t FI_EP_RDM        # must list an "efa" provider
```

**If no `efa` provider appears, STOP AND REPORT IMMEDIATELY** — do not continue to Step 4 or 5. Without the
generic provider there is no EFA LND for Lustre to use, so continuing only arrives at the Step 5 gate having
spent two installs and a reboot.

If the kernel enables Yama, relax it for EFA's shared-memory path (skip if the sysctl does not exist):

```bash
sudo sysctl -w kernel.yama.ptrace_scope=0
echo "kernel.yama.ptrace_scope = 0" | sudo tee /etc/sysctl.d/10-ptrace.conf
```

**This is the generic EFA stack, not the Lustre EFA configuration** — Step 5 is still required.

## Step 4 — Lustre client modules *(ask first; kernel-sensitive; reboots)*

**Settle the kernel question before running anything here.** The two options, and the human picks:

- **Pin the kernel** — install a Lustre client build that matches the *running* kernel, checking
  availability first against AWS's Lustre-client install page for this OS (Amazon Linux 2023). Keeps the
  contract intact. **Preferred.**
- **Accept a kernel change** — take the kernel the client packages require, then **re-baseline both legs**
  and record that decision. Expensive; only if no matching client build exists.

Add AWS's FSx Lustre client repository per the current AWS "installing the Lustre client" documentation, then
install, then reboot, then:

```bash
uname -r                           # compare against the value from Step 1
modinfo lustre | head -3           # module present?
```

> **If the module will not load or does not exist for this kernel**, that is the known trap: the client packages
> must match the kernel exactly. Surface it with the
> package-search output for the Lustre client on this OS and let the human choose. **Do not** silently take the
> kernel-upgrading path.

## Step 5 — Configure the Lustre client for EFA — THE GATE *(ask first)*

**This is the step whose absence silently invalidates Leg B.** AWS ships an FSx-Lustre-specific EFA client
configuration; the generic EFA installer from Step 3 does not do it.

**Fetch the current procedure from AWS's FSx for Lustre client documentation** — this tooling has changed names
and locations, so do not run a command remembered from anywhere, including this file. Then:

```bash
sudo lnetctl net show          # must list an `efa` net, not only `tcp`
```

### Hard gate: if it shows only `tcp` — STOP IMMEDIATELY AND REPORT

**Stop here, at this step.** Do not continue to Step 6 — **do not mount at all** — and do not let a benchmark
cell run. Report at once: what you ran, the exact output, which AWS page you followed, and where the procedure
diverged from it. **Then wait for the human.**

*Why not "mount over TCP and flag it in the report":* a TCP mount works. It produces a complete, believable set
of numbers for a transport this project explicitly decided not to measure (**D16**), while forfeiting GPUDirect
Storage *and* the escape from the per-client-per-file-server bandwidth cap — so it breaks the "Lustre at
maximum" fairness basis (**D7**) invisibly. Flagging it afterwards does not undo the wallclock, the money, or a
results tree whose provenance now has to be argued about. Mounting over TCP anyway is a **human decision, in
writing, with the reason recorded.**

Record what you did and what `lnetctl net show` printed — the next rebuild needs it, and so does the writeup.

## Step 6 — Mount *(ask first)*

Get the mount command from the FSx console for **this** file system (**FSx → your file system → Attach**) rather
than typing one from memory: the DNS name and short mount name are specific to it, and the network-transport
portion of the device string changes once the EFA LND is in use.

```bash
sudo mkdir -p "$FS_MOUNT"
# ... the console's exact mount command, adjusted for the EFA transport ...
sudo chown "$USER:$USER" "$FS_MOUNT"
mkdir -p "$FS_MOUNT/data"
```

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

## Step 7 — Tuning is part of the fairness basis, not an optimisation *(propose; ask before applying)*

Leaving Lustre untuned would **understate** it and break the "provisioned at maximum" promise as surely as a TCP
mount would. This is deferred item `D-11`.

Fetch AWS's current FSx for Lustre performance and client-tuning guidance plus `doc.lustre.org` on striping, then
**propose** a stripe layout and client tunables suited to this workload — large-file sequential reads and writes
alongside small-file metadata pressure — with the reasoning and the source for each. Apply only what the human
approves, and **record every value applied**, because it is part of what was measured.

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
