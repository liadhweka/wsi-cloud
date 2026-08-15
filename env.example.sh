#!/usr/bin/env bash
# env.example.sh — the project's configuration template.
#
# scripts/bootstrap-instance.sh generates env.sh from this file at boot, filling
# every instance-derived value from the machine's own evidence. Manual fallback:
#
#     cp env.example.sh env.sh && $EDITOR env.sh && source env.sh
#     ./env.sh --check          # validate before running anything
#
# env.sh is gitignored. Every name here is documented in docs/NAMING-AND-VARIABLES.md.
#
# ⚠ NO SECRETS IN HERE. AWS credentials come from the instance profile; Hugging Face
#   from `hf auth login`. Treat this file as if it were public.
#
# The scripts FAIL LOUDLY on an unset required variable rather than defaulting —
# because a wrong default (especially a mount path) produces a plausible-looking
# number from the wrong filesystem, which is the worst failure mode in this project.

# ── Identity & location (DECIDE NOW) ─────────────────────────────────────────────
export PROJECT_USER="ec2-user"                   # AMI default user. NOT root — see the doc.
export PROJECT_HOME="/home/${PROJECT_USER}"
export REPO_DIR="${PROJECT_HOME}/wsi-cloud"

# ── AWS (DECIDE NOW) ─────────────────────────────────────────────────────────────
export AWS_REGION="ap-northeast-2"               # instance + both filesystems + bucket, all same region
export S3_BUCKET="liad-wsi-cloud"                # the only durable store

# ── Filesystems (DECIDE NOW) ─────────────────────────────────────────────────────
export WEKA_MOUNT="/mnt/weka"                    # Leg A
export LUSTRE_MOUNT="/mnt/lustre"                # Leg B

# ── Local scratch & Python (DECIDE NOW) ──────────────────────────────────────────
export SCRATCH_DIR="/data/local-nvme"            # EPHEMERAL — dies with the instance
export CONDA_ROOT="${SCRATCH_DIR}/miniforge"     # the miniforge INSTALL root
export CONDA_ENVS_DIR="${SCRATCH_DIR}/conda-envs"  # where the ENVS live (not under CONDA_ROOT)
export CONDA_ENV_MAIN="wsi-cucim-2604"           # matches scripts/env-specs/ filenames
export CONDA_ENV_ALT="wsi-cucim"

# ── Tools & GDS config (DECIDE NOW) ──────────────────────────────────────────────
export CLAM_DIR="${PROJECT_HOME}/wsi-tools/CLAM" # tissue detector (Stage 3); cloned during setup
export CUFILE_CONFIG_DIR="${PROJECT_HOME}/cufile-config"
export CUFILE_ENV_PATH_JSON="${CUFILE_CONFIG_DIR}/cufile.json"   # generated per instance (D-10)

# LIBCUFILE_PRELOAD — the PATH of the system libcufile matched to the loaded
# nvidia-fs module. Exporting the PATH is safe and required: the kvikIO sweep
# drivers read it and refuse to start without it. What must NOT be exported
# globally is LD_PRELOAD itself — the drivers set that per cell, on kvikIO cells
# only, because cuCIM segfaults under a preloaded newer libcufile.
# Written by bootstrap-instance.sh from the installed CUDA line; the benchmark
# session verifies it matches the loaded nvidia-fs module (D-10).
export LIBCUFILE_PRELOAD=""                      # e.g. /usr/local/cuda-<ver>/targets/x86_64-linux/lib/libcufile.so.<ver>

# ── Which leg is running (set per leg) ───────────────────────────────────────────
export LEG="weka"                                # weka | lustre

# ── DERIVED — do not set by hand ─────────────────────────────────────────────────
case "${LEG}" in
  weka)   export FS_MOUNT="${WEKA_MOUNT}" ;;
  lustre) export FS_MOUNT="${LUSTRE_MOUNT}" ;;
  *)      echo "env.sh: LEG must be 'weka' or 'lustre', got '${LEG}'" >&2 ;;
