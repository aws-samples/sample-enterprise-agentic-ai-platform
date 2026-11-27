# EAP Domain Module — Main
# Provisions a federated administration boundary (multi-tenancy)
# Creates: IAM permission boundary, IdP group, Cedar isolation policies, ECR repo
# Requirements: R17.1, R17.2, R17.3, R17.6, R17.7, R15.9, R13.1

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  idp_group_name = coalesce(var.idp_config.group_name, "eap-domain-${var.name}")

  module_tags = merge(var.tags, {
    eap_module = "domain"
    eap_domain = var.name
  })
}

# ---------------------------------------------------------------------------
# IAM Permission Boundary — scopes what agents in this domain can do
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "boundary" {
  count = var.iam_boundary.create ? 1 : 0

  name        = "eap-domain-boundary-${var.name}"
  path        = "/eap/domains/"
  description = "Permission boundary for EAP domain: ${var.name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockAgentCore"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrockagentcore:*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/eap_domain" = var.name
          }
        }
      },
      {
        Sid    = "AllowECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:aws:ecr:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:repository/eap-${var.name}/*"
      },
      {
        Sid    = "AllowLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/eap/${var.name}/*"
      },
      {
        Sid    = "AllowS3StateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::eap-state-${data.aws_caller_identity.current.account_id}/${var.name}/*",
          "arn:aws:s3:::eap-state-${data.aws_caller_identity.current.account_id}",
        ]
      },
      {
        Sid      = "DenyOtherDomains"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:ResourceTag/eap_domain" = [var.name, ""]
          }
          "ForAnyValue:StringLike" = {
            "aws:ResourceTag/eap_domain" = ["*"]
          }
        }
      }
    ]
  })

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Cedar Domain Isolation Policy — agents in this domain cannot access other domains
# ---------------------------------------------------------------------------
resource "aws_s3_object" "domain_isolation_policy" {
  bucket       = var.policy_store_bucket
  key          = "${var.name}/policies/domain-isolation/policy.cedar"
  content_type = "text/plain"

  content = <<-CEDAR
    // Domain isolation policy for: ${var.name}
    // Agents in this domain can only access resources tagged with this domain.
    // Cross-domain access requires an explicit cross-domain policy.

    permit (
      principal in EAPDomain::"${var.name}",
      action,
      resource in EAPDomain::"${var.name}"
    );

    forbid (
      principal in EAPDomain::"${var.name}",
      action,
      resource
    )
    unless { resource in EAPDomain::"${var.name}" };
  CEDAR

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# ECR Repository — container image storage for this domain
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "domain" {
  count = var.ecr_config.create_repo ? 1 : 0

  name                 = "eap-${var.name}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # always on; ecr_config.scan_on_push is ignored
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS-managed aws/ecr key
  }

  tags = local.module_tags
}

resource "aws_ecr_lifecycle_policy" "domain" {
  count = var.ecr_config.create_repo ? 1 : 0

  repository = aws_ecr_repository.domain[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.ecr_config.lifecycle_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_config.lifecycle_days
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ECR repository policy — allow cross-account pull if configured
resource "aws_ecr_repository_policy" "cross_account" {
  count = var.ecr_config.create_repo && length(var.ecr_config.cross_account_pull_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.domain[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCrossAccountPull"
        Effect = "Allow"
        Principal = {
          AWS = var.ecr_config.cross_account_pull_arns
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
      }
    ]
  })
}


