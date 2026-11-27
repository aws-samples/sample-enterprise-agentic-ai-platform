# Studio-Read Backend module — outputs

output "alb_dns_name" {
  description = "DNS name of the studio-read backend ALB. Demo: consumed by the console CloudFront as the /api/* origin. Enterprise: the internal ALB hostname the BYO UI calls."
  value       = aws_lb.backend.dns_name
}

output "alb_internal" {
  description = "Whether the ALB is internal. Always true: the demo reaches it through a CloudFront VPC origin."
  value       = aws_lb.backend.internal
}

output "origin_secret_header_name" {
  description = "Header name CloudFront must inject for the ALB to forward (public_edge only)."
  value       = var.cloudfront_origin_secret_header
}

output "origin_secret_value" {
  description = "Secret value CloudFront must send in the origin header (public_edge only; empty when internal)."
  value       = local.origin_secret_value
  sensitive   = true
}

output "backend_ecr_repository_url" {
  description = "ECR repository URL for the studio-read backend image."
  value       = aws_ecr_repository.backend.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster running the studio-read backend."
  value       = aws_ecs_cluster.this.name
}

output "backend_service_name" {
  description = "ECS service name for the studio-read backend."
  value       = aws_ecs_service.backend.name
}

output "vpc_origin_id" {
  description = "CloudFront VPC origin ID for the studio-read ALB (public_edge only; empty when internal-only)."
  value       = var.public_edge ? aws_cloudfront_vpc_origin.alb[0].id : ""
}
