#!/usr/bin/env bash
#
# Build & push the Agent Deployment Engineer image.
#
# On a CLEAN account, the ECR repos are created by the platform apply
# (module.ecr) but start empty. Seed images once before creating the runtime:
#   1. Build + push the base image (eap-agents-base-strands:latest).
#   2. Run this script to build + push the agent image
#      (eap-agents:agent-deployment-engineer-latest).
#   3. terraform apply — the runtime references the pushed image by digest.
#
# For steady-state deploys the image already exists, so applies need no Docker.
# Use this script whenever you edit studio/app/ and want to ship a new image.
# Requires Docker/Lima running locally + AWS credentials.
#
# Usage:
#   ./build-and-push.sh [IMAGE_TAG]
#
# Then, if you used a non-default tag, set it in your deployment:
#   terraform apply -var 'studio_image_tag=<IMAGE_TAG>'   (wire as needed)
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REPO="eap-agents"
BASE_IMAGE_REPO="eap-agents-base-strands"
IMAGE_TAG="${1:-agent-deployment-engineer-latest}"

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
BASE_IMAGE_URI="${REGISTRY}/${BASE_IMAGE_REPO}:latest"

cd "$(dirname "$0")/app"

echo "=== ECR login ==="
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "=== Pull base image ==="
docker pull "$BASE_IMAGE_URI" || true

echo "=== Build Agent Deployment Engineer image (linux/arm64) -> $IMAGE_URI ==="
docker build --platform linux/arm64 \
  --build-arg BASE_IMAGE_URI="$BASE_IMAGE_URI" \
  -t "$IMAGE_URI" \
  -f Dockerfile .

echo "=== Push ==="
docker push "$IMAGE_URI"
echo "=== Done: $IMAGE_URI ==="
echo "Re-run 'terraform apply' to roll the runtime onto the new image."
