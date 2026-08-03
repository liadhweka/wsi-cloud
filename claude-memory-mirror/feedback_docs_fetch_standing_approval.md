---
name: docs-fetch-standing-approval
description: "WebFetch of official docs (AWS, WEKA, Lustre, HF cards, library docs) is standing-approved — fetch before proposing any API/flag/config/price, never ask first. Exceptions (still ask) listed below."
metadata:
  node_type: memory
  type: feedback
---

Fetching official docs to ground any API / flag / config / sizing / methodology proposal is **standing
approved — just fetch, don't ask.** Accuracy beats speed; proposing from memory is a recurring
re-run-causing failure. Cite the page used; **if docs and training data disagree, the docs win — say so.**

**Sources this project leans on:** AWS (`docs.aws.amazon.com` — EC2 instance specs, FSx for Lustre
performance/tiers/limits, EFA, S3, IAM, quotas), WEKA (`docs.weka.io`), Lustre (`doc.lustre.org`),
NVIDIA (GDS / cuFile / nvidia-fs), and the toolkit/model docs — OpenSlide, cuCIM & kvikIO
(`docs.rapids.ai`), tifffile, MONAI, CLAM/Trident, PyTorch, fio, plus HF model cards for Virchow2 /
GigaPath / UNI2-h and the dataset portals (GDC, CAMELYON via the AWS Open Data registry).

**Cloud specifics are especially version- and region-sensitive** — instance specs, FSx throughput tiers,
per-client caps, quotas and prices all change. Never quote one from memory; fetch it, and pair any price
figure with the date it was checked.

**Still ask first:** a fetch downloading a >100 MB asset; a service named off-limits; anything sending
project data in the request; or any non-WebFetch outbound channel (email/Slack/Notion/Jira/Drive — that
is external output, ask-first like any state-mutating action).
