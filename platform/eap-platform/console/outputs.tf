output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for cache invalidation"
  value       = aws_cloudfront_distribution.console.id
}

output "cloudfront_domain_name" {
  description = "CloudFront domain name for the console"
  value       = aws_cloudfront_distribution.console.domain_name
}

output "s3_bucket_name" {
  description = "S3 bucket name for static site deployment"
  value       = aws_s3_bucket.console.id
}

output "identity_pool_id" {
  description = "Cognito Identity Pool ID for browser credential exchange. Null when an external OIDC IdP is used (ADR-028)."
  value       = one(aws_cognito_identity_pool.console[*].id)
}

output "console_admin_username" {
  description = "Demo console Cognito admin username (Cognito path only; null under an external IdP)."
  value       = local.create_console_admin ? local.console_admin_username : null
}

output "console_admin_secret_arn" {
  description = "Secrets Manager ARN holding the demo console admin login (username + password). Read it to sign in to the console. Null under an external IdP."
  value       = local.create_console_admin ? aws_secretsmanager_secret.console_admin[0].arn : null
}
