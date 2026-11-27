# EAP State Backend — S3 + DynamoDB
# Provisions the S3 bucket and DynamoDB lock table used by all EAP workspaces.
# State keys follow: {domain}/{team}/terraform.tfstate
# Requirements: R14.1, R14.2, R14.5

variable "bucket_name" {
  type        = string
  default     = ""
  description = "S3 bucket name for Terraform state. Empty (default) => eap-platform-state-<ACCOUNT_ID>, the account-scoped name bootstrap.sh uses."
}

variable "lock_table_name" {
  type        = string
  default     = "eap-terraform-locks"
  description = "DynamoDB table name for state locking"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kms_key_arn" {
  type        = string
  default     = null
  description = "Customer-managed KMS key ARN for the state bucket's at-rest encryption (ADR-035). Null (default) => the AWS-managed key (aws/s3). NOTE: the LIVE state bucket is created by bootstrap.sh, not this module; set TF_STATE_KMS_KEY_ARN there. This module mirrors that for parity."
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "eap-platform-state-${data.aws_caller_identity.current.account_id}"
  tags = merge(var.tags, {
    "eap:managed"   = "true"
    "eap:component" = "state-backend"
  })
}

# ---------------------------------------------------------------------------
# S3 Bucket — Terraform state storage with encryption
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    # ADR-035: aws:kms with the customer-managed key when supplied; otherwise
    # the AWS-managed aws/s3 key (kms_master_key_id null).
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB Table — State locking
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  # ADR-035: the customer-managed key when kms_key_arn is set, otherwise the
  # AWS-managed aws/dynamodb key.
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "state_bucket_name" {
  description = "S3 bucket name for Terraform state"
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "S3 bucket ARN for Terraform state"
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB table name for state locking"
  value       = aws_dynamodb_table.locks.name
}

output "lock_table_arn" {
  description = "DynamoDB table ARN for state locking"
  value       = aws_dynamodb_table.locks.arn
}
