# Task prompt — stand up and mount the WEKA filesystem for this leg

You are Claude Code on the project's AWS GPU instance. This is a **self-contained storage-provisioning task**:
take a freshly provisioned WEKA cluster and leave the GPU instance with a healthy, correctly sized `wekafs`
mount plus every provisioning fact recorded. **You are not benchmarking here** — the WSI pipeline, the stages
and the workload code are irrelevant to this task and you do not need to read them.

**You will run this again** on every rebuild and every new cluster, so keep it repeatable: prefer commands
whose output you record over judgements you keep in your head.

---

## What the human has already done, and what only they can do

Done before you start: provisioned the WEKA cluster through the company's self-service blueprint, in the same
region/AZ/VPC as this instance and with the `wsi-bench-sg` security group attached. They have **one backend's
IP or hostname** and any cluster credentials.

**Ask them for, do not guess:** the backend IP/hostname, cluster credentials if the CLI demands them, and the
sizing they chose (backend instance type and count, usable capacity, protection/EC scheme, client networking
mode). Those last ones are *their* provisioning decisions — you record them, you do not infer them.

---

## Rules you operate under

- **Verify before you change anything.** Read-only inspection first, always.
- **Ask before every mutating or destructive step**, stating exactly what will happen and what would be lost.
  In this task that means: resizing an existing filesystem, `curl … | sh`, anything with `sudo`, any mount, and
  any reboot. Show the command, wait for the answer.
- **Reference `docs.weka.io`, not recall,** for every command and flag. **The WEKA CLI has changed command
  names between versions** — this document flags the known cases, but check `weka version current` and
  `weka <cmd> --help` on the actual cluster before running anything. Doc-fetching is standing-approved.
- **Fail loud.** If you cannot verify something worked, say so plainly rather than reporting success.
- **Never invent a value for the environment file.** If you cannot determine something, leave it blank and say
  which one and why.

---

## Why the details matter here (read this once — it changes what "good enough" means)

This filesystem is **one half of a controlled comparison**: the same workload will later run against a
different filesystem, and every difference between the two runs that is *not* the filesystem is a confound. So:

- **Do not enable options that change the I/O path** — no encryption, no data reduction — unless the human
  explicitly asks and understands it must then be matched on the other leg.
- **The client's reserved core count is measured data, not a tuning knob.** WEKA's client reserves cores for
  its own data path; the other filesystem's client does not. That asymmetry is accounted for explicitly, so the
  number you choose must be **recorded** and then **held constant for the whole leg**. Changing it mid-leg is a
  benchmark change requiring a re-baseline.
- **DPDK is a precondition, not a preference. If DPDK does not come up, STOP AND REPORT IMMEDIATELY** — do not
  mount UDP, do not continue this prompt, and do not let a benchmark cell run (**D16**). UDP trades throughput
  for CPU and would understate this filesystem, corrupting the comparison as silently as under-configuring the
  other side would. Reporting it *after* measuring is too late: the numbers look fine.
- **The protection/EC scheme is required downstream**, not optional bookkeeping: a per-sweep consistency check
  derives the expected wire-vs-application write amplification from it and cannot run without it.

---

## Step 1 — Orient (read-only)

```bash
source cloud-setup/env.sh 2>/dev/null || true
echo "$WEKA_MOUNT $WEKA_FS_NAME"        # the target mount path and filesystem name
findmnt "$WEKA_MOUNT" || echo "not mounted yet (expected)"
```

Confirm with the human: backend address, and whether they want a **new** filesystem (recommended) or to use
whatever the deployment created.

## Step 2 — Reach the cluster and confirm it is healthy

The WEKA CLI is installed **on every backend** — there is no separate admin host. Either `ssh` to a backend, or
once the client is installed here use `weka -H <BACKEND> …`, which "directs the CLI to communicate with the
cluster through the specified hostname or IP".

```bash
ssh <user>@<BACKEND>            # user depends on the backend AMI the blueprint used
weka status
```

**`weka status` must report healthy.** It shows healthy / partially protected / rebuilding / unavailable, and
numbers taken from a rebuilding cluster are meaningless. If it is rebuilding, stop and tell the human — waiting
is correct.

If the CLI demands credentials: `weka user login` writes a token to `~/.weka/auth-token.json`;
`WEKA_USERNAME` / `WEKA_PASSWORD` are read from the environment if set; with no login and no token file the CLI
falls back to `admin`/`admin`. `weka user whoami` confirms who you are. **Ask the human for credentials — never
try password guesses.**

