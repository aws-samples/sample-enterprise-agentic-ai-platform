# EAP Langfuse_Stack Module — Outputs

output "cluster_arn" {
  description = "ECS cluster ARN running the Langfuse services"
  value       = local.cluster_arn
}

output "web_service_name" {
  description = "Name of the Langfuse web ECS service"
  value       = aws_ecs_service.web.name
}

output "worker_service_name" {
  description = "Name of the Langfuse worker ECS service"
  value       = aws_ecs_service.worker.name
}

output "clickhouse_service_name" {
  description = "Name of the ClickHouse ECS service"
  value       = aws_ecs_service.clickhouse.name
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------
output "alb_dns_name" {
  description = "Internal DNS name of the private Langfuse ALB (ADR-030: HTTP, VPC-internal)"
  value       = aws_lb.langfuse.dns_name
}

output "alb_arn" {
  description = "ARN of the Langfuse ALB"
  value       = aws_lb.langfuse.arn
}

output "http_listener_arn" {
  description = "ARN of the Langfuse ALB internal HTTP listener"
  value       = aws_lb_listener.http.arn
}

output "web_target_group_arn" {
  description = "ARN of the Langfuse web target group"
  value       = aws_lb_target_group.web.arn
}

output "langfuse_base_url" {
  description = "Private internal base URL for Langfuse (http://<internal-alb-dns>:<port>) — NEXTAUTH_URL and the on-network console embed origin (ADR-030)"
  value       = local.nextauth_url
}

output "langfuse_otlp_endpoint" {
  description = "Langfuse OTLP receiver endpoint the OTel Collector exports to (internal, HTTP)"
  value       = "${local.nextauth_url}/api/public/otel"
}

output "langfuse_init_user_email" {
  description = "Email of the headless-init Langfuse admin/owner user (log in with this + the generated password secret)."
  value       = var.langfuse_init_user_email
}

output "langfuse_init_user_password_secret_arn" {
  description = "Secrets Manager ARN holding the generated Langfuse admin/owner password. Read it to log into the UI: aws secretsmanager get-secret-value --secret-id <arn>."
  value       = aws_secretsmanager_secret.langfuse_init_user_password.arn
}

# ---------------------------------------------------------------------------
# Per-BU Langfuse project bindings (task 10.1 — Requirement 14.1)
#
# One `LangfuseProjectBinding` per Business_Unit, keyed by `bu`, matching the
# TypeScript `LangfuseProjectBinding` type
# (platform/eap-platform/observability/src/lib/types.ts):
#   { bu, projectId, publicKeyRef, secretKeyRef, otlpBasicAuthRef }
# The refs are Secrets Manager ARNs (never plaintext keys). The OTel_Collector
# per-BU routing (task 10.2) consumes these together with langfuse_otlp_endpoint.
# ---------------------------------------------------------------------------
output "langfuse_project_bindings" {
  description = "Map of Business_Unit -> LangfuseProjectBinding { bu, projectId, publicKeyRef (secret ARN), secretKeyRef (secret ARN), otlpBasicAuthRef (secret ARN) }. One distinct project + key set per BU (R14.1)."
  value = {
    for bu, u in local.business_unit_map : bu => {
      bu               = bu
      projectId        = local.langfuse_project_ids[bu]
      publicKeyRef     = aws_secretsmanager_secret.langfuse_project_public_key[bu].arn
      secretKeyRef     = aws_secretsmanager_secret.langfuse_project_secret_key[bu].arn
      otlpBasicAuthRef = aws_secretsmanager_secret.langfuse_project_otlp_basic_auth[bu].arn
    }
  }
}

# ---------------------------------------------------------------------------
# Datastores
# ---------------------------------------------------------------------------
output "aurora_cluster_endpoint" {
  description = "Aurora PostgreSQL writer endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora PostgreSQL reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "clickhouse_host" {
  description = "In-VPC Cloud Map DNS name of the ClickHouse service"
  value       = local.clickhouse_host
}

output "redis_primary_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "blob_bucket_name" {
  description = "S3 bucket for Langfuse event/media blobs"
  value       = aws_s3_bucket.blobs.bucket
}

output "blob_bucket_arn" {
  description = "ARN of the S3 bucket for Langfuse event/media blobs"
  value       = aws_s3_bucket.blobs.arn
}

# ---------------------------------------------------------------------------
# Security groups (task 8.2 hardening reference)
# ---------------------------------------------------------------------------
output "web_security_group_id" {
  description = "Security group ID of the Langfuse web service"
  value       = aws_security_group.web.id
}

output "worker_security_group_id" {
  description = "Security group ID of the Langfuse worker service"
  value       = aws_security_group.worker.id
}

output "alb_security_group_id" {
  description = "Security group ID of the Langfuse_ALB"
  value       = aws_security_group.alb.id
}

# ---------------------------------------------------------------------------
# Secrets (Secrets Manager ARNs — task 8.2 least-privilege reference)
# ---------------------------------------------------------------------------
output "database_url_secret_arn" {
  description = "Secrets Manager ARN holding the Langfuse DATABASE_URL"
  value       = aws_secretsmanager_secret.database_url.arn
}

output "encryption_key_secret_arn" {
  description = "Secrets Manager ARN holding the Langfuse ENCRYPTION_KEY"
  value       = aws_secretsmanager_secret.langfuse_encryption_key.arn
}

output "salt_secret_arn" {
  description = "Secrets Manager ARN holding the Langfuse SALT"
  value       = aws_secretsmanager_secret.langfuse_salt.arn
}

output "vpc_origin_id" {
  description = "CloudFront VPC origin ID for the Langfuse ALB (enable_cloudfront_origin only; empty otherwise)."
  value       = var.enable_cloudfront_origin ? aws_cloudfront_vpc_origin.alb[0].id : ""
}
