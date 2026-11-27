# EAP Commit Validation Module — Main
# Deploys a Lambda function that enforces Conventional Commits on CodeCommit pushes.
# Attached as a trigger on referenceUpdated events for all team repositories.
# Fail-open: if Lambda errors, pushes proceed; CloudWatch alarm alerts platform team.
# Requirements: R10.4, R10.7, R10.8

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  region        = data.aws_region.current.id
  function_name = "eap-commit-validation"

  tags = merge(var.tags, {
    "eap:component" = "commit-validation"
    "eap:managed"   = "true"
  })
}

# ---------------------------------------------------------------------------
# Lambda Deployment Package — zip the validation script
# ---------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../scripts/validate_commit_message.py"
  output_path = "${path.module}/lambda_package.zip"
}

# ---------------------------------------------------------------------------
# IAM — Lambda execution role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ADR-033: create the role + its policies only when no pre-created ARN is
# supplied; otherwise the Lambda uses the supplied ARN.
locals {
  create_role = var.role_arn == ""
  role_arn    = local.create_role ? aws_iam_role.lambda[0].arn : var.role_arn
}

resource "aws_iam_role" "lambda" {
  count = local.create_role ? 1 : 0

  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "lambda_policy" {
  # CloudWatch Logs — write permissions
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.function_name}:*"]
  }

  # CodeCommit — read permissions for commit inspection
  statement {
    effect = "Allow"
    actions = [
      "codecommit:GetCommit",
      "codecommit:GetRepository",
    ]
    resources = var.codecommit_repo_arns
  }

  # CloudWatch — PutMetricData for fail-open alerting
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["EAP/CommitValidation"]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  count = local.create_role ? 1 : 0

  name   = "${local.function_name}-policy"
  role   = aws_iam_role.lambda[0].id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

# ---------------------------------------------------------------------------
# Lambda Function — Commit Validation
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "commit_validation" {
  function_name    = local.function_name
  description      = "Enforces Conventional Commits on CodeCommit pushes (fail-open)"
  role             = local.role_arn
  handler          = "validate_commit_message.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # ADR-032: run in the enterprise VPC when the platform is in VPC mode so the
  # CodeCommit reads resolve via the VPC endpoint. Omitted (null) in PUBLIC mode.
  dynamic "vpc_config" {
    for_each = var.vpc_config != null ? [var.vpc_config] : []
    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  tags = local.tags
}

# ADR-032: ENI-management permissions required for a Lambda running in-VPC.
# Attached only in VPC mode (kept least-privilege otherwise). ENI mutations are
# scoped to network interfaces in this account/region plus the configured
# subnets / security groups; ec2:DescribeNetworkInterfaces has no resource
# type, so the API requires Resource = "*".
resource "aws_iam_role_policy" "lambda_vpc" {
  # ADR-032 (VPC mode) AND ADR-033 (only when the module owns the role).
  count = var.vpc_config != null && local.create_role ? 1 : 0

  name = "${local.function_name}-vpc-eni"
  role = aws_iam_role.lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaVpcEniCreate"
        Effect = "Allow"
        Action = ["ec2:CreateNetworkInterface"]
        Resource = concat(
          ["arn:${data.aws_partition.current.partition}:ec2:${local.region}:${local.account_id}:network-interface/*"],
          [for id in try(var.vpc_config.subnet_ids, []) : "arn:${data.aws_partition.current.partition}:ec2:${local.region}:${local.account_id}:subnet/${id}"],
          [for id in try(var.vpc_config.security_group_ids, []) : "arn:${data.aws_partition.current.partition}:ec2:${local.region}:${local.account_id}:security-group/${id}"]
        )
      },
      {
        Sid    = "LambdaVpcEniManage"
        Effect = "Allow"
        Action = [
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${local.region}:${local.account_id}:network-interface/*"
      },
      {
        # ec2:DescribeNetworkInterfaces has no resource type; the API requires "*".
        Sid      = "LambdaVpcEniDescribe"
        Effect   = "Allow"
        Action   = ["ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda Permission — Allow CodeCommit to invoke
# ---------------------------------------------------------------------------
resource "aws_lambda_permission" "codecommit" {
  count         = length(var.codecommit_repo_arns)
  statement_id  = "AllowCodeCommitInvoke-${count.index}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.commit_validation.function_name
  principal     = "codecommit.amazonaws.com"
  source_arn    = var.codecommit_repo_arns[count.index]
}

# ---------------------------------------------------------------------------
# CodeCommit Trigger — Attach to each repository
# ---------------------------------------------------------------------------
resource "aws_codecommit_trigger" "commit_validation" {
  count           = length(var.codecommit_repo_arns)
  repository_name = element(split(":", var.codecommit_repo_arns[count.index]), length(split(":", var.codecommit_repo_arns[count.index])) - 1)

  trigger {
    name            = "commit-validation"
    events          = ["updateReference"]
    destination_arn = aws_lambda_function.commit_validation.arn
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Alarm — Lambda errors (fail-open alerting)
# Fires when the Lambda is erroring, meaning commits are being allowed without
# validation. Platform team must investigate.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name        = "${local.function_name}-errors"
  alarm_description = "Commit validation Lambda is failing — commits are passing without validation (fail-open)"
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.commit_validation.function_name
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = local.tags
}
