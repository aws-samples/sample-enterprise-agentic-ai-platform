# EAP Policy Module — Outputs

output "policy_s3_key" {
  description = "S3 key of the Cedar policy document"
  value       = aws_s3_object.policy_document.key
}

output "policy_s3_version_id" {
  description = "S3 version ID of the Cedar policy document"
  value       = aws_s3_object.policy_document.version_id
}

output "name" {
  description = "Name of the policy set"
  value       = var.name
}

output "domain" {
  description = "Domain this policy applies to"
  value       = var.domain
}

output "scope" {
  description = "Policy scope"
  value       = var.scope
}

output "policy_count" {
  description = "Number of Cedar policies in this set"
  value       = length(local.all_policies)
}
