#!/usr/bin/env bash
# Stage 7 Clinical Inference Deployment sweep driver.
#
# Targets:
#   smoke              — minimal validation (1-slide cuCIM Virchow2 + 90s mini orchestrator)
#   tier1_baselines    — 6 cells: cuCIM/kvikIO × cold/warm × Virchow2 + GigaPath warm + UNI2-h warm
#   tier2_concurrent   — 4 cells: N ∈ {1, 4, 16, 64} × Virchow2 kvikIO warm-cache, bs scaling per Q8
#   tier3_heatmaps     — 3 cells: tiff5x / tiff_l0 / png × Virchow2 kvikIO warm, 50 slides
#   tier4_streaming    — 2 cells: 7.4.a streaming-loop (10 slides @ 60s) + 7.4.b read-after-write (20 slides)
#   tier5_mixed        — 1 cell:  30-min all-four-up (inference N=4 + ingest + heatmap-viewer + viewer)
#   tier5_endurance    — 1 cell:  4-hr all-four-up endurance
#   tier6_cam16        — 1 cell:  CAM16 inference N=4 Virchow2 kvikIO warm-cache
#   all                — runs all of the above in order
#
# Total: ~18 cells, ~10-12 hr execution wallclock (endurance dominates).
#
# Per-cell:
#   - RECORD_RUN_DIR pre-computed to avoid the caller/wrapper timestamp race (see record-run.sh).
#   - LD_PRELOAD scoped per-cell (kvikIO cells set the system libcufile; cuCIM unset).
#   - UNI2-h cells auto-tagged [PENDING-APPROVAL-DO-NOT-EXTERNALIZE] (per uni2h memory).
#   - Per-process inference batch size scales DOWN as N rises (VRAM headroom;
#     see inference-per-slide-stage7.py).
set -uo pipefail

# Repo root derived from this script's own location (scripts -> runs -> root),
# so the tree is wherever the script physically lives. No hardcoded path.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${FS_MOUNT:?FS_MOUNT is unset -- source env.sh. Refusing to guess a mount: a wrong mount silently measures the OTHER filesystem}"
: "${LEG:?LEG is unset -- source env.sh. The run-dir name must carry the filesystem: sync-to-s3.sh and teardown-preflight.sh glob runs/*-$LEG-s*/, so a dir without it is never backed up}"
: "${CONDA_ENVS_DIR:?CONDA_ENVS_DIR is unset -- source env.sh}"
CONDA_ENV="${CONDA_ENVS_DIR}/${CONDA_ENV_MAIN:?CONDA_ENV_MAIN is unset -- source env.sh}"
PY="$CONDA_ENV/bin/python"
# The SYSTEM libcufile, matched to the installed kernel nvidia-fs module. Read from
# the environment (docs/NAMING-AND-VARIABLES.md Table 1) — never hardcoded:
# the conda env bundles an older copy, the right path is instance-specific, and a
# path pointing nowhere makes LD_PRELOAD a silent no-op, so the kvikIO cells would
# quietly run on the WRONG libcufile and still report numbers. ⏳ D-10: locate it on
# the real instance and export LIBCUFILE_PRELOAD before running any kvikIO sweep.
: "${LIBCUFILE_PRELOAD:?LIBCUFILE_PRELOAD is unset -- locate the system libcufile matched to the loaded nvidia-fs module and export it (see docs/NAMING-AND-VARIABLES.md Table 1)}"
LIBCUFILE_SYSTEM="$LIBCUFILE_PRELOAD"
[ -f "$LIBCUFILE_SYSTEM" ] || { echo "LIBCUFILE_PRELOAD points at a nonexistent file: $LIBCUFILE_SYSTEM" >&2; exit 1; }
CUFILE_JSON=${CUFILE_ENV_PATH_JSON}

RECORD="$REPO/scripts/record-run.sh"
INFER_WORKER="$REPO/scripts/inference-per-slide-stage7.py"
ORCH="$REPO/scripts/orchestrate-clinical-deployment-stage7.sh"
STREAMING="$REPO/scripts/streaming-loop-stage7.sh"
RAW_HELPER="$REPO/scripts/read-after-write-stage7.py"

