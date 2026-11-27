#!/usr/bin/env bash
# 03 — Create the 5 externalized hardened standalone roles (Option A) + the
# scoped PassRole policy. Billable-ish (IAM is free, but real resources).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="$HERE/iam-roles"
AUTO="${1:-}"

echo "=== 03 — create externalized hardened IAM roles ($IAM_DIR) ==="
cd "$IAM_DIR"
terraform init -input=false >/dev/null
terraform plan -input=false -out=tfplan

if [ "$AUTO" != "--yes" ]; then
  read -r -p "Apply this plan? Creates 5 IAM roles + a PassRole policy. [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; rm -f tfplan; exit 1; }
fi

terraform apply -input=false tfplan
rm -f tfplan

echo ""
echo "IAM roles created. Role ARNs:"
terraform output enterprise_tfvars_iam_snippet
echo ""
PASSROLE_ARN=$(terraform output -raw passrole_policy_arn)
echo "Scoped PassRole policy: $PASSROLE_ARN"
echo "Attach it to your deploy principal so script 05 can iam:PassRole these roles, e.g.:"
echo "  aws iam attach-user-policy   --user-name  <you> --policy-arn $PASSROLE_ARN   # (IAM user)"
echo "  aws iam attach-role-policy   --role-name  <you> --policy-arn $PASSROLE_ARN   # (assumed role)"
