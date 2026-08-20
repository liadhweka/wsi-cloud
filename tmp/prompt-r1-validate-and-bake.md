# R1 — first rebuild: prove the baked spinup, then finish the lustre-side automation

Written: 2026-08-20 · Leg: **lustre** (Leg B) · **No benchmark cells run in this session — not one, and
explicitly NOT canary-bands calibration** (the bands die with the filesystem at the next destroy; they are
R2's). You are a fresh Claude Code session on the rebuilt Leg-B box, inside `tmux new -A -s wsi`.

**Why you exist:** the 2026-08-20 session walked the gated EFA/mount procedure once, ratified every value,
and baked the automation (`scripts/wsi-lustre-phase2.sh`, armed by bootstrap as a per-boot oneshot). This
rebuild is that bake's **from-scratch proof** — the box you are on was built with zero human steps beyond
`terraform apply` and `/login`. Your mission: (1) verify the spinup end to end and fix what diverged,
(2) bake the ratified remainder so the NEXT rebuild needs nothing but a sanity check, (3) tear down clean.
The benchmark starts in R2 (`tmp/prompt-r2-verify-and-benchmark.md`), after the second rebuild.

**Read first, in order:** `CLAUDE.md` in full (eleven rules; "Concurrent legs" — you are Leg B: push only
via `scripts/push-safe.sh`, never write Leg A's files, structural docs are proposals unless a scope below
ratifies the edit) → your memory `cloud-session-open-items-lustre` (**the work list; keep it current**) →
`docs/cloud-setup/LUSTRE-PROVISIONING.md` (the decision register L1–L7 — ratified; do not re-litigate) →
the tracker entries for `wsi-lustre-phase2.sh` and `bootstrap-instance.sh`.

---

## Phase 1 — prove the spinup (read-only first; report, then fix)

Treat any failure as **a baking bug before an environment bug** (memory item B.1). Verify, with evidence:

1. `git pull --ff-only`; note the commit. Bootstrap triage: `grep WSI- /var/log/wsi-bootstrap.log`
   (FATAL = stop and report; WARN = triage). Conf sanity: `LEG=lustre`, FSX facts present,
   `GIT_USER_EMAIL` non-empty (the terraform fix's first proof), `git config user.email` set.
2. **Phase-2 ran unattended and passed its gates:** `journalctl -u wsi-lustre-phase2.service` — the D16
   gate line, the counter-proof line (~1 RPC/MiB on the efa net), no WSI-FATAL. `findmnt /mnt/lustre`;
   fstab entry present; `configure-efa-fsx-lustre-client.service` and `wsi-lustre-tuning.service` enabled;
   tuning values live (`lctl get_param` the L4 set).
3. **Re-evidence the transport yourself** — never inherit it: `sudo lnetctl net show` (efa net(s) up) and
   an efa send_count delta across a small direct-I/O dd. `FS_TRANSPORT=efa` in env.sh.
4. **The interface count** (register L7): enumerate `/sys/class/infiniband`. If the reapply carried the
   second efa-only interface: both devices present, LNet shows two efa NIs, the AWS configurator's CPT
   options landed in `/etc/modprobe.d/modprobe.conf` (`cpu_npartitions`/`cpu_pattern`), and
   `FS_CLIENT_RESERVED_CORES=none` still holds (CPT partitions LNet work; it reserves nothing). Its known
   fail-loud mode and recovery are in memory item A.3. Record the evidenced count; **rewrite register L7**
   to state the count as built (that doc is Leg B's).
5. **Contract:** `env.sh --check`; contract-recovered values present (cost trio, ceiling trio, FSX facts —
   from the committed contract via the bootstrap merge); then
   `python3 scripts/env-contract.py write --leg lustre` (env sourced!) and `verify` against Leg A's
   committed contract — every MUST_MATCH must hold (kernel/AMI/driver: the D-17 tripwires); `aws_az`
   MAY_DIFFER. The verify must come back **fully clean** — the contract shipped 19/19 at the teardown, so
   any unverifiable field here means the bootstrap merge dropped something (a baking bug).
6. Public path via the EIP (you are logged in over it); conda envs (`verify-conda-env.sh` when the
   background build completes — do not block on it); S3 reachable; `backup.sh` exits 0.

**Report #1 to the human, then fix divergences.** Every fix goes into the same files that were wrong
(script, bootstrap, terraform proposal — numbered, never applied by you), with doc cadence. When the
from-scratch proof stands: **delete the proof-pending notes** — `wsi-lustre-phase2.sh` header, its tracker
entry, memory item B.1/C.

## Phase 2 — bake the ratified remainder (this scope is human-ratified for these deliverables)

1. **Contract-at-boot** (lustre-only code path): after phase-2 succeeds, write the leg contract and verify
   against Leg A's committed one automatically; write `runs/.leg-state/lustre/contract-verified` on a clean
   verify, refuse-loud otherwise (`run-leg.sh` already refuses without the marker). Wire it into the
   bootstrap's lustre branch or a phase-2 stage — match the existing refuse-loud shape; `bash -n`; tracker.
2. **The three `stage1_*` fields — DONE at the 2026-08-20 teardown** (D13 re-verified: FSx PERSISTENT-1000
   documents 27.3 GiB RAM/TiB → ~768 GiB server cache; WEKA's 1536 GiB remains the larger side; 2×1536 =
   3072 = the recorded corpus — source: docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html). The
   contract shipped **fully clean (19/19 captured, 0 unverifiable)**. Your only job here: the boot
   contract-verify on the rebuilt box must reproduce that clean result.
3. **NVIDIA driver pin (D-17's open half, cross-cutting — Leg A shares the code path):** propose pinning
   the bootstrap's NVIDIA install to the contract-recorded NVRs (dnf versionlock or explicit versions);
   implement only on the human's explicit ratification; otherwise record the decision and leave the
   contract verify as the tripwire.
4. **D-4, the Lustre recorder half — the big one.** Live-derive the recorder set from this box's real
   streams (`/proc/fs/lustre`, `lctl get_param osc.*.stats llite.*.stats` — never a recalled format):
   `record-run.sh`'s per-`$FS` recorder set + required-stream list for lustre (drop its `--fs lustre`
   refusal), `parse-results.py`'s lustre-side series. The consistency relation derives from the recorded
   stripe layout (register L2/D12, `wsi_agg_helper.py` refuses until derived — derive it now; band
   *calibration* stays R2's). Verify capture on a throwaway **unrecorded infra probe is NOT a cell** —
   use the recording-proof shape (`prove-recording.sh`) and mark never-quote, exactly as Leg A did.
5. Full doc cadence as you go: tracker entries, `LUSTRE-PROVISIONING.md` where provisioning facts changed,
   memory (resolved items deleted — the strongest test: what would a fresh session not need?).

## Phase 3 — close

`./backup.sh` (must exit 0) → commit/push via push-safe (per work block, never mid-edit) → run
`scripts/teardown-prep.sh` gated by `scripts/teardown-preflight.sh` to a GO → final report: spinup verdict
with evidence, what got baked, what R2 inherits, terraform proposals if any — then **stop; the human
destroys and reapplies.** The preflight's handoff check is warn-only; `tmp/prompt-r2-verify-and-benchmark.md`
already satisfies it — if it warns on age, confirm the R2 prompt still describes the intended next state
(update it if your session changed the plan) and proceed.

**Done means:** the from-scratch proof is recorded with its notes deleted, contract verifies fully clean
end-to-end automatically on the next boot, the recorder half exists and is capture-verified, docs/memory
current, teardown GO handed over — and not a single benchmark cell has run.
