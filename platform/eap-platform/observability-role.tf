# ---------------------------------------------------------------------------
# Observability_Role — least-privilege, read-only IAM role for the Console
# observability surfaces (Deep_Link_Service + Telemetry_API_Service).
# ---------------------------------------------------------------------------
# The Console_Backend assumes this role via STS and performs observability
# reads on behalf of the caller — never with the caller's own AWS identity
# (Req 5.3, 5.4). Its permissions are limited to EXACTLY the read operations
# required to serve the observability experience (Req 5.1) and it can create,
# modify, or delete NOTHING (Req 5.2).
#
# Trust (Req 5.5): sts:AssumeRole is permitted ONLY by the observability
# service Lambda execution roles. The Deep_Link_Service role (the day-one
# "View in CloudWatch" path) is trusted now; the Telemetry_API_Service role is
# added by task 4.9 by appending its ARN to var.observability_trusted_role_arns
# (or the local list below) — no rewrite of this file is required.
#
# The service Lambda execution roles are created later (Deep_Link_Service in
# task 2.14, Telemetry_API_Service in task 4.9). They are referenced here by
# their forward-known ARNs (a variable / local placeholder) so this file is
# valid and forward-compatible ahead of those roles existing.
#
# _Requirements: 5.1, 5.2, 5.5_
# ---------------------------------------------------------------------------

variable "observability_trusted_role_arns" {
  description = <<-EOT
    Additional IAM role ARNs permitted to assume the Observability_Role, in
    addition to the Deep_Link_Service execution role trusted by default. The
    Telemetry_API_Service execution role is appended here (or via the local
    below) by task 4.9 without rewriting the trust policy.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_observability_role" {
  description = <<-EOT
    Create the read-only Observability_Role. OPT-IN — defaults to false.

    The role's trust policy names the Deep_Link_Service Lambda execution role
    (deep-link-lambda-<env>) as a principal. AWS IAM rejects an assume-role
    policy that references a role principal which does not yet exist
    (MalformedPolicyDocument: Invalid principal), so this role can only be
    created once the Deep_Link_Service Lambda (task 2.14) is deployed. Enable
    this flag together with that Lambda. Leaving it false keeps the platform
    apply green before the observability service Lambdas exist.
  EOT
  type        = bool
  default     = false
}

locals {
  # Deep_Link_Service Lambda execution role (created in task 2.14). Named to
  # mirror the sibling read-only service convention (studio-read's
  # "studio-read-lambda-<environment>"): "deep-link-lambda-<environment>".
  # Referenced by its forward-known ARN so the trust policy is valid before the
  # role resource exists.
  deep_link_service_role_arn = "arn:aws:iam::${local.account_id}:role/deep-link-lambda-${var.environment}"

  # Telemetry_API_Service Lambda execution role (added in task 4.9). Kept as a
  # documented forward-reference; task 4.9 appends this ARN to the trusted set
  # via var.observability_trusted_role_arns:
  #   "arn:aws:iam::${local.account_id}:role/telemetry-api-lambda-${var.environment}"

  # The full set of principals allowed to assume the Observability_Role. Adding
  # the Telemetry_API_Service role later is a pure list append — no structural
  # change to the trust policy (Req 5.5).
  observability_trusted_principal_arns = concat(
    [local.deep_link_service_role_arn],
    var.observability_trusted_role_arns,
  )
}

resource "aws_iam_role" "observability" {
  # ADR-033: created only when enabled AND no pre-created ARN is supplied.
  count = local.create_observability_role ? 1 : 0

  name = "observability-readonly-${var.environment}"

  # Trust policy (Req 5.5): only the observability service Lambda execution
  # role(s) may assume this role. No AWS service principal, no account-wide
  # trust — just the explicit, forward-known service role ARN(s).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowObservabilityServicesAssume"
        Effect = "Allow"
        Principal = {
          AWS = local.observability_trusted_principal_arns
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Component = "observability"
    ManagedBy = "eap-platform"
  })
}

# Least-privilege, read-only permissions (Req 5.1, 5.2). The action set is
# EXACTLY the observability reads the console needs — CloudWatch metric reads,
# CloudWatch Logs Insights query lifecycle, and X-Ray trace reads — and nothing
# else. There are NO create/modify/delete actions and NO action wildcards
# (e.g. no "cloudwatch:*", "logs:*", or "xray:*").
#
# Resource scoping: logs:StartQuery and logs:GetQueryResults support the
# log-group resource type, so they are scoped to log groups in this
# account/region. logs:StopQuery, cloudwatch:GetMetricData (dataset resource is
# optional and not used for standard metrics) and the X-Ray read actions have no
# required resource type, so the API requires Resource = "*". Per-Business_Unit narrowing is
# applied at AssumeRole time via an inline session policy / session tags passed
# by the Deep_Link_Service (Req 4.4, 5.6), which narrows — never widens — these
# permissions.
resource "aws_iam_role_policy" "observability_readonly" {
  # ADR-033: shares the role's create gate (create only when the platform owns
  # the role; a supplied external role carries its own policy).
  count = local.create_observability_role ? 1 : 0

  name = "observability-readonly"
  role = aws_iam_role.observability[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch metric reads — session count, latency, duration, token
        # usage, error rate (Req 5.1).
        Sid    = "CloudWatchMetricRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData"
        ]
        Resource = "*"
      },
      {
        # CloudWatch Logs Insights query lifecycle — start/poll/stop only, no
        # log creation or mutation (Req 5.1, 5.2).
        Sid    = "CloudWatchLogsInsightsQuery"
        Effect = "Allow"
        Action = [
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${local.account_id}:log-group:*"
      },
      {
        # logs:StopQuery has no resource type; the API requires "*".
        Sid      = "CloudWatchLogsInsightsStopQuery"
        Effect   = "Allow"
        Action   = ["logs:StopQuery"]
        Resource = "*"
      },
      {
        # X-Ray trace reads — trace-summary list + span drill-down (Req 5.1).
        Sid    = "XRayTraceRead"
        Effect = "Allow"
        Action = [
          "xray:GetTraceSummaries",
          "xray:BatchGetTraces"
        ]
        Resource = "*"
      }
    ]
  })
}