esac

# ── WORKLOAD SHAPE — Stage 6.C / 6.D / 7 knobs (LEAVE COMMENTED unless a cell needs otherwise) ──
# The three multi-workload orchestrators read these and fall back to the in-script
# defaults reproduced below (docs/NAMING-AND-VARIABLES.md Table 5). Nothing fails when
# one is unset — that is the risk. These are workload SHAPE, so they are part of what
# was measured: exporting one here applies it to EVERY cell of this leg, and the other
# leg must then export exactly the same value, or the comparison varies two things at
# once. Unset means the driver default, which is identical on both legs by construction.
# `--check` reports any that ARE set, so an override is visible rather than assumed.
#
# Stage 6.C — orchestrate-concurrent-stage6c.sh (its sweep driver overrides NOTHING)
# ⚠ EXTRACT_GPUS: the driver default (0,1,2,3) OVERLAPS the MIL workload's pinned GPU 0,
#   and 6.C runs its workloads CONCURRENTLY — so a cell naming both `extract` and `mil`
#   contends on GPU 0 and reports a concurrency figure for a placement nobody chose.
#   Set it explicitly off GPU 0 for such a cell until the driver default is fixed (D-8),
#   and set EXTRACT_N_GPUS to match the count, or the driver's own guard will refuse.
#export EXTRACT_MODEL="virchow2"                  # uni2-h also tags the cell PENDING-APPROVAL
#export EXTRACT_DATASET_TAG="brca50"              # names the feature OUTPUT dir, not the slides
#export EXTRACT_GPUS="0,1,2,3"                    # ⏳ D-8: SET is right for 4 GPUs, ORDER not yet derived
#export EXTRACT_N_GPUS="4"                        # DDP world size; must match the count in EXTRACT_GPUS
#export MIL_FEATURES_TAG="brca_full"              # <10 .pt files there → silently falls back to brca50
#export INGEST_N="4"                              # fpsync concurrency (scanner-pace background load)
#export INGEST_SRC="${SCRATCH_DIR}/fpsync-source/tcga-brca"   # local NVMe: read side not under test
#export INGEST_DST="${FS_MOUNT}/runs-stage6c-ingest-target"
#export VIEWER_N="4"                              # fio numjobs; bs=4K randread (1.6 pattern)
#export VIEWER_SCRATCH="${FS_MOUNT}/benchmarks/fio-scratch-6c-viewer"
#
# Stage 6.D — pipeline-end-to-end-stage6d.sh (the end-to-end pipeline's extraction phase)
# ORDER: ⏳ D-8 — the SET is valid on a 4-GPU instance, but the NUMA/NIC-aware ORDERING
#   is still to be re-derived on the real instance. The driver's guard catches a wrong
#   SET (an index that does not exist); it cannot catch a wrong order.
# WIDTH: must equal Stage 6.A Tier 2's N. 6.D's output IS per-phase wallclock, and it is
#   composed against 6.A's extraction cell — an extraction phase of any other width
#   yields an end-to-end number that cannot be composed with 6.A's at all.
#export PIPELINE_GPUS="0,1,2,3"                   # CUDA_VISIBLE_DEVICES for Phase 3
#export PIPELINE_N_GPUS="4"                       # world size; must match the count in PIPELINE_GPUS
#
# Stage 7 — orchestrate-clinical-deployment-stage7.sh (its sweep driver sets INFER_* per cell)
#export INFER_MODEL="virchow2"                    # uni2-h also tags the cell PENDING-APPROVAL
#export INFER_BACKEND="kvikio"                    # also selects per-process LD_PRELOAD (cuCIM: unset)
#export INFER_CACHE_POLICY="warm"                 # cold/warm is an ENFORCED axis (PROJECT-THESIS.md §6)
#export INFER_HEATMAP_FORMAT="tiff5x"             # the write side of the cell
#export INFER_MANIFEST="${REPO_DIR}/scripts/manifests/tcga-brca-stage4a-subset.tsv"
#export INFER_COORDS_DIR="${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches"
#export INFER_RAWTIFF_DIR="${FS_MOUNT}/data/tcga-brca-rawtiff"
#export INFER_SVS_DIR="${FS_MOUNT}/data/tcga-brca"
#export INGEST_N="4"
#export INGEST_SRC="${SCRATCH_DIR}/fpsync-source/tcga-brca"
#export INGEST_DST="${FS_MOUNT}/runs-stage7-ingest-target"     # stage-specific: NOT the 6.C target
#export VIEWER_N="4"
#export VIEWER_SCRATCH="${FS_MOUNT}/benchmarks/fio-scratch-7-viewer"   # NOT the 6.C scratch
#export HEATMAP_VIEWER_N="4"
#export HEATMAP_VIEWER_DIR="${FS_MOUNT}/heatmaps/7.5/viewer-scratch"   # not inference's output dir
#
# NOTE: Stage 1.6 (sweep-stage1-mixed.sh) sets its OWN INGEST_N=4 internally and ignores
# the environment — fixed across that sweep on purpose. INGEST_N here changes 6.C and 7 only.

