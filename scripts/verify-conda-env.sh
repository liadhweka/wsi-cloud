#!/usr/bin/env bash
# verify-conda-env.sh — fail-loud verification of both conda environments (D-22).
#
# The bootstrap's own smoke test is import-level and WARN-only (the boot
# continues); this is the verification it lacks: real imports, CUDA
# availability, visible-GPU count against nvidia-smi, and — when a reference
# environment contract exists — the python version against it. Non-zero on any
# drift. VERIFICATION ONLY: environment creation stays in the bootstrap.
#
# Run on every rebuild, before any cell. ~30 s (torch import dominates).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
: "${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
: "${CONDA_ENV_ALT:?CONDA_ENV_ALT is unset -- source env.sh}"

FAIL=0
say() { echo "verify-conda-env: $*"; }
bad() { echo "verify-conda-env: FAIL — $*" >&2; FAIL=1; }

GPUS_SMI=$(nvidia-smi -L 2>/dev/null | wc -l)
[ "$GPUS_SMI" -ge 1 ] || bad "nvidia-smi lists no GPUs"

check_env() { # check_env <env-name> <space-separated import list> <needs_cuda 0|1>
  local env="$1" mods="$2" needs_cuda="$3"
  local py="$CONDA_ENVS_DIR/$env/bin/python"
  if [ ! -x "$py" ]; then bad "$env: interpreter missing at $py"; return; fi
  local out
  out=$("$py" - "$mods" "$needs_cuda" "$GPUS_SMI" <<'EOF'
import importlib, sys
mods, needs_cuda, gpus_smi = sys.argv[1].split(), sys.argv[2] == "1", int(sys.argv[3])
rc = 0
for m in mods:
    try:
        mod = importlib.import_module(m)
        print(f"ok {m} {getattr(mod, '__version__', '?')}")
    except Exception as e:
        print(f"FAIL {m}: {e}")
        rc = 1
if needs_cuda:
    import torch
    if not torch.cuda.is_available():
        print("FAIL torch.cuda.is_available() is False"); rc = 1
    elif torch.cuda.device_count() != gpus_smi:
        print(f"FAIL visible GPUs {torch.cuda.device_count()} != nvidia-smi {gpus_smi}"); rc = 1
    else:
        print(f"ok cuda available, {gpus_smi} GPUs visible")
import platform
print(f"python_version {platform.python_version()}")
sys.exit(rc)
EOF
  ) || bad "$env: import/CUDA check failed"
  echo "$out" | sed "s/^/  [$env] /"

  # Python version vs the reference contract, when one exists (Leg B's rebuild
  # verifies against Leg A's; on a first Leg-A build there is nothing to match
  # yet and the check reports itself skipped rather than silently passing).
  local contract="$REPO/runs/env-contract-leg-weka.json"
  local pyver; pyver=$(echo "$out" | awk '/^python_version /{print $2}')
  if [ -f "$contract" ]; then
    local want
    want=$(python3 -c "import json,sys; print(json.load(open('$contract')).get('python_version') or '')" 2>/dev/null)
    if [ -n "$want" ] && [ "$env" = "$CONDA_ENV_MAIN" ]; then
      [ "$pyver" = "$want" ] || bad "$env: python $pyver != contract's $want (MUST_MATCH field)"
    fi
  else
    say "  [$env] no reference contract yet — python-version cross-check skipped (first Leg-A build)"
  fi
}

check_env "$CONDA_ENV_MAIN" "torch cupy cucim kvikio openslide tifffile h5py timm transformers" 1
check_env "$CONDA_ENV_ALT"  "torch cucim openslide tifffile h5py numpy" 0

if [ "$FAIL" -ne 0 ]; then
  echo "verify-conda-env: FAILED — do not run cells on this environment." >&2
  exit 1
fi
say "both environments verified."
