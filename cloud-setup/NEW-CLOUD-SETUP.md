# Cloud setup guide — standing this project up from nothing

Step-by-step for bringing the project up on a **blank AWS GPU instance**. Copy-paste in order. You do the
identity/credential bootstrap and the storage provisioning; **Claude does the hardware-dependent setup** (GPU
stack, GDS, local scratch, environments, datasets, tuning) and then runs the benchmark.

Two prompts get pasted into Claude at marked steps:
- **`prompt-env-prep-cloud.md`** — Claude verifies/installs the system stack and provisions local scratch,
  then reports back (**step B7**).
- **`handoff-cloud.md`** — the full project handoff: Claude discovers the environment, builds it out, and
  starts Leg A (**step B11**).

The provisioning specifics — region, quota, bucket, IAM, and the WEKA cluster parameters — live in
**[`SPINUP-CHECKLIST.md`](SPINUP-CHECKLIST.md)**, which is written to be handed to whoever helps you
provision. This guide references it rather than repeating it, so there is one source of truth.

> **Sequencing:** **WEKA is Leg A and runs first.** FSx for Lustre is provisioned later, before Leg B —
> see [Phase D](#phase-d--before-leg-b-lustre) at the end. The instance is the **same** in both legs.

---

## Guiding principle

**Replicate what's identity/continuity-critical; provision the rest optimally for the hardware.**

| Replicate exactly | Provision optimally / re-derive |
|---|---|
| OS user + sudo | GPU count, NUMA/GPU↔NIC topology (Claude re-derives) |
| SSH key ↔ GitHub | Storage client tuning (cores, NICs, stripe layout) |
| Repo path (memory-slug dependency — see B8) | GDS/cuFile config — generated for **this** instance |
| **All memories** (restored to the exact dir) | DDP / concurrency ranges to match the GPU count |
| Methodology, the 20× contract, scripts, docs | Driver/CUDA/client versions — match for compatibility, newer is fine |
| The **datasets** (byte-verified, identical in both legs) | Nothing about the ceiling should be assumed — measure it |

> **Why the repo path matters.** Memories live at `~/.claude/projects/<SLUG>/memory/`, where `<SLUG>` is the
> repo path with `/` → `-`. Use the same user and repo path and the restore lands where Claude reads.
> **B8 discovers the exact slug** rather than assuming it, so a different path still works.

---

## Phase A — On the current machine, before anything else

Everything the cloud instance needs must be in GitHub — git is the migration vehicle.

```bash
cd ~/weka-vs-lustre-cloud
git add -A
git commit -m "project ready for cloud bootstrap"
git push
git status                  # must be clean and pushed
```

> ### ⚠ Do NOT run `./backup.sh` on this machine — the mirror is currently the source of truth
>
> `backup.sh` copies **live memories → mirror**. But the memories in `claude-memory-mirror/` were
> **authored directly into the mirror**, and no live memory directory exists for this repo's slug yet
> (nothing has run here). Running `backup.sh` now would be backing up *from* a directory that doesn't
> exist.
>
> It is safe to try — the script's guard detects a missing or empty source and **refuses, exiting 1**,
> precisely so a `--delete` sync can never silently empty the mirror. But there is no reason to run it.
>
> **The direction inverts once, here, and only here.** After **B8** restores the mirror into the live
> memory directory on the cloud instance, the normal direction resumes — live is authoritative, the mirror
> is generated output, and `backup.sh` is correct and required before every commit and every teardown.

> **Datasets are NOT in git** (~1.8 TB). They are downloaded **once** from public sources and parked in S3,
> then hydrated onto each filesystem — which is also a measured cell (Stage 1.7). Claude handles this.

---

## Phase B — Bootstrap the instance (in order)

### B1 — Provision the environment
Work through **[`SPINUP-CHECKLIST.md`](SPINUP-CHECKLIST.md)** with whoever helps you: region, g6e quota,
the instance (EFA-capable, with the EFA security-group rule), the S3 bucket and IAM instance profile, and
the WEKA cluster. **Capture the five WEKA values** in checklist section D as you set them — they are hard to
change later and they feed the fairness contract.

### B2 — User with sudo
Skip if you are already logged in as your own user with sudo.
```bash
sudo adduser <user>
sudo usermod -aG sudo <user>
su - <user>
whoami
```

### B3 — Base tools — check first, install only what's missing
```bash
for c in curl git ssh node npm; do
  printf '%-6s ' "$c"; command -v "$c" >/dev/null 2>&1 && ($c --version 2>&1 | head -1) || echo "MISSING"
done
```
Install anything missing among the first three (safe to run even if present — `apt` skips those):
```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates git openssh-client
```
`node`/`npm` are for the Claude install in **B5** — note here whether they showed up.

### B4 — SSH key ↔ GitHub
```bash
ssh-keygen -t ed25519 -C "<user>@cloud" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub          # copy the ENTIRE line
```
In a browser: your GitHub account → **Settings → SSH and GPG keys → New SSH key** → paste → **Add**. Then:
```bash
ssh -T git@github.com              # expect: "Hi <account>! You've successfully authenticated..."
```

### B5 — Install Claude Code
npm needs **Node.js 18+**. If B3 showed `node`/`npm` missing or below 18, install a current Node first —
the distro default is often too old:
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version                     # must be ≥ v18
```
Then:
```bash
npm install -g @anthropic-ai/claude-code
claude --version
claude                             # inside: /login  then  /exit
```
> Alternative with no Node at all: the native installer at `https://claude.ai/install.sh`. Either works; if a
> package name or command has changed, check `https://docs.claude.com/claude-code`.

### B6 — Clone the repo
```bash
cd /home/<user>
git clone git@github.com:<account>/weka-vs-lustre-cloud.git
cd weka-vs-lustre-cloud && ls      # CLAUDE.md, PROJECT-THESIS.md, runs/, cloud-setup/, …
```

### B7 — Let Claude prepare the system + local scratch *(first Claude task)*
```bash
tmux new -A -s wsi
cd /home/<user>/weka-vs-lustre-cloud
claude
```
Paste **exactly this**:
> Read the file `cloud-setup/prompt-env-prep-cloud.md` and do everything it says, then report back.

Claude verifies/installs the GPU + CUDA + **GDS** + networking + tool stack and provisions local scratch,
asking before anything destructive. When it reports back, confirm it finished cleanly and resolve anything it
flags before continuing. Then `/exit` (you relaunch in B11).

### B8 — Restore the memories
The destination folder is derived from the repo path — **discover it** (it exists now, because Claude ran in
the repo during B7):
```bash
ls ~/.claude/projects/                         # look for the entry containing "weka-vs-lustre"
```
```bash
SLUG=$(ls ~/.claude/projects/ | grep weka-vs-lustre | head -1)
echo "restoring into: ~/.claude/projects/$SLUG/memory/"
mkdir -p ~/.claude/projects/$SLUG/memory
rsync -a ~/weka-vs-lustre-cloud/claude-memory-mirror/ ~/.claude/projects/$SLUG/memory/
ls ~/.claude/projects/$SLUG/memory/            # verify: 20 files, including MEMORY.md
```
> If nothing matches, Claude has not run in the repo yet — do B7 first (or `cd` in, launch `claude`, `/exit`),
> then re-run the block.

**This is the single most important step in the bootstrap.** The memories are the only continuity that
survives an instance rebuild, and the project's docs assume they are loaded.

### B9 — Hugging Face login
```bash
hf auth login          # paste your token
```
Two of the three foundation models are open; one is gated and needs this.

### B10 — Mount the WEKA filesystem at `/mnt/weka`
Your part; Claude deep-verifies it read-only in B11.
- [ ] Join the instance to the WEKA cluster as a client — **use all available NICs and a frontend-core count
      sized to the instance**, in **DPDK** (performance) mode.
- [ ] Create the filesystem and mount it at **`/mnt/weka`** *(the mount path is a project convention — the
      scripts resolve it through `$FS_MOUNT`)*.
- [ ] `sudo chown <user>:<user> /mnt/weka`
- [ ] `mkdir -p /mnt/weka/data`

### B11 — Hand the project to Claude
```bash
tmux new -A -s wsi
cd /home/<user>/weka-vs-lustre-cloud
claude
```
Paste **exactly this**:
> Read the file `cloud-setup/handoff-cloud.md` and follow it.

Claude then does deep read-only discovery, builds the environment, downloads and stages the datasets, does
the deferred script re-engineering, takes a baseline (**it will stop for your greenlight**), and starts Leg A.

---

## Phase C — What Claude does after B11 (summary)

Full detail in [`handoff-cloud.md`](handoff-cloud.md).

Deep read-only discovery and sanity-check of your bootstrap **and** the hardware → build the Python
environments → set up and tune the GDS/cuFile stack for **this** instance → download the datasets once into
S3 and hydrate onto `/mnt/weka` with byte verification → **do the deferred script work** (mount retargeting,
`--fs` plumbing, per-filesystem recording adapters, S3 sync, watchdog, canary-abort) → prove the recording
pipeline end-to-end on a throwaway cell → **recorded per-block-size baseline (stops for your greenlight)** →
run Leg A per the plan in `runs/STAGES.md`.

---

## Phase D — Before Leg B (Lustre)

Do **not** do this at the start; it is a separate provisioning round after Leg A completes.

1. **Close out Leg A properly** — the teardown checklist in `SPINUP-CHECKLIST.md` § E: handoff prompt →
   `./backup.sh` → `git push` → **verified S3 sync** → **environment contract written**. Skipping any one of
   these loses work permanently.
2. **Provision FSx for Lustre at maximum capability** per the fairness basis (`runs/STAGES.md` **D7**):
   top SSD throughput tier, capacity high enough that its disk throughput exceeds what the client can
   consume, **user-provisioned high metadata IOPS**, and **EFA enabled on the file system**.
3. **Mount it at `/mnt/lustre` over EFA** — EFA is required both for GPUDirect Storage and to escape the
   per-client-per-server bandwidth cap that applies to non-EFA clients.
4. **Rebuild the instance from the pinned AMI** — same type, same region/AZ.
5. **Hand off to Claude again** with the same handoff prompt. It will **verify the environment contract
   before its first cell** and fail loud on a mismatch.

> **Why rebuild rather than keep the instance running between legs:** cost, and a clean instance is
> reproducible. The environment contract is what makes the rebuild safe — it turns "were these comparable?"
> from a judgement call into a check.

---

## Reference

### What must be identical across legs
Instance type, region and AZ, AMI, kernel, driver and CUDA versions, dataset bytes, script commit, the
magnification contract, the model set, the recording harness. **Recorded in the environment contract at the
end of Leg A and verified at the start of Leg B.**

### Datasets (NOT in git — Claude downloads once into S3)
| Dataset | Approx size | Source |
|---|---|---|
| TCGA-BRCA diagnostic slides | ~1.05 TiB | GDC portal, via the tracked manifest |
| CAMELYON16 | ~710 GiB | AWS Open Data (`s3://camelyon-dataset`, `us-west-2`, CC0) |

Manifests are in `runs/manifests/`. The 1073-slide cohort of record is
`tcga-brca-full40x-stage4a-format.tsv`.

### Python environments
Rebuilt by Claude from `cloud-setup/env-specs/` onto local scratch. **Use the conda builds, not pip** — pip
cuCIM wheels have been observed to crash on a libstdc++ ABI mismatch inside `read_region()`.

### Memory backup / restore
- **Backup** (before every commit and every teardown): `./backup.sh`
- **Restore** (fresh instance): the B8 block — discover the slug, then rsync the mirror into it.