[ -x "$RECORD" ] || { echo "missing $RECORD" >&2; exit 1; }
FAILED_CELLS=0
[ -f "$INFER_WORKER" ] || { echo "missing $INFER_WORKER" >&2; exit 1; }
[ -x "$ORCH" ] || { echo "missing $ORCH" >&2; exit 1; }
[ -x "$STREAMING" ] || { echo "missing $STREAMING" >&2; exit 1; }
[ -f "$RAW_HELPER" ] || { echo "missing $RAW_HELPER" >&2; exit 1; }

# Common paths
BRCA_SVS=${FS_MOUNT}/data/tcga-brca
BRCA_RAWTIFF=${FS_MOUNT}/data/tcga-brca-rawtiff
BRCA_COORDS=${FS_MOUNT}/tissue-detection/3.0/tcga-brca/n64/patches
CAM16_SVS=${FS_MOUNT}/data/camelyon16/images
CAM16_RAWTIFF=${FS_MOUNT}/data/camelyon16-rawtiff
CAM16_COORDS=${FS_MOUNT}/tissue-detection/3.0/camelyon16/n64/patches
BRCA_SUBSET_MANIFEST="$REPO/scripts/manifests/tcga-brca-stage4a-subset.tsv"
CAM16_SUBSET_MANIFEST="$REPO/scripts/manifests/camelyon16-stage4a-subset.tsv"

# Per-Q8 bs schedule (N → bs map): exposed here so it's audit-visible
bs_for_n() {
  case "$1" in
    1|4) echo 256 ;;
    8)   echo 128 ;;
    16)  echo 64  ;;
    32)  echo 32  ;;
    64)  echo 16  ;;
    *)   echo 256 ;;
  esac
}

# ---------- Per-cell direct invocation of inference-per-slide-stage7.py -----
# Used by tier1_baselines, tier3_heatmaps, tier6_cam16. Single-process cells.
run_single_inference_cell() {
  local cell_name="$1"; local backend="$2"; local model="$3"
  local cache="$4"; local heatmap_format="$5"; local max_slides="$6"
  local rawtiff_dir="$7"; local svs_dir="$8"; local coords_dir="$9"
  local manifest="${10}"
  local gpu="${11:-2}"

  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s7-${cell_name}"

  # UNI2-h conditional-use tag (per uni2h-conditional-use-status memory)
  local approval_tag=""
  [ "$model" = "uni2-h" ] && approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "

  # Per-cell LD_PRELOAD scoping (per `docs/RUNBOOK.md` (mixed-backend sweeps))
  local preload=""
  [ "$backend" = "kvikio" ] && preload="$LIBCUFILE_SYSTEM"

  local stage_tag="7.1"
  case "$cell_name" in
    *7.3*) stage_tag="7.3" ;;
    *7.6*|*cam16*) stage_tag="7.6" ;;
  esac

  # Heatmaps go under the documented per-substage tree, $FS_MOUNT/heatmaps/7.x/<cell>/
  # (docs/FILESYSTEM-MAP.md). A flat stage-wide dir puts this stage's write output
  # outside the 7.x glob that capacity accounting and post-presentation cleanup walk —
  # on the filesystem under test, in the one stage whose write volume is a measured
  # result — and breaks the by-substage grouping 7.3's three format cells are read by.
  local heatmap_dir="${FS_MOUNT}/heatmaps/${stage_tag}/${cell_name}"
  mkdir -p "$heatmap_dir"

  # D-30/D13: the cell's declared regime IS its cache argument (the roadmap
  # names each 7.1/7.3/7.6 cell's regime). Cold cells' achieved evidence is the
  # worker's per-slide discard counters in inference-summary.json (the
  # reconciler consumes them); warm cells' evidence is the construction wording
  # in the note. kvikIO cells declare RECORD_KVIKIO_CELL=1, so a missing
  # path_accounting split fails loud as INCOMPLETE (D8/D21) — the Stage-7
  # worker's accounting wiring is tracked in D-6 and must land before this
  # stage runs.
  local regime_note
  if [ "$cache" = "cold" ]; then
    regime_note="Regime: cold — per-slide client page-cache discard, achieved counters recorded in inference-summary.json; the server-side cache is not clearable and its residual is stated, not hidden (D13)."
  else
    regime_note="Regime: warm — cache carries over across slides by design; re-inference on already-read slides is production steady-state."
  fi
  local kvik_env=()
  [ "$backend" = "kvikio" ] && kvik_env=("RECORD_KVIKIO_CELL=1")

  local note="${approval_tag}Stage 7 single-process inference cell: backend=${backend} model=${model} cache=${cache} heatmap=${heatmap_format} N_slides=${max_slides}. WHY: per-slide inference latency baseline with per-phase decomposition (tissue/extract/MIL/heatmap-write). The clinical-deployment-decisive 'T seconds per inference' customer number. ${regime_note}"

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name (stage $stage_tag)"
  echo "  backend=$backend model=$model cache=$cache heatmap=$heatmap_format gpu=$gpu N_slides=$max_slides"
  echo "=========================================="

  env "${kvik_env[@]}" \
  CUDA_VISIBLE_DEVICES="$gpu" \
  LD_PRELOAD="$preload" \
  CUFILE_ENV_PATH_JSON="$CUFILE_JSON" \
  CONDA_PREFIX="$CONDA_ENV" \
  OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 \
  RECORD_CACHE_STATE="$cache" \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage "$stage_tag" \
    --note "$note" \
    -- "$PY" "$INFER_WORKER" \
       --backend "$backend" --model "$model" \
       --rawtiff-dir "$rawtiff_dir" --svs-dir "$svs_dir" \
       --coords-dir "$coords_dir" --manifest "$manifest" \
       --heatmap-dir "$heatmap_dir" \
       --heatmap-format "$heatmap_format" \
       --inference-batch-size 256 \
       --cache-policy "$cache" \
       --max-slides "$max_slides" \
       --per-slide-csv "$run_dir/per-slide-inference-latencies.csv" \
       --per-slide-heatmap-csv "$run_dir/per-slide-heatmap-writes.csv" \
       --summary-json "$run_dir/inference-summary.json"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

