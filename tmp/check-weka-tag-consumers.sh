#!/usr/bin/env bash
# check-weka-tag-consumers.sh — LAPTOP-side (admin creds; the instance role can't read IAM).
# Answers: does anything key on the weka_hostgroup_type instance tag, or is it safe to drop
# from tmp/lustre-main.tf?
#
# Decision rule:
#   - Zero hits in checks 1+2  -> drop the tag + its comment from tmp/lustre-main.tf.
#   - Any hit                  -> paste it back to the Leg-B session; a hit inside the WEKA
#     module that is only backend/client DISCOVERY is irrelevant to Leg B (no WEKA cluster
#     there) — what matters is the tag inside an IAM policy Condition.
# Repo-side consumers were already checked from the Leg-B box 2026-08-20: none.
set -uo pipefail

TAG="weka_hostgroup_type"
ROLE="${ROLE:-wsi-liad-client-role}"
TF_DIR="${TF_DIR:-$HOME/terraform}"

echo "== 1. terraform trees ($TF_DIR) — the likely author of any consumer =="
grep -ri "$TAG" "$TF_DIR" || echo "terraform: clean"

echo
echo "== 2a. role '$ROLE' inline policies =="
found=0
for p in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text); do
  aws iam get-role-policy --role-name "$ROLE" --policy-name "$p" \
    --query PolicyDocument --output json | grep -i "$TAG" && { echo "  ^ in inline policy: $p"; found=1; }
done
[ "$found" -eq 0 ] && echo "inline: clean"

echo
echo "== 2b. role '$ROLE' attached managed policies =="
found=0
for arn in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text); do
  v=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$v" \
    --query PolicyVersion.Document --output json | grep -i "$TAG" && { echo "  ^ in attached policy: $arn"; found=1; }
done
[ "$found" -eq 0 ] && echo "attached: clean"

echo
echo "== 3. (optional completeness) every customer-managed policy in the account =="
for arn in $(aws iam list-policies --scope Local --query 'Policies[].Arn' --output text); do
  v=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$v" \
    --query PolicyVersion.Document --output json | grep -qi "$TAG" && echo "HIT: $arn"
done
echo "account scan done"
