#!/usr/bin/env bash
# 05 — Deploy the EAP platform in enterprise mode against the test-bed VPC + roles.
# Billable: ECR, AgentCore, Fargate/Langfuse, VPC endpoints, etc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"
TFVARS="configs/enterprise.testbed.tfvars"
AUTO="${1:-}"

echo "=== 05 — deploy platform (enterprise mode) ==="
cd "$PLATFORM"

[ -f "$TFVARS" ] || { echo "Missing $TFVARS — run 04-gen-tfvars.sh first."; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "--- bootstrap state backend (idempotent) ---"
./bootstrap.sh

echo "--- terraform init ---"
terraform init -input=false -backend-config="bucket=eap-platform-state-${ACCOUNT_ID}"

# --- cross-mode guard ------------------------------------------------------
# There is ONE platform state per account (backend key platform/terraform.tfstate).
# The ENTERPRISE and DEMO test beds are two POSTURES of that single deployment, not two
# stacks — deploying one on top of the other silently CONVERTS it (and collides
# on the shared ECR/CodeCommit/pipeline/runtime names). Refuse if a DEMO
# deployment is already present, so the operator tears it down first.
if terraform state list 2>/dev/null | grep -qE '^module\.console'; then
  echo ""
  echo "REFUSING TO PROCEED: a DEMO deployment (public console) is already present"
  echo "in this account's platform state. ENTERPRISE and DEMO cannot coexist — they share"
  echo "one Terraform state and account-global resource names."
  echo "Tear down the demo bed first:  (cd test/demo-testbed && ./99-teardown.sh)"
  echo "Then re-run this script. (Or use a SEPARATE AWS account for each mode.)"
  exit 1
fi

echo "--- create ECR repos first (images depend on them) ---"
terraform apply -input=false -target=module.ecr -auto-approve

echo ""
echo "NOTE: seed the base/agent images into ECR (Step 1 of DEPLOY-RUNBOOK) if this"
echo "is a clean account, OR deploy Docker-free with studio_build_image=false"
echo "(reuses an image already in ECR). This script uses studio_build_image=false"
echo "so it does not require Docker; ensure the ADE image exists in ECR first."
echo ""

terraform plan -input=false -var-file="$TFVARS" -var 'studio_build_image=false' -out=tfplan

if [ "$AUTO" != "--yes" ]; then
  read -r -p "Apply the platform plan? Creates billable AWS resources. [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; rm -f tfplan; exit 1; }
fi

terraform apply -input=false tfplan
rm -f tfplan

echo ""
echo "Platform applied. Posture:"
terraform output agent_network_posture 2>/dev/null || true
terraform output agent_network_vpc_id 2>/dev/null || true
