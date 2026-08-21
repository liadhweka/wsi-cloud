# [USER ACTION] IAM grant for D-39 — FSx CloudWatch read on the Leg-B client role

**Run this in your local terminal** (any shell with AWS credentials that carry
`iam:PutRolePolicy`; IAM is global — no region flag needed):

```bash
aws iam put-role-policy \
  --role-name wsi-liad-client-role \
  --policy-name wsi-d39-cloudwatch-read \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "WsiD39CloudWatchMetricsRead",
      "Effect": "Allow",
      "Action": ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"],
      "Resource": "*"
    }]
  }'
```

To confirm it landed:

```bash
aws iam get-role-policy --role-name wsi-liad-client-role --policy-name wsi-d39-cloudwatch-read
```

## Why

`fsx-cloudwatch-dump.py` (tracker **D-39**) captures the RUNBOOK's declared
server-side Primary — the FSx per-OST/MDT CloudWatch metrics — per cell. The
instance role denies both CloudWatch read actions (verified live 2026-08-21:
`AccessDenied` on `cloudwatch:ListMetrics` and `cloudwatch:GetMetricData` for
`arn:aws:sts::130745022161:assumed-role/wsi-liad-client-role/i-006cc930fed5cf053`).
This gates `run-leg.sh` start (the first measured cell), per the open-items
memory. `"Resource": "*"` because neither action supports resource-level
scoping — this is the standard shape for CloudWatch metric reads; both are
read-only.

## Notes

- The change takes effect within seconds on the instance's existing credentials
  (STS role credentials pick up policy changes without a new session).
- If `wsi-liad-client-role` is terraform-managed **with exclusive inline-policy
  management** (legacy `inline_policy` blocks), mirror the same statement into
  the terraform so a future apply cannot silently strip it. A standalone
  out-of-band inline policy is otherwise left alone by terraform — and this leg
  ends in a destroy regardless.
- After you run it, tell the Leg-B session (R2): it re-runs the dump on the
  stage-0 proof cell, closes tracker D-39, and deletes this file (TEMP/
  convention: spent once applied).
