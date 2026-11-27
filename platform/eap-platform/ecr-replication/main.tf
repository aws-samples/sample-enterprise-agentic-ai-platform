# Cross-Account ECR Replication — Agent School
# Replicates agent images from non-prod to prod account.
# Images are built once in non-prod, promoted by tag to prod.
#
# Owner: Platform Operator
# Trigger: Gate stage marks image as prod-eligible → replication picks it up
#
# Note: ECR replication is configured at the registry level (account-wide).
# It replicates ALL images matching the filter to the destination.
# Use prefix filters to scope to agent images only.

variable "prod_account_id" {
  description = "AWS account ID for the production environment"
  type        = string
}

variable "prod_region" {
  description = "AWS region for the production environment"
  type        = string
  default     = "us-east-1"
}

variable "ecr_repo_prefix" {
  description = "ECR repository name prefix to replicate (e.g., 'eap-agents')"
  type        = string
  default     = "eap-agents"
}

# ECR Replication Configuration
# Replicates images from this account's ECR to the prod account's ECR.
# Only images in repos matching the prefix filter are replicated.
resource "aws_ecr_replication_configuration" "cross_account" {
  replication_configuration {
    rule {
      destination {
        region      = var.prod_region
        registry_id = var.prod_account_id
      }

      repository_filter {
        filter      = var.ecr_repo_prefix
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

# The prod account must grant permission for the non-prod account to replicate.
# This resource should be applied in the PROD account (or via cross-account role).
# For now, output the policy that needs to be applied in prod.
output "prod_ecr_permission_policy" {
  description = "IAM policy to apply in the prod account's ECR registry to allow replication from non-prod"
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCrossAccountReplication"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "ecr:CreateRepository",
          "ecr:ReplicateImage"
        ]
        Resource = "arn:aws:ecr:${var.prod_region}:${var.prod_account_id}:repository/${var.ecr_repo_prefix}*"
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

output "replication_status" {
  value       = "ECR replication configured: ${var.ecr_repo_prefix}* → ${var.prod_account_id} (${var.prod_region})"
  description = "Summary of replication configuration"
}
