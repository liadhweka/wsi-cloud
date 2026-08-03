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

    Facts are collected automatically where possible (uname, nvidia-smi, git,
    versions, mount info) and read from the environment otherwise — see
    cloud-setup/NAMING-AND-VARIABLES.md Table 2. Anything unavailable is recorded as
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
    "instance_type", "aws_region", "aws_az", "ami_id",
    "kernel", "driver_version", "cuda_version",
    "nvidia_fs_version", "libcufile_version",
    "gpu_model", "gpu_count", "cpu_count", "mem_total_kb",
    "script_commit", "dataset_manifest_sha",
    "conda_env_main", "python_version",
]
# EXPECTED to differ: filesystem-specific, i.e. the variable under test.
MAY_DIFFER = [
    "leg", "fs_mount", "fs_type", "client_hostname", "libcufile_path",
    "weka_backend_type", "weka_backend_count", "weka_capacity_tb",
    "weka_ec_scheme", "weka_backend_ram_total",
    "weka_client_cores", "weka_client_nics",
    "fsx_tier", "fsx_capacity_tib", "fsx_metadata_iops",
    "fsx_efa_enabled", "lustre_stripe_layout",
    "written_utc", "instance_id",
]


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


def _libcufile_version(path):
    """Extract a 3-component version from a libcufile filename, or None."""
    if not path:
        return None
    m = re.search(r"libcufile\.so\.(\d+\.\d+\.\d+)$", path)
    return m.group(1) if m else None


def collect(leg, repo_root):
    """Gather every contract field. Unavailable facts are null, never guessed."""
    fs_mount = env("FS_MOUNT")
    c = {
        # ---- held constant ----
        "instance_type":   env("INSTANCE_TYPE") or sh("curl -s --max-time 2 "
                           "http://169.254.169.254/latest/meta-data/instance-type"),
        "aws_region":      env("AWS_REGION"),
        "aws_az":          env("AWS_AZ") or sh("curl -s --max-time 2 "
                           "http://169.254.169.254/latest/meta-data/placement/availability-zone"),
        "ami_id":          env("AMI_ID") or sh("curl -s --max-time 2 "
                           "http://169.254.169.254/latest/meta-data/ami-id"),
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
        "dataset_manifest_sha": sh(f"cat {repo_root}/runs/manifests/*.tsv 2>/dev/null | sha256sum "
                                   "| cut -c1-16"),
        "conda_env_main":  env("CONDA_ENV_MAIN"),
        "python_version":  platform.python_version(),
        # ---- expected to differ ----
        "leg":             leg,
        "fs_mount":        fs_mount,
        "fs_type":         sh(f"findmnt -no FSTYPE {fs_mount}") if fs_mount else None,
        "client_hostname": env("CLIENT_HOSTNAME") or platform.node(),
        "weka_backend_type":      env("WEKA_BACKEND_TYPE"),
        "weka_backend_count":     env("WEKA_BACKEND_COUNT"),
        "weka_capacity_tb":       env("WEKA_CAPACITY_TB"),
        "weka_ec_scheme":         env("WEKA_EC_SCHEME"),
        "weka_backend_ram_total": env("WEKA_BACKEND_RAM_TOTAL"),
        "weka_client_cores":      env("WEKA_CLIENT_CORES"),
        "weka_client_nics":       env("WEKA_CLIENT_NICS"),
        "fsx_tier":               env("FSX_TIER"),
        "fsx_capacity_tib":       env("FSX_CAPACITY_TIB"),
        "fsx_metadata_iops":      env("FSX_METADATA_IOPS"),
        "fsx_efa_enabled":        env("FSX_EFA_ENABLED"),
        "lustre_stripe_layout":   (sh(f"lfs getstripe -d {fs_mount} 2>/dev/null | tr '\\n' ' '")
                                   or env("LUSTRE_STRIPE_LAYOUT")) if fs_mount else None,
        "instance_id":     env("INSTANCE_ID") or sh("curl -s --max-time 2 "
                           "http://169.254.169.254/latest/meta-data/instance-id"),
        "written_utc":     datetime.now(timezone.utc).isoformat(),
    }
    return c


