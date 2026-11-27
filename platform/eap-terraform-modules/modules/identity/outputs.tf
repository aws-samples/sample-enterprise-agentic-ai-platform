# EAP Identity Module — Outputs

output "workload_identity_arn" {
  description = "ARN of the Workload Identity"
  value       = aws_bedrockagentcore_workload_identity.this.workload_identity_arn
}

output "name" {
  description = "Name of the Workload Identity"
  value       = aws_bedrockagentcore_workload_identity.this.name
}

output "domain" {
  description = "Domain this identity belongs to"
  value       = var.domain
}

output "oauth2_provider_arns" {
  description = "Map of OAuth2 provider name to ARN"
  value       = { for k, v in aws_bedrockagentcore_oauth2_credential_provider.this : k => v.credential_provider_arn }
}

output "api_key_provider_arns" {
  description = "Map of API key provider name to ARN"
  value       = { for k, v in aws_bedrockagentcore_api_key_credential_provider.this : k => v.credential_provider_arn }
}
