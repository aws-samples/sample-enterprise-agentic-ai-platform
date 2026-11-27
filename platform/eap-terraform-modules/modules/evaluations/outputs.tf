# EAP Evaluations Module — Outputs

output "schedule_rule_arn" {
  description = "CloudWatch Event Rule ARN for evaluation schedule"
  value       = aws_cloudwatch_event_rule.eval_schedule.arn
}

output "name" {
  description = "Name of the evaluation configuration"
  value       = var.name
}

output "domain" {
  description = "Domain this evaluation config belongs to"
  value       = var.domain
}

output "runtime_id" {
  description = "Runtime ID being evaluated"
  value       = var.runtime_id
}

output "evaluator_names" {
  description = "List of enabled evaluator names"
  value       = [for e in var.evaluators : e.name if e.enabled]
}