# ── RECORDED AT PROVISIONING — fill in as you go; feeds the environment contract ──
# Leave blank until known. `--check` warns (does not fail) on these, because they are
# captured progressively rather than up front.
export WEKA_BACKEND_TYPE=""
export WEKA_BACKEND_COUNT=""
export WEKA_CAPACITY_TB=""
export WEKA_EC_SCHEME=""                         # REQUIRED to derive the WEKA canary relation (D12)
export WEKA_BACKEND_RAM_TOTAL=""                 # drives Stage 6.B corpus sizing (tracker item 5b)
export WEKA_CLIENT_CORES=""
export WEKA_CLIENT_NICS=""
# The client's reserved-core ID LIST for this leg, from the client's own report
# (e.g. "24-31"). record-run.sh records it into every run's cores_reserved;
# CPU aggregators refuse runs recorded without it (D15). Set "none" on a leg
# whose client reserves no cores. (RECORD_CACHE_STATE is per-CELL, set by the
# sweep drivers — deliberately not an env.sh field.)
export FS_CLIENT_RESERVED_CORES=""
export FSX_TIER=""                               # Leg B
export FSX_CAPACITY_TIB=""
export FSX_METADATA_IOPS=""
export FSX_EFA_ENABLED=""

# ── Cost inputs (PROJECT-THESIS.md §4, STAGES.md D7) ─────────────────────────────
# Fetch from CURRENT vendor pricing THE DAY you set these — never recall a price.
# record-run.sh records all four per cell (null + warned when unset, never guessed);
# both infra-only and all-in cost figures are computed from them.
export INSTANCE_USD_PER_HR=""
export FS_USD_PER_HR=""                          # per leg: the provisioned filesystem's rate
# WEKA leg: the PUBLIC AWS Marketplace rate (citable; a negotiated price is not).
# Lustre leg: 0 — the FSx service rate is software-inclusive (basis recorded per cell).
export SOFTWARE_USD_PER_HR=""
export PRICE_CHECKED_UTC=""                      # e.g. 2026-08-15 — undated is unusable

