# QA Pipeline Module — Outputs

output "pipeline_arn" {
  description = "CodePipeline ARN"
  value       = aws_codepipeline.this.arn
}

output "repository_arn" {
  description = "CodeCommit repository ARN"
  value       = aws_codecommit_repository.this.arn
}

output "ground_truth_bucket" {
  description = "S3 bucket for ground truth datasets"
  value       = var.ground_truth_bucket
}
