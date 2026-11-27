# Governance Infrastructure
# Provisions the S3 bucket for graduation policies and the CodePipeline
# that validates + uploads policies from the governance repo.
#
# Owner: Platform Operator
# Consumer: AI Governance (pushes to governance repo)
# Reader: Agent pipelines (gate stage reads policy from S3 at runtime)

variable "environment" {
  description = "Platform environment (dev, qa, uat, prod)"
  type        = string
  default     = "dev"
}

variable "governance_repo_name" {
  description = "CodeCommit repo name for governance policies"
  type        = string
  default     = "governance"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# S3 bucket for governance artifacts (graduation policy, red-team suites, Cedar policies)
resource "aws_s3_bucket" "governance" {
  bucket = "governance-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Platform    = "eap"
    Component   = "governance"
    Environment = var.environment
    Owner       = "ai-governance"
  }
}

resource "aws_s3_bucket_versioning" "governance" {
  bucket = aws_s3_bucket.governance.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "governance" {
  bucket = aws_s3_bucket.governance.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "governance" {
  bucket = aws_s3_bucket.governance.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

# Outputs for cross-module consumption
output "governance_bucket_name" {
  value       = aws_s3_bucket.governance.id
  description = "S3 bucket name for governance artifacts"
}

output "governance_bucket_arn" {
  value       = aws_s3_bucket.governance.arn
  description = "S3 bucket ARN for governance artifacts"
}

output "graduation_policy_s3_uri" {
  value       = "s3://${aws_s3_bucket.governance.id}/graduation-policy.yaml"
  description = "Full S3 URI for the graduation policy (read by agent pipeline gate stage)"
}
