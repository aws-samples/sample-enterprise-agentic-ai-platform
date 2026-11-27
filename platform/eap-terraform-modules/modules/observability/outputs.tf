# EAP Observability Module — Outputs

output "log_group_name" {
  description = "CloudWatch log group name for agent logs"
  value       = aws_cloudwatch_log_group.agents.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.agents.arn
}

output "otel_endpoint" {
  description = "OTLP exporter endpoint"
  value       = var.otel_endpoint
}

output "otel_resource_attributes" {
  description = "OTel resource attributes string for env var injection"
  value       = local.otel_resource_attributes_string
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = var.create_dashboard ? aws_cloudwatch_dashboard.this[0].dashboard_name : null
}

output "domain" {
  description = "Domain this observability config applies to"
  value       = var.domain
}
