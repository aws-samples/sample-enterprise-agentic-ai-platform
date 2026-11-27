#!/usr/bin/env bash
# 02 — Deploy the EAP platform in DEMO mode.
# Billable: ECR, AgentCore, Fargate/Langfuse, the platform-created VPC (NAT), and
# the public console stack (S3 + CloudFront + API Gateways + Lambdas).
#
# Uses the COMMITTED preset configs/demo.tfvars directly — DEMO needs no test-bed
# fixtures (the platform creates its own VPC + all IAM roles). The apply is
# Docker-free for the ADE image (studio_build_image=false, reuses the ECR image),
# but the console SPA is built here via the console module's npm build/s3-sync,
# so Node/npm must be present (checked by script 01).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"
TFVARS="configs/demo.tfvars"
REGION="${AWS_REGION:-us-east-1}"
AUTO="${1:-}"

echo "=== 02 — deploy platform (DEMO mode) ==="
cd "$PLATFORM"

[ -f "$TFVARS" ] || { echo "Missing $TFVARS (committed preset) — is the platform tree intact?"; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "--- bootstrap state backend (idempotent) ---"
./bootstrap.sh

echo "--- terraform init ---"
terraform init -input=false -backend-config="bucket=eap-platform-state-${ACCOUNT_ID}"

# --- cross-mode guard ------------------------------------------------------
# There is ONE platform state per account (backend key platform/terraform.tfstate).
# The DEMO and ENTERPRISE test beds are two POSTURES of that single deployment, not two
# stacks — deploying one on top of the other silently CONVERTS it (and collides
# on the shared ECR/CodeCommit/pipeline/runtime names). Detect an existing enterprise
# deployment (platform resources present but NO public console) and refuse, so
# the operator tears it down first. A fresh/empty account passes through.
STATE="$(terraform state list 2>/dev/null || true)"
if echo "$STATE" | grep -qE '^module\.pipelines' && ! echo "$STATE" | grep -qE '^module\.console'; then
  echo ""
  echo "REFUSING TO PROCEED: a platform deployment WITHOUT the public console is"
  echo "already present in this account's state — that is the enterprise posture. DEMO and"
  echo "Enterprise cannot coexist: they share one Terraform state and account-global names."
  echo "Tear down the enterprise bed first:  (cd test/enterprise-testbed && ./99-teardown.sh)"
  echo "Then re-run this script. (Or use a SEPARATE AWS account for each mode.)"
  exit 1
fi

echo "--- create ECR repos first (images depend on them) ---"
terraform apply -input=false -target=module.ecr -auto-approve

echo ""
echo "NOTE: seed the base/ADE images into ECR (DEPLOY-RUNBOOK Step 1) if this is a"
echo "clean account. This script uses studio_build_image=false (Docker-free ADE),"
echo "so the ADE image must already exist in ECR. The console SPA IS built here."
echo ""

terraform plan -input=false -var-file="$TFVARS" -var 'studio_build_image=false' -out=tfplan

if [ "$AUTO" != "--yes" ]; then
  read -r -p "Apply the platform plan? Creates billable AWS resources (incl. public console). [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; rm -f tfplan; exit 1; }
fi

terraform apply -input=false tfplan
rm -f tfplan

echo ""
echo "Platform applied (DEMO). Posture:"
terraform output agent_network_posture 2>/dev/null || true

# The root module does not re-export the (count-gated) console CloudFront domain,
# so discover it directly for convenience.
CONSOLE_DOMAIN=$(aws cloudfront list-distributions --region "$REGION" \
  --query "DistributionList.Items[?contains(to_string(Origins.Items[].Id), 's3-console')].DomainName | [0]" \
  --output text 2>/dev/null || true)
if [ -n "$CONSOLE_DOMAIN" ] && [ "$CONSOLE_DOMAIN" != "None" ]; then
  echo "Console (public CloudFront): https://$CONSOLE_DOMAIN"
  echo "Open it and sign in via Cognito. (First load after a fresh deploy may need"
  echo "the Cognito callback synced to this domain — see DEPLOY-RUNBOOK known issues.)"
else
  echo "Console deployed. Find its CloudFront domain in the AWS console or via:"
  echo "  aws cloudfront list-distributions --query 'DistributionList.Items[].DomainName'"
fi
