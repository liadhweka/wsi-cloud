# Reprice at publication — one snapshot, every cell, nothing overwritten

Run this **after both legs are complete**, when the whitepaper/blog is being written
(`../PROJECT-THESIS.md` §4). You are producing the publication cost tables: **one fresh, dated price
snapshot applied to both legs' recorded wallclocks**, so the headline cannot be attacked as "two legs
priced on different days."

## Hard rules

1. **Read-only over `runs/`.** You never modify any `metadata.json` or any existing run artifact. The
   as-run `cost_inputs` are provenance and stay exactly as recorded.
2. **Output is a NEW, dated snapshot pair** at the runs root (the committed-summary-CSV convention):
   - `runs/cost-reprice-<PRICE_DATE>.csv` — machine-readable, one row per cell.
   - `runs/cost-reprice-<PRICE_DATE>.md` — the arithmetic a human can follow: per stage, per leg.
   Never overwrite an earlier snapshot pair — a draft-time and a publication-time reprice may coexist,
   and the filename date is what distinguishes them.
3. **Completeness is proven, not assumed.** Enumerate cells two ways and reconcile: every run directory
   matching `runs/*-s*/`, and every line of `runs/INDEX.md`. Report both counts and explain any
   difference before producing numbers. Every enumerated cell appears in the CSV — a cell with no
   recorded `wallclock_s` (interrupted before the benchmark returned) appears as an **unpriced row with
   the reason**, never silently dropped.

## The snapshot

Fetch on the day you run this, and record `price_checked_utc` for the snapshot (it stamps the filenames
and every table):

- **Instance $/hr** — current AWS on-demand price for the recorded instance type, in the recorded region.
- **Filesystem $/hr, per leg** — WEKA: the leg's recorded backend fleet at current EC2 pricing;
  Lustre: current FSx pricing for the recorded tier × capacity × provisioned metadata IOPS.
  Derive each from the **provisioned configuration in that leg's environment contract** — never from
  memory of what was provisioned.
- **Software $/hr, per leg** — WEKA: the current **public AWS Marketplace rate** (citable; a negotiated
  price is not); Lustre: `0`, basis "FSx service rate is software-inclusive."
- Record the source URL beside every figure.

## The arithmetic

Per cell: `infra_only = (instance + filesystem) × wallclock_s / 3600` and
`all_in = infra_only + software × wallclock_s / 3600` — both bases, always (D7).
Per stage: subtotals by the `stage` metadata field, **including** `stability`, smoke and `-repN` cells —
overhead is real spent wallclock; label it so the writeup can subset. Per leg: the sum of everything,
plus the pipeline-only subtotal (excluding stability/smoke) stated separately.

## The drift table

The `.md` closes with as-run vs snapshot: each distinct as-run price set found in the recorded
`cost_inputs` (per leg, with its `price_checked_utc`) beside the fresh snapshot, and the resulting per-leg
cost delta. Drift is shown, not discovered by a reviewer.

## Done when

Both files exist and are committed; the row count equals the reconciled cell count; every unpriced cell
carries its reason; every price carries a source URL and the snapshot date; and `docs/RESULTS.md`'s
headline cost figures point at this snapshot.
