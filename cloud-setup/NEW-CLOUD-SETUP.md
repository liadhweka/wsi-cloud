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
Console → **EC2** → **Instances** → **Launch instances**

| Section | What to do |
|---|---|
| **Name** | `wsi-bench` |
| **Application and OS Images** | **Ubuntu**, version **22.04 LTS** or **24.04 LTS**, architecture **64-bit (x86)** |
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

### 3.2 — Update the system and install basics
```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl ca-certificates git openssh-client unzip
```
A few minutes. If it says a reboot is required: `sudo reboot`, wait ~60 s, SSH back in, `tmux new -A -s wsi`.

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
ssh -T git@github.com        # expect: "Hi liadhweka! You've successfully authenticated..."
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
lines blank — you fill those in Part 6 and Part 8.

Save in nano with **Ctrl+O**, Enter, then **Ctrl+X**.

```bash
source cloud-setup/env.sh
echo "$FS_MOUNT"                     # should print /mnt/weka
echo 'source /home/ubuntu/wsi-cloud/cloud-setup/env.sh' >> ~/.bashrc   # automatic next login
```

> `env.sh` is deliberately **not** in GitHub (it's per-machine), so it does **not** survive a rebuild — which is
> why Part 6.5 saves the same values into a contract file in S3.

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

### 4.4 — Log in to Hugging Face
One of the three AI models is access-gated.
```bash
hf auth login       # paste your Hugging Face token
```
> If `hf` isn't found yet, skip it and come back after Part 5 — it arrives with the Python environment.

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
package manager.

**Expect 20–40 minutes.** It may need a reboot — `sudo reboot`, SSH back, `tmux new -A -s wsi`, relaunch
`claude`.

**When it reports back:** read the verdict, and resolve anything it flags for you before continuing. Then
`/exit`.

---

## Part 6 — WEKA: create and mount the filesystem (Leg A)

### 6.1 — Provision the cluster
Use your normal Port blueprint. Put it in the **same region, AZ, and VPC** as the instance, and attach the
`wsi-bench-sg` security group.

Sizing, and **why** — full reasoning in [`SPINUP-CHECKLIST.md`](SPINUP-CHECKLIST.md) § D:
- **Enough backends to comfortably exceed ~25 GB/s** to one client. WEKA must not be the bottleneck, or a
  measured difference is a sizing artifact rather than a real finding.
- **~20–25 TB usable.**
- **Client networking: DPDK** (the "performance" option), not UDP.

### 6.2 — Record the values — several are hard to get later
Into `env.sh`:

| Variable | What | Why it matters |
|---|---|---|
| `WEKA_BACKEND_TYPE`, `WEKA_BACKEND_COUNT` | Instance type and how many | Evidence for the fairness comparison |
| `WEKA_CAPACITY_TB` | Usable size | Same |
| `WEKA_EC_SCHEME` | Protection scheme (e.g. `3+2`) | **Required** — the consistency check that validates every measurement can't run without it |
| `WEKA_BACKEND_RAM_TOTAL` | Total RAM across backends | Sets how large a later test file set must be to bypass caching |
| `WEKA_CLIENT_CORES`, `WEKA_CLIENT_NICS` | Cores/NICs the client uses | WEKA reserves CPU cores; that's part of its cost and gets measured |

### 6.3 — Join as a client and mount
Follow your usual WEKA client-join process, then create the filesystem and mount it at **`/mnt/weka`**:
```bash
sudo mkdir -p /mnt/weka
# ... your WEKA mount command ...
sudo chown ubuntu:ubuntu /mnt/weka
mkdir -p /mnt/weka/data
```

### 6.4 — Verify it actually works
```bash
findmnt /mnt/weka                                                      # mount + type
df -h /mnt/weka                                                        # expected capacity
dd if=/dev/zero of=/mnt/weka/testfile bs=1M count=1000 oflag=direct    # writes 1 GB
rm /mnt/weka/testfile
```
`dd` should report a sensible speed. **If it doesn't run at all, stop here** — a broken mount invalidates
everything after it.

### 6.5 — Save the configuration to S3
```bash
source cloud-setup/env.sh
./cloud-setup/env.sh --check          # must pass; fix anything it flags
runs/lib/env-contract.py write --leg weka
runs/lib/sync-to-s3.sh --mode full
```
> This records the whole environment into S3. **It's also how you recover `env.sh` after a rebuild**, since that
> file isn't in GitHub.

---

## Part 7 — Hand off to Claude: run the benchmark *(second handoff)*

```bash
tmux new -A -s wsi
cd /home/ubuntu/wsi-cloud
claude
```
Paste **exactly this**:

> Read the file `cloud-setup/handoff-cloud.md` and follow it.

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

uname -r                       # note your kernel version
sudo apt install -y linux-aws lustre-client-modules-aws && sudo reboot
```
Reconnect and confirm the module exists:
```bash
modinfo lustre | head -3
```
> **If you get `Module Not Found`:** the client packages must match the kernel exactly. Run
> `sudo apt-cache search lustre-client-modules` to see which kernels are supported and install the matching
> one. **Don't skip this** — a mismatched module simply will not mount.

### 8.5 — Mount it
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
3. **`env-contract.py write`** (6.5) — it's how you prove the two legs were comparable, *and* how you recover
   `env.sh` after a rebuild.
