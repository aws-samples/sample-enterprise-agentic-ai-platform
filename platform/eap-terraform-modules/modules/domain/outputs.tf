# EAP Domain Module — Outputs
# Requirements: R17.1, R17.2, R17.3

locals {
  boundary_policy_arn = var.iam_boundary.create ? aws_iam_policy.boundary[0].arn : var.iam_boundary.policy_arn
  ecr_repository_url  = var.ecr_config.create_repo ? aws_ecr_repository.domain[0].repository_url : null
}

output "name" {
  value       = var.name
  description = "Domain name"
}

output "idp_group_name" {
  value       = local.idp_group_name
  description = "IdP group name for this domain (agents auto-join on deploy)"
}

output "boundary_policy_arn" {
  value       = local.boundary_policy_arn
  description = "IAM permission boundary ARN for this domain"
}

output "ecr_repository_url" {
  value       = local.ecr_repository_url
  description = "ECR repository URL for this domain's container images"
}

output "ecr_repository_arn" {
  value       = var.ecr_config.create_repo ? aws_ecr_repository.domain[0].arn : null
  description = "ECR repository ARN"
}

output "isolation_policy_key" {
  value       = aws_s3_object.domain_isolation_policy.key
  description = "S3 key for the domain isolation Cedar policy"
}
