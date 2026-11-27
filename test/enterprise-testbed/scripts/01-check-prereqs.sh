#!/usr/bin/env bash
# 01 — Prerequisite checks for the enterprise test bed.
# Read-only; makes no changes. Exits non-zero if a hard requirement is missing.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
FAIL=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

echo "=== enterprise test bed — prerequisite checks (region: $REGION) ==="

# --- tooling ---
command -v terraform >/dev/null && ok "terraform: $(terraform version | head -1)" || bad "terraform not found (need >= 1.5)"
command -v aws >/dev/null && ok "aws cli: $(aws --version 2>&1)" || bad "aws cli v2 not found"
command -v jq >/dev/null && ok "jq present" || warn "jq not found — some scripts pretty-print with it"

# --- credentials ---
if IDENT=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ACCT=$(echo "$IDENT" | jq -r .Account 2>/dev/null || echo "?")
  ARN=$(echo "$IDENT" | jq -r .Arn 2>/dev/null || echo "?")
  ok "authenticated — account $ACCT, principal $ARN"
else
  bad "AWS credentials invalid/expired — run your creds refresh, then retry"
fi

# --- region sanity ---
[ "$REGION" = "us-east-1" ] && ok "region us-east-1" || warn "region is $REGION (platform + fixtures default to us-east-1)"

# --- Docker (clean-account image seed, script 00) ---
# Script 00-seed-images.sh builds the base + ADE images on a clean account, which
# needs a running Docker daemon. (05 itself is Docker-free once images exist.)
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  ok "docker daemon reachable (needed by 00-seed-images.sh on a clean account)"
else
  warn "docker not running — needed by 00-seed-images.sh to seed base/ADE images on a clean account (skip if they already exist in ECR)"
fi

# --- required ECR images (DEPLOY-RUNBOOK Step 1) ---
# 05 runs studio_build_image=false, so the base + ADE images MUST already exist
# or the apply fails. WARN (not FAIL): 00-seed-images.sh seeds them idempotently
# and run-all.sh runs 00 before 05.
if aws ecr describe-images --repository-name eap-agents-base-strands --image-ids imageTag=latest --region "$REGION" >/dev/null 2>&1 \
   && aws ecr describe-images --repository-name eap-agents --image-ids imageTag=agent-builder-studio-latest --region "$REGION" >/dev/null 2>&1; then
  ok "required ECR images present (base + ADE) — script 05 can deploy Docker-free"
else
  warn "base/ADE images missing in ECR — run scripts/00-seed-images.sh first (clean-account bootstrap, DEPLOY-RUNBOOK Step 1). run-all.sh does this for you."
fi

# --- PassRole reminder (informational) ---
say ""
say "NOTE: the platform apply (script 05) hands the externalized roles to their"
say "services, which requires iam:PassRole on those ARNs. Script 03 creates a"
say "scoped PassRole policy; attach it to your deploy principal (03 prints how)."

# --- AgentCore-supported AZ reminder (cannot be validated here) ---
say ""
say "NOTE: verify the enterprise-vpc private subnets land on AgentCore-supported"
say "AZ IDs before deploy. After script 02, check each subnet:"
say "  aws ec2 describe-subnets --subnet-ids <id> --query 'Subnets[0].AvailabilityZoneId'"
say "and cross-reference the AgentCore VPC docs' supported-AZ table."

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "Prerequisites NOT met — fix the FAIL items above."
  exit 1
fi
echo "Prerequisites OK."
