#!/usr/bin/env bash
# bootstrap.sh — One-time state backend provisioning
#
# Creates the S3 bucket and DynamoDB lock table needed by terraform backend.
# Idempotent: safe to run multiple times. Skips resources that already exist.
#
# Run ONCE before the first `terraform init` on a fresh account:
#   cd platform/eap-platform && ./bootstrap.sh
#
# After this, run: terraform init -migrate-state (if migrating from local)
#                  terraform init              (if fresh)

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# S3 bucket names are GLOBALLY unique across all AWS accounts, so the state
# bucket is account-scoped: eap-platform-state-<ACCOUNT_ID>. Override the
# whole name with TF_STATE_BUCKET if you have a naming convention of your own.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="${TF_STATE_BUCKET:-eap-platform-state-${ACCOUNT_ID}}"

# DynamoDB table names are account+region scoped (not global), so a fixed name
# is safe here.
LOCK_TABLE="${TF_LOCK_TABLE:-eap-platform-locks}"

# Optional customer-managed KMS key (CMK) for the state bucket's at-rest
# encryption (ADR-035). Empty (default) => the AWS-managed aws/s3 key. Set to a
# key ARN/ID for a CMK. NOTE: S3 SSE is not retroactive — set this at first
# bucket creation; changing it later re-encrypts only new object versions.
STATE_KMS_KEY_ARN="${TF_STATE_KMS_KEY_ARN:-}"

echo "=== EAP Platform State Backend Bootstrap ==="
echo "  Account:    $ACCOUNT_ID"
echo "  Bucket:     $BUCKET_NAME"
echo "  Lock Table: $LOCK_TABLE"
echo "  Region:     $REGION"
echo ""

# --- S3 Bucket ---
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "✓ S3 bucket '$BUCKET_NAME' already exists — skipping"
else
  echo "→ Creating S3 bucket '$BUCKET_NAME'..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi

  # Enable versioning (state history)
  aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

  # Enable encryption (ADR-035): aws:kms with the customer-managed key when
  # TF_STATE_KMS_KEY_ARN is set, otherwise the AWS-managed aws/s3 key.
  if [ -n "$STATE_KMS_KEY_ARN" ]; then
    echo "  Using customer-managed KMS key: $STATE_KMS_KEY_ARN"
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
      --server-side-encryption-configuration "{
        \"Rules\": [{\"ApplyServerSideEncryptionByDefault\": {\"SSEAlgorithm\": \"aws:kms\", \"KMSMasterKeyID\": \"$STATE_KMS_KEY_ARN\"}, \"BucketKeyEnabled\": true}]
      }"
  else
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
      --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}, "BucketKeyEnabled": true}]
      }'
  fi

  # Block public access
  aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
    --public-access-block-configuration '{
      "BlockPublicAcls": true,
      "IgnorePublicAcls": true,
      "BlockPublicPolicy": true,
      "RestrictPublicBuckets": true
    }'

  echo "✓ S3 bucket created with versioning + encryption + public access blocked"
fi

# --- DynamoDB Lock Table ---
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "✓ DynamoDB table '$LOCK_TABLE' already exists — skipping"
else
  echo "→ Creating DynamoDB lock table '$LOCK_TABLE'..."
  aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    ${STATE_KMS_KEY_ARN:+--sse-specification "Enabled=true,SSEType=KMS,KMSMasterKeyId=$STATE_KMS_KEY_ARN"} \
    --tags Key=Platform,Value=eap Key=Component,Value=state-backend

  aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
  aws dynamodb update-continuous-backups --table-name "$LOCK_TABLE" --region "$REGION" \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true >/dev/null
  echo "✓ DynamoDB lock table created"
fi

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Next steps (the bucket name is account-scoped, so pass it via -backend-config):"
echo "  terraform init -backend-config=\"bucket=${BUCKET_NAME}\""
echo "  # migrating existing local state to S3:"
echo "  terraform init -backend-config=\"bucket=${BUCKET_NAME}\" -migrate-state"
