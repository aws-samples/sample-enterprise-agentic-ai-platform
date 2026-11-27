# EAP ECR — Image Repositories
# Provisions agent images, base image, and Terraform build image repos.
# IAM policy allows AgentCore Runtime to pull images.
# Requirements: R13.1, R13.2, R13.3

variable "repository_name" {
  type        = string
  default     = "eap-agents"
  description = "ECR repository name for agent images"
}

variable "base_image_repository_name" {
  type        = string
  default     = "eap-agents-base-strands"
  description = "ECR repository name for the pre-built base image"
}

variable "terraform_image_repository_name" {
  type        = string
  default     = "eap-terraform"
  description = "ECR repository name for the Terraform build image used by CodeBuild"
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.id

  tags = merge(var.tags, {
    "eap:managed"   = "true"
    "eap:component" = "ecr"
  })
}

# ---------------------------------------------------------------------------
# ECR Repository — agent images (per-agent tags pushed by CodePipeline)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "agents" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS-managed aws/ecr key
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "agents" {
  repository = aws_ecr_repository.agents.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# ECR Repository — base image (platform-owned, built from eap-terraform-modules)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "base_image" {
  name                 = var.base_image_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS-managed aws/ecr key
  }

  tags = merge(local.tags, {
    "eap:component" = "base-image"
  })
}

resource "aws_ecr_lifecycle_policy" "base_image" {
  repository = aws_ecr_repository.base_image.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# ECR Repository — Terraform build image (used by CodeBuild deploy stages)
# Contains hashicorp/terraform + aws-cli, avoids Docker Hub rate limits.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "terraform" {
  name                 = var.terraform_image_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS-managed aws/ecr key
  }

  tags = merge(local.tags, {
    "eap:component" = "build-image"
  })
}

# Allow CodeBuild to pull the terraform build image
resource "aws_ecr_repository_policy" "terraform_codebuild" {
  repository = aws_ecr_repository.terraform.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CodeBuildAccess"
        Effect    = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "terraform" {
  repository = aws_ecr_repository.terraform.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["1."]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "repository_url" {
  description = "ECR repository URL for agent images"
  value       = aws_ecr_repository.agents.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.agents.arn
}

output "repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.agents.name
}

output "base_image_repository_url" {
  description = "ECR repository URL for base images"
  value       = aws_ecr_repository.base_image.repository_url
}

output "base_image_repository_arn" {
  description = "ECR repository ARN for base images"
  value       = aws_ecr_repository.base_image.arn
}

output "terraform_image_repository_url" {
  description = "ECR repository URL for Terraform build image"
  value       = aws_ecr_repository.terraform.repository_url
}

output "terraform_image_repository_arn" {
  description = "ECR repository ARN for Terraform build image"
  value       = aws_ecr_repository.terraform.arn
}