# ---------- Per-cell orchestrator invocation (tier2_concurrent, tier5_mixed) -
run_orchestrator_cell() {
  local cell_name="$1"; local workloads="$2"; local n_concurrent="$3"
  local ramp="$4"; local runtime="$5"
  local extra_env="${6:-}"
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s7-${cell_name}"
  local bs; bs=$(bs_for_n "$n_concurrent")

  local stage_tag="7.2"
  [[ "$cell_name" == *mixed* || "$cell_name" == *endurance* ]] && stage_tag="7.5"
  [[ "$cell_name" == *cam16* || "$cell_name" == *7.6* ]] && stage_tag="7.6"

  local approval_tag=""
  [ "${INFER_MODEL:-virchow2}" = "uni2-h" ] && approval_tag="[PENDING-APPROVAL-DO-NOT-EXTERNALIZE] "

  # D-30/D13 declaration: inference-only orchestrator cells run the stated
  # INFER_CACHE_POLICY (roadmap: 7.2/7.6 warm — production-realistic; a clinical
  # deployment processes many slides per shift). Mixed multi-workload cells
  # (7.5) declare na-mixed-concurrent-clinical (ratified 2026-08-21): the
  # cold/warm axis deliberately does not apply — the measured quantity is
  # per-workload QoS retention against same-filesystem solo baselines.
  local declare_env=()
  local regime_note=""
  if [ "$workloads" = "inference" ]; then
    local policy=warm
    [[ "$extra_env" == *INFER_CACHE_POLICY=cold* ]] && policy=cold
    declare_env+=("RECORD_CACHE_STATE=$policy")
    regime_note=" Regime: ${policy} — cache carries over across slides and processes by design; production steady-state (a clinical deployment processes many slides per shift)."
  else
    declare_env+=("RECORD_CACHE_STATE=na-mixed-concurrent-clinical")
    # The two viewer workloads are 4K fio streams: the aggregate read ratio is
    # a heterogeneous mix, judged at the small-bs-widened envelope (D12).
    declare_env+=("RECORD_BS_HINT=heterogeneous-small-block")
    regime_note=" Regime: na — the cold/warm axis deliberately does not apply to a mixed multi-workload cell (ratified 2026-08-21): the measured quantity is per-workload QoS retention against same-filesystem solo baselines."
  fi
  # The inference workload's backend defaults to kvikio (Table 5); only an
  # explicit cucim override makes this a non-kvikIO cell.
  [[ "$extra_env" != *INFER_BACKEND=cucim* ]] && declare_env+=("RECORD_KVIKIO_CELL=1")

  local note="${approval_tag}Stage 7 orchestrator cell: workloads={$workloads} N_concurrent=${n_concurrent} per-process bs=${bs} (per Q8 schedule) ramp=${ramp}s runtime=${runtime}s. WHY: per-slide latency under concurrent inference load — the clinical-deployment SLA number ('p99 latency stays under X sec at deployment concurrency Y'). bs scales DOWN with N to keep per-GPU memory bounded.${regime_note}"

  echo ""
  echo "=========================================="
  echo "[$now_utc] cell: $cell_name (stage $stage_tag)"
  echo "  workloads=$workloads N=$n_concurrent per-process bs=$bs ramp=${ramp}s runtime=${runtime}s"
  echo "=========================================="

  # Per-cell env (caller may override INFER_* via $extra_env)
  env $extra_env \
  "${declare_env[@]}" \
  RECORD_RUN_DIR="$run_dir" \
  INFERENCE_BATCH_SIZE="$bs" \
  N_CONCURRENT="$n_concurrent" \
  "$RECORD" \
    --run-name "$cell_name" \
    --stage "$stage_tag" \
    --note "$note" \
    -- "$ORCH" --workloads "$workloads" --n-concurrent "$n_concurrent" \
       --inference-batch-size "$bs" --ramp "$ramp" --runtime "$runtime" \
       --run-dir "$run_dir"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

# ---------- Tier definitions ------------------------------------------------

smoke() {
  echo "=== Stage 7 smoke ==="
  # Small single-slide inference smoke (cuCIM Virchow2 warm — fastest path)
  run_single_inference_cell "smoke-cucim-virchow2-warm" \
    cucim_batched_cpu virchow2 warm tiff5x 1 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  # Mini orchestrator smoke, 240s steady: a Virchow2 ViT-H/14 forward at bs=256
  # over a ~37K-tile slide can take minutes single-process, so a short steady
  # window can't finish even slide 0. With 240s steady + 30s ramp, each process
  # completes a few slides. At single-process scale this cell tends to be
  # COMPUTE-bound, not storage-bound — never read the smoke as a storage number.
  run_orchestrator_cell "smoke-concurrent-N2" "inference" 2 30 240 ""
}

tier1_baselines() {
  echo "=== Tier 7.1 — Per-slide inference latency baselines (6 cells, 50 slides each) ==="
  # 6 cells, 50 slides each: with a smaller sample (e.g. 20), p95/p99 estimates
  # are driven by 1-2 outlier slides. Plus smoother heatmap rendering (bilinear-interp)
  # gives production-realistic per-slide hm_write_ms.
  run_single_inference_cell "7.1.a-cucim-virchow2-cold"  cucim_batched_cpu virchow2 cold tiff5x 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.1.b-cucim-virchow2-warm"  cucim_batched_cpu virchow2 warm tiff5x 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.1.c-kvikio-virchow2-cold" kvikio            virchow2 cold tiff5x 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.1.d-kvikio-virchow2-warm" kvikio            virchow2 warm tiff5x 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.1.e-cucim-gigapath-warm"  cucim_batched_cpu gigapath warm tiff5x 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.1.f-cucim-uni2-h-warm"    cucim_batched_cpu uni2-h   warm tiff5x 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
}

tier2_concurrent() {
  echo "=== Tier 7.2 — Latency under concurrent inference load (4 cells) ==="
  # Virchow2 kvikIO warm-cache; per-process bs scales DOWN with N per Q8.
  # Each cell: 5 min ramp + 25 min steady = 30 min.
  # Tier 7.2 uses the FULL BRCA manifest
  # (the uniform 40×-base cohort, STAGES.md D5; not the 1131-slide
  # pre-mpp-filter set, which is a different file in the same dir) rather than
  # the 50-slide subset used by 7.1. Reason: at
  # N=64 with the 50-slide subset, modulo partition leaves 14 of 64 procs
  # with 0 slides (idle), making N=64 throughput numbers asymmetric vs
  # N=1/4/16. Full manifest gives every proc at N=64 ~17 unique slides;
  # also tightens p50/p95/p99 distribution by enlarging the sample.
  local common_env="INFER_BACKEND=kvikio INFER_MODEL=virchow2 INFER_CACHE_POLICY=warm INFER_HEATMAP_FORMAT=tiff5x \
INFER_MANIFEST=$REPO/scripts/manifests/tcga-brca-full40x-stage4a-format.tsv"
  run_orchestrator_cell "7.2-concurrent-virchow2-kvikio-warm-N1"  "inference" 1  300 1500 "$common_env"
  run_orchestrator_cell "7.2-concurrent-virchow2-kvikio-warm-N4"  "inference" 4  300 1500 "$common_env"
  run_orchestrator_cell "7.2-concurrent-virchow2-kvikio-warm-N16" "inference" 16 300 1500 "$common_env"
  run_orchestrator_cell "7.2-concurrent-virchow2-kvikio-warm-N64" "inference" 64 300 1500 "$common_env"
}

tier3_heatmaps() {
  echo "=== Tier 7.3 — Heatmap output write characterization (3 cells) ==="
  run_single_inference_cell "7.3.a-heatmap-tiff5x-virchow2-brca50"  kvikio virchow2 warm tiff5x  50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.3.b-heatmap-tiff-l0-virchow2-brca50" kvikio virchow2 warm tiff_l0 50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
  run_single_inference_cell "7.3.c-heatmap-png-virchow2-brca50"     kvikio virchow2 warm png     50 \
    "$BRCA_RAWTIFF" "$BRCA_SVS" "$BRCA_COORDS" "$BRCA_SUBSET_MANIFEST" 2
}

tier4_streaming() {
  echo "=== Tier 7.4 — Streaming clinical loop + read-after-write (2 cells) ==="
  local now_utc; now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  local run_dir="$REPO/runs/${now_utc}-${LEG}-s7-7.4.a-streaming-loop-virchow2-kvikio"
  echo "[$now_utc] cell: 7.4.a-streaming-loop-virchow2-kvikio"
  RECORD_CACHE_STATE=warm \
  RECORD_KVIKIO_CELL=1 \
  RECORD_RUN_DIR="$run_dir" \
  "$RECORD" --run-name "7.4.a-streaming-loop-virchow2-kvikio" --stage 7.4 \
    --note "Stage 7.4.a streaming clinical loop — 10 slides emitted @ 60s cadence (~1500 slides/day rate). Captures end-to-end 'scanner-to-pathologist-visibility' wallclock per slide + cross-slide queueing if inference falls behind scanner. WHY: the end-to-end workflow bookend — it also captures cross-slide queueing if inference falls behind the emitter, which a per-slide latency number alone hides. Regime: warm — cache carries over across the loop by design; production steady-state (roadmap 7.4.a)." \
    -- "$STREAMING" --run-dir "$run_dir" --n-slides 10 --cadence-s 60 \
       --model virchow2 --backend kvikio --manifest "$BRCA_SUBSET_MANIFEST"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi

  now_utc=$(date -u +%Y-%m-%d-%H%M%S)
  run_dir="$REPO/runs/${now_utc}-${LEG}-s7-7.4.b-read-after-write"
  echo "[$now_utc] cell: 7.4.b-read-after-write"
  RECORD_CACHE_STATE=na-visibility-consistency-cell \
  RECORD_RUN_DIR="$run_dir" \
  CONDA_PREFIX="$CONDA_ENV" \
  "$RECORD" --run-name "7.4.b-read-after-write" --stage 7.4 \
    --note "Stage 7.4.b read-after-write consistency — 20 writes of MEASURED-7.3-matched heatmaps; concurrent reader polls every 1ms for first-visible (ratified 2026-08-21: build-machine visibility fell BELOW the old 10ms floor, so 10ms sampled poll phase; the recorded resolution floor stays the quantisation guard). ARTIFACT MATCHED TO A MEASURED 7.3 OUTPUT ON THIS LEG (the register's synthetic-writer exception, evidenced): size target 6,440,000 B = the mean of the 50 recorded tiff5x heatmap writes in cell 2026-08-23-033008-weka-s7-7.3.a-heatmap-tiff5x-virchow2-brca50 (median 6.19 MB, range 1.3-14.6 MB); tile geometry 256x256 single-level, identical to the measured artifact by construction; the writer records target-vs-achieved. Latency = first-visible - write-complete. WHY: read-after-write visibility is a CONSISTENCY property, not a bandwidth one, and the two filesystems have different metadata architectures — so there is no reason to assume they behave the same. SCOPE: single-client (writer and reader are processes on one instance); cross-client consistency would need a second instance and is out of scope. Regime: na — the cold/warm axis deliberately does not apply: the measured quantity is visibility latency, and the reader's first read is warm by construction (bytes written milliseconds earlier), labelled cache-served and never quoted as a storage read (D13)." \
    -- "$PY" "$RAW_HELPER" \
       --output-dir "${FS_MOUNT}/heatmaps/7.4b" \
       --n-slides 20 --bytes-per-write 6440000 \
       --poll-interval-s 0.001 \
       --per-slide-csv "$run_dir/read-after-write-latencies.csv" \
       --summary-json "$run_dir/raw-summary.json"
  _rc=$?; if (( _rc != 0 )); then FAILED_CELLS=$(( FAILED_CELLS + 1 )); echo "WARN: cell exited rc=$_rc — recorded INCOMPLETE; sweep continues (fails loud at the end)"; fi
}

tier5_mixed() {
  echo "=== Tier 7.5.a — Clinical-deployment mixed workload (1 cell, 30 min) ==="
  local common_env="INFER_BACKEND=kvikio INFER_MODEL=virchow2 INFER_CACHE_POLICY=warm INFER_HEATMAP_FORMAT=tiff5x"
  run_orchestrator_cell "7.5.a-mixed-all-four" \
    "inference,ingest,heatmap-viewer,viewer" 4 300 1500 "$common_env"
}

tier5_endurance() {
  echo "=== Tier 7.5.b — Endurance (1 cell, ~4 hr) ==="
  local common_env="INFER_BACKEND=kvikio INFER_MODEL=virchow2 INFER_CACHE_POLICY=warm INFER_HEATMAP_FORMAT=tiff5x"
  # 4 hr = 14400s steady + 5 min ramp = ~4 hr 5 min cell
  run_orchestrator_cell "7.5.b-endurance-all-four-4hr" \
    "inference,ingest,heatmap-viewer,viewer" 4 300 14400 "$common_env"
}

tier6_cam16() {
  echo "=== Tier 7.6 — Cross-dataset inference validation (1 cell, CAM16) ==="
  # CAM16 N=4 concurrent Virchow2 kvikIO warm-cache. Use the orchestrator since
  # N>1 (concurrent), reusing the standard inference workload but with the
  # CAM16 manifest + coords + raw-TIFF dir.
  local common_env="INFER_BACKEND=kvikio INFER_MODEL=virchow2 INFER_CACHE_POLICY=warm INFER_HEATMAP_FORMAT=tiff5x \
INFER_MANIFEST=$CAM16_SUBSET_MANIFEST \
INFER_COORDS_DIR=$CAM16_COORDS \
INFER_RAWTIFF_DIR=$CAM16_RAWTIFF \
INFER_SVS_DIR=$CAM16_SVS"
  run_orchestrator_cell "7.6-cam16-virchow2-kvikio-warm-N4" \
    "inference" 4 300 1500 "$common_env"
}

all() {
  tier1_baselines
  tier2_concurrent
  tier3_heatmaps
  tier4_streaming
  tier5_mixed
  tier5_endurance
  tier6_cam16
  echo ""
  echo "=== Stage 7 sweep done. Aggregate with: $REPO/scripts/aggregate-stage7-clinical.py ==="
}

case "${1:-}" in
  smoke)            smoke ;;
  tier1_baselines)  tier1_baselines ;;
  tier2_concurrent) tier2_concurrent ;;
  tier3_heatmaps)   tier3_heatmaps ;;
  tier4_streaming)  tier4_streaming ;;
  tier5_mixed)      tier5_mixed ;;
  tier5_endurance)  tier5_endurance ;;
  tier6_cam16)      tier6_cam16 ;;
  all)              all ;;
  *) echo "usage: $0 {smoke|tier1_baselines|tier2_concurrent|tier3_heatmaps|tier4_streaming|tier5_mixed|tier5_endurance|tier6_cam16|all}" >&2; exit 2 ;;
esac

if (( FAILED_CELLS > 0 )); then
  echo "FAILED: $FAILED_CELLS cell(s) exited non-zero — every cell was attempted (per-cell isolation)," >&2
  echo "        and this exit tells the chain a hole exists rather than letting the step be marked done." >&2
  exit 1
fi
