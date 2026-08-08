---
name: uni2h-conditional-use-status
description: "UNI2-h runs as a first-class third foundation model, but its results are INTERNAL ONLY until the Mahmood Lab grants written approval. Every UNI2-h cell carries the [PENDING-APPROVAL-DO-NOT-EXTERNALIZE] tag."
metadata:
  type: project
---

UNI2-h is benchmarked alongside Virchow2 and GigaPath, but its licence carries a non-commercial clause, so
**every UNI2-h result is internal-only until the Mahmood Lab grants written approval to externalize.**

**Why this is a memory and not a doc:** it is an external commitment whose state is set by someone outside this
project, so it cannot be derived from the repo.

**How to apply:**
- Every UNI2-h cell auto-tags `[PENDING-APPROVAL-DO-NOT-EXTERNALIZE]` via `record-run.sh --note`, which carries
  it into `INDEX.md`, `metadata.json` and the run's `0_README.md`. **Do not strip these tags in refactors.**
- **Filter UNI2-h rows out of anything that leaves the building** — briefs, slides, customer-facing summaries.
- Virchow2 and GigaPath carry no such restriction.

The unsent approach drafts are in `uni2h-legal/`. If approval is granted, that is the moment to remove the tags
project-wide and delete this memory.
