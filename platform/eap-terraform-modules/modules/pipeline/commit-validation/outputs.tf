# EAP Commit Validation Module — Outputs

output "lambda_function_arn" {
  description = "ARN of the commit validation Lambda function"
  value       = aws_lambda_function.commit_validation.arn
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role. Resolves to the deployer-supplied role_arn when set (ADR-033), else the module-created role."
  value       = local.role_arn
}
