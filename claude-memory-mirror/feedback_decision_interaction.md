---
name: list-decisions-as-plain-text-not-askuserquestion-shells
description: Surface open decisions as a plain-text numbered list with a recommendation each; the user replies with their own numbered list. Do NOT use the AskUserQuestion tool for methodology/plan choices in this project.
metadata:
  node_type: memory
  type: feedback
---

When surfacing decisions (methodology forks, plan options, ratification points), use a **plain-text
numbered list in the response**: each item = short question, 2–4 options, a clear recommendation. The
user replies with their own numbered list — picking tersely, asking follow-ups, deferring, or attaching
side notes.

**Why:** the AskUserQuestion picker forces one click per decision and blocks discussion/deferral; plain
text keeps simple choices simple AND allows back-and-forth in one exchange. In practice the highest-value
exchanges in this project have been multi-turn discussions where the user brought new information
mid-thread and the recommendation changed — a picker would have foreclosed that.

Do NOT use AskUserQuestion for this. (Rare exception: a genuine binary destructive-action go/no-go gate.)
