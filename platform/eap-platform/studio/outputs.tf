# Agent Deployment Engineer — Module Outputs

output "runtime_id" {
  description = "Studio AgentCore runtime ID"
  value       = module.runtime.id
}

# Construct the runtime ARN from the runtime ID. The runtime module intentionally
# does not expose an `arn` output (avoids a Terraform graph cycle), so we build it
# from the well-known ARN format:
#   arn:aws:bedrock-agentcore:<region>:<account>:runtime/<runtimeId>
output "runtime_arn" {
  description = "Studio AgentCore runtime ARN (target for the invoke proxy)"
  value       = "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:runtime/${module.runtime.id}"
}

output "endpoint_arn" {
  description = "Studio AgentCore runtime endpoint ARN"
  value       = module.runtime.endpoint_arn
}

output "endpoint_qualifier" {
  description = "Studio runtime endpoint qualifier (e.g., <name>_endpoint)"
  value       = "${module.runtime.name}_endpoint"
}

output "memory_id" {
  description = "Studio AgentCore memory ID"
  value       = module.memory.id
}
