# EAP Platform — Domain Provisioning
# Provisions EAP domains with Cognito group + IAM permission boundary.
# Each domain is an isolation boundary for agents.
# Requirements: R17.1, R17.2, R17.3, R17.6, R17.7

variable "environment" {
  type    = string
  default = "dev"
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito User Pool ID from the identity module. Empty when an external OIDC IdP is used (ADR-028) — the per-domain Cognito group is then skipped; the IAM permission boundary (IdP-independent) still applies."
  default     = ""
}

variable "create_cognito_group" {
  type        = bool
  description = "Whether to create the per-domain Cognito user group. True on the platform-Cognito path; false under an external OIDC IdP (ADR-028). Known at plan time (unlike cognito_user_pool_id, which is only known at apply), so it is safe for for_each."
  default     = true
}

variable "domains" {
  type = map(object({
    description    = optional(string, "")
    allowed_models = optional(list(string), [])
  }))
  default = {
    team-bu-1 = {
      description    = "Business Unit 1 — Agentic AI agents"
      allowed_models = ["us.anthropic.claude-sonnet-5"]
    }
  }
  description = "Map of domain names to their configuration"
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Cognito User Group per domain — agents in this domain belong to this group
# ---------------------------------------------------------------------------
# Created only when the platform provisions Cognito (pool id non-empty). Under
# an external IdP, domain-to-group mapping is the IdP's responsibility (ADR-028).
resource "aws_cognito_user_group" "domain" {
  for_each = var.create_cognito_group ? var.domains : {}

  name         = each.key
  user_pool_id = var.cognito_user_pool_id
  description  = "EAP domain: ${each.key}. ${each.value.description}"
}

# ---------------------------------------------------------------------------
# IAM Permission Boundary per domain — scopes what agents can do
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "domain_boundary" {
  for_each = var.domains

  name        = "eap-domain-boundary-${each.key}-${var.environment}"
  path        = "/eap/domains/"
  description = "Permission boundary for EAP domain: ${each.key}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockInvocation"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          for model_id in each.value.allowed_models :
          "arn:aws:bedrock:*::foundation-model/${model_id}"
        ]
      },
      {
        Sid      = "AllowAgentCoreOperations"
        Effect   = "Allow"
        Action   = ["bedrockagentcore:*"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/eap_domain" = each.key
          }
        }
      },
      {
        Sid    = "AllowECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:repository/*"
      },
      {
        # ecr:GetAuthorizationToken has no resource type; the API requires "*".
        Sid      = "AllowECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "AllowLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/eap/${each.key}/*"
      },
    ]
  })

  tags = merge(var.tags, {
    eap_module = "domain"
    eap_domain = each.key
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "domain_cognito_groups" {
  description = "Map of domain name to Cognito group name"
  value       = { for k, v in aws_cognito_user_group.domain : k => v.name }
}

output "domain_boundary_arns" {
  description = "Map of domain name to IAM permission boundary ARN"
  value       = { for k, v in aws_iam_policy.domain_boundary : k => v.arn }
}