def cmd_write(a, repo_root):
    c = collect(a.leg, repo_root)
    out = Path(a.output or f"{repo_root}/runs/env-contract-leg-{a.leg}.json")
    out.write_text(json.dumps(c, indent=2, sort_keys=True) + "\n")

    missing = [k for k in MUST_MATCH if c.get(k) in (None, "")]
    print(f"env-contract: wrote {out}")
    print(f"env-contract: {len(MUST_MATCH) - len(missing)}/{len(MUST_MATCH)} held-constant fields captured")
    if missing:
        # Loud, because an unrecorded fact can never be shown to have matched later.
        print("\nenv-contract: WARNING — these held-constant fields are UNRECORDED:", file=sys.stderr)
        for k in missing:
            print(f"  - {k}", file=sys.stderr)
        print("env-contract: verify() will treat each as a VIOLATION on the other leg,\n"
              "              because a null cannot be proven equal. Fill them in\n"
              "              (see cloud-setup/NAMING-AND-VARIABLES.md Table 2) and re-run.",
              file=sys.stderr)
        return 1
    print("env-contract: complete. Upload with sync-to-s3.sh and keep it for Leg B.")
    return 0


def cmd_verify(a, repo_root):
    ref = json.loads(Path(a.against).read_text())
    leg = a.leg or env("LEG") or "unknown"
    cur = collect(leg, repo_root)

    violations, expected, unrecorded = [], [], []
    for k in MUST_MATCH:
        r, v = ref.get(k), cur.get(k)
        if r in (None, "") or v in (None, ""):
            unrecorded.append((k, r, v))
        elif str(r) != str(v):
            violations.append((k, r, v))
    for k in MAY_DIFFER:
        if str(ref.get(k)) != str(cur.get(k)):
            expected.append((k, ref.get(k), cur.get(k)))

    print(f"env-contract verify: this leg = {leg!r}  vs  reference leg = {ref.get('leg')!r}\n")
    print(f"── Held constant: {len(MUST_MATCH) - len(violations) - len(unrecorded)} match, "
          f"{len(violations)} VIOLATION, {len(unrecorded)} unverifiable ──")
    for k, r, v in violations:
        print(f"  VIOLATION  {k}\n               reference: {r}\n               this leg : {v}")
    for k, r, v in unrecorded:
        print(f"  UNVERIFIABLE {k} (reference={r!r}, this leg={v!r})")

    print(f"\n── Differs as expected (the variable under test): {len(expected)} ──")
    for k, r, v in expected:
        print(f"  differs    {k}: {r} -> {v}")

    if violations or unrecorded:
        print("\nenv-contract verify: FAILED.", file=sys.stderr)
        print("  The two legs are NOT demonstrably comparable. Any head-to-head number\n"
              "  produced from them would be attributing an environment difference to the\n"
              "  filesystem. Resolve every VIOLATION, and record every UNVERIFIABLE field,\n"
              "  before running a measured cell.", file=sys.stderr)
        return 1
    print("\nenv-contract verify: PASSED — every held-constant field matches. Cleared for Leg B.")
    return 0


def cmd_show(a, repo_root):
    c = json.loads(Path(a.file).read_text())
    for title, keys in (("Held constant", MUST_MATCH), ("Expected to differ", MAY_DIFFER)):
        print(f"── {title} ──")
        for k in keys:
            print(f"  {k:26s} {c.get(k)}")
    return 0


def main():
    repo_root = str(Path(__file__).resolve().parent.parent.parent)
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write");  w.add_argument("--leg", required=True, choices=["weka", "lustre"]); w.add_argument("-o", "--output")
    v = sub.add_parser("verify"); v.add_argument("--against", required=True); v.add_argument("--leg", choices=["weka", "lustre"])
    s = sub.add_parser("show");   s.add_argument("--file", required=True)
    a = ap.parse_args()
    return {"write": cmd_write, "verify": cmd_verify, "show": cmd_show}[a.cmd](a, repo_root)


if __name__ == "__main__":
    sys.exit(main())
