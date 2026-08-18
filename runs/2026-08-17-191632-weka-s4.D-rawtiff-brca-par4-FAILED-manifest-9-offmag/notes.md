# Post-run notes — why this dir is FAILED-renamed, and why its data is still the measurement

**The measurement in this dir is valid and is the Leg-A 4.D BRCA number.** The cell converted
**1064/1073 queued slides (5,899,897,346,000 bytes written, 56,590 s wallclock at PARALLEL=4)** with all
nine recording streams verified. The `INCOMPLETE` verdict (rc=1) exists because 9 manifest entries were
invalid, not because the conversion or its recording failed.

**The 9 failures** (`TCGA-OL-A66{H,I,J,K,L,N,O,P}`, `TCGA-OL-A6VO`) are finer-than-40× scans
(openslide mpp-x 0.116–0.164 despite `objective-power=40`) refused in ≤1 s each by the converter's
fail-loud mpp guard — eff_mpp 0.23–0.33, below the 0.4 floor of the 20× contract. The manifest's
derivation criterion (`mpp<0.35`) had no fine-end floor; the guard is the arbiter (STAGES.md **D5**,
overwritten accordingly). The cohort of record is now **1064** and the 9 IDs sit in the manifest's
commented-exclusion tail. Their ≤1 s refusals are negligible perturbation inside the 15.7 h window.

**Consistency canary (wsi_agg_helper.py check, recorded judgement):** write direction **PASS** at
ratio 1.482 (5+2 EC relation, band centred 1.456); read direction **FAIL** at 1.219 against the
single-direction band [0.992, 1.095] — judged the expected mixed read+write widening (this cell reads
SVS while writing EC-amplified raw-TIFF concurrently; no mixed band is calibrated yet — open item B.3).
Report-only per the pre-ratified 4.D canary policy; not an instrumentation failure. The write direction,
which carries the EC physics, sits dead-centre.

**Successor cells:** the 4.D step was re-invoked after the manifest amendment — the follow-up BRCA cell
is a **completion-verification pass** (1064 × SKIP-EXISTS, converts nothing, and must never be quoted as
the conversion measurement); the CAM16 cell that this cell's failure aborted runs there for real.
Quotable BRCA numbers come from **this** dir; the roadmap results row points here.

raw/ is relocated to `/data/local-nvme/runs-raw-overflow/2026-08-17-191632-weka-s4.D-rawtiff-brca-par4-raw`
(symlinked back) and verified in S3 under the original dir name.