# ── Per-client throughput ceiling (STAGES.md D7) ─────────────────────────────────
# Fetched DATED, like a price. Lustre leg: the DOCUMENTED per-client throughput cap
# from the AWS FSx performance page D7 cites. WEKA leg: no per-client cap is
# documented, so record the instance's own line rate (g6e.24xlarge network
# bandwidth) with basis "instance-line-rate". Results are then quotable as
# measured-vs-documented-ceiling per leg.
export FS_PER_CLIENT_CEILING_GBPS=""
export FS_PER_CLIENT_CEILING_BASIS=""            # "vendor-documented: <url>" | "instance-line-rate: <url>"
export CEILING_CHECKED_UTC=""
export LUSTRE_STRIPE_LAYOUT=""                   # REQUIRED to derive the Lustre canary relation (D12)
# SCRIPT_COMMIT is deliberately NOT here: env-contract.py collects it itself, from
# `git rev-parse HEAD` at contract-write time. A hand-typed copy would be a second
# source of truth for one held-constant field, and the wrong one — the contract is
# written at the END of a leg, so any commit typed in here goes stale the moment the
# tree advances, while --check would keep printing it back as "ok".

# FS_TRANSPORT — the transport this leg's client is ACTUALLY on, from evidence.
#   weka:   dpdk | udp        lustre:  efa | tcp
# Written from the client's own report, never from the mount options that were
# passed — by bootstrap-instance.sh at boot where it can prove the transport, by the
# Lustre cluster prompt on Leg B otherwise; verified either way. run-leg.sh REFUSES to start a leg when it is
# unset, or when it is the fallback without a written waiver in
# runs/.leg-state/$LEG/transport-waiver (D16). Why a hard gate and not a caveat: UDP
# and TCP mount cleanly and report plausible numbers for a transport this project
# decided not to measure, so "run now, flag later" spends the wallclock first.
export FS_TRANSPORT=""

