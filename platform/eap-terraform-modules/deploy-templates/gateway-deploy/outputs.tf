# Gateway Deploy Template — Outputs

output "gateway_id" {
  description = "Gateway ID (read from platform state)"
  value       = local.gateway_id
}

output "mcp_target_ids" {
  description = "Map of MCP target name to target ID"
  value       = { for k, v in aws_bedrockagentcore_gateway_target.mcp : k => v.target_id }
}

output "rest_target_ids" {
  description = "Map of REST target name to target ID"
  value       = { for k, v in aws_bedrockagentcore_gateway_target.rest : k => v.target_id }
}
