#!/usr/bin/env bash
# teardown-preflight.sh — prove everything survives a teardown, BEFORE you tear down.
#
# WHY THIS IS A VERIFIER, NOT A TEARDOWN SCRIPT
#   Terminating the instance and deleting the filesystems is irreversible, so it stays
#   a human action (and is in the `ask` list in .claude/settings.json). The part worth
#   automating is not the destruction — it is PROVING that nothing is lost, because
#   that is the part a person does badly: it is easy to assume a sync worked, and
#   impossible to eyeball whether some run dir exists only on a disk that's about to
#   disappear.
#
#   This script therefore does exactly one thing: it answers GO or NO-GO, and on NO-GO
#   it says precisely what would be lost.
#
# WHAT IT CHECKS
#   1. Nothing is mid-flight (a running sweep would be interrupted mid-cell)
#   2. Live memories are mirrored into the repo
#   3. Git working tree is clean AND pushed  (Claude commits and pushes; this only verifies)
#   4. The environment contract exists for this leg and is complete
#   5. Every local run dir's raw telemetry is present in S3  <-- the one that matters
#   6. Nothing else lives only on ephemeral storage
#   7. The rebuild inputs (AMI, instance type, region/AZ) are recorded in the contract
#
# USAGE
#   source env.sh
#   scripts/teardown-preflight.sh              # full check, prints GO / NO-GO
#   scripts/teardown-preflight.sh --quick      # skip the per-run S3 comparison
#
# EXIT CODES
#   0 = GO (verified safe to tear down)   1 = NO-GO (something would be lost)
# Non-zero is deliberate: never wire this into an automated teardown that ignores it.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

FAIL=0; WARN=0
ok()   { printf '  \033[32mOK\033[0m       %s\n' "$*"; }
bad()  { printf '  \033[31mNO-GO\033[0m    %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m     %s\n' "$*"; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }

echo "teardown-preflight: leg=${LEG:-unset}  mount=${FS_MOUNT:-unset}  bucket=${S3_BUCKET:-unset}"

# ── 0. Config sanity ─────────────────────────────────────────────────────────────
hdr "Configuration"
[ -n "${LEG:-}" ]       && ok "LEG=$LEG"             || bad "LEG unset — cannot tell which leg's artifacts to check"
[ -n "${S3_BUCKET:-}" ] && ok "S3_BUCKET=$S3_BUCKET" || bad "S3_BUCKET unset — cannot verify anything survived"
if [ -n "${S3_BUCKET:-}" ]; then
  if aws s3 ls "s3://$S3_BUCKET/" >/dev/null 2>&1; then ok "bucket reachable"
  else bad "cannot reach s3://$S3_BUCKET/ — nothing can be verified as backed up"; fi
fi

# ── 1. Nothing mid-flight ────────────────────────────────────────────────────────
hdr "Nothing in flight"
running=$(pgrep -fa 'record-run\.sh|sweep-stage|run-leg\.sh|run-stage6a|pipeline-end-to-end|fio --client|fio --server' 2>/dev/null | grep -v teardown-preflight || true)
if [ -n "$running" ]; then
  bad "benchmark processes still running — tearing down now corrupts the in-flight cell:"
  echo "$running" | sed 's/^/             /'
else ok "no benchmark processes running"; fi

# ── 2. Memories mirrored ─────────────────────────────────────────────────────────
hdr "Memories"
SLUG="$(printf '%s' "$REPO" | sed 's#^/#-#; s#/#-#g')"
LIVE="$HOME/.claude/projects/$SLUG/memory"
MIRROR="$REPO/claude-memory-mirror"
if [ -d "$LIVE" ]; then
  if diff -rq "$LIVE" "$MIRROR" >/dev/null 2>&1; then
    ok "live memories match the mirror ($(find "$MIRROR" -type f | wc -l) files)"
  else
    bad "live memories DIFFER from the mirror — run ./backup.sh (memories are the only continuity)"
    diff -rq "$LIVE" "$MIRROR" 2>/dev/null | head -5 | sed 's/^/             /'
  fi
else
  warn "no live memory dir at $LIVE (expected if memories were authored straight into the mirror)"
fi

