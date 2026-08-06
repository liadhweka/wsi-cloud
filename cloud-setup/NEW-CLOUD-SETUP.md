# Cloud setup — from an empty AWS account to a running benchmark

**Read this top to bottom and do it in order.** It assumes **nothing** is set up. Every command is meant to be
copy-pasted, and every step says what it does and how to tell it worked.

**Who does what.** You do the AWS clicking, the credentials, and the storage provisioning. **Claude does all
the hardware-dependent software work** (GPU stack, GDS, scratch disks, Python environments, datasets, tuning)
and then runs the benchmark. **You hand off to Claude four times**, at clearly marked steps: system prep
(Part 5), the WEKA filesystem (Part 6), the benchmark itself (Part 7), and — later — the Lustre filesystem
(Part 8). Each handoff is a self-contained prompt in `cloud-setup/`, reusable on every rebuild. (A fifth,
`prompt-teardown-cloud.md`, closes a leg out — that one lives in
[`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md), not here.)

**Order of the project.** **WEKA is Leg A and runs first** (Parts 1–7). **FSx for Lustre is Leg B and comes
later** (Part 8) — its instructions are written out in advance so nothing is a surprise, but **do not do Part 8
now.**

> **Notation.** `$THINGS_IN_CAPS` are variables from [`NAMING-AND-VARIABLES.md`](NAMING-AND-VARIABLES.md).
> Anything in `<angle brackets>` is a value you paste in.
>
> **When a step in Parts 1–2 says *note this down*, it means exactly that — a scratch note, not a file.**
> `cloud-setup/env.sh` does not exist yet: it is created **on the instance** at § 4.2, which is also where you
> enter these values. Parts 1–2 happen in a browser on your laptop, before the instance even has the repo.
> Keep a scratch note with four things: **region, AZ, bucket name, and (after launch) the AMI and instance
> IDs.** § 4.2 collects them, and shows you how to read the last few off the instance instead of transcribing
> them.

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

**Note both down** — they become `AWS_REGION` and `AWS_AZ` in § 4.2.

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

**Note the name down** — it becomes `S3_BUCKET` in § 4.2. This one cannot be derived later; only you know
which bucket you made.

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

### 2.3 — Note what you launched
Instances → select yours. **You need the public IP right now to connect**; the other two you will read off the
instance itself in § 4.2, so do not bother transcribing them carefully.

- **Public IPv4 address** → needed immediately, for § 2.4. Not a config value.
- **Instance ID** (`i-…`) and **AMI ID** (`ami-…`, Details tab) → these become `INSTANCE_ID` and `AMI_ID`, but
  **§ 4.2 reads both from the instance's own metadata** — one copy-pasteable command, no transcription errors.
  Glance at the AMI ID anyway so you can sanity-check it later: it must be the GPU image you chose, and
  **rebuilding for Leg B must use this exact image** or the OS and drivers silently change underneath the
  comparison.

> **Nothing here needs to go into a file yet.** `env.sh` is created at § 4.2, on the instance.

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

> **What `env.sh` is, since you have only ever seen `env.example.sh`.**
> `cloud-setup/env.example.sh` is the **tracked template** — it lives in GitHub, contains every variable name
> with safe defaults, and no real values. You copy it to `cloud-setup/env.sh`, which is **your private copy on
> this instance**: it is in `.gitignore`, so it never goes to GitHub and you never commit it. That is
> deliberate — it is the one file that may hold environment-specific values, and it is also why **it does not
> survive a rebuild**, which is what the contract in § 6.3 is for.
>
> You edit it with a text editor **on the instance**, over SSH. Not in the GitHub web UI, not on your laptop.

```bash
cd /home/ubuntu/wsi-cloud
cp cloud-setup/env.example.sh cloud-setup/env.sh
```

**First, let the instance tell you about itself.** Four of the five values are already knowable here, so
transcribing them from the console is unnecessary work and a chance to fat-finger an ID:

```bash
# EC2 Instance Metadata Service v2 — get a token, then query with it.
# --max-time is deliberate: without it this hangs instead of failing if IMDS is
# unreachable (e.g. run on the wrong machine, or metadata disabled on the instance).
TOKEN=$(curl -sfX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --max-time 2 || true)
for k in instance-id ami-id instance-type placement/availability-zone placement/region; do
  v=$(curl -sf --max-time 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/$k" || true)
  printf '%-30s %s\n' "$k" "${v:-<EMPTY - read it from the console instead>}"
done
```

> **Why the token.** Newer instances require IMDSv2, and "if IMDSv2 is required, IMDSv1 does not work" — a
> plain `curl` just returns nothing. The `PUT` above obtains a session token and the `X-aws-ec2-metadata-token`
> header presents it. `-f` is deliberate: without it, `curl` prints the error *into* the variable and the
> failure looks like data.
> *(Source: [Access instance metadata for an EC2 instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html).)*
>
> **If any line prints `<EMPTY>`, that is not a disaster** — read that value off the console instead. The loop
> tells you rather than silently filling in a blank, which is the failure mode worth avoiding.

Now edit the file:

```bash
nano cloud-setup/env.sh
```

| Fill in now | From |
|---|---|
| `S3_BUCKET` | your scratch note (§ 1.4) — **your choice, and the only one nothing on the instance can discover** |
| `AWS_REGION`, `AWS_AZ` | the command above — then **check they match your § 1.1 choice.** They came from the instance, so a mismatch doesn't mean a typo: it means you launched somewhere you didn't intend, and cross-AZ traffic would contaminate the comparison |
| `INSTANCE_ID`, `AMI_ID` | the command above |
| `INSTANCE_TYPE` | already correct in the template if you launched `g6e.24xlarge`; otherwise correct it |

| Leave blank for now | Filled in at |
|---|---|
| `LIBCUFILE_PRELOAD` | **Part 5** — Claude reports the path; the GPU-direct sweeps refuse to start without it |
| `WEKA_*` | **Part 6** — Claude writes them itself |
| `FSX_*`, `LUSTRE_STRIPE_LAYOUT` | **Part 8** (Leg B) |
| `CLIENT_HOSTNAME`, `SCRIPT_COMMIT` | Claude, during Part 7 |

Save in nano with **Ctrl+O**, Enter, then **Ctrl+X**.

> **Can Claude do this instead of me?** For everything after this step, yes — from Part 5 onward there is a
> Claude session on this instance with write access to the repo, and it fills in `LIBCUFILE_PRELOAD`, the WEKA
> and FSx configuration, and the contract. **Not this step**, though, for one hard reason: **there is no Claude
> session until Part 5** — it is installed in § 3.5 and the repo only arrives in § 4.1 — and the memory restore
> in § 4.3 needs `env.sh` to exist first.
>
> Of the five values, only `S3_BUCKET` is genuinely undiscoverable; the rest come from the instance itself. So
> **Part 5 re-derives them from instance metadata and cross-checks them against what you typed here**, and
> tells you about any disagreement. This step is the bootstrap, not the source of truth — and § 6.3's
> `./cloud-setup/env.sh --check` is what proves nothing was missed.

```bash
source cloud-setup/env.sh
echo "$FS_MOUNT"                     # should print /mnt/weka
echo 'source /home/ubuntu/wsi-cloud/cloud-setup/env.sh' >> ~/.bashrc   # automatic next login
```

> `env.sh` is deliberately **not** in GitHub (it's per-machine), so it does **not** survive a rebuild — which is
> why Part 6.3 saves the same values into a contract file in S3.

### 4.3 — Restore Claude's memories — **do not skip**
The project's accumulated knowledge lives in files Claude reads at startup. Without them a new session doesn't
know the methodology, the decisions, or what's already been done.
```bash
cd /home/ubuntu/wsi-cloud
./cloud-setup/restore-memories.sh
```
> It's a script rather than a few `rsync` lines because it runs on **every** build and its failure mode is
> silent — copying into the wrong directory succeeds, and a fresh session then starts amnesiac with no error.
> The script derives the directory name from the repo path instead of trusting a typed one, refuses to
> "restore" an empty mirror, and **verifies** the result. It prints `OK — N memory file(s) live` when it
> worked; anything else is a real failure, so don't continue past it.

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

## Part 6 — WEKA: create and mount the filesystem (Leg A) *(second handoff)*

**Almost all of this is Claude's work now.** Provisioning a WEKA filesystem and joining a client to it is a
dozen CLI steps with version-sensitive command names, a destructive resize in the middle, and half a dozen
values that must be recorded exactly. That is a bad fit for a human following prose and a good fit for a session
that can read the vendor docs, check `--help` against the actual cluster, and write the values into `env.sh`
itself.

### 6.1 — What only you can do

1. **Provision the cluster** through your Port blueprint — same **region, AZ and VPC** as the instance, with the
   `wsi-bench-sg` security group attached. This is a web tool; Claude cannot drive it.
2. **Note one backend's IP or hostname.** Claude needs it and cannot discover it.
3. **Have the cluster credentials to hand**, if your cluster requires a CLI login.
4. **Know your sizing choices**, because they are recorded as evidence and cannot be inferred: backend instance
   type and count, usable capacity, protection/EC scheme, and client networking mode.

Sizing, and **why** — full reasoning in [`SPINUP-CHECKLIST.md`](SPINUP-CHECKLIST.md) § D:
- **Enough backends to comfortably exceed ~25 GB/s** to one client. WEKA must not be the bottleneck, or a
  measured difference is a sizing artifact rather than a real finding.
- **~20–25 TB usable.**
- **Client networking: DPDK** (the "performance" option), not UDP.

> **What a WEKA-on-AWS deployment builds, for context.** WEKA's reference path provisions the backends in an
> Auto Scaling Group behind a Launch Template, inside an AWS **Placement Group** to cut inter-node latency, plus
> Lambda functions, a Step Functions state machine, Secrets Manager entries and CloudWatch log groups for
> scale-out and auto-healing. Your blueprint may differ in mechanism but produces the same thing: backend
> instances you can `ssh` to. The placement group is a deliberate trade — WEKA's docs note it "prioritizes
> performance over resilience" — which is right for a benchmark, but record it, because it is part of what was
> measured. *(Source: [WEKA installation on AWS](https://docs.weka.io/planning-and-installation/aws).)*

### 6.2 — Hand off to Claude

```bash
tmux new -A -s wsi
cd /home/ubuntu/wsi-cloud
claude
```
Paste **exactly this**:

> Read the file `cloud-setup/prompt-weka-cluster-cloud.md` and do everything it says, then report back.

Then **give it the four things from 6.1** when it asks.

Claude inspects the cluster read-only first and reports what it found; **asks before the destructive step**
(cloud deployments ship a default filesystem holding all the capacity, so room has to be made); creates the
filesystem group and filesystem; installs the client and mounts it at `/mnt/weka`; verifies with a real write;
and **writes the WEKA values into `cloud-setup/env.sh` itself** rather than asking you to transcribe them.

**Expect to approve several steps.** Resizing a filesystem, `curl | sh`, `sudo`, and mounting all pause for you
by design — read what it proposes rather than waving it through, especially the resize.

**When it reports back**, check three things: the mount is `wekafs` and writable, it is on **DPDK and not UDP**
(it must show you evidence, not an inference), and `./cloud-setup/env.sh --check` passes. Then `/exit`.

> **Why DPDK-versus-UDP is worth your attention:** UDP trades throughput for CPU and would understate WEKA,
> which corrupts the comparison exactly as silently as under-configuring Lustre would.
>
> **Claude is instructed to stop the moment DPDK fails to come up — before mounting, before Part 7, before any
> cell — and report to you.** So if it reports UDP, or cannot evidence which transport it is on, **nothing has
> been measured yet and nothing should be.** Fix DPDK or change the instance; measuring UDP and noting it in the
> writeup is explicitly not an option (**D16**), because the numbers come out looking fine.

### 6.3 — Save the configuration to S3

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

## Part 7 — Hand off to Claude: run the benchmark *(third handoff)*

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

## Part 8 — LATER: FSx for Lustre (Leg B) *(fourth handoff)*

> **Do not do this yet.** It happens after Leg A is finished and closed out. Written now so it holds no
> surprises.

**Like Part 6, almost all of this is Claude's work.** The Lustre side is *more* delicate than the WEKA side, not
less: the client is a kernel module that must match your exact kernel, EFA has to be configured for the Lustre
client specifically, and the tuning is part of what makes the comparison fair. Two of those have failure modes
that produce believable numbers while invalidating the leg — which is exactly why they belong in a prompt with
hard gates rather than a checklist.

### 8.1 — Finish Leg A properly first

Work through [`TEARDOWN-AND-REBUILD.md`](TEARDOWN-AND-REBUILD.md) § Teardown, including
`runs/lib/teardown-preflight.sh`, which must print **GO**. Then rebuild the instance from the **same `AMI_ID`**,
same type, same AZ, and bootstrap it per that document's § Rebuild.

### 8.2 — What only you can do

1. **Create the FSx file system** — or approve Claude creating it via `aws fsx create-file-system`, which it will
   offer. It is a paid resource whose configuration *is* the experiment, so it never happens unilaterally.
   Letting Claude use the CLI has one real advantage: the exact parameters land in the transcript, which is the
   evidence the fairness basis needs later.

   | Setting | Value | Why |
   |---|---|---|
   | Deployment type | **Persistent 2** | Current generation, and the only one where metadata performance is provisioned independently of capacity |
   | Throughput per unit of storage | **1000 MB/s/TiB** — the highest | We deliberately give Lustre its **best** configuration; beating a competitor's best is worth far more than beating a weak setup |
   | Storage capacity | **at least 25 TiB** | At 1000 MB/s/TiB, 25 TiB is where Lustre's disks can finally saturate the instance's network. Below that, Lustre is the bottleneck and we'd be measuring our own sizing choice |
   | Metadata configuration | **User-provisioned**, a high value | Metadata is where the two filesystems differ most architecturally |
   | VPC / subnet / security group | **Same as the instance**, `wsi-bench-sg` | Cross-AZ would distort results |
   | EFA | **Enabled** | Required for GPUDirect Storage, and it removes a hard per-server bandwidth cap |

   Creation takes ~10 minutes.

2. **Decide the kernel policy** when Claude asks — see the warning below.
3. **Approve the installs, the reboots and the mount.**

### 8.3 — Hand off to Claude

```bash
tmux new -A -s wsi
cd /home/ubuntu/wsi-cloud
claude
```
Paste **exactly this**:

> Read the file `cloud-setup/prompt-lustre-cluster-cloud.md` and do everything it says, then report back.

Claude verifies the environment contract against Leg A **before** anything is provisioned (a mismatch found then
costs nothing); installs the EFA software and the Lustre client; **configures the Lustre client for EFA**;
mounts; captures the stripe layout; proposes tuning; and writes the FSx values into `env.sh` itself.

### 8.4 — The two things to watch for in its report

> ## ⚠ 1. EFA must actually be in use, not merely installed
> Enabling EFA on the instance and on the file system, and installing the generic EC2 EFA software, does **not**
> configure the *Lustre client* to use EFA. Without the FSx-specific client configuration the mount quietly runs
> over **TCP** — forfeiting GPUDirect Storage **and** the escape from the per-server bandwidth cap, while still
> producing a full set of believable numbers. That would mean Leg B was measured at a configuration this project
> explicitly promised not to use.
>
> **Claude must show you `lnetctl net show` listing an `efa` net.** Not "I installed EFA" — the output.
>
> **If it shows only `tcp`, Claude is instructed to stop right there — before mounting, before any cell — and
> report to you.** Leg B does not start, and it does not get measured-then-flagged; per **D16** the transport is
> a precondition of the measurement. Tracked as `D-16`.

> ## ⚠ 2. The kernel must not drift
> `kernel` is a held-constant field in the environment contract. The documented Lustre client install pulls
> `linux-aws`, the *latest* AWS kernel — so run naively it can invalidate the comparison the contract exists to
> protect. Claude will ask you to choose: **pin the kernel** and install the matching
> `lustre-client-modules-$(uname -r)` (preferred), or accept the change and **re-baseline both legs**.
> Tracked as `D-17`.

**Also confirm before you let it move on:** `./cloud-setup/env.sh --check` passes, `LUSTRE_STRIPE_LAYOUT` is
recorded (the consistency check derives Lustre's expected wire-vs-application relation from it), and
`env-contract.py verify` comes back clean on every held-constant field.

### 8.5 — Then hand off to the benchmark

Same as Part 7 — `cloud-setup/handoff-cloud.md`. Claude re-hydrates the datasets from S3, applies the remaining
Lustre-leg work, and runs the same cells against the new mount.

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
3. **`env-contract.py write`** (6.3) — it's how you prove the two legs were comparable, *and* how you recover
   `env.sh` after a rebuild.
