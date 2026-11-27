# Examples Console backend module — outputs (ADR-037)
# Consumed by the console distribution (Path 1 / C2) to add the examples ALB
# origin (/examples-api/*), attach the WAF, and inject the secret origin header.

output "alb_dns_name" {
  description = "DNS name of the examples ALB (reachable only via CloudFront)."
  value       = aws_lb.backend.dns_name
}

output "origin_secret_header_name" {
  description = "Header name CloudFront must inject for the ALB to forward (origin lockdown)."
  value       = local.origin_secret_header
}

output "origin_secret_value" {
  description = "Secret value CloudFront must send in the origin header."
  value       = random_password.origin_secret.result
  sensitive   = true
}

output "waf_web_acl_arn" {
  description = "ARN of the CLOUDFRONT-scope WAF WebACL to attach to the console distribution."
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "backend_ecr_repository_url" {
  description = "ECR repository URL for the examples backend image."
  value       = aws_ecr_repository.backend.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster running the examples backend."
  value       = aws_ecs_cluster.this.name
}

output "backend_service_name" {
  description = "ECS service name for the examples backend."
  value       = aws_ecs_service.backend.name
}

output "langfuse_cloudfront_domain" {
  description = "Domain of the dedicated hardened CloudFront distribution fronting Langfuse (ADR-039). Empty when no Langfuse ALB is supplied. The console embeds https://<this>."
  value       = var.langfuse_alb_dns != "" ? aws_cloudfront_distribution.langfuse[0].domain_name : ""
}

output "vpc_origin_id" {
  description = "CloudFront VPC origin ID for the examples ALB (consumed by the console distribution)."
  value       = aws_cloudfront_vpc_origin.alb.id
}
