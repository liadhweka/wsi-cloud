#!/usr/bin/env python3
"""env-contract.py — write and verify the environment contract (deferred item D-12).

WHY THIS EXISTS
    The two legs of this comparison run at DIFFERENT TIMES on a REBUILT instance.
    Anything that drifts between them — AMI, driver, dataset bytes, script commit —
    is indistinguishable from a filesystem difference once the numbers are in. The
    contract makes comparability a mechanical check instead of a judgement call:

        end of Leg A :  env-contract.py write  --leg weka
                          -> runs/env-contract-leg-weka.json (also uploaded to
                             s3://$S3_BUCKET/env-contracts/ by sync-to-s3.sh --mode full)
        start of Leg B: env-contract.py verify --against <that file>

    A mismatch on a held-constant field is FAIL-LOUD. That is the whole point.

THE CENTRAL DISTINCTION
    Some fields MUST match across legs; others are EXPECTED to differ (they are the
    thing under test). A verifier that ignored the difference would either fail on
    everything or catch nothing. So the field sets are explicit below, and the report
    prints "differs (expected)" separately from "DIFFERS (VIOLATION)".

USAGE
    env-contract.py write  --leg {weka|lustre} [-o PATH]
    env-contract.py verify --against PATH [--leg {weka|lustre}]
    env-contract.py show   --file PATH
    env-contract.py env    --file PATH [--for-leg {weka|lustre}]
                                         # emit env.sh export lines (rebuild recovery);
                                         # --for-leg matching the contract's leg emits
                                         # the leg-specific fields LIVE (same-leg rebuild)

    Facts are collected automatically where possible (uname, nvidia-smi, git,
    versions, mount info) and read from the environment otherwise — see
    docs/NAMING-AND-VARIABLES.md Table 2. Anything unavailable is recorded as
    null rather than guessed, and verify treats null-vs-value as a violation on a
    held-constant field (an unrecorded fact cannot be shown to have matched).
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Field sets — the load-bearing decision in this script ────────────────────────
# MUST match across legs: if any of these differ, the comparison is invalid.
MUST_MATCH = [
    "instance_type", "aws_region", "ami_id",
    "kernel", "driver_version", "cuda_version",
    "nvidia_fs_version", "libcufile_version",
    "gpu_model", "gpu_count", "cpu_count", "mem_total_kb",
    "script_commit", "dataset_manifest_sha",
    "conda_env_main", "python_version",
    # The Stage-1.0 read-corpus definition is identical-by-design across legs
    # (D13: one corpus definition serves both, or the held-constant contract
    # breaks on the substage most sensitive to cache). Carrying it here both
    # enforces that mechanically and lets the emit rebuild env.sh with it.
    "stage1_seq_corpus_gib", "stage1_randr_region_gib", "stage1_randr_regions",
]
# EXPECTED to differ: filesystem-specific, i.e. the variable under test — plus the
# per-leg inputs that legitimately drift (prices, dated ceilings, reserved cores):
# they are recorded for recovery and reporting, and must never fail a verify.
MAY_DIFFER = [
    # aws_az reclassified 2026-08-19 (concurrent legs, capacity-forced): each leg is
    # intra-AZ by construction (client beside its filesystem), the AZ shapes no
    # measured quantity the way kernel/driver do, and ambient variance is exactly
    # what D18's per-leg canary bands measure. Region stays MUST_MATCH: pricing,
    # service availability and the D7-cited ceilings are regional. Rationale: D6.
    "aws_az",
    "leg", "fs_mount", "fs_type", "fs_transport", "client_hostname", "libcufile_path",
    "weka_backend_type", "weka_backend_count", "weka_backend_ami", "weka_capacity_tb",
    "weka_ec_scheme", "weka_backend_ram_total",
    "weka_client_cores", "weka_client_nics",
    "fsx_tier", "fsx_capacity_tib", "fsx_metadata_iops",
    "fsx_efa_enabled", "lustre_stripe_layout",
    "fs_client_reserved_cores",
    "instance_usd_per_hr", "fs_usd_per_hr", "software_usd_per_hr", "price_checked_utc",
    "per_client_ceiling_gbps", "per_client_ceiling_basis", "ceiling_checked_utc",
    "written_utc", "instance_id",
]
# Neither compared nor expected-to-differ: present ONLY so the contract can rebuild
# env.sh after a teardown. WHY it needs its own list: `s3_bucket` is what you must
# already know to have FETCHED this contract, so comparing it proves nothing — but
# leaving it out meant the recovery artifact could not reconstruct the file it is the
# recovery source for. Both `verify` and `write`'s completeness check iterate the two
# lists above, so a field here is correctly invisible to them.
RECOVERY_ONLY = ["s3_bucket"]


def sh(cmd, default=None):
    """Run a command, return stripped stdout, or `default` if it fails."""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        out = r.stdout.strip()
        return out if (r.returncode == 0 and out) else default
    except Exception:
        return default


def env(name):
    v = os.environ.get(name, "").strip()
    return v or None


def _env_python_version():
    """The benchmark environment's Python, never this tool's interpreter.

    platform.python_version() reports whichever interpreter happens to RUN this
    script — miniforge base at a teardown, system python at boot — so the field
    described the launcher, not the held-constant environment, and the identical
    environment then 'failed' verify whenever a different launcher ran the check.
    Collect from the env's own binary; null when it is not built yet, never guessed.
    """
    d, e = env("CONDA_ENVS_DIR"), env("CONDA_ENV_MAIN")
    if not (d and e):
        return None
    return sh(f'"{d}/{e}/bin/python" -c "import platform; print(platform.python_version())"')


def _libcufile_version(path):
    """Extract a 3-component version from a libcufile filename, or None."""
    if not path:
        return None
    m = re.search(r"libcufile\.so\.(\d+\.\d+\.\d+)$", path)
    return m.group(1) if m else None


_IMDS = "http://169.254.169.254"


def imds(path):
    """Read one EC2 instance-metadata value, IMDSv2 first.

    WHY the token: newer instances require IMDSv2, and AWS's docs are explicit that
    "if IMDSv2 is required, IMDSv1 does not work" — a plain GET returns nothing. This
    used to be a bare `curl`, which meant every metadata-derived contract field came
    back null on such an instance and `write` failed for reasons that looked unrelated.
    `curl -f` matters too: without it curl prints the HTTP error INTO the output, so a
    failure arrives looking like data.
    Source: docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html
    """
    token = sh(f'curl -sfX PUT "{_IMDS}/latest/api/token" '
               f'-H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --max-time 2')
    if token:
        v = sh(f'curl -sf -H "X-aws-ec2-metadata-token: {token}" '
               f'--max-time 2 "{_IMDS}/latest/meta-data/{path}"')
        if v:
            return v
    # IMDSv1 fallback for instances where it is still permitted.
    return sh(f'curl -sf --max-time 2 "{_IMDS}/latest/meta-data/{path}"')


def _reconcile(conflicts, field, env_name, imds_path):
    """Prefer instance metadata over env.sh, and RECORD any disagreement.

    WHY metadata wins: it is what the instance actually IS. The env side is a
    cross-check for any of these fields env.sh still carries (today: AWS_REGION);
    for the rest the env side is empty by design — the slimmed env.sh does not
    duplicate instance facts — and this reduces to a pure metadata read.
    A disagreement, where one occurs, is itself
    a finding (a region/AZ mismatch means the instance is not where it was meant to be),
    so it is recorded rather than silently resolved.
    """
    e, m = env(env_name), imds(imds_path)
    if e and m and e.strip() != m.strip():
        conflicts.append({"field": field, "env_sh": e, "instance_metadata": m})
        return m
    return m or e


def collect(leg, repo_root):
    """Gather every contract field. Unavailable facts are null, never guessed."""
    fs_mount = env("FS_MOUNT")
    conflicts = []
    c = {
        # ---- held constant ----
        "instance_type":   _reconcile(conflicts, "instance_type", "INSTANCE_TYPE", "instance-type"),
        "aws_region":      _reconcile(conflicts, "aws_region", "AWS_REGION", "placement/region"),
        "aws_az":          _reconcile(conflicts, "aws_az", "AWS_AZ", "placement/availability-zone"),
        "ami_id":          _reconcile(conflicts, "ami_id", "AMI_ID", "ami-id"),
        "kernel":          platform.release(),
        "driver_version":  sh("nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1"),
        "cuda_version":    sh("nvidia-smi | grep -oE 'CUDA Version: [0-9.]+' | grep -oE '[0-9.]+'"),
        "nvidia_fs_version": sh("cat /sys/module/nvidia_fs/version"),
        # Prefer the libcufile the kvikIO cells actually preload; fall back to the
        # newest versioned file under the CUDA install.
        # WHY not `ls … | head -1`: that sorts the SONAME symlink `libcufile.so.0`
        # first, which has no 3-component version, so the grep found nothing and
        # this held-constant field came out null — making `write` exit non-zero and
        # `verify` report it UNVERIFIABLE (= FAILED) on every single run.
        "libcufile_version": (
            _libcufile_version(env("LIBCUFILE_PRELOAD"))
            or sh("ls -1 /usr/local/cuda*/targets/*/lib/libcufile.so.* 2>/dev/null "
                  "| grep -E 'libcufile\\.so\\.[0-9]+\\.[0-9]+\\.[0-9]+$' "
                  "| sort -V | tail -1 | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+$'")),
        "libcufile_path": env("LIBCUFILE_PRELOAD"),
        "gpu_model":       sh("nvidia-smi --query-gpu=name --format=csv,noheader | head -1"),
        "gpu_count":       sh("nvidia-smi --query-gpu=name --format=csv,noheader | wc -l"),
        "cpu_count":       str(os.cpu_count()),
        "mem_total_kb":    sh("awk '/MemTotal/{print $2}' /proc/meminfo"),
        "script_commit":   sh(f"git -C {repo_root} rev-parse HEAD"),
        "dataset_manifest_sha": sh(f"cat {repo_root}/scripts/manifests/*.tsv 2>/dev/null | sha256sum "
                                   "| cut -c1-16"),
        "conda_env_main":  env("CONDA_ENV_MAIN"),
        "python_version":  _env_python_version(),
        "stage1_seq_corpus_gib":   env("STAGE1_SEQ_CORPUS_GIB"),
        "stage1_randr_region_gib": env("STAGE1_RANDR_REGION_GIB"),
        "stage1_randr_regions":    env("STAGE1_RANDR_REGIONS"),
        # ---- expected to differ ----
        "leg":             leg,
        "fs_mount":        fs_mount,
        "fs_type":         sh(f"findmnt -no FSTYPE {fs_mount}") if fs_mount else None,
        # The transport actually in use (dpdk|udp for WEKA, efa|tcp for Lustre). D16
        # makes it a precondition of the measurement, so it belongs in the contract:
        # a leg measured on a fallback transport is not comparable, and the artifact
        # that proves comparability has to say which transport it was.
        "fs_transport":    env("FS_TRANSPORT"),
        "client_hostname": env("CLIENT_HOSTNAME") or platform.node(),
        "weka_backend_type":      env("WEKA_BACKEND_TYPE"),
        "weka_backend_count":     env("WEKA_BACKEND_COUNT"),
        # Backend AMI is recorded, never pinned (ratified): backends are MAY_DIFFER
        # and absent on Leg B, but the leg's provenance must say what they ran.
        "weka_backend_ami":       env("WEKA_BACKEND_AMI"),
        "weka_capacity_tb":       env("WEKA_CAPACITY_TB"),
        "weka_ec_scheme":         env("WEKA_EC_SCHEME"),
        "weka_backend_ram_total": env("WEKA_BACKEND_RAM_TOTAL"),
        "weka_client_cores":      env("WEKA_CLIENT_CORES"),
        "weka_client_nics":       env("WEKA_CLIENT_NICS"),
        "fsx_tier":               env("FSX_TIER"),
        "fsx_capacity_tib":       env("FSX_CAPACITY_TIB"),
        "fsx_metadata_iops":      env("FSX_METADATA_IOPS"),
        "fsx_efa_enabled":        env("FSX_EFA_ENABLED"),
        # Per-client throughput ceiling (D7): the vendor-DOCUMENTED per-client cap
        # where one is documented (FSx publishes per-client throughput); the
        # instance's own line rate otherwise (WEKA publishes no per-client cap, so
        # the physical NIC is the honest ceiling). Recorded dated, like every
        # price, so the writeup can put measured-vs-documented-ceiling side by
        # side per leg and the "single client can't drive an aggregate maximum"
        # objection becomes a table instead of an argument.
        "per_client_ceiling_gbps":  env("FS_PER_CLIENT_CEILING_GBPS"),
        "per_client_ceiling_basis": env("FS_PER_CLIENT_CEILING_BASIS"),
        "ceiling_checked_utc":      env("CEILING_CHECKED_UTC"),
        "lustre_stripe_layout":   (sh(f"lfs getstripe -d {fs_mount} 2>/dev/null | tr '\\n' ' '")
                                   or env("LUSTRE_STRIPE_LAYOUT")) if fs_mount else None,
        # Per-leg measured/priced inputs. Recorded so the recovery emit can rebuild
        # env.sh with them (the 2026-08 rebuild lost every value that lived only in
        # the gitignored env.sh); MAY_DIFFER because prices and reserved cores
        # legitimately differ per leg and must never fail a verify.
        "fs_client_reserved_cores": env("FS_CLIENT_RESERVED_CORES"),
        "instance_usd_per_hr":      env("INSTANCE_USD_PER_HR"),
        "fs_usd_per_hr":            env("FS_USD_PER_HR"),
        "software_usd_per_hr":      env("SOFTWARE_USD_PER_HR"),
        "price_checked_utc":        env("PRICE_CHECKED_UTC"),
        "instance_id":     _reconcile(conflicts, "instance_id", "INSTANCE_ID", "instance-id"),
        "written_utc":     datetime.now(timezone.utc).isoformat(),
        # ---- recovery only: not compared, see RECOVERY_ONLY ----
        "s3_bucket":       env("S3_BUCKET"),
        # Empty when env.sh and the instance agree, which is the normal case.
        "source_conflicts": conflicts,
    }
    return c


def cmd_write(a, repo_root):
    c = collect(a.leg, repo_root)
    out = Path(a.output or f"{repo_root}/runs/env-contract-leg-{a.leg}.json")
    out.write_text(json.dumps(c, indent=2, sort_keys=True) + "\n")

    missing = [k for k in MUST_MATCH if c.get(k) in (None, "")]
    print(f"env-contract: wrote {out}")
    print(f"env-contract: {len(MUST_MATCH) - len(missing)}/{len(MUST_MATCH)} held-constant fields captured")

    # Loud: env.sh disagreeing with the instance means one of them is describing a
    # machine this is not. The metadata value was recorded; the human decides whether
    # env.sh is simply wrong (fix it) or the instance is not where it should be (worse).
    if c.get("source_conflicts"):
        print("\nenv-contract: WARNING — env.sh disagrees with this instance's own metadata:",
              file=sys.stderr)
        for d in c["source_conflicts"]:
            print(f"  - {d['field']}: env.sh={d['env_sh']!r}  instance={d['instance_metadata']!r}"
                  "  → recorded the instance value", file=sys.stderr)
        print("env-contract: fix env.sh to match, or explain the difference —\n"
              "              a region/AZ conflict means the instance is not where it was\n"
              "              meant to be, which contaminates the comparison.", file=sys.stderr)
    if missing:
        # Loud, because an unrecorded fact can never be shown to have matched later.
        print("\nenv-contract: WARNING — these held-constant fields are UNRECORDED:", file=sys.stderr)
        for k in missing:
            print(f"  - {k}", file=sys.stderr)
        print("env-contract: verify() will treat each as a VIOLATION on the other leg,\n"
              "              because a null cannot be proven equal. Fill them in\n"
              "              (see docs/NAMING-AND-VARIABLES.md Table 2) and re-run.",
              file=sys.stderr)
        return 1
    print("env-contract: complete. Upload with sync-to-s3.sh and keep it for Leg B.")
    return 0


def cmd_verify(a, repo_root):
    ref = json.loads(Path(a.against).read_text())
    leg = a.leg or env("LEG") or "unknown"
    cur = collect(leg, repo_root)

    violations, expected, unrecorded, advanced = [], [], [], []
    for k in MUST_MATCH:
        r, v = ref.get(k), cur.get(k)
        if r in (None, "") or v in (None, ""):
            unrecorded.append((k, r, v))
        elif k == "script_commit" and str(r) != str(v):
            # The teardown writes the contract BEFORE its own final commit+push, so
            # HEAD is legitimately ahead of the recorded commit on every rebuild —
            # equality here failed structurally, for a reason nobody chose. The real
            # invariant is that the tree only moved FORWARD: the recorded commit must
            # be an ancestor of HEAD. Divergence (a revert, a different branch, a
            # rewritten history) stays a VIOLATION. The forward diff is auditable in
            # git; measured cells additionally record their own commit per run.
            ok_hex = all(re.fullmatch(r"[0-9a-f]{7,40}", str(x)) for x in (r, v))
            anc = ok_hex and subprocess.run(
                f"git -C {repo_root} merge-base --is-ancestor {r} {v}",
                shell=True, capture_output=True).returncode == 0
            (advanced if anc else violations).append((k, r, v))
        elif str(r) != str(v):
            violations.append((k, r, v))
    for k in MAY_DIFFER:
        if str(ref.get(k)) != str(cur.get(k)):
            expected.append((k, ref.get(k), cur.get(k)))

    print(f"env-contract verify: this leg = {leg!r}  vs  reference leg = {ref.get('leg')!r}\n")
    print(f"── Held constant: {len(MUST_MATCH) - len(violations) - len(unrecorded) - len(advanced)} match, "
          f"{len(violations)} VIOLATION, {len(unrecorded)} unverifiable"
          + (f", {len(advanced)} advanced (ancestor-ok)" if advanced else "") + " ──")
    for k, r, v in violations:
        print(f"  VIOLATION  {k}\n               reference: {r}\n               this leg : {v}")
    for k, r, v in unrecorded:
        print(f"  UNVERIFIABLE {k} (reference={r!r}, this leg={v!r})")
    for k, r, v in advanced:
        print(f"  advanced   {k}: {str(r)[:12]} -> {str(v)[:12]} (reference is an ancestor of HEAD —\n"
              f"             the tree only moved forward; audit the diff with `git diff {str(r)[:12]}..{str(v)[:12]}`)")

    print(f"\n── Differs as expected (the variable under test): {len(expected)} ──")
    for k, r, v in expected:
        print(f"  differs    {k}: {r} -> {v}")

    # Not a violation by itself — the metadata value is what got compared above — but it
    # means env.sh describes a machine this is not, and env.sh is what the next rebuild
    # is reconstructed from.
    for label, d in (("reference", ref), ("this leg", cur)):
        for x in d.get("source_conflicts") or []:
            print(f"\n  NOTE ({label}) {x['field']}: env.sh said {x['env_sh']!r}, "
                  f"instance said {x['instance_metadata']!r} — the instance value was used.")

    # D-21 phase 1: the verified marker. run-leg.sh refuses a leg without a marker
    # matching the current contract (phase 2, ratified 2026-08-16) — "verify ran and
    # passed" must be a checkable fact, not an instruction followed hours earlier.
    # The marker records the contract's sha256 so a re-written contract invalidates
    # a stale PASS mechanically, without trusting mtimes across git checkouts.
    import hashlib
    marker = Path(repo_root) / "runs" / ".leg-state" / leg / "contract-verified"
    if violations or unrecorded:
        marker.unlink(missing_ok=True)
        print("\nenv-contract verify: FAILED.", file=sys.stderr)
        print("  The two legs are NOT demonstrably comparable. Any head-to-head number\n"
              "  produced from them would be attributing an environment difference to the\n"
              "  filesystem. Resolve every VIOLATION, and record every UNVERIFIABLE field,\n"
              "  before running a measured cell.", file=sys.stderr)
        return 1
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({
        "verified_utc": datetime.now(timezone.utc).isoformat(),
        "against": str(Path(a.against).resolve()),
        "against_sha256": hashlib.sha256(Path(a.against).read_bytes()).hexdigest(),
        "advanced_script_commit": ({"from": advanced[0][1], "to": advanced[0][2]}
                                   if advanced else None),
    }, indent=2) + "\n")
    print(f"\nenv-contract verify: PASSED — every held-constant field matches. Marker: {marker}")
    return 0


# Contract field -> env.sh variable. Only fields that belong in env.sh appear here;
# the rest of the contract is measured state, not configuration.
# Only variables that exist in the slimmed env.example.sh appear here: the
# bootstrap's rebuild merge py_sets every live line this mode emits, so a key
# absent from the template would be re-INSERTED into env.sh with no consumer.
# The other held-constant facts (AMI, instance type, AZ ...) live in the contract
# itself and in Terraform, not in env.sh.
ENV_MAP_HELD = {
    "aws_region": "AWS_REGION", "conda_env_main": "CONDA_ENV_MAIN",
    "stage1_seq_corpus_gib": "STAGE1_SEQ_CORPUS_GIB",
    "stage1_randr_region_gib": "STAGE1_RANDR_REGION_GIB",
    "stage1_randr_regions": "STAGE1_RANDR_REGIONS",
}
ENV_MAP_LEG = {
    "leg": "LEG",
    "libcufile_path": "LIBCUFILE_PRELOAD", "fs_transport": "FS_TRANSPORT",
    "weka_backend_type": "WEKA_BACKEND_TYPE", "weka_backend_count": "WEKA_BACKEND_COUNT",
    "weka_backend_ami": "WEKA_BACKEND_AMI",
    "weka_capacity_tb": "WEKA_CAPACITY_TB", "weka_ec_scheme": "WEKA_EC_SCHEME",
    "weka_backend_ram_total": "WEKA_BACKEND_RAM_TOTAL",
    "weka_client_cores": "WEKA_CLIENT_CORES", "weka_client_nics": "WEKA_CLIENT_NICS",
    "fsx_tier": "FSX_TIER", "fsx_capacity_tib": "FSX_CAPACITY_TIB",
    "fsx_metadata_iops": "FSX_METADATA_IOPS", "fsx_efa_enabled": "FSX_EFA_ENABLED",
    "lustre_stripe_layout": "LUSTRE_STRIPE_LAYOUT",
    "fs_client_reserved_cores": "FS_CLIENT_RESERVED_CORES",
    # Prices ride here so a SAME-leg rebuild recovers them; on a cross-leg rebuild
    # they emit commented, which is correct — the next leg re-fetches its own,
    # dated the day they are set, per the pricing rule.
    "instance_usd_per_hr": "INSTANCE_USD_PER_HR", "fs_usd_per_hr": "FS_USD_PER_HR",
    "software_usd_per_hr": "SOFTWARE_USD_PER_HR", "price_checked_utc": "PRICE_CHECKED_UTC",
    "per_client_ceiling_gbps": "FS_PER_CLIENT_CEILING_GBPS",
    "per_client_ceiling_basis": "FS_PER_CLIENT_CEILING_BASIS",
    "ceiling_checked_utc": "CEILING_CHECKED_UTC",
}


def cmd_env(a, repo_root):
    """Emit env.sh-shaped export lines from a contract.

    WHY: env.sh is gitignored, so it is LOST on every rebuild. On a rebuild the
    bootstrap consumes this output programmatically (its merge py_sets every live
    line over the freshly generated env.sh, so the contract's values win where both
    exist); pasting it by hand is the fallback when provisioning outside the
    bootstrap. Emitting rather than retyping matters because a transcription typo
    in a held-constant field defeats the check the contract exists to pass.

    Held-constant values are emitted live; leg-specific ones are emitted COMMENTED,
    because on a cross-leg rebuild the previous leg's filesystem facts must not be
    carried over — they are the variable under test. On a SAME-leg rebuild pass
    --for-leg: when it matches the contract's leg, the leg-specific fields emit
    LIVE too — the 2026-08 mid-leg rebuild lost exactly those fields because the
    bootstrap's merge consumes only live lines.
    """
    c = json.loads(Path(a.file).read_text())
    src_leg = c.get("leg") or "unknown"
    same_leg = bool(getattr(a, "for_leg", None)) and a.for_leg == src_leg
    print(f"# Generated from {a.file} (leg {src_leg!r}) by env-contract.py env")
    print("# Paste these OVER the placeholders in the top half of env.sh.")
    print("# Do NOT '>>' append: env.sh's --check block sits at the bottom and runs")
    print("# BEFORE anything after it, so appended values would source fine and still")
    print("# be reported MISSING by --check.")
    print()
    print("# ── Held constant across legs: these MUST match or the comparison is invalid ──")
    for k, var in list(ENV_MAP_HELD.items()) + [("s3_bucket", "S3_BUCKET")]:
        v = c.get(k)
        if v in (None, ""):
            print(f'# {var}=""    # NOT RECORDED in this contract — fill in by hand')
        else:
            print(f'export {var}="{v}"')
    print()
    if same_leg:
        print(f"# ── Specific to leg {src_leg!r} — emitted LIVE (--for-leg matches) ──")
        print("# Same-leg rebuild: these describe THIS leg and carry over. Re-verify any")
        print("# value the rebuild could have changed (cluster facts) against the live system.")
    else:
        print(f"# ── Specific to leg {src_leg!r} — COMMENTED deliberately ──")
        print("# On a SAME-leg rebuild pass --for-leg (or uncomment what still applies).")
        print("# On a CROSS-leg rebuild these belong to the other filesystem: leave them")
        print("# commented and let this leg's setup (bootstrap or cluster prompt) write the new ones.")
    for k, var in ENV_MAP_LEG.items():
        v = c.get(k)
        if v not in (None, ""):
            print(('export' if same_leg else '# export') + f' {var}="{v}"')
    print()
    print("# ── NOT in the contract; supply these yourself ──")
    print("#   everything else has a working default in env.example.sh")
    if c.get("source_conflicts"):
        print()
        print("# ⚠ This contract recorded a disagreement between the previous env.sh and")
        print("#   that instance's metadata. The values above are the metadata ones:")
        for d in c["source_conflicts"]:
            print(f"#     {d['field']}: env.sh={d['env_sh']!r} instance={d['instance_metadata']!r}")
    return 0


def cmd_show(a, repo_root):
    c = json.loads(Path(a.file).read_text())
    for title, keys in (("Held constant", MUST_MATCH), ("Expected to differ", MAY_DIFFER)):
        print(f"── {title} ──")
        for k in keys:
            print(f"  {k:26s} {c.get(k)}")
    return 0


def main():
    repo_root = str(Path(__file__).resolve().parent.parent)
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write");  w.add_argument("--leg", required=True, choices=["weka", "lustre"]); w.add_argument("-o", "--output")
    v = sub.add_parser("verify"); v.add_argument("--against", required=True); v.add_argument("--leg", choices=["weka", "lustre"])
    s = sub.add_parser("show");   s.add_argument("--file", required=True)
    e = sub.add_parser("env");    e.add_argument("--file", required=True); e.add_argument("--for-leg", dest="for_leg", choices=["weka", "lustre"])
    a = ap.parse_args()
    return {"write": cmd_write, "verify": cmd_verify, "show": cmd_show,
            "env": cmd_env}[a.cmd](a, repo_root)


if __name__ == "__main__":
    sys.exit(main())
