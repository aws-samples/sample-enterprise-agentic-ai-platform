# QA Deploy Template — Outputs

output "evaluator_arns" {
  description = "Map of app_name to evaluator ARN"
  value       = { for k, v in aws_bedrockagentcore_evaluator.qa_evaluator : k => v.arn }
}

output "evaluator_names" {
  description = "Map of app_name to evaluator name"
  value       = { for k, v in aws_bedrockagentcore_evaluator.qa_evaluator : k => v.name }
}

output "ground_truth_uris" {
  description = "Map of app_name to S3 URI for ground truth datasets"
  value = {
    for k, v in aws_s3_object.ground_truth : k => "s3://${v.bucket}/${v.key}"
  }
}

output "domain" {
  description = "Business unit domain"
  value       = var.domain
}

output "repository_name" {
  description = "QA repo name"
  value       = var.repository_name
}
