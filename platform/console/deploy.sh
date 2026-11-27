#!/bin/bash
# Deploy the Platform Console UI to S3 + CloudFront
# Prerequisites: terraform apply on eap-platform (creates infra)
# Usage: ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$SCRIPT_DIR/../eap-platform"

echo "=== Platform Console Deploy ==="

# 1. Get Terraform outputs from platform
echo "→ Reading Terraform outputs..."
cd "$PLATFORM_DIR"
CF_DOMAIN=$(terraform output -raw console_cloudfront_domain 2>/dev/null || echo "")
CF_DIST_ID=$(terraform output -raw console_distribution_id 2>/dev/null || echo "")
S3_BUCKET=$(terraform output -raw console_s3_bucket 2>/dev/null || echo "")
POOL_ID=$(terraform output -raw cognito_user_pool_id 2>/dev/null || echo "")
COGNITO_DOMAIN=$(terraform output -raw cognito_domain_prefix 2>/dev/null || echo "eap-platform-bu-1-dev")
IDENTITY_POOL_ID=$(terraform output -raw console_identity_pool_id 2>/dev/null || echo "")
CLIENT_ID=$(terraform output -raw console_cognito_client_id 2>/dev/null || echo "")
REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")

if [ -z "$CF_DOMAIN" ] || [ -z "$S3_BUCKET" ]; then
  echo "ERROR: Console infrastructure not deployed. Run 'terraform apply' in eap-platform/ first."
  exit 1
fi

echo "  CloudFront: https://$CF_DOMAIN"
echo "  S3 Bucket:  $S3_BUCKET"
echo "  Client ID:  $CLIENT_ID"

# 2. Build the console with production values
echo "→ Building console..."
cd "$SCRIPT_DIR"
VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN" \
VITE_COGNITO_REGION="$REGION" \
VITE_COGNITO_CLIENT_ID="$CLIENT_ID" \
VITE_REDIRECT_URI="https://$CF_DOMAIN/auth/callback" \
VITE_USER_POOL_ID="$POOL_ID" \
VITE_IDENTITY_POOL_ID="$IDENTITY_POOL_ID" \
VITE_STATE_TABLE="agent-school-lifecycle-team-bu-1-dev" \
npm run build

# 3. Upload to S3
echo "→ Uploading to S3..."
aws s3 sync dist/ "s3://$S3_BUCKET/" --delete

# 4. Invalidate CloudFront cache
echo "→ Invalidating CloudFront cache..."
aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" --paths "/*" --output text

echo ""
echo "=== Deploy Complete ==="
echo "Console URL: https://$CF_DOMAIN"
echo ""
echo "Login with Cognito credentials (see platform/console/LOGIN.md)"
