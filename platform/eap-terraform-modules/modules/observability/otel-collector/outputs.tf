# EAP OTel_Collector Module — Outputs

output "cluster_arn" {
  description = "ECS cluster ARN running the collector service"
  value       = local.cluster_arn
}

output "service_name" {
  description = "Name of the ECS Fargate collector service"
  value       = aws_ecs_service.collector.name
}

output "task_definition_arn" {
  description = "ARN of the collector task definition"
  value       = aws_ecs_task_definition.collector.arn
}

output "task_role_arn" {
  description = "IAM task role ARN used by the collector (export identity)"
  value       = local.task_role_arn
}

output "security_group_id" {
  description = "Security group ID for the collector OTLP receiver"
  value       = aws_security_group.collector.id
}

output "log_group_name" {
  description = "CloudWatch log group for the collector container logs"
  value       = aws_cloudwatch_log_group.collector.name
}

output "service_discovery_endpoint" {
  description = "In-VPC Cloud Map DNS name of the collector OTLP receiver, or null when service discovery is disabled"
  value       = var.enable_service_discovery ? "${var.name}.${var.service_discovery_namespace}" : null
}

output "nlb_dns_name" {
  description = "Internal NLB DNS name for the collector OTLP receiver, or null when the NLB is disabled"
  value       = var.enable_internal_nlb ? aws_lb.collector[0].dns_name : null
}

output "otlp_grpc_endpoint" {
  description = "In-VPC OTLP/gRPC endpoint for the third-party leg. The runtime module wires this into the base-image Additional_Span_Exporter via EAP_OTEL_COLLECTOR_ENDPOINT (NOT OTEL_EXPORTER_OTLP_ENDPOINT, which stays as AgentCore configures it for the AWS-native leg)."
  value = var.enable_service_discovery ? "http://${var.name}.${var.service_discovery_namespace}:${var.otlp_grpc_port}" : (
    var.enable_internal_nlb ? "http://${aws_lb.collector[0].dns_name}:${var.otlp_grpc_port}" : null
  )
}

output "otlp_http_endpoint" {
  description = "In-VPC OTLP/HTTP endpoint for the third-party leg (base-image Additional_Span_Exporter target via EAP_OTEL_COLLECTOR_ENDPOINT)."
  value       = var.enable_service_discovery ? "http://${var.name}.${var.service_discovery_namespace}:${var.otlp_http_port}" : null
}

output "collector_config_yaml" {
  description = "The rendered THIRD-PARTY-ONLY collector config YAML (tasks 7.3 + 7.6) delivered to the container via AOT_CONFIG_CONTENT. Contains an OTLP receiver + third-party pipeline(s); ZERO AWS-native exporters/pipelines."
  value       = local.collector_config_yaml
}

output "third_party_exporter_names" {
  description = "The rendered `otlphttp/<name>` third-party exporter keys (per-BU `otlphttp/langfuse-<bu>` when langfuse_project_bindings is set, else the default resolved set). Every entry is a third-party OTLP exporter — never an AWS-native exporter."
  value       = keys(local.collector_config.exporters)
}
