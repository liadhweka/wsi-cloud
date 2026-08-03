#!/usr/bin/env bash
# env.example.sh — the project's configuration. Copy to env.sh, fill in, source it.
#
#     cp cloud-setup/env.example.sh cloud-setup/env.sh
#     $EDITOR cloud-setup/env.sh
#     source cloud-setup/env.sh
#     ./cloud-setup/env.sh --check          # validate before running anything
#
# env.sh is gitignored. Every name here is documented in NAMING-AND-VARIABLES.md.
#
# ⚠ NO SECRETS IN HERE. AWS credentials come from the instance profile; Hugging Face
#   from `hf auth login`. Treat this file as if it were public.
#
# The scripts FAIL LOUDLY on an unset required variable rather than defaulting —
# because a wrong default (especially a mount path) produces a plausible-looking
# number from the wrong filesystem, which is the worst failure mode in this project.

# ── Identity & location (DECIDE NOW) ─────────────────────────────────────────────
export PROJECT_USER="ubuntu"                     # AMI default user. NOT root — see the doc.
export PROJECT_HOME="/home/${PROJECT_USER}"
export REPO_DIR="${PROJECT_HOME}/wsi-cloud"
export GITHUB_REPO="liadhweka/wsi-cloud"

# ── AWS (DECIDE NOW) ─────────────────────────────────────────────────────────────
export AWS_REGION="us-west-2"                    # instance + both filesystems + bucket, all same region
export AWS_AZ=""                                 # FILL IN: pick one and keep it (cross-AZ contaminates)
export INSTANCE_TYPE="g6e.24xlarge"              # (subject to change — see STAGES.md D10)
export S3_BUCKET=""                              # FILL IN: globally unique, e.g. weka-wsi-bench-<suffix>

# ── Filesystems (DECIDE NOW) ─────────────────────────────────────────────────────
export WEKA_MOUNT="/mnt/weka"                    # Leg A
export LUSTRE_MOUNT="/mnt/lustre"                # Leg B
export WEKA_FS_NAME="wsibench"                   # the filesystem NAME (need not equal the mount path)

# ── Local scratch & Python (DECIDE NOW) ──────────────────────────────────────────
export SCRATCH_DIR="/data/local-nvme"            # EPHEMERAL — dies with the instance
export CONDA_ROOT="${SCRATCH_DIR}/miniforge"
export CONDA_ENV_MAIN="wsi-cucim-2604"           # matches cloud-setup/env-specs/ filenames
export CONDA_ENV_ALT="wsi-cucim"

# ── Tools & GDS config (DECIDE NOW) ──────────────────────────────────────────────
export CLAM_DIR="${PROJECT_HOME}/wsi-tools/CLAM" # tissue detector (Stage 3); cloned during setup
export CUFILE_CONFIG_DIR="${PROJECT_HOME}/cufile-config"
export CUFILE_ENV_PATH_JSON="${CUFILE_CONFIG_DIR}/cufile.json"   # generated per instance (D-10)
# LIBCUFILE_PRELOAD is located on the instance and set PER CELL (kvikIO cells only —
# cuCIM segfaults under a preloaded newer libcufile). Do not export it globally.

# ── Which leg is running (set per leg) ───────────────────────────────────────────
export LEG="weka"                                # weka | lustre

# ── DERIVED — do not set by hand ─────────────────────────────────────────────────
export MEMORY_SLUG="$(printf '%s' "$REPO_DIR" | sed 's#^/#-#; s#/#-#g')"
case "${LEG}" in
  weka)   export FS_MOUNT="${WEKA_MOUNT}" ;;
  lustre) export FS_MOUNT="${LUSTRE_MOUNT}" ;;
  *)      echo "env.sh: LEG must be 'weka' or 'lustre', got '${LEG}'" >&2 ;;
esac

