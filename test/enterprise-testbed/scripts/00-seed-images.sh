#!/usr/bin/env bash
# 00 — Seed container images (clean-account bootstrap; DEPLOY-RUNBOOK Step 0+1).
#
# AgentCore Runtime can only pull images from ECR, and Terraform creates the ECR
# *repos* but not the *images*. On a brand-new account both repos start empty, so
# script 05 (which runs studio_build_image=false) would fail — the ADE runtime
# has no image to pull. This step seeds the two required images ONCE:
#   1a. base image (eap-agents-base-strands)  — FROM public.ecr.aws/docker/library/python:3.12-slim
#   1b. ADE image  (eap-agents:agent-builder-studio-latest) — FROM the base
#
# IDEMPOTENT: if both images already exist in ECR it is a no-op, so it is safe to
# run before every 05. It bootstraps the state backend + ECR repos itself (via
# the same bootstrap.sh + terraform -target=module.ecr as script 05) so it can
# run early on a clean account. Image seeding is platform-level and posture-
# independent — identical to the demo bed's 00.
#
# Requires a working Docker daemon (checked by script 01). This is the ONLY
# testbed step that builds images; after it the platform apply is control-plane.
#
# Usage:
#   scripts/00-seed-images.sh           # seed if missing
#   scripts/00-seed-images.sh --force   # rebuild + push even if present
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLATFORM="$REPO/platform/eap-platform"
FORCE=""
[ "${1:-}" = "--force" ] && FORCE="yes"

echo "=== 00 — seed container images (clean-account bootstrap) ==="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# --- ensure ECR repos exist (Step 0) ---------------------------------------
cd "$PLATFORM"
echo "--- bootstrap state backend + ECR repos (idempotent) ---"
./bootstrap.sh
terraform init -input=false -backend-config="bucket=eap-platform-state-${ACCOUNT_ID}" >/dev/null
terraform apply -input=false -target=module.ecr -auto-approve

AGENT_ECR_URL=$(terraform output -raw ecr_repository_url)
BASE_ECR_URL=$(terraform output -raw ecr_base_image_repository_url)
echo "  Agent ECR:      $AGENT_ECR_URL"
echo "  Base Image ECR: $BASE_ECR_URL"

ADE_TAG="agent-builder-studio-latest"

# --- presence check --------------------------------------------------------
have_image() { # repo_name, tag
  aws ecr describe-images --repository-name "$1" --image-ids imageTag="$2" \
    --region "$REGION" >/dev/null 2>&1
}
BASE_REPO="${BASE_ECR_URL##*/}"
AGENT_REPO="${AGENT_ECR_URL##*/}"

if [ -z "$FORCE" ] && have_image "$BASE_REPO" latest && have_image "$AGENT_REPO" "$ADE_TAG"; then
  echo ""
  echo "Both images already present (base:latest + $AGENT_REPO:$ADE_TAG) — nothing to do."
  echo "(use --force to rebuild.)"
  exit 0
fi

echo ""
echo "--- ECR login ---"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --- 1a. base image --------------------------------------------------------
if [ -n "$FORCE" ] || ! have_image "$BASE_REPO" latest; then
  echo ""
  echo ">>> [1a] building strands base image (linux/arm64) -> $BASE_ECR_URL:latest"
  ( cd "$REPO/platform/eap-terraform-modules/base-images/strands"
    docker build --platform linux/arm64 -t "$BASE_ECR_URL:latest" .
    docker push "$BASE_ECR_URL:latest" )
else
  echo ">>> [1a] base image already present — skip"
fi

# --- 1b. ADE image (FROM the base) -----------------------------------------
if [ -n "$FORCE" ] || ! have_image "$AGENT_REPO" "$ADE_TAG"; then
  echo ""
  echo ">>> [1b] building Agent Deployment Engineer image -> $AGENT_ECR_URL:$ADE_TAG"
  ( cd "$PLATFORM/studio" && AWS_REGION="$REGION" ./build-and-push.sh "$ADE_TAG" )
else
  echo ">>> [1b] ADE image already present — skip"
fi

echo ""
echo "Images seeded. Script 05 can now deploy Docker-free (studio_build_image=false)."
