#!/usr/bin/env bash
# 01 — Prerequisite checks for the DEMO test bed.
# Read-only; makes no changes. Exits non-zero if a hard requirement is missing.
#
# DEMO posture (configs/demo.tfvars): deploy_console=true, agents in-VPC (the
# agent_network_mode default "VPC" is not overridden), no imported VPC (the
# platform creates its own, hosting both agents and the observability leg),
# Cognito reference IdP, self-hosted Langfuse, all IAM roles platform-created.
# So — unlike the enterprise bed — there is NO enterprise-vpc fixture, NO externalized
# IAM roles, and NO iam:PassRole requirement. The one EXTRA demo requirement is a
# Node/npm toolchain: the console module builds the SPA (`npm run build`) and
# s3-syncs it at apply time.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
FAIL=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

echo "=== DEMO test bed — prerequisite checks (region: $REGION) ==="

# --- tooling ---
command -v terraform >/dev/null && ok "terraform: $(terraform version | head -1)" || bad "terraform not found (need >= 1.5)"
command -v aws >/dev/null && ok "aws cli: $(aws --version 2>&1)" || bad "aws cli v2 not found"
command -v jq >/dev/null && ok "jq present" || warn "jq not found — some scripts pretty-print with it"

# --- console build toolchain (demo deploys the public console) ---
# The console module runs `npm run build` + `s3 sync` as a post-apply local-exec.
command -v node >/dev/null && ok "node: $(node --version 2>&1)" || bad "node not found — deploy_console=true builds the SPA (npm run build) at apply time"
command -v npm  >/dev/null && ok "npm: $(npm --version 2>&1)"  || bad "npm not found — needed to build the console SPA"

# --- Docker (examples backend image, ADR-037) ---
# The examples-console module builds + pushes the Fargate signer backend image
# (platform/examples-backend) to ECR at apply time. This runs a `docker build`,
# so a working Docker daemon is REQUIRED for the demo apply (this is separate
# from studio_build_image, which stays false).
if command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable (examples backend image build, ADR-037)"
  else
    bad "docker installed but daemon not reachable — the examples backend image build (ADR-037) needs it running"
  fi
else
  bad "docker not found — deploy_console=true builds the examples backend image (platform/examples-backend) at apply time"
fi

# --- git-remote-codecommit (CI/CD seed, script 04) ---
command -v git-remote-codecommit >/dev/null \
  && ok "git-remote-codecommit present (CodeCommit push over SigV4)" \
  || warn "git-remote-codecommit not found — script 04 needs it: pip install git-remote-codecommit"

# --- credentials ---
if IDENT=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ACCT=$(echo "$IDENT" | jq -r .Account 2>/dev/null || echo "?")
  ARN=$(echo "$IDENT" | jq -r .Arn 2>/dev/null || echo "?")
  ok "authenticated — account $ACCT, principal $ARN"
else
  bad "AWS credentials invalid/expired — run your creds refresh, then retry"
fi

# --- region sanity ---
[ "$REGION" = "us-east-1" ] && ok "region us-east-1" || warn "region is $REGION (platform defaults to us-east-1)"

# --- required ECR images (DEPLOY-RUNBOOK Step 1) ---
# Script 02 runs studio_build_image=false, so the base + ADE images MUST already
# exist in ECR or the apply fails (the ADE runtime has no image to pull). This is
# a WARN (not FAIL) because script 00-seed-images.sh seeds them idempotently and
# run-all.sh runs 00 before 02 — but flag it so a manual step-by-step run knows.
BASE_REPO="eap-agents-base-strands"
AGENT_REPO="eap-agents"
ADE_TAG="agent-builder-studio-latest"
if aws ecr describe-images --repository-name "$BASE_REPO" --image-ids imageTag=latest --region "$REGION" >/dev/null 2>&1 \
   && aws ecr describe-images --repository-name "$AGENT_REPO" --image-ids imageTag="$ADE_TAG" --region "$REGION" >/dev/null 2>&1; then
  ok "required ECR images present (base + ADE) — script 02 can deploy Docker-free"
else
  warn "base/ADE images missing in ECR — run scripts/00-seed-images.sh first (clean-account bootstrap, DEPLOY-RUNBOOK Step 1). run-all.sh does this for you."
fi

# --- image build reminders (informational) ---
say ""
say "NOTE (ADR-037): the demo apply also builds one image locally — the examples"
say "backend (platform/examples-backend) — and pushes it to ECR at apply time."
say "That is a second reason Docker must be running (checked above)."

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "Prerequisites NOT met — fix the FAIL items above."
  exit 1
fi
echo "Prerequisites OK."
