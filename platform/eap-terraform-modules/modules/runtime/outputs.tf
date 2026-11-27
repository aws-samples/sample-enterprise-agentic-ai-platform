# EAP Runtime Module — Outputs
# Only expose outputs that are consumed by callers.
# Unused outputs (arn, version, workload_identity_arn) removed to avoid
# Terraform graph cycles in newer versions (1.14+).

output "id" {
  description = "Unique identifier of the Agent Runtime"
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
}

output "endpoint_arn" {
  description = "ARN of the Agent Runtime Endpoint"
  value       = aws_bedrockagentcore_agent_runtime_endpoint.this.agent_runtime_endpoint_arn
}

output "protocols" {
  description = "Protocols enabled for this runtime"
  value       = var.protocols
}

output "domain" {
  description = "Domain this runtime belongs to"
  value       = var.domain
}

output "name" {
  description = "Name of the runtime"
  value       = var.name
}
