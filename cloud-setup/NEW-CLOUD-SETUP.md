# Cloud setup — from an empty AWS account to a running benchmark

**Read this top to bottom and do it in order.** It assumes **nothing** is set up. Every command is meant to be
copy-pasted, and every step says what it does and how to tell it worked.

**Who does what.** You do the AWS clicking, the credentials, and the storage provisioning. **Claude does all
the hardware-dependent software work** (GPU stack, GDS, scratch disks, Python environments, datasets, tuning)
and then runs the benchmark. You hand off to Claude twice, at clearly marked steps.

**Order of the project.** **WEKA is Leg A and runs first** (Parts 1–7). **FSx for Lustre is Leg B and comes
later** (Part 8) — its instructions are written out in advance so nothing is a surprise, but **do not do Part 8
now.**

> **Notation.** `$THINGS_IN_CAPS` are variables from [`NAMING-AND-VARIABLES.md`](NAMING-AND-VARIABLES.md).
> Anything in `<angle brackets>` is a value you paste in. When a step says *record this*, write the value into
> `cloud-setup/env.sh` — later steps and the whole benchmark read from there.

---

## Part 0 — Before you touch AWS

**You need:**
- An AWS account with permission to create EC2 instances, S3 buckets, IAM roles, and FSx file systems.
- Your GitHub account (the repo lives there).
- The WEKA cluster provisioning path you already use (your company's Port blueprint).

**Decide the names first.** Open [`NAMING-AND-VARIABLES.md`](NAMING-AND-VARIABLES.md) and settle the
*decide-now* column. Recommended values are filled in already; the ones you must actually choose are the
**region**, the **availability zone**, and the **S3 bucket name**.

Already decided, so you don't have to think about them:

| | |
|---|---|
| Login user | **`ubuntu`** (the AMI's built-in user — no account creation needed) |
| Repo folder | **`/home/ubuntu/wsi-cloud`** |
| GitHub repo | **`liadhweka/wsi-cloud`** |
| WEKA mount | **`/mnt/weka`** · Lustre mount **`/mnt/lustre`** |
| Instance | **`g6e.24xlarge`** — 96 vCPU, 768 GiB RAM, 4× L40S GPUs, 200 Gbps |

---

## Part 1 — AWS foundations

Do all five **before** launching the instance. They're quick, and two of them (quota, security group) block you
later if skipped.

### 1.1 — Pick your region and availability zone
Everything must live in **one region and one AZ** — the instance, both filesystems, and the S3 bucket. Traffic
between AZs costs money and adds latency, which would quietly distort the benchmark.

- **Region:** `us-west-2` is a good default (the CAMELYON dataset is hosted there, so that download is local).
  But your company's standard region, or wherever you can actually get GPU capacity, wins.
- **AZ:** pick any one in that region, e.g. `us-west-2a`, and use it for everything.

**Record both** as `AWS_REGION` and `AWS_AZ`.

### 1.2 — Request GPU quota *(do this first — it can take a day)*
AWS limits how many GPU instances you can run, counted in **vCPUs**. `g6e.24xlarge` needs **96**. A brand-new
account often has 0.

1. AWS Console → search **Service Quotas** → **AWS services** → **Amazon Elastic Compute Cloud (Amazon EC2)**
2. Search for **Running On-Demand G and VT instances**
3. Click it → **Request increase at account level** → enter **192** → submit

> Why 192 rather than 96: it leaves room to move up to `g6e.48xlarge` later without another wait.

Approval is usually hours but can be a day. **Everything else can be done while you wait.**

### 1.3 — Create the security group
This controls network access. It needs one unusual rule (a self-referencing "all traffic" rule) that **EFA
requires** — EFA is the fast network path Lustre needs in Part 8. Setting it up now avoids rebuilding the
instance later.

1. Console → **EC2** → **Security Groups** → **Create security group**
2. **Name:** `wsi-bench-sg` · **VPC:** leave the default
3. **Create security group**, then **select it** and copy its **Security group ID** (`sg-…`)
4. **Actions → Edit inbound rules → Add rule:**
   - Type **All traffic**, Source type **Custom**, and paste **that same `sg-…` ID** into the source box
   - **Add rule** again: Type **SSH**, Source type **My IP**
   - **Save rules**
5. **Actions → Edit outbound rules → Add rule:**
   - Type **All traffic**, Destination type **Custom**, paste the **same `sg-…` ID**
   - **Save rules**

> The self-referencing rule looks strange but is correct — it lets the instance's EFA interface talk to itself
> and to others in the group. *(Source: AWS EFA getting-started guide, Step 1.)*

### 1.4 — Create the S3 bucket
**This is the only thing that survives the instance being deleted.** All raw benchmark measurements and the
datasets live here. Without it, tearing down the instance destroys the results.

1. Console → **S3** → **Create bucket**
2. **Name:** must be **globally unique across all of AWS** — use something like `weka-wsi-bench-liad-2026`. If
   it says the name is taken, add more to it.
3. **Region:** the same one from 1.1
4. Leave everything else at defaults: Block Public Access **on**, Versioning **off**, encryption on
5. **Create bucket**

**Record the name** as `S3_BUCKET`.

> Versioning stays **off** deliberately: measurements are written once and never edited, so versioning would
> double the storage bill for no benefit.

### 1.5 — Create the IAM role that lets the instance use the bucket
This is how the instance gets access **without putting any passwords or keys on disk**.

1. Console → **IAM** → **Policies** → **Create policy** → **JSON** tab → paste this, replacing
   `YOUR-BUCKET-NAME` in **both** places:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME" },
    { "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME/*" }
  ]
}
```

2. **Next** → **Name:** `wsi-bench-s3-policy` → **Create policy**
3. **IAM** → **Roles** → **Create role**
4. **Trusted entity type:** AWS service · **Use case:** **EC2** → **Next**
5. Search for and tick **`wsi-bench-s3-policy`** → **Next**
6. **Name:** `wsi-bench-instance-role` → **Create role**

> Two separate statements because S3 expresses bucket-level and object-level permissions differently — the
> first has no `/*`, the second does. Fiddly, but that's the required shape.

---

## Part 2 — Launch the instance

### 2.1 — Create an SSH key pair (if you don't have one)
1. Console → **EC2** → **Key Pairs** → **Create key pair**
2. **Name:** `wsi-bench-key` · **Type:** RSA · **Format:** `.pem`
3. **Create** — the file downloads automatically. **You can never download it again.** Then, on your laptop:

```bash
mkdir -p ~/.ssh && mv ~/Downloads/wsi-bench-key.pem ~/.ssh/
chmod 400 ~/.ssh/wsi-bench-key.pem      # SSH refuses to use a key others can read
```

### 2.2 — Launch

> ## ⚠ READ THIS BEFORE YOU TOUCH THE WIZARD — the image choice is the first field, and an OPEN DECISION
> A stock Ubuntu image ships **no NVIDIA driver, no CUDA toolkit, no `nvidia-fs`, no `libcufile`**, and the
> env-prep session in Part 5 is instructed to **stop and report** rather than install a GPU driver (that is a
> reboot-class task, deliberately not automated). So launching plain Ubuntu **dead-ends this guide at Part 5.**
>
> **Choose a GPU-bearing AMI** — e.g. the current *AWS Deep Learning Base GPU AMI* on Ubuntu. **Confirm the
> exact image name in the console rather than trusting a remembered title**, because the variants and titles
> change. Architecture must be **64-bit (x86)**.
>
> **This is an open decision, not a settled one** — item 2 in `AUDIT-REPORT.md`, `C10` in the
> `cloud-session-open-items` memory. Whatever you pick, **pin its AMI ID** (2.3): Leg B rebuilds from it, and
> `kernel`, `driver_version` and `cuda_version` are all held-constant contract fields, so a different image at
> rebuild time invalidates the comparison.
>
> **Two other fields in this wizard cannot be changed after launch** — the EFA interface type and the IAM
> instance profile. Getting either wrong means rebuilding. They are called out in the table.

Console → **EC2** → **Instances** → **Launch instances**

| Section | What to do |
|---|---|
| **Name** | `wsi-bench` |
| **Application and OS Images** | The GPU AMI from the note above · **64-bit (x86)** |
| **Instance type** | `g6e.24xlarge` — type it into the search box |
| **Key pair** | `wsi-bench-key` |
| **Network settings** | Click **Edit**. **Subnet:** pick the one in your chosen **AZ** (it must not be "no preference"). **Firewall:** *Select existing security group* → `wsi-bench-sg` |
| **Advanced network configuration** | Expand it. For **Network interface 1**: Network card index **0**, Device index **0**, **Interface type = EFA with ENA** |
| **Configure storage** | Root volume **200 GiB**, type `gp3` |
| **Advanced details** | **IAM instance profile** → `wsi-bench-instance-role` |

Then **Launch instance**.

> **The EFA interface type is the step most easily missed**, and it **cannot be changed after launch** — you'd
> have to rebuild the instance. Lustre needs it in Part 8.
>
> The 200 GiB root volume is for the OS only. The instance also has two fast NVMe disks (~3.8 TB) that Claude
> sets up later as scratch — those are **wiped whenever the instance stops**, which is why S3 exists.
>
> **From this moment you are paying by the hour**, and from Part 6 the filesystem usually costs more per hour
> than the instance. Stopping the instance alone is *not* a cost pause — see the cost note in
> [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md) § 8 before you leave anything idle for long.

### 2.3 — Record what you launched
Instances → select yours → copy these into `env.sh`:
- **Instance ID** (`i-…`) → `INSTANCE_ID`
- **AMI ID** (`ami-…`, on the Details tab) → `AMI_ID` — **this one matters**: rebuilding later must use this
  exact image, or the OS and drivers silently change
- **Public IPv4 address** → for connecting

### 2.4 — Connect
```bash
ssh -i ~/.ssh/wsi-bench-key.pem ubuntu@<PUBLIC-IP>
```
Type `yes` when asked about authenticity. You should land at a prompt like `ubuntu@ip-10-0-1-23:~$`.

> **Stuck?** Timeout = the security group's SSH rule doesn't include your current IP (re-check 1.3 — your IP
> may have changed). "Permission denied" = wrong key path, or `chmod 400` not applied.

---

## Part 3 — Prepare the instance

Everything from here runs **on the instance**, over SSH.

### 3.1 — Start a tmux session — do this before anything long
`tmux` keeps your work alive if your laptop disconnects. **Without it, a dropped connection kills a running
benchmark.**
```bash
tmux new -A -s wsi
```
(Disconnected later? SSH back in and run the same command to reattach.)

### 3.2 — Note the kernel, then update the system

**Write the kernel version down first.** It is a held-constant field in the environment contract, and the next
command can change it:

```bash
uname -r                                 # note this exact string
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl ca-certificates git openssh-client unzip
uname -r                                 # did it change?
```

A few minutes. If it says a reboot is required: `sudo reboot`, wait ~60 s, SSH back in, `tmux new -A -s wsi`,
then check `uname -r` again — a pending kernel only takes effect after the reboot.

> ⚠ **If the kernel changed, that is fine on Leg A but must be recorded.** `kernel` is a `MUST_MATCH` field, so
> the value that ends up in the contract is the one **Leg B must reproduce**. The hazard is doing this
> *differently* on the rebuild: see open item `D-17` and the same warning on Part 8.4's Lustre-client install.
> Note both `uname -r` values now and tell Claude in Part 5 — it records them.

### 3.3 — Install the AWS CLI and confirm the bucket works
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install && cd ~
aws --version
```
Now prove the IAM role works — **no keys, no configuration needed:**
```bash
aws sts get-caller-identity                  # ARN should end in .../wsi-bench-instance-role/...
aws s3 ls s3://<YOUR-BUCKET-NAME>/           # empty bucket = no output = success
```
> **If either fails, stop and fix it.** Everything downstream assumes the bucket is reachable, and a benchmark
> that can't reach S3 has nowhere durable to put its measurements.

### 3.4 — Set up SSH access to GitHub
```bash
ssh-keygen -t ed25519 -C "ubuntu@wsi-bench" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```
Copy that **entire line**. In a browser: GitHub → avatar → **Settings** → **SSH and GPG keys** → **New SSH
key** → paste → **Add SSH key**. Then:
```bash
ssh -T git@github.com        # expect: "Hi <your-github-username>! You've successfully authenticated..."
```
(The message greets **your** account, whichever it is; "successfully authenticated" is the part that matters.
GitHub always adds "but GitHub does not provide shell access" — that is normal, not an error.)
Set your commit identity now — git refuses to commit without it, and **you** make every commit in this
project:
```bash
git config --global user.name  "<Your Name>"
git config --global user.email "<your@email>"
```

### 3.5 — Install Claude Code
Needs Node.js 18+; Ubuntu's default is too old:
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version                          # must be v20.x or higher
npm install -g @anthropic-ai/claude-code
claude --version
```
Log in once — launch `claude`, type `/login`, follow the browser prompt, then `/exit`.

---

## Part 4 — Get the project onto the instance

### 4.1 — Clone the repo
```bash
cd /home/ubuntu
git clone git@github.com:liadhweka/wsi-cloud.git
cd wsi-cloud && ls
```
You should see `CLAUDE.md`, `PROJECT-THESIS.md`, `runs/`, `cloud-setup/`, and others.

### 4.2 — Create the configuration file
```bash
cp cloud-setup/env.example.sh cloud-setup/env.sh
nano cloud-setup/env.sh
```
Fill in what you recorded: `AWS_REGION`, `AWS_AZ`, `S3_BUCKET`, `AMI_ID`, `INSTANCE_ID`. Leave the WEKA and FSx
lines blank — you fill those in Part 6 and Part 8. Leave `LIBCUFILE_PRELOAD` blank too; Claude reports the
path in Part 5 and you paste it in then (the GPU-direct sweeps refuse to run without it).

Save in nano with **Ctrl+O**, Enter, then **Ctrl+X**.

```bash
source cloud-setup/env.sh
echo "$FS_MOUNT"                     # should print /mnt/weka
echo 'source /home/ubuntu/wsi-cloud/cloud-setup/env.sh' >> ~/.bashrc   # automatic next login
```

> `env.sh` is deliberately **not** in GitHub (it's per-machine), so it does **not** survive a rebuild — which is
> why Part 6.9 saves the same values into a contract file in S3.

### 4.3 — Restore Claude's memories — **do not skip**
The project's accumulated knowledge lives in files Claude reads at startup. Without them a new session doesn't
know the methodology, the decisions, or what's already been done.
```bash
cd /home/ubuntu/wsi-cloud
SLUG=$(printf '%s' "$PWD" | sed 's#^/#-#; s#/#-#g')
echo "$SLUG"                                        # -home-ubuntu-wsi-cloud
mkdir -p ~/.claude/projects/$SLUG/memory
rsync -a claude-memory-mirror/ ~/.claude/projects/$SLUG/memory/
ls ~/.claude/projects/$SLUG/memory/                 # expect ~20 files, including MEMORY.md
```

### 4.4 — Get your Hugging Face token ready *(you cannot log in yet)*
One of the three AI models is access-gated, so a token is required — but the `hf` command **does not exist
until Part 7**, when Claude builds the Python environments. Part 5 installs only the package manager.

**So do the browser half now and the login later:**
1. Hugging Face → your avatar → **Settings** → **Access Tokens** → create a **read** token, and keep it to hand.
2. Confirm you have been **granted access** to the gated model on its model page (approval is not instant, so
   request it now rather than discovering the wait in Part 7).
3. The actual `hf auth login` happens in **Part 7.1**, below. Do not run it here — it will say
   `command not found`.

---

## Part 5 — Hand off to Claude: system preparation *(first handoff)*

```bash
tmux new -A -s wsi
cd /home/ubuntu/wsi-cloud
claude
```
Paste **exactly this**:

> Read the file `cloud-setup/prompt-env-prep-cloud.md` and do everything it says, then report back.

Claude checks the GPU drivers, CUDA, the GPUDirect Storage stack and the network setup; installs missing tools;
formats the fast NVMe scratch disks (**it asks first** — that step erases them); and installs the Python
package manager (**not** the Python environments themselves — those come in Part 7).

It also reports the full path of the system `libcufile`. **Paste that into `LIBCUFILE_PRELOAD` in
`cloud-setup/env.sh`** — the GPU-direct sweeps read it and refuse to start without it.

**Expect 20–40 minutes.** It may need a reboot — `sudo reboot`, SSH back, `tmux new -A -s wsi`, relaunch
`claude`.

**When it reports back:** read the verdict, and resolve anything it flags for you before continuing. Then
`/exit`.

---

## Part 6 — WEKA: create and mount the filesystem (Leg A)

**This part assumes no prior WEKA knowledge.** It is written to the same depth as Part 8 (Lustre), because the
two legs must be provisioned with equal care — an under-configured WEKA is a "sizing artifact", not a finding.

**The shape of it.** A WEKA cluster is a set of **backend** EC2 instances that own the storage. Your GPU
instance joins as a **client**: it installs WEKA's client software, joins the cluster, and mounts a filesystem
over a kernel filesystem type called `wekafs`. Between "the cluster exists" and "I can write to `/mnt/weka`"
there are four things that are easy to miss the first time:

1. capacity in a cluster is handed out to **filesystems**, and on a cloud deployment a **default filesystem
   already holds all of it** — so you must free some before you can create your own;
2. every filesystem must belong to a **filesystem group**;
3. the client software is installed **from a backend**, not from a package repo;
4. the **first mount** is what actually joins the client to the cluster, and it needs networking arguments the
   later mounts do not.

> **Version drift is real, and the CLI has changed names between versions.** Everything below cites
> `docs.weka.io`, but **confirm against the version your cluster actually runs** — `weka version current`, then
> `weka <command> --help`. Where the docs themselves disagree between versions, both forms are given.

---

### 6.1 — Provision the cluster

Use your normal Port blueprint. Put it in the **same region, AZ, and VPC** as the GPU instance, and attach the
`wsi-bench-sg` security group.

> **What a WEKA-on-AWS deployment builds, for context.** WEKA's own reference path is a Terraform package that
> provisions the backends in an **Auto Scaling Group behind a Launch Template**, inside an AWS **Placement
> Group** to cut inter-node latency, plus Lambda functions, a Step Functions state machine, Secrets Manager
> entries and CloudWatch log groups for scale-out/scale-in and auto-healing. Your blueprint may differ in
> mechanism but produces the same thing: a set of backend instances you can `ssh` to.
> *(Source: [WEKA installation on AWS](https://docs.weka.io/planning-and-installation/aws).)*
>
> Note the placement group is a deliberate trade: WEKA's docs say it "prioritizes performance over resilience
> and may reduce fault tolerance in the event of hardware failures." For a benchmark that is the right side of
> the trade — but record it, because it is part of what was measured.

Sizing, and **why** — full reasoning in [`SPINUP-CHECKLIST.md`](SPINUP-CHECKLIST.md) § D:
- **Enough backends to comfortably exceed ~25 GB/s** to one client. WEKA must not be the bottleneck, or a
  measured difference is a sizing artifact rather than a real finding.
- **~20–25 TB usable.**
- **Client networking: DPDK** (the "performance" option), not UDP. This is a deployment-time choice and it
  matters to the comparison — see 6.7.

**Before you leave the console, note one backend's IP or hostname.** You need it in 6.2 and again in 6.7, and
hunting for it later is the single most common stall in this part. Any backend will do.

---

### 6.2 — Reach the cluster and authenticate

The WEKA CLI is installed **on every backend**. There is no separate admin host.

```bash
ssh <your-key> ec2-user@<BACKEND-IP>      # user depends on the backend AMI your blueprint used
weka status
```

`weka status` "displays the overall status of the WEKA cluster", showing whether it is healthy, partially
protected, rebuilding, or unavailable. **It must say healthy before you go further** — provisioning numbers
taken from a rebuilding cluster are meaningless.
*(Source: [Manage the system using the WEKA CLI](https://docs.weka.io/getting-started-with-weka/manage-the-system-using-weka-cli).)*

**Authentication.** If the CLI asks for credentials:

```bash
weka user login            # writes a token to ~/.weka/auth-token.json
weka user whoami           # confirms who you are
```
The CLI reads `WEKA_USERNAME` / `WEKA_PASSWORD` from the environment if set; otherwise it uses the token file;
and **if no user is logged in and no token file exists it defaults to `admin`/`admin`** — which is also worth
knowing as a thing to change.
*(Source: [Manage users using the CLI](https://docs.weka.io/operation-guide/user-management/user-management-1).)*

> **You can also drive the cluster from the GPU instance** once the client is installed (6.7), using
> `weka -H <BACKEND-IP> <command>` — the `-H/--hostname` option "directs the CLI to communicate with the
> cluster through the specified hostname or IP". That is often more convenient than keeping a second ssh
> session open, and it is what `record-run.sh` relies on.
>
> **A browser GUI is served by the backends on port 14000.** Whether you can reach it depends on your security
> group and whether you are inside the VPC; the CLI path below is authoritative either way, so do not block on
> the GUI. (Port 14000 is also the port the client installer is fetched from — 6.7.)

---

### 6.3 — Look at what the deployment already gave you *(the step that surprises everyone)*

```bash
weka status                # capacity summary
weka fs                    # list existing filesystems
weka fs group              # list existing filesystem groups
```

**On a cloud deployment there is already a filesystem, and it holds everything.** WEKA's docs state that "when
deploying a WEKA system on a cloud platform (AWS, Azure, or GCP), the WEKA system includes a default filesystem
configured to maximum capacity."
*(Source: [Manage filesystems](https://docs.weka.io/weka-filesystems-and-object-stores/managing-filesystems).)*

So `weka fs add` for a new filesystem will fail for lack of capacity until you deal with that. **Note the exact
name shown by `weka fs`** — use what is printed, not a name from a guide.

**Two valid ways forward. Pick one and record which:**

| Option | Do this | When |
|---|---|---|
| **A — shrink the default, create your own** | 6.4 then 6.5/6.6 | **Recommended.** The benchmark filesystem is then explicitly sized and named, and appears in the contract as your own object |
| **B — just use the default filesystem** | skip to 6.7, mount the default fs at `/mnt/weka` | Fewer steps, but the filesystem's size and settings are whatever the deployment chose — you must still record them |

Either way the mount point is `/mnt/weka`, which is all the benchmark scripts care about (`$FS_MOUNT`).

---

### 6.4 — Free capacity by shrinking the default filesystem

```bash
weka fs update <default-fs-name> --total-capacity <smaller-size>     # e.g. 1TiB
weka fs                                                             # confirm the freed capacity
```

`weka fs update <name> [--total-capacity total-capacity] [--ssd-capacity ssd-capacity] …` is the documented way
to change an existing filesystem's size.
*(Source: [Manage filesystems using the CLI](https://docs.weka.io/weka-filesystems-and-object-stores/managing-filesystems/managing-filesystems-1).)*

> ⚠ **Shrinking a filesystem that holds data can destroy it.** On a freshly deployed cluster the default
> filesystem is empty, so this is safe — but confirm it is empty first, and never run this against a
> filesystem with anything in it. If `weka fs` shows used capacity, stop and ask.

---

### 6.5 — Create a filesystem group

Every filesystem belongs to a **filesystem group**, which is where the tiering policy lives. You may already
have one from 6.3; if not:

```bash
weka fs group                                  # list groups
weka fs group create wsibench-group            # create one if none suits
```

Signature: `weka fs group create <name> [--target-ssd-retention=<seconds>] [--start-demote=<seconds>]`. The two
optional parameters control tiering to an object store, which **this project does not use** — object/S3 access
is explicitly out of scope — so the defaults are correct and you should not set them.
*(Source: [Managing Filesystem Groups](https://docs.weka.io/3.14/fs/managing-filesystems/managing-filesystem-groups) — verify with `weka fs group --help`, as this page is from an older doc branch.)*

---

### 6.6 — Create the benchmark filesystem

```bash
weka fs add wsibench wsibench-group 20TiB      # <name> <group> <total-capacity>
weka fs                                        # confirm it exists at the size you asked for
```

Signature: `weka fs add <name> <group-name> <total-capacity> [--ssd-capacity …] [--encrypted] [--data-reduction] …`
Minimum capacity is 1 GiB, and **the group name is mandatory** — that is why 6.5 comes first.
*(Source: [Manage filesystems using the CLI](https://docs.weka.io/weka-filesystems-and-object-stores/managing-filesystems/managing-filesystems-1).)*

> **`add` or `create`?** The current CLI reference documents `weka fs add`; WEKA's own getting-started page
> shows `weka fs create new_fs my_fs_group 1TiB`. Both appear in official docs, so the name has moved between
> versions. Run `weka fs --help` and use what your cluster accepts.
>
> **Do not enable `--encrypted` or `--data-reduction`.** Both change the I/O path, and this filesystem is one
> half of a controlled comparison — every setting that is not held constant across the two legs is a confound.
> Record whatever you *do* set.
>
> **`WEKA_FS_NAME` in `env.sh` is this name** (`wsibench` by default). It is deliberately separate from the
> mount path: the filesystem is named `wsibench`, and it is mounted at `/mnt/weka`.

---

### 6.7 — Install the WEKA client on the GPU instance, and mount

**Back on the GPU instance now**, not a backend.

The client software is fetched **from a backend over port 14000** — not from a package repository:

```bash
curl http://<BACKEND-IP>:14000/dist/v1/install | sh     # installs the WEKA agent
sudo mkdir -p /mnt/weka
```
*(Source: [Adding Clients (AWS)](https://docs.weka.io/3.14/install/aws/adding-clients) — confirm the current
install URL for your cluster version before running it; piping a URL to `sh` deserves that much care.)*

Then the **first mount**, which does more than mount: "The first `mount` command serves a dual purpose: 1) It
installs the WEKA client software. 2) It joins the WEKA cluster." Later mounts need only per-mount options.
*(Source: [Mount filesystems](https://docs.weka.io/weka-filesystems-and-object-stores/mounting-filesystems).)*

```bash
# DPDK mount — the performance path this project measures
sudo mount -t wekafs -o num_cores=<N> -o net=<netdev> <BACKEND-IP>/wsibench /mnt/weka
```

The syntax is
`mount -t wekafs -o <options> <backend0>[,<backend1>,…,<backendN>]/<fs> <mount-point>`; a `:/` separator works
in place of `/`. Listing **several backends** is supported and is the more robust form. The options that matter:

| Option | What it does |
|---|---|
| `num_cores=<N>` | "the number of processing cores allocated to handle client network operations". `0` means UDP-only. **Mutually exclusive with `core=`** |
| `core=<core-id>` | pins specific cores instead of a count — repeatable, e.g. `-o core=2 -o core=4` |
| `net=<netdev>` | the client's network device for WEKA traffic |

> **`num_cores` is not a throwaway number — it is measured.** Those cores are **reserved by the WEKA client and
> unavailable to the benchmark**, which is exactly the asymmetry decision **D15** exists for: the Lustre client
> reserves none, so CPU-derived metrics are computed over *application-available* cores and the reservation is
> reported as part of WEKA's cost. Whatever you choose, put it in `WEKA_CLIENT_CORES` (6.8) and **do not change
> it mid-leg** — a client reconfiguration is a benchmark change and forces a re-baseline.
>
> **If DPDK will not come up**, the documented fallback is UDP mode:
> `sudo mount -t wekafs -o num_cores=0 -o net=udp <BACKEND-IP>/wsibench /mnt/weka`.
> **Treat that as a finding, not a workaround** — UDP trades throughput for CPU and would understate WEKA,
> which breaks the fairness basis (**D7**) just as silently as an under-configured Lustre would. Also note a
> UDP-mode client "cannot be configured in high availability mode".
>
> **Why DPDK needs care on a VM at all:** WEKA's docs note that for DPDK on a virtual machine, "Single Root I/O
> Virtualization (SR-IOV) must be used to expose a Virtual Function (VF) of the physical device to the client."
> On AWS that is the enhanced-networking/ENA path you already enabled at launch. If the mount rejects your
> `net=` device, this is the area to look at — and it is a question for Claude's Part 7 discovery pass, which
> is required to consult WEKA's docs rather than guess.

Finally, make the mount usable by the benchmark user and create the data directory:

```bash
sudo chown ubuntu:ubuntu /mnt/weka
mkdir -p /mnt/weka/data
```

---

### 6.8 — Verify it actually works, and record the values

```bash
findmnt /mnt/weka                                                      # mount + type (expect wekafs)
df -h /mnt/weka                                                        # expected capacity
weka status                                                            # still healthy?
weka local status                                                      # the client container's own state
dd if=/dev/zero of=/mnt/weka/testfile bs=1M count=1000 oflag=direct    # writes 1 GB
rm /mnt/weka/testfile
```

`dd` should report a sensible speed. **If it doesn't run at all, stop here** — a broken mount invalidates
everything after it.

Now fill these into `env.sh`. **Most are your 6.1 provisioning choices** — they are inputs you already made,
not things to go hunting for:

| Variable | What | Where it comes from | Why it matters |
|---|---|---|---|
| `WEKA_FS_NAME` | Filesystem name (`wsibench`) | **6.6** | The scripts mount by name; kept distinct from the mount path deliberately |
| `WEKA_BACKEND_TYPE`, `WEKA_BACKEND_COUNT` | Backend instance type and how many | **Your 6.1 choice** | Evidence for the fairness comparison |
| `WEKA_CAPACITY_TB` | Usable size | **6.6**; cross-check `df -h /mnt/weka` | Same |
| `WEKA_EC_SCHEME` | Protection scheme (e.g. `3+2`) | **Your 6.1 choice** | **Required** — the per-sweep consistency canary derives the wire-vs-app write amplification from it and cannot run without it |
| `WEKA_BACKEND_RAM_TOTAL` | Total RAM across backends | Backend instance type × count | Server-side cache size; sets how large the Stage 6.B corpus must be to read genuinely cold |
| `WEKA_CLIENT_CORES`, `WEKA_CLIENT_NICS` | Cores and NICs the client reserves | **Your 6.7 mount options**; cross-check `weka local status` | WEKA reserves CPU cores; that is part of its cost and is measured per cell (**D15**) |

> **If you cannot pin down a value, leave it blank and move on** — except `WEKA_EC_SCHEME`, which the canary
> needs. Claude re-reads the client and cluster configuration during its Part 7 discovery pass; it is on the
> box, it has the mount, and it is required to fetch WEKA's documentation rather than guess. What matters is
> that **every one of these is filled in before teardown**, because `runs/lib/teardown-preflight.sh` checks the
> contract for completeness and the fairness basis is unverifiable afterwards.

---

### 6.9 — Save the configuration to S3
```bash
source cloud-setup/env.sh
./cloud-setup/env.sh --check          # must pass; fix anything it flags
runs/lib/env-contract.py write --leg weka
runs/lib/sync-to-s3.sh --mode full
```
> This records the whole environment into S3. **It's also how you recover `env.sh` after a rebuild**, since that
> file isn't in GitHub.
>
> `env-contract.py write` **exits non-zero and lists any held-constant field it could not record.** At this
> point in the setup that is expected for anything the Python environments supply — they don't exist until
> Part 7. Note what it lists and move on; what matters is that the contract is **complete before teardown**,
> which `runs/lib/teardown-preflight.sh` checks against the contract's own field list.

---

## Part 7 — Hand off to Claude: run the benchmark *(second handoff)*

### 7.1 — Start the session

```bash
tmux new -A -s wsi
cd /home/ubuntu/wsi-cloud
claude
```
Paste **exactly this**:

> Read the file `cloud-setup/handoff-cloud.md` and follow it.

### 7.2 — Log in to Hugging Face, once the environments exist

Claude builds the Python environments early in its plan. **As soon as it reports them built**, do the login you
deferred at 4.4 — in a second terminal, or after Claude pauses for sign-off:

```bash
source cloud-setup/env.sh
"$CONDA_ENVS_DIR/$CONDA_ENV_MAIN/bin/hf" auth login     # paste your read token
```
(Plain `hf auth login` works too if that environment is on your `PATH`.)

> **Why it cannot wait:** the gated model's weights download on first use, deep inside a feature-extraction
> cell. Discovering the missing login there wastes the cell. Claude will ask you to confirm this is done before
> Stage 6.

### 7.3 — What Claude then does

Claude inspects everything you set up, builds the Python environments, downloads the datasets (~1.8 TB — hours,
in the background), finishes the remaining code work, proves the measurement system works on a throwaway test,
then **stops and asks you to approve the baseline numbers** before running the real benchmark.

**This is a multi-day process.** Long runs happen unattended inside tmux — you can disconnect, then reconnect
with SSH and `tmux new -A -s wsi`.

**When Leg A finishes**, go to [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md) before deleting anything.

---

## Part 8 — LATER: FSx for Lustre (Leg B)

> **Do not do this yet.** It happens after Leg A is finished and closed out. Written now so it holds no
> surprises.

Lustre works differently from WEKA: instead of a vendor client, it uses a **kernel module that must match your
exact Linux kernel version**, and it reaches full speed over **EFA** (the network path you enabled at launch).

### 8.1 — Finish Leg A properly first
Work through [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md) § Teardown, including
`runs/lib/teardown-preflight.sh`, which must print **GO**. Then rebuild the instance from the **same `AMI_ID`**,
same type, same AZ.

### 8.2 — Create the file system
Console → **FSx** → **Create file system** → **Amazon FSx for Lustre**.

| Setting | Value | Why |
|---|---|---|
| Deployment type | **Persistent 2** | Current generation, and the only one where metadata performance is provisioned independently |
| Throughput per unit of storage | **1000 MB/s/TiB** — the highest | We deliberately give Lustre its **best** configuration; beating a competitor's best is worth far more than beating a weak setup |
| Storage capacity | **at least 25 TiB** | At 1000 MB/s/TiB, 25 TiB is where Lustre's disks can finally saturate the instance's network. Below that, Lustre is the bottleneck and we'd be measuring our own sizing choice |
| Metadata configuration | **User-provisioned**, a high value | Metadata is where the two filesystems differ most architecturally |
| VPC / subnet / security group | **Same as the instance**, `wsi-bench-sg` | Cross-AZ would distort results |
| EFA | **Enabled** | Required for GPUDirect Storage, and it removes a hard per-server bandwidth cap |

Creation takes ~10 minutes. **Record** `FSX_TIER`, `FSX_CAPACITY_TIB`, `FSX_METADATA_IOPS`, `FSX_EFA_ENABLED`.

### 8.3 — Install the EFA software
*(Source: AWS EFA getting-started guide, Step 3.)*
```bash
curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
tar -xf aws-efa-installer-latest.tar.gz && cd aws-efa-installer
sudo ./efa_installer.sh -y
cd ~ && sudo reboot
```
Reconnect, then verify:
```bash
fi_info -p efa -t FI_EP_RDM       # must list an "efa" provider
```
Ubuntu also needs one protection setting relaxed for EFA's shared-memory path:
```bash
sudo sysctl -w kernel.yama.ptrace_scope=0
echo "kernel.yama.ptrace_scope = 0" | sudo tee /etc/sysctl.d/10-ptrace.conf
```

### 8.4 — Install the Lustre client
*(Source: AWS "Installing the Lustre client", Ubuntu section.)*
```bash
wget -O - https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-ubuntu-public-key.asc \
  | gpg --dearmor | sudo tee /usr/share/keyrings/fsx-ubuntu-public-key.gpg >/dev/null

sudo bash -c 'echo "deb [signed-by=/usr/share/keyrings/fsx-ubuntu-public-key.gpg] https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu $(lsb_release -cs) main" > /etc/apt/sources.list.d/fsxlustreclientrepo.list && apt-get update'

uname -r                       # note your kernel version — and compare it to the contract
sudo apt install -y linux-aws lustre-client-modules-aws && sudo reboot
```
> ## ⚠ This command can change the kernel — OPEN DECISION (`D-17`)
> `linux-aws` is the *latest* AWS kernel, and **`kernel` is a `MUST_MATCH` field in the environment
> contract** you verify three sub-sections later in 8.7. So run as written, this step can make Leg B fail its
> own comparability gate — the one thing this project is built to prevent.
>
> **Decide before running it:** either pin the kernel and install the matching module
> (`sudo apt install -y lustre-client-modules-$(uname -r)`, checking availability with
> `apt-cache search lustre-client-modules` first), or accept the kernel change and **re-baseline both legs**,
> recording that decision. Do not discover this at 8.7.
Reconnect and confirm the module exists:
```bash
modinfo lustre | head -3
```
> **If you get `Module Not Found`:** the client packages must match the kernel exactly. Run
> `sudo apt-cache search lustre-client-modules` to see which kernels are supported and install the matching
> one. **Don't skip this** — a mismatched module simply will not mount.

### 8.5 — Mount it

> ## ⚠ MISSING STEP — the Lustre client is not yet configured for EFA (`D-16`)
> Everything so far enables EFA on the **instance** (2.2), requests it on the **file system** (8.2), and
> installs the **generic EC2** EFA software (8.3). None of that configures the *Lustre client* to use EFA — AWS
> ships a separate FSx-Lustre EFA client setup for that, and this guide does not run it.
>
> **Without it the mount below goes over TCP**, which forfeits **both** GPUDirect Storage and the escape from
> the per-client-per-server bandwidth cap — while still producing perfectly plausible numbers. That silently
> breaks the "Lustre at maximum" fairness basis (**D7**) this whole comparison rests on: Leg B would be
> measured at a configuration we explicitly promised not to use.
>
> **Before mounting:** get the current procedure from AWS's own FSx for Lustre client documentation (do not
> follow a remembered command — this tooling changes), run it, then treat the check below as a **hard gate**:
>
> ```bash
> sudo lnetctl net show      # must list an `efa` net, not only `tcp`
> ```
>
> **If it lists only `tcp`, stop.** Do not run a Leg-B cell. This is open item `D-16` in the
> `cloud-session-open-items` memory and item 3 in `AUDIT-REPORT.md`; the mount string the console gives you
> will also change once the EFA LND is in use.

The FSx console gives you the exact command for your file system:

Console → **FSx** → your file system → **Attach** → copy the mount command shown.

It looks like this:
```bash
sudo mkdir -p /mnt/lustre
sudo mount -t lustre -o relatime,flock <dns-name>@tcp:/<mountname> /mnt/lustre
sudo chown ubuntu:ubuntu /mnt/lustre
```
> **Use the console's exact string** rather than typing from memory — the DNS name and the short mount name are
> specific to your file system, and a wrong one fails confusingly.

Verify:
```bash
findmnt /mnt/lustre
lfs df -h /mnt/lustre          # Lustre-specific: storage and metadata targets
lfs getstripe -d /mnt/lustre   # how files are spread across servers
```
**Record the `lfs getstripe` output** as `LUSTRE_STRIPE_LAYOUT` — the measurement-validation check needs it,
exactly as WEKA's needed its protection scheme.

### 8.6 — Switch the project to Leg B
```bash
nano cloud-setup/env.sh        # change: export LEG="lustre"
source cloud-setup/env.sh
echo "$FS_MOUNT"               # must now print /mnt/lustre
./cloud-setup/env.sh --check
```

### 8.7 — Prove the two legs are comparable — the gate
```bash
aws s3 cp s3://$S3_BUCKET/env-contracts/env-contract-leg-weka.json /tmp/
runs/lib/env-contract.py verify --against /tmp/env-contract-leg-weka.json --leg lustre
```
It separates **VIOLATION** (something that should have stayed identical has changed — the comparison is
invalid) from **differs as expected** (the filesystem settings, which are the whole point).

**A VIOLATION means stop and fix it.** Comparing two environments that differ in more than the filesystem would
blame the filesystem for something else — the single error this project exists to avoid.

### 8.8 — Hand off to Claude for Leg B
Same as Part 7. Claude verifies everything, applies Lustre-specific tuning (part of giving Lustre its best
configuration), re-loads the datasets from S3, and runs the same benchmark.

---

## Quick troubleshooting

| Symptom | Cause and fix |
|---|---|
| SSH times out | Your IP changed; update the SSH rule in `wsi-bench-sg` (1.3) |
| `Permission denied (publickey)` | Wrong `.pem` path, or `chmod 400` not applied |
| "Insufficient capacity" at launch | No GPU capacity in that AZ right now. Try another AZ **in the same region**, or wait |
| Quota error at launch | 1.2 hasn't been approved yet |
| `aws s3 ls` says Access Denied | IAM role not attached, or the policy has the wrong bucket name |
| Lustre `Module Not Found` | Client packages don't match your kernel — see 8.4 |
| Anything on a mount is slow or fails | **Stop.** A degraded mount invalidates every measurement after it |
| Disconnected mid-run | Fine — reconnect and `tmux new -A -s wsi` |

## The three things that cause real damage if skipped

1. **EFA interface type at launch** (2.2) — cannot be added later; Lustre needs it.
2. **The S3 bucket and IAM role** (1.4, 1.5) — without them, deleting the instance destroys all results.
3. **`env-contract.py write`** (6.9) — it's how you prove the two legs were comparable, *and* how you recover
   `env.sh` after a rebuild.
