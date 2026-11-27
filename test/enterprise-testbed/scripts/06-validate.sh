#!/usr/bin/env bash
# 06 — Validate the enterprise deployment posture. Read-only checks.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "=== 06 — validate enterprise posture ==="
cd "$PLATFORM"

POSTURE=$(terraform output -raw agent_network_posture 2>/dev/null || echo "?")
[ "$POSTURE" = "VPC" ] && ok "agent_network_posture = VPC" || bad "agent_network_posture = $POSTURE (expected VPC)"

VPCID=$(terraform output -raw agent_network_vpc_id 2>/dev/null || echo "")
[ -n "$VPCID" ] && ok "agents run in VPC $VPCID" || bad "no agent VPC id — agents may be PUBLIC"

# Console stack must be absent (deploy_console=false).
echo "--- console stack should be absent ---"
if terraform state list 2>/dev/null | grep -qE '^module\.console'; then
  bad "module.console present — expected none (deploy_console=false)"
else
  ok "no module.console resources"
fi
if terraform state list 2>/dev/null | grep -qE '^module\.invoke_proxy'; then
  bad "module.invoke_proxy present — expected none"
else
  ok "no module.invoke_proxy resources"
fi

# Externalized IAM: platform should have created NO IAM role for the 5 standalone
# roles (they came from the fixture). Spot-check by name.
echo "--- externalized IAM (platform created none of the 5 standalone) ---"
if terraform state list 2>/dev/null | grep -qiE 'aws_iam_role\..*(gateway|studio_runtime|studio_read|commit_validation|observability)'; then
  echo "  (review) some IAM role resources are in platform state — confirm they are"
  echo "  pipeline roles (expected) and NOT the externalized standalone 5."
else
  ok "no standalone IAM roles in platform state"
fi

echo ""
echo "Manual checks (need a jumphost / console user):"
echo "  - Langfuse ALB is internal (aws elbv2 describe-load-balancers ... Scheme=internal)"
echo "  - Agent/Lambda ENIs are in the private subnets"
echo "  - Invoke an agent end-to-end from the jumphost"
