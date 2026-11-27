terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id           = data.aws_caller_identity.current.account_id
  partition            = data.aws_partition.current.partition
  region               = var.aws_region
  deploy_principal_arn = var.deploy_principal_arn != "" ? var.deploy_principal_arn : data.aws_caller_identity.current.arn

  # Deterministic platform resource names the standalone hardened policies
  # reference (all knowable pre-apply; MATCH the platform's naming).
  lifecycle_table = var.lifecycle_table != "" ? var.lifecycle_table : "agent-school-lifecycle-${var.domain}-${var.environment}"
  deploy_repo     = var.domain
  deploy_pipeline = "${var.domain}-deploy-pipeline"
  target_repo     = var.domain
  codecommit_arns = "arn:${local.partition}:codecommit:${local.region}:${local.account_id}:*"

  # Published role pack (repo root docs/iam/roles).
  iam_pack = "${path.module}/../../../docs/iam/roles"

  # The 5 standalone roles this fixture externalizes (Option A).
  # trust_service: for a service-principal trust we build it directly (simpler +
  #   avoids parsing the JSON); observability uses an AWS-principal trust.
  standalone_roles = {
    gateway = {
      dir             = "gateway"
      trust_service   = "bedrock-agentcore.amazonaws.com"
      has_permissions = false
    }
    studio-runtime = {
      dir             = "studio-runtime"
      trust_service   = "bedrock-agentcore.amazonaws.com"
      has_permissions = true
    }
    studio-read = {
      dir             = "studio-read"
      trust_service   = "lambda.amazonaws.com"
      has_permissions = true
    }
    commit-validation = {
      dir             = "commit-validation"
      trust_service   = "lambda.amazonaws.com"
      has_permissions = true
    }
    observability = {
      dir             = "observability"
      trust_service   = "" # AWS-principal trust (built below), not a service
      has_permissions = true
    }
  }

  # Render a hardened permission JSON by substituting every <TOKEN>. HCL has no
  # fold, so we chain replace() over the known token set (unused tokens in a
  # given file are simply no-ops). Kept in one place so every role renders
  # identically.
  perms_rendered = {
    for role, cfg in local.standalone_roles :
    role => cfg.has_permissions ? replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
      file("${local.iam_pack}/${cfg.dir}/permissions-policy-hardened.json"),
      "<PARTITION>", local.partition),
      "<REGION>", local.region),
      "<ACCOUNT_ID>", local.account_id),
      "<ENVIRONMENT>", var.environment),
      "<DOMAIN>", var.domain),
      "<DEPLOY_REPO>", local.deploy_repo),
      "<DEPLOY_PIPELINE>", local.deploy_pipeline),
      "<TARGET_REPO>", local.target_repo),
      "<LIFECYCLE_TABLE>", local.lifecycle_table),
    "<CODECOMMIT_REPO_ARNS>", local.codecommit_arns) : ""
  }
}

# ---------------------------------------------------------------------------
# Trust policies
#   - service-principal roles: built inline from trust_service
#   - observability: AWS-principal trust (deploy principal is the trusted role)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  for_each = { for k, v in local.standalone_roles : k => v if v.trust_service != "" }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = [each.value.trust_service]
    }
  }
}

data "aws_iam_policy_document" "trust_observability" {
  statement {
    sid     = "AllowObservabilityConsumerAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.deploy_principal_arn]
    }
  }
}

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------
resource "aws_iam_role" "this" {
  for_each = local.standalone_roles

  name = "${var.role_name_prefix}-${each.key}-${var.environment}"
  assume_role_policy = (
    each.key == "observability"
    ? data.aws_iam_policy_document.trust_observability.json
    : data.aws_iam_policy_document.trust[each.key].json
  )

  tags = merge(var.tags, {
    "eap:testbed" = "true"
    "eap:role"    = each.key
  })
}

# Inline hardened permission policy (roles that have one).
resource "aws_iam_role_policy" "this" {
  for_each = { for k, v in local.standalone_roles : k => v if v.has_permissions }

  name   = "${each.key}-hardened"
  role   = aws_iam_role.this[each.key].id
  policy = local.perms_rendered[each.key]
}

# ---------------------------------------------------------------------------
# Scoped iam:PassRole grant for the deploy principal (ADR-033).
# The platform apply hands these roles to their services (runtime -> AgentCore,
# Lambdas -> Lambda), which requires iam:PassRole on exactly these ARNs.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "passrole" {
  statement {
    sid       = "PassStandaloneRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [for r in aws_iam_role.this : r.arn]
  }
}

resource "aws_iam_policy" "passrole" {
  name        = "${var.role_name_prefix}-passrole-${var.environment}"
  description = "Scoped iam:PassRole for the deploy principal over the externalized standalone roles (ADR-033 test bed)."
  policy      = data.aws_iam_policy_document.passrole.json
  tags        = merge(var.tags, { "eap:testbed" = "true" })
}
