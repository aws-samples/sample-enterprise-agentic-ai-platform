# EAP Gateway Module — Outputs

output "id" {
  description = "Unique identifier of the Gateway"
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "arn" {
  description = "ARN of the Gateway"
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}

output "url" {
  description = "URL endpoint for the gateway"
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "workload_identity_arn" {
  description = "ARN of the workload identity for this gateway"
  value       = try(aws_bedrockagentcore_gateway.this.workload_identity_details[0].workload_identity_arn, null)
}

output "domain" {
  description = "Domain this gateway belongs to"
  value       = var.domain
}

output "lambda_target_ids" {
  description = "Map of lambda target name to target ID (FUTURE — lambda targets parked)"
  value       = {}
}

output "mcp_server_target_ids" {
  description = "Map of MCP server target name to target ID"
  value       = { for k, v in aws_bedrockagentcore_gateway_target.mcp_server : k => v.target_id }
}

output "policy_engine_id" {
  description = "Policy engine ID (for governance repo to attach Cedar policies)"
  value       = var.enable_policy_engine ? aws_bedrockagentcore_policy_engine.this[0].policy_engine_id : null
}

output "policy_engine_arn" {
  description = "Policy engine ARN"
  value       = var.enable_policy_engine ? aws_bedrockagentcore_policy_engine.this[0].policy_engine_arn : null
}