# ── 2b. The next-session handoff prompt — REMINDER, NOT A GATE ───────────────────
# Memory + repo are the DESIGNED continuity (CLAUDE.md: a fresh session loads
# memory plus the rules and continues) — a handoff prompt is an accelerator on
# top, written into TEMP/ at the human's discretion when a teardown lands
# mid-work. So its absence warns; it never blocks a GO. (Same-instance session
# turnover hands off inline and never runs this machinery at all.)
hdr "Next-session handoff prompt (TEMP/, optional)"
newest=""; newest_epoch=0
for f in "$REPO"/TEMP/*.md; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "README.md" ] && continue
  grep -qi "${LEG:-}" "$f" 2>/dev/null || continue
  written=$(grep -m1 -oE 'Written:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
  [ -n "$written" ] || continue
  w_epoch=$(date -u -d "$written" +%s 2>/dev/null || echo 0)
  if [ "$w_epoch" -gt "$newest_epoch" ]; then newest="$f"; newest_epoch=$w_epoch; newest_written=$written; fi
done
if [ -z "$newest" ]; then
  warn "no TEMP/ handoff naming leg '${LEG:-unset}' — the next session starts from memory + repo alone (the designed continuity); if this teardown lands mid-work, consider writing one from prompts/handoff-skeleton.md"
else
  age=$(( ( $(date -u +%s) - newest_epoch ) / 86400 ))
  if [ "$age" -le 2 ]; then ok "handoff $(basename "$newest") written $newest_written (${age}d old)"
  else warn "newest TEMP/ handoff for this leg is ${age}d old ($(basename "$newest"), Written: $newest_written) — confirm it still describes the intended next-session state"; fi
fi

# ── 3. Git clean and pushed ──────────────────────────────────────────────────────
hdr "Git"
dirty=$(git -C "$REPO" status --porcelain | wc -l)
[ "$dirty" -eq 0 ] && ok "working tree clean" || bad "$dirty uncommitted file(s) — the human must commit + push before teardown"
if git -C "$REPO" rev-parse @{u} >/dev/null 2>&1; then
  ahead=$(git -C "$REPO" rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
  [ "$ahead" = "0" ] && ok "pushed (no unpushed commits)" || bad "$ahead commit(s) not pushed — git is the migration vehicle"
else
  bad "no upstream configured — nothing has been pushed anywhere"
fi

# ── 4. Environment contract ──────────────────────────────────────────────────────
hdr "Environment contract (what makes the next leg comparable)"
CONTRACT="$REPO/runs/env-contract-leg-${LEG:-unknown}.json"
if [ -f "$CONTRACT" ]; then
  # Import MUST_MATCH from env-contract.py rather than restating it here. The list
  # WAS duplicated in this script and had already drifted (9 fields against the
  # contract's 17), so this check could report "complete" for a contract that
  # env-contract.py's own `write` had rejected. One source of truth, by import.
  # (importlib, not `import env_contract`: the filename is hyphenated.)
  nulls=$(python3 -c "
import json, importlib.util
spec = importlib.util.spec_from_file_location('ec', '$REPO/scripts/env-contract.py')
ec = importlib.util.module_from_spec(spec); spec.loader.exec_module(ec)
c = json.load(open('$CONTRACT'))
print(sum(1 for k in ec.MUST_MATCH if not c.get(k)))" 2>/dev/null || echo "?")
  if [ "$nulls" = "0" ]; then ok "contract written and complete: $(basename "$CONTRACT")"
  elif [ "$nulls" = "?" ]; then bad "could not evaluate $(basename "$CONTRACT") against env-contract.py's MUST_MATCH — treat as incomplete"
  else bad "contract has $nulls unrecorded held-constant field(s) — Leg B cannot verify comparability"; fi
  if aws s3 ls "s3://$S3_BUCKET/env-contracts/$(basename "$CONTRACT")" >/dev/null 2>&1; then
    ok "contract present in S3"
  else bad "contract NOT in S3 — it dies with the instance"; fi
  # A recorded env.sh-vs-metadata conflict means the contract is right (it kept the
  # metadata value) but env.sh described a machine this is not. env.sh is generated
  # by the bootstrap from the instance's own evidence, so a conflict indicates a
  # hand edit or a stale value worth explaining before trusting the leg.
  # Self-clearing: fix env.sh, re-run `env-contract.py write`, and the field empties.
  # -1 = the field is absent, which is NOT the same as "no conflicts": a contract
  # written before this check existed simply never looked, so claiming agreement would
  # be asserting something unverified.
  conflicts=$(python3 -c "
import json
c = json.load(open('$CONTRACT'))
print(len(c['source_conflicts']) if 'source_conflicts' in c else -1)" 2>/dev/null || echo "?")
  if [ "$conflicts" = "0" ]; then ok "env.sh agrees with instance metadata"
  elif [ "$conflicts" = "-1" ]; then warn "contract predates the env.sh-vs-metadata check — agreement is unverified, not confirmed"
  elif [ "$conflicts" = "?" ]; then warn "could not parse $(basename "$CONTRACT") to read source_conflicts"
  else
    bad "$conflicts field(s) where env.sh disagreed with instance metadata — fix env.sh and re-run env-contract.py write"
    python3 -c "
import json
for d in json.load(open('$CONTRACT'))['source_conflicts']:
    print('             %s: env.sh=%r instance=%r' % (d['field'], d['env_sh'], d['instance_metadata']))" 2>/dev/null
  fi
else
  bad "no contract for leg '${LEG:-unknown}' — run: scripts/env-contract.py write --leg ${LEG:-<leg>}"
fi

# ── 5. THE important one: is every local run dir's telemetry in S3? ──────────────
hdr "Telemetry durability (raw/ is gitignored — S3 is its ONLY home)"
if [ "$QUICK" -eq 1 ]; then
  warn "--quick: skipped the per-run S3 comparison (this is the check that matters — re-run without --quick)"
elif [ -z "${S3_BUCKET:-}" ]; then
  bad "cannot check without S3_BUCKET"
else
  s3list=$(mktemp); aws s3 ls "s3://$S3_BUCKET/runs/${LEG:-}/" --recursive 2>/dev/null | awk '{print $4}' > "$s3list"
  missing=0; checked=0
  shopt -s nullglob
  for d in "$REPO"/runs/*-"${LEG:-}"-s*/; do
    [ -d "$d/raw" ] || continue
    checked=$((checked+1))
    local_n=$(find "$d/raw" -type f | wc -l)
    [ "$local_n" -eq 0 ] && continue
    s3_n=$(grep -c "runs/${LEG}/$(basename "$d")/raw/" "$s3list" || true)
    if [ "$s3_n" -lt "$local_n" ]; then
      bad "$(basename "$d"): $local_n local file(s), only $s3_n in S3 — WOULD BE LOST"
      missing=$((missing+1))
    fi
  done
  shopt -u nullglob
  rm -f "$s3list"
  if [ "$checked" -eq 0 ]; then warn "no run dirs for leg '${LEG:-}' — nothing recorded yet?"
  elif [ "$missing" -eq 0 ]; then ok "all $checked run dir(s) fully present in S3"; fi