# ── RECORDED AT PROVISIONING — fill in as you go; feeds the environment contract ──
# Leave blank until known. `--check` warns (does not fail) on these, because they are
# captured progressively rather than up front.
export AMI_ID=""
export INSTANCE_ID=""
export CLIENT_HOSTNAME=""                        # load-bearing: aggregators filter telemetry by it
export WEKA_BACKEND_TYPE=""
export WEKA_BACKEND_COUNT=""
export WEKA_CAPACITY_TB=""
export WEKA_EC_SCHEME=""                         # REQUIRED to derive the WEKA canary relation (D12)
export WEKA_BACKEND_RAM_TOTAL=""                 # drives Stage 6.B corpus sizing (tracker item 5b)
export WEKA_CLIENT_CORES=""
export WEKA_CLIENT_NICS=""
export FSX_TIER=""                               # Leg B
export FSX_CAPACITY_TIB=""
export FSX_METADATA_IOPS=""
export FSX_EFA_ENABLED=""
export LUSTRE_STRIPE_LAYOUT=""                   # REQUIRED to derive the Lustre canary relation (D12)

# ─────────────────────────────────────────────────────────────────────────────────
# --check : validate the configuration before anything runs.
# Sourcing this file does NOT run the check; you must invoke it explicitly.
# ─────────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  fail=0; warn=0
  _req() { # _req VAR "why it matters"
    if [ -z "${!1:-}" ]; then echo "  MISSING  $1 — $2" >&2; fail=$((fail+1));
    else printf '  ok       %-24s = %s\n' "$1" "${!1}"; fi
  }
  _rec() {
    if [ -z "${!1:-}" ]; then echo "  pending  $1 — $2"; warn=$((warn+1));
    else printf '  ok       %-24s = %s\n' "$1" "${!1}"; fi
  }
  _dir() {
    if [ -d "${!1:-/nonexistent}" ]; then printf '  ok       %-24s = %s (exists)\n' "$1" "${!1}";
    else echo "  MISSING  $1 = '${!1:-}' — directory does not exist" >&2; fail=$((fail+1)); fi
  }

  echo "── Required ─────────────────────────────────────────────────────────"
  _req PROJECT_USER    "everything else derives from it"
  _req REPO_DIR        "the memory slug derives from this path"
  _req AWS_REGION      "instance, filesystems and bucket must share it"
  _req AWS_AZ          "cross-AZ traffic contaminates the comparison"
  _req INSTANCE_TYPE   "held constant across both legs"
  _req S3_BUCKET       "the only durable store; teardown loses telemetry without it"
  _req LEG             "determines FS_MOUNT and the S3 prefix"
  _req FS_MOUNT        "a wrong mount silently measures the other filesystem"
  _req MEMORY_SLUG     "where memories are restored to"
  _req CONDA_ENV_MAIN  "matches the env-specs filenames"

  echo "── Paths ────────────────────────────────────────────────────────────"
  _dir REPO_DIR
  _dir FS_MOUNT
  _dir SCRATCH_DIR

  echo "── Recorded at provisioning (blank is OK early) ──────────────────────"
  _rec CLIENT_HOSTNAME        "aggregators filter telemetry by hostname"
  _rec WEKA_EC_SCHEME         "needed to derive the WEKA canary relation (D12)"
  _rec WEKA_BACKEND_RAM_TOTAL "drives Stage 6.B corpus sizing"
  _rec AMI_ID                 "Leg B rebuilds from this exact AMI"
  _rec SCRIPT_COMMIT          "both legs must run the same code"

  echo "── AWS reachability ─────────────────────────────────────────────────"
  if command -v aws >/dev/null 2>&1; then
    if aws sts get-caller-identity >/dev/null 2>&1; then
      echo "  ok       credentials (instance profile) working"
      if [ -n "${S3_BUCKET:-}" ] && aws s3 ls "s3://${S3_BUCKET}/" >/dev/null 2>&1; then
        echo "  ok       s3://${S3_BUCKET}/ reachable"
      else
        echo "  MISSING  cannot list s3://${S3_BUCKET:-<unset>}/ — wrong name or missing s3:ListBucket" >&2
        fail=$((fail+1))
      fi
    else
      echo "  MISSING  no working AWS credentials — expected an instance profile" >&2; fail=$((fail+1))
    fi
  else
    echo "  MISSING  aws CLI not on PATH" >&2; fail=$((fail+1))
  fi

  echo "─────────────────────────────────────────────────────────────────────"
  if [ "$fail" -gt 0 ]; then
    echo "env.sh --check: $fail REQUIRED item(s) missing, $warn pending. DO NOT run benchmarks yet." >&2
    exit 1
  fi
  echo "env.sh --check: all required items present ($warn still pending at provisioning). OK."
fi
