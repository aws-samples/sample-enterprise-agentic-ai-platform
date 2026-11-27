# EAP Pipeline Module — Outputs

output "pipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.agent_deploy.name
}

output "pipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.agent_deploy.arn
}

output "artifacts_bucket" {
  description = "S3 bucket for pipeline artifacts"
  value       = aws_s3_bucket.artifacts.bucket
}

output "codebuild_role_arn" {
  description = "ARN of the CodeBuild service role. Resolves to the deployer-supplied codebuild_role_arn when set (ADR-033), else the module-created role."
  value       = local.codebuild_role_arn
}