fi

# ── 6. Anything else living only on ephemeral storage ────────────────────────────
hdr "Other ephemeral-only artifacts"
# No default for SCRATCH_DIR: guessing it would check the wrong directory and
# report "nothing stranded" about a path that is not the scratch disk.
if [ -z "${SCRATCH_DIR:-}" ]; then
  warn "SCRATCH_DIR unset — cannot check whether anything is stranded on ephemeral scratch"
else
  for p in "$SCRATCH_DIR/staging" "$SCRATCH_DIR/runs"; do
    if [ -d "$p" ] && [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
      warn "$p is non-empty ($(du -sh "$p" 2>/dev/null | cut -f1)) — confirm nothing there is needed"
    fi
  done
fi
if [ -d "$REPO/runs/sweep-logs" ] && [ -n "$(ls -A "$REPO/runs/sweep-logs" 2>/dev/null)" ]; then
  if aws s3 ls "s3://$S3_BUCKET/runs/${LEG:-}/sweep-logs/" >/dev/null 2>&1; then ok "sweep logs in S3"
  else bad "sweep logs exist locally but not in S3 — they are the only record of unattended runs"; fi
fi

# ── 7. Rebuild inputs ────────────────────────────────────────────────────────────
hdr "Rebuild inputs (needed to stand the next leg up identically)"
# These live in the CONTRACT (collected from instance metadata at write time) and
# in Terraform — env.sh no longer carries them. The contract is the recorded proof;
# Terraform is the mechanism that reproduces them.
if [ -f "$CONTRACT" ]; then
  for f in ami_id instance_type aws_region aws_az; do
    v=$(python3 -c "import json;print(json.load(open('$CONTRACT')).get('$f') or '')" 2>/dev/null)
    if [ -n "$v" ]; then ok "$f=$v (from the contract)"
    else bad "$f not recorded in the contract — the rebuild cannot be shown identical"; fi
  done
else
  bad "no contract file — rebuild inputs unverifiable (check 4 already failed)"
fi

# ── Verdict ──────────────────────────────────────────────────────────────────────
printf '\n\033[1m─────────────────────────────────────────\033[0m\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31mNO-GO\033[0m — %d blocking issue(s), %d warning(s).\n' "$FAIL" "$WARN"
  echo "Do NOT tear down. Every blocking issue above means something is lost permanently."
  exit 1
fi
printf '\033[32mGO\033[0m — verified safe to tear down (%d warning(s) to eyeball).\n' "$WARN"
echo "Next: follow docs/cloud-setup/TEARDOWN-AND-REBUILD.md § Teardown from step 6."
exit 0
