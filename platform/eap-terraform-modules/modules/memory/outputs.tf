# EAP Memory Module — Outputs

output "id" {
  description = "Unique identifier of the Memory"
  value       = aws_bedrockagentcore_memory.this.id
}

output "arn" {
  description = "ARN of the Memory"
  value       = aws_bedrockagentcore_memory.this.arn
}

output "name" {
  description = "Name of the Memory"
  value       = aws_bedrockagentcore_memory.this.name
}

output "domain" {
  description = "Domain this memory belongs to"
  value       = var.domain
}

output "memory_type" {
  description = "Type of memory (short-term, long-term, episodic)"
  value       = var.memory_type
}

output "retention_days" {
  description = "Retention period in days"
  value       = local.event_expiry_duration
}

output "strategy_ids" {
  description = "Map of strategy name to strategy ID"
  value       = { for k, v in aws_bedrockagentcore_memory_strategy.this : k => v.memory_strategy_id }
}
