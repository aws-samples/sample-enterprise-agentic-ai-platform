# EAP Evaluations Module — Main
# Manages agent quality evaluation configuration
# Requirements: R7.1, R7.2, R7.3
#
# NOTE: This module uses an SSM + CloudWatch workaround because the
# Terraform AWS provider does not yet have native AgentCore evaluation resources.
# CloudFormation has AWS::BedrockAgentCore::Evaluator and
# AWS::BedrockAgentCore::OnlineEvaluationConfig — when Terraform equivalents
# land, rewrite this module to use them so evaluations appear in the AgentCore
# console.

locals {
  module_tags = merge(var.tags, {
    eap_module = "evaluations"
    eap_domain = var.domain
  })

  # Build evaluator config map
  evaluator_config = {
    for e in var.evaluators : e.name => {
      name      = e.name
      type      = "builtin"
      threshold = e.threshold
      enabled   = e.enabled
    }
  }

  custom_evaluator_config = {
    for e in var.custom_evaluators : e.name => {
      name        = e.name
      type        = "custom"
      lambda_arn  = e.lambda_arn
      description = e.description
      threshold   = e.threshold
    }
  }
}



# ---------------------------------------------------------------------------
# CloudWatch Event Rule — Evaluation schedule
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "eval_schedule" {
  name                = "eap-eval-${var.name}"
  description         = "Scheduled evaluation for ${var.name} in domain ${var.domain}"
  schedule_expression = var.schedule

  tags = local.module_tags
}