*Sources: [Manage the system using the WEKA CLI](https://docs.weka.io/getting-started-with-weka/manage-the-system-using-weka-cli),
[Manage users using the CLI](https://docs.weka.io/operation-guide/user-management/user-management-1).*

## Step 3 — Inspect what the deployment already created

```bash
weka status                 # capacity summary
weka fs                     # existing filesystems
weka fs group               # existing filesystem groups
weka cluster container      # the backend containers, their roles and addresses
weka version current
```

**Expect capacity to be fully allocated already.** WEKA's docs state that "when deploying a WEKA system on a
cloud platform (AWS, Azure, or GCP), the WEKA system includes a default filesystem configured to maximum
capacity" — so creating a new filesystem will fail for lack of capacity until you free some.
*(Source: [Manage filesystems](https://docs.weka.io/weka-filesystems-and-object-stores/managing-filesystems).)*

**Report to the human before proceeding:** cluster health, total/free capacity, the exact name of every existing
filesystem, existing groups, and which of the two paths in Step 4 you propose.

## Step 4 — Make room *(ask first — this is the destructive step)*

**Path A (recommended): shrink the default filesystem, then create a dedicated one.**

```bash
weka fs update <default-fs-name> --total-capacity <smaller-size>
weka fs                                     # confirm the capacity is freed
```

`weka fs update <name> [--total-capacity …] [--ssd-capacity …]` is the documented resize.
*(Source: [Manage filesystems using the CLI](https://docs.weka.io/weka-filesystems-and-object-stores/managing-filesystems/managing-filesystems-1).)*

> ⚠ **Shrinking a filesystem that holds data can destroy that data.** Before proposing this, prove the
> filesystem is empty (`weka fs` used capacity, and mount it read-only to look if there is any doubt) and say
> so in the same message as the request. On a freshly deployed cluster it is empty and this is safe. **If it
> shows used capacity, do not propose the shrink at all** — surface it and let the human decide.

**Path B: use the existing default filesystem as-is.** Fewer moving parts, but its size and settings are
whatever the deployment chose, and you must still record them. Skip to Step 6.

## Step 5 — Create the filesystem group and the filesystem *(ask first)*

Every filesystem belongs to a **filesystem group**, which is where tiering policy lives. Reuse a suitable
existing group if there is one; otherwise create one:

```bash
weka fs group                                    # list
weka fs group create <group-name>                # create
```

Signature: `weka fs group create <name> [--target-ssd-retention=<seconds>] [--start-demote=<seconds>]`. **Leave
both optional parameters at their defaults** — they control tiering to an object store, which this project does
not use.
*(Source: [Managing Filesystem Groups](https://docs.weka.io/3.14/fs/managing-filesystems/managing-filesystem-groups) — an older doc branch, so confirm with `weka fs group --help`.)*

Then the filesystem, named `$WEKA_FS_NAME` from `env.sh`:

```bash
weka fs add "$WEKA_FS_NAME" <group-name> <total-capacity>
weka fs                                          # confirm name and size
```

Signature: `weka fs add <name> <group-name> <total-capacity> [--ssd-capacity …] [--encrypted] [--data-reduction] …`
Minimum 1 GiB; **the group name is mandatory**, which is why the group comes first.

> **`add` or `create`?** The current CLI reference documents `weka fs add`; WEKA's own getting-started page
> shows `weka fs create <name> <group> <capacity>`. Both appear in official docs — the name has moved between
> versions. Run `weka fs --help` and use what this cluster accepts. **Report which form worked**, so the
> teardown/rebuild run does not have to rediscover it.
>
> **Do not pass `--encrypted` or `--data-reduction`** — see the framing note above.

## Step 6 — Install the client on this instance and mount *(ask first — `sudo` and `curl | sh`)*

**On the GPU instance now, not a backend.** The client software is served **by a backend on port 14000**, not
from a package repository:

```bash
curl http://<BACKEND>:14000/dist/v1/install | sh
sudo mkdir -p "$WEKA_MOUNT"
```
*(Source: [Adding clients (AWS)](https://docs.weka.io/3.14/install/aws/adding-clients) — an older doc branch.
**Confirm the current install URL for this cluster's version before running it**; piping a URL into a shell
deserves that much care, and say so when you ask.)*

Then the **first mount, which also joins the cluster**: "The first `mount` command serves a dual purpose: 1) It
installs the WEKA client software. 2) It joins the WEKA cluster." Later mounts need only per-mount options.

```bash
sudo mount -t wekafs -o num_cores=<N> -o net=<netdev> <BACKEND>[,<BACKEND2>,…]/"$WEKA_FS_NAME" "$WEKA_MOUNT"
```

Syntax: `mount -t wekafs -o <options> <backend0>[,<backend1>,…]/<fs> <mount-point>` (a `:/` separator also
works). **Listing several backends is the more robust form** — do that.

| Option | Meaning |
|---|---|
| `num_cores=<N>` | "the number of processing cores allocated to handle client network operations"; `0` means UDP-only. **Mutually exclusive with `core=`** |
| `core=<core-id>` | pins specific cores instead of a count; repeatable |
| `net=<netdev>` | the client network device for WEKA traffic |

*Source: [Mount filesystems](https://docs.weka.io/weka-filesystems-and-object-stores/mounting-filesystems).*

**Choosing `num_cores`:** propose a value to the human with your reasoning, given this instance's core count and
that the cores are then unavailable to the benchmark. **Record whatever is chosen and do not change it later in
the leg.**

### If DPDK will not come up — STOP IMMEDIATELY AND REPORT

**This is a full stop, not a note for later.** Do not mount in UDP mode. Do not continue to Step 7. Do not
start, or let anything else start, a benchmark cell. Report at once: what you ran, the exact error, the
`net=` device you tried, what the docs said, and your reading of why DPDK failed. **Then wait for the human.**

WEKA *does* document a UDP fallback (`-o num_cores=0 -o net=udp`), and it is named here **only so you recognise
it if you see it** — it is not an instruction and not a step in this prompt. A UDP mount succeeds, serves data,
and reports plausible numbers for a transport this project has decided not to measure (**D16**); it also
"cannot be configured in high availability mode". Measuring it and flagging it afterwards is the failure mode
this gate exists to prevent, because by then the wallclock and the money are already spent and the numbers look
fine.

Mounting UDP deliberately is a **human decision, in writing, with the reason recorded** — and it would require
re-baselining and restating the fairness basis, so expect the answer to be "fix DPDK or change the instance."

> DPDK on a virtual machine requires SR-IOV to "expose a Virtual Function (VF) of the physical device to the
> client"; on AWS that is the enhanced-networking/ENA path already enabled at launch. If the mount rejects your
> `net=` device, that is the area to investigate — and it is worth fetching WEKA's current networking docs
> rather than guessing at option syntax.

Finally:

```bash
sudo chown "$USER:$USER" "$WEKA_MOUNT"
mkdir -p "$WEKA_MOUNT/data"
```

## Step 7 — Verify, then write the values into `env.sh` yourself

```bash
findmnt "$WEKA_MOUNT"          # expect type wekafs
df -h "$WEKA_MOUNT"            # expect the capacity you provisioned
weka status                    # still healthy after the client joined?
weka local status              # this client container's own state
dd if=/dev/zero of="$WEKA_MOUNT/testfile" bs=1M count=1000 oflag=direct
rm "$WEKA_MOUNT/testfile"
```

`dd` must run and report a plausible rate. **If it fails, stop** — a broken mount invalidates everything after
it, and it is far cheaper to fix now.

**Then edit `cloud-setup/env.sh` directly** — do not ask the human to transcribe values you already have:

| Variable | Source |
|---|---|
| `WEKA_FS_NAME` | Step 5 (or the existing name, on Path B) |
| `WEKA_CAPACITY_TB` | Step 5, cross-checked against `df -h` |
| `WEKA_CLIENT_CORES`, `WEKA_CLIENT_NICS` | your Step 6 mount options, cross-checked with `weka local status` |
| **`FS_TRANSPORT`** | `dpdk` or `udp` — **from the client's own report, never from the mount options you passed.** `run-leg.sh` refuses to start the leg if this is unset, and refuses if it says `udp` without a written waiver (**D16**). If you cannot evidence which it is, leave it blank and say so: an unrecorded transport correctly blocks the leg rather than quietly passing |
| `WEKA_BACKEND_TYPE`, `WEKA_BACKEND_COUNT`, `WEKA_EC_SCHEME`, `WEKA_BACKEND_RAM_TOTAL` | **the human's provisioning answers** — ask if you do not have them; `weka cluster container` and `weka status` may corroborate but the human's blueprint choice is authoritative |

Then prove the configuration is complete:

```bash
source cloud-setup/env.sh
./cloud-setup/env.sh --check
```

`--check` **must pass on the required items.** Items it reports as `pending` are filled in later by other steps;
say which remain and who fills them.

## Step 8 — Report back, then stop

1. **A table of what exists now:** cluster health, filesystem name / group / capacity, mount point and type,
   client core and NIC binding, WEKA version, and the `add`-vs-`create` form that worked.
2. **Every value you wrote into `env.sh`**, and **every one you left blank, with the reason.**
3. **The `dd` result and the `--check` output**, verbatim.
4. **Whether the client is on DPDK or UDP**, with evidence — not an inference from the mount options you passed.
5. **A ready / not-ready verdict**, plus a numbered list of anything the human must resolve, each with a
   recommendation.
6. **Anything that differed from this document**, so it can be corrected — command names, install URLs, option
   syntax. You will run this again on the next cluster; leaving the prompt wrong wastes that run.

Then **stop.** Do not start any benchmark work: that is a separate handoff
(`cloud-setup/handoff-cloud.md`), and it has its own reading and its own gates.
