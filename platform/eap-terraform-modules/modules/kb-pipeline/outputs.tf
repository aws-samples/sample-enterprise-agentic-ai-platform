# KB Pipeline Module — Outputs

output "repository_arn" {
  description = "CodeCommit repository ARN"
  value       = aws_codecommit_repository.this.arn
}

output "pipeline_arn" {
  description = "CodePipeline ARN"
  value       = aws_codepipeline.this.arn
}

output "artifacts_bucket_id" {
  description = "S3 artifacts bucket ID"
  value       = aws_s3_bucket.artifacts.id
}