# ─────────────────────────────────────────────────────────────────────────────────
# --check : validate the configuration before anything runs.
# Sourcing this file does NOT run the check; you must invoke it explicitly.
# ─────────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  fail=0; warn=0; ovr=0
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
  # _recfile: progressively-captured like _rec, but a value that IS set must point at a
  # real file. WHY the asymmetry: blank means "not captured yet", which is fine early —
  # whereas a set-but-nonexistent path is the one state that fails SILENTLY. A stale
  # LIBCUFILE_PRELOAD (e.g. carried over from a previous instance) makes LD_PRELOAD a
  # no-op, so the GPU-direct cells quietly run on the conda env's bundled libcufile and
  # still report perfectly plausible numbers.
  _recfile() {
    if [ -z "${!1:-}" ]; then echo "  pending  $1 — $2"; warn=$((warn+1));
    elif [ -f "${!1}" ]; then printf '  ok       %-24s = %s (exists)\n' "$1" "${!1}";
    else echo "  MISSING  $1 = '${!1}' — set but the file does not exist on THIS instance" >&2; fail=$((fail+1)); fi
  }
  # _genfile: for a path that is ALWAYS set from the template, so blankness carries no
  # information — what matters is whether the file has been generated on this instance
  # yet. Warns rather than fails, because generation legitimately happens after the
  # first --check. (Do NOT use _recfile here: it would fail every fresh bootstrap.)
  _genfile() {
    if [ -f "${!1:-/nonexistent}" ]; then printf '  ok       %-24s = %s (exists)\n' "$1" "${!1}";
    else echo "  pending  $1 = '${!1:-}' — not generated on this instance yet: $2"; warn=$((warn+1)); fi
  }
  # _pybin: the interpreter every sweep driver builds as $CONDA_ENVS_DIR/<env>/bin/python.
  # WHY check the built path and not just the two strings it is built from: CONDA_ENVS_DIR
  # lives under SCRATCH_DIR, which is instance-store and is EMPTY on every rebuild. Both
  # _req's pass (the strings are non-empty) and _dir SCRATCH_DIR passes (the mount point
  # exists) while there is no interpreter at all — so --check reports OK for a config on
  # which every sweep driver dies at exec time, which is the single most likely thing to
  # be missing on a rebuilt instance. Warns rather than fails, for _genfile's reason: the
  # envs are legitimately built after the first --check.
  _pybin() { # _pybin CONDA_ENV_VAR "why it matters"
    local _p="${CONDA_ENVS_DIR:-}/${!1:-}/bin/python"
    if [ -x "$_p" ]; then printf '  ok       %-24s = %s (exists)\n' "$1/bin/python" "$_p";
    else echo "  pending  $1/bin/python = '$_p' — env not built on this instance yet: $2"; warn=$((warn+1)); fi
  }

  echo "── Required ─────────────────────────────────────────────────────────"
  _req PROJECT_USER    "everything else derives from it"
  _req REPO_DIR        "the memory slug derives from this path"
  _req AWS_REGION      "instance, filesystems and bucket must share it"
  _req S3_BUCKET       "the only durable store; teardown loses telemetry without it"
  _req LEG             "determines FS_MOUNT and the S3 prefix"
  _req FS_MOUNT        "a wrong mount silently measures the other filesystem"
  _req CONDA_ENV_MAIN  "matches the env-specs filenames"
  _req CONDA_ENV_ALT   "the two cuCIM-CPU drivers (Stage 4.A, 4.B) refuse to start without it"
  _req CONDA_ENVS_DIR  "every sweep driver builds its interpreter path from it"
  _req SCRATCH_DIR     "the local-scratch source paths derive from it"

  echo "── Paths ────────────────────────────────────────────────────────────"
  _dir REPO_DIR
  _dir FS_MOUNT
  _dir SCRATCH_DIR

  echo "── Recorded at provisioning (blank is OK early) ──────────────────────"
  _pybin   CONDA_ENV_MAIN         "nearly every sweep driver execs it; nothing runs without it"
  _pybin   CONDA_ENV_ALT          "the Stage 4.A and 4.B drivers exec it"
  _recfile LIBCUFILE_PRELOAD      "every kvikIO sweep driver refuses to start without it"
  _genfile CUFILE_ENV_PATH_JSON   "written per instance by bootstrap-instance.sh (compat mode on the WEKA leg; Leg B is D-10)"
  _rec     FS_TRANSPORT           "run-leg.sh refuses to start a leg without it (D16)"
  _rec     WEKA_EC_SCHEME         "needed to derive the WEKA canary relation (D12) — Leg A"
  _rec     LUSTRE_STRIPE_LAYOUT   "needed to derive the Lustre canary relation (D12) — Leg B"
  _rec     WEKA_BACKEND_RAM_TOTAL "drives Stage 6.B corpus sizing"

  # Workload shape: report OVERRIDES, not absences. An unset knob is the driver's own
  # default, identical on both legs by construction; a SET one applies to every cell of
  # this leg and must be set identically on the other, so it is the only state worth
  # surfacing. Informational — --check cannot know the other leg's values.
  echo "── Workload shape — Stage 6.C / 6.D / 7 (unset = the driver's own default) ─"
  for _v in EXTRACT_MODEL EXTRACT_DATASET_TAG EXTRACT_GPUS EXTRACT_N_GPUS MIL_FEATURES_TAG \
            PIPELINE_GPUS PIPELINE_N_GPUS \
            INFER_MODEL INFER_BACKEND INFER_CACHE_POLICY INFER_HEATMAP_FORMAT INFER_MANIFEST \
            INFER_COORDS_DIR INFER_RAWTIFF_DIR INFER_SVS_DIR \
            INGEST_N INGEST_SRC INGEST_DST VIEWER_N VIEWER_SCRATCH \
            HEATMAP_VIEWER_N HEATMAP_VIEWER_DIR; do
    if [ -n "${!_v:-}" ]; then printf '  OVERRIDE %-24s = %s\n' "$_v" "${!_v}"; ovr=$((ovr+1)); fi
  done
  if [ "$ovr" -eq 0 ]; then
    echo "  ok       none set — every Stage 6.C / 6.D / 7 cell runs the in-script defaults"
  else
    echo "  ->       $ovr override(s): the OTHER leg must export the identical values (Table 5)"
  fi

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
