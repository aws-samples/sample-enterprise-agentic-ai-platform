# EAP Deploy Template — Auto-provisions agents from agent.yaml
# This config is used by the pipeline's Deploy stage (CodeBuild).
# It discovers all uc*/*/agent.yaml manifests via fileset() and provisions
# AgentCore runtimes using the eap runtime module.
#
# All values are injected via TF_VAR_ environment variables from CodeBuild.
# App teams write YAML — this Terraform is platform-owned.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37.0"
    }
  }

  # Backend configured dynamically via -backend-config in deploy buildspec.
  # State stored in the pipeline artifacts bucket under _tfstate/ prefix.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Agent discovery — read all agent.yaml manifests from uc*/ directories
# ---------------------------------------------------------------------------
locals {
  # TEMPORARY: Scoped to uc1* only while stabilizing the full-agent pattern (memory + evals + gateway).
  # TODO: Revert to "uc*/*/agent.yaml" once UC1 is fully operational.
  agent_yamls = toset(fileset(".", "uc1*/*/agent.yaml"))
  agent_dirs  = toset([for f in local.agent_yamls : dirname(f)])

  agents = {
    for dir in local.agent_dirs : dir => merge(
      yamldecode(file("${dir}/agent.yaml")),
      {
        dir_name    = dir
        description = try(yamldecode(file("${dir}/agent-card.yaml")).description, "")
      }
    )
  }

  # Re-key by agent name for for_each (avoids collisions across UCs)
  agents_by_name = {
    for dir, agent in local.agents : agent.name => merge(agent, { dir_path = dir })
  }

  # Safe name for Terraform resource naming (underscores, no hyphens)
  agent_safe_names = {
    for name, agent in local.agents_by_name : name => replace(name, "-", "_")
  }

  # Map agent name → dir for cross-referencing (allowed_callers → Cognito client ID)
  name_to_dir = { for dir, agent in local.agents : agent.name => dir }

  # Collect all unique model IDs across agents (for IAM policy)
  all_model_ids = toset([
    for name, agent in local.agents_by_name : try(agent.model_id, var.model_id)
  ])

  # Agents that declare memory: in agent.yaml
  agents_with_memory = {
    for name, agent in local.agents_by_name : name => agent
    if try(agent.memory, null) != null
  }

  # Agents that declare evaluations: in agent.yaml
  agents_with_evaluations = {
    for name, agent in local.agents_by_name : name => agent
    if try(agent.evaluations, null) != null
  }

  # Agents that declare gateway_refs: in agent.yaml (stubbed — requires data-services)
  agents_with_gateway = {
    for name, agent in local.agents_by_name : name => agent
    if length(try(agent.gateway_refs, [])) > 0
  }
}

# ---------------------------------------------------------------------------
# IAM Role — shared by all agent runtimes in this domain
# TODO: Replace AdministratorAccess with least-privilege managed policy.
#       Current blockers: model ID ARN patterns, AgentCore-specific permissions
#       not yet fully documented.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "runtime_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.domain}-runtime-role"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
}

