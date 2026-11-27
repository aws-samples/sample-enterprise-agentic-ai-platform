# EAP Orchestration Module — Main
# Creates an AWS Step Functions state machine for multi-agent orchestration.
# Maps application.yaml topology → ASL → Step Functions state machine.
# Requirements: R31.3, R31.4, R31.5, R31.7, R31.8, R31.10

locals {
  module_tags = merge(var.tags, {
    managed_by          = "eap"
    eap_module          = "orchestration"
    eap_domain          = var.domain
    "eap:application"   = var.app_name
    "eap:orchestration" = "step-functions"
  })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# IAM Role — allows Step Functions to invoke AgentCore Runtimes
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy" "sfn_invoke" {
  name = "${var.name}-sfn-invoke"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeAgentCoreRuntimes"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:InvokeRuntime"]
        Resource = var.runtime_arns
      },
      {
        Sid      = "InvokeBridgeLambda"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.invoke_bridge_lambda_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Log Group — execution logging
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.domain}/${var.app_name}"
  retention_in_days = var.log_group_retention_days
  tags              = local.module_tags
}

# ---------------------------------------------------------------------------
# Step Functions State Machine
# ---------------------------------------------------------------------------
resource "aws_sfn_state_machine" "this" {
  name       = var.name
  role_arn   = aws_iam_role.sfn.arn
  definition = var.definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.module_tags
}