# Memory ARNs created by this template.
locals {
  runtime_memory_arns = [for m in module.memory : m.arn]
}
resource "aws_iam_role_policy" "runtime" {
  name = "${var.domain}-runtime-policy"
  role = aws_iam_role.runtime.id

  # AWS-documented least-privilege execution role for AgentCore Runtime.
  # Reference: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ECRImageAccess"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/*"]
      },
      {
        Sid      = "ECRTokenAccess"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "LogsCreateGroup"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"]
      },
      {
        Sid      = "LogsDescribeGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:*"]
      },
      {
        Sid      = "LogsWriteEvents"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = ["*"]
      },
      {
        Sid       = "CloudWatchMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" } }
      },
      {
        Sid    = "WorkloadIdentityTokens"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/*"
        ]
      },
      {
        Sid    = "BedrockModelInvocation"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
        ]
      },
      ],
      # AgentCore Memory data-plane access, scoped to the memories this template
      # creates (module.memory). Actions are the calls made by the Strands
      # AgentCoreMemorySessionManager (bedrock-agentcore SDK). Statement omitted
      # when no agent declares memory: (IAM rejects an empty Resource list).
      length(local.runtime_memory_arns) > 0 ? [
        {
          Sid    = "AgentCoreMemory"
          Effect = "Allow"
          Action = [
            "bedrock-agentcore:CreateEvent",
            "bedrock-agentcore:GetEvent",
            "bedrock-agentcore:ListEvents",
            "bedrock-agentcore:DeleteEvent",
            "bedrock-agentcore:RetrieveMemoryRecords"
          ]
          Resource = local.runtime_memory_arns
        }
      ] : [],
      [
        {
          # Third-party observability leg (agentcore-observability, task 15.2):
          # the base image resolves the OTel_Collector endpoint from this single
          # SSM parameter at boot. Scoped to EXACTLY that parameter ARN — no
          # wildcard. Additive third-party leg only; grants no CloudWatch/X-Ray
          # write and cannot affect the AWS-native leg.
          Sid      = "OtelCollectorEndpointSsmRead"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter"]
          Resource = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/eap/observability/collector-endpoint"]
        }
    ])
  })
}

# ---------------------------------------------------------------------------
# Cognito Per-Agent Identity — PARKED
# ---------------------------------------------------------------------------
# Per-agent Cognito app clients, users, and group memberships are disabled
# because the AgentCore runtime sidecar does not compute SECRET_HASH when
# calling Cognito's /oauth2/token endpoint. This blocks agents
# from acquiring JWTs, which in turn blocks the JWT authorizer on the runtime.
#
# To re-enable per-agent Cognito identity, uncomment the three blocks below and set
# enable_auth = true in the runtime module call to restore:
#   - Per-agent Cognito app client (client_credentials grant)
#   - Per-agent Cognito user (digital worker identity)
#   - Group membership (domain-level RBAC)
#
# A2A auth is routed through AgentCore Gateway instead (see ADR-017).
# ---------------------------------------------------------------------------

# resource "aws_cognito_user_pool_client" "agent" {
#   for_each = local.agents_by_name
#
#   name         = "${var.domain}-${each.key}"
#   user_pool_id = var.cognito_user_pool_id
#
#   generate_secret = true
#
#   allowed_oauth_flows_user_pool_client = true
#   allowed_oauth_flows                  = ["client_credentials"]
#   allowed_oauth_scopes                 = [var.cognito_a2a_scope]
#   supported_identity_providers         = ["COGNITO"]
#
#   explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]
# }

# resource "aws_cognito_user" "agent" {
#   for_each = local.agents_by_name
#
#   user_pool_id = var.cognito_user_pool_id
#   username     = "${var.domain}-${each.key}-agent"
#
#   attributes = {
#     email                      = "${var.domain}-${each.key}@eap.internal"
#     email_verified             = "true"
#     "custom:eap_domain" = var.domain
#   }
#
#   lifecycle {
#     ignore_changes = [attributes["email_verified"]]
#   }
# }

# resource "aws_cognito_user_in_group" "agent" {
#   for_each = local.agents_by_name
#
#   user_pool_id = var.cognito_user_pool_id
#   group_name   = var.domain
#   username     = aws_cognito_user.agent[each.key].username
# }

# ---------------------------------------------------------------------------
# Agent Runtimes — one per agent, using the eap runtime module
# ---------------------------------------------------------------------------
module "runtime" {
  source   = "./runtime"
  for_each = local.agents_by_name

  name        = replace("${var.domain}_${each.key}", "-", "_")
  domain      = var.domain
  description = each.value.description
  framework   = try(each.value.framework, "strands")
  protocols   = try(each.value.protocols, ["a2a"])
  role_arn    = aws_iam_role.runtime.arn
  model_id    = try(each.value.model_id, var.model_id)

  container_image = "${var.ecr_repo_url}:${each.key}-latest"

  # Auth disabled — Cognito JWT authorizer parked (the runtime sidecar does not compute SECRET_HASH; see ADR-017).
  # When re-enabling, also uncomment the Cognito resource blocks above and pass:
  #   cognito_user_pool_id  = var.cognito_user_pool_id
  #   cognito_app_client_id = aws_cognito_user_pool_client.agent[each.key].id
  #   allowed_callers       = [for c in each.value.allowed_callers : aws_cognito_user_pool_client.agent[c].id]
  # See ADR-017.
  enable_auth = false

  extra_environment_variables = merge(
    # Inject memory ID for agents that declare memory: in agent.yaml
    try(each.value.memory, null) != null ? {
      AGENTCORE_MEMORY_ID = module.memory[each.key].id
    } : {},
    # Inject callee runtime names — agents resolve endpoints at runtime via AgentCore API.
    # Using names instead of endpoint ARNs avoids a Terraform cycle (runtime A env vars →
    # runtime B endpoint → runtime B resource → runtime B env vars → ...).
    {
      for callee_name in try(each.value.calls, []) :
      "${upper(replace(callee_name, "-", "_"))}_RUNTIME_NAME" =>
      replace("${var.domain}_${callee_name}", "-", "_")
    }
  )
}

# ---------------------------------------------------------------------------
# Agent Memory — one per agent that declares memory: in agent.yaml
# ---------------------------------------------------------------------------
module "memory" {
  source   = "./memory"
  for_each = local.agents_with_memory

  name        = replace("${var.domain}_${each.key}_memory", "-", "_")
  domain      = var.domain
  description = "Memory for ${each.key} in domain ${var.domain}"
  memory_type = try(each.value.memory.type, "long-term")
  retention   = try(each.value.memory.retention, "90d")
}

# ---------------------------------------------------------------------------
# Agent Evaluations — one per agent that declares evaluations: in agent.yaml
# Stores eval config in SSM + creates CloudWatch schedule.
# ---------------------------------------------------------------------------
module "evaluations" {
  source   = "./evaluations"
  for_each = local.agents_with_evaluations

  name       = replace("${var.domain}_${each.key}_eval", "-", "_")
  domain     = var.domain
  runtime_id = module.runtime[each.key].id

  evaluators = [
    for e in try(each.value.evaluations.evaluators, ["correctness", "helpfulness", "safety"]) : {
      name      = e
      threshold = try(each.value.evaluations.thresholds[e], null)
      enabled   = true
    }
  ]
}

# ---------------------------------------------------------------------------
# Gateway Refs — STUBBED (requires eap-data-services, post-MVP)
# Agents that declare gateway_refs: in agent.yaml will get gateway connectivity
# once the data-services repo provisions MCP server gateways.
# ---------------------------------------------------------------------------
# TODO: Wire up gateway module when eap-data-services is available.
# Agents with gateway_refs: ${jsonencode(keys(local.agents_with_gateway))}
# Each agent.yaml can declare:
#   gateway_refs:
#     - mcp_servers: [snowflake-warehouse, sharepoint-docs]
# The deploy-template will resolve gateway IDs and pass them to the runtime module.
