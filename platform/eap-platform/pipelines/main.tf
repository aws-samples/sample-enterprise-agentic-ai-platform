# EAP Platform — Pipeline Provisioning
# Platform_Admin provisions one pipeline per domain.
# Each pipeline watches a CodeCommit repo and auto-discovers all uc*/ directories,
# building and deploying every agent via the runtime module.
# App teams write agent.yaml — all Terraform is platform-owned.

variable "environment" {
  type    = string
  default = "dev"
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito User Pool ID from identity module"
}

variable "cognito_token_endpoint" {
  type        = string
  description = "Cognito OAuth2 token endpoint"
}

variable "cognito_a2a_scope" {
  type        = string
  default     = "a2a/invoke"
  description = "OAuth2 scope for A2A invocation"
}

variable "ecr_repository_url" {
  type        = string
  description = "ECR repository URL for agent images"
}

variable "base_image_ecr_repo_url" {
  type        = string
  description = "ECR repository URL for the pre-built base image"
}

variable "model_id" {
  type        = string
  default     = "us.anthropic.claude-sonnet-5"
  description = "Default Bedrock foundation model ID (cross-region inference profile format for Claude Sonnet 5)"
}

variable "agent_pipelines" {
  type = map(object({
    domain          = string
    repository_name = string
    branch          = optional(string, "main")
    source_provider = optional(string, "CodeCommit")
    model_id        = optional(string, "")
    protocols       = optional(list(string), ["a2a"])
    # ADR-048: manual approval stage before Deploy.
    require_manual_approval = optional(bool, false)
  }))
  description = "Map of agent pipeline name to configuration"
  default = {
    a2a-demo = {
      domain          = "team-bu-1"
      repository_name = "team-bu-1"
    }
    nocode-user-deploy = {
      domain                  = "nocode-user"
      repository_name         = "nocode-user"
      require_manual_approval = true
    }
  }
}

# ---------------------------------------------------------------------------
# Enterprise Integrations Pipeline
# Simpler than agent pipelines — no Docker build, just TF plan/apply.
# Reads YAML sources from the mcp-integrations repo and provisions
# the AgentCore Gateway via the gateway-deploy template.
# ---------------------------------------------------------------------------
variable "integration_pipelines" {
  type = map(object({
    domain             = string
    repository_name    = string
    branch             = optional(string, "main")
    oidc_discovery_url = optional(string, "")
  }))
  description = "Map of integration pipeline name to configuration. oidc_discovery_url is normally injected from the platform-wide value (var.oidc_discovery_url below), not set per-entry."
  default = {
    mcp-integrations = {
      domain          = "shared-services"
      repository_name = "mcp-integrations"
    }
  }
}

variable "oidc_discovery_url" {
  type        = string
  description = "Platform-wide resolved OIDC discovery URL (external IdP or the platform-created Cognito pool). Injected into each integration pipeline's gateway JWT authorizer unless the per-entry oidc_discovery_url overrides it."
  default     = ""
}

variable "platform_state_bucket" {
  type        = string
  description = "Account-scoped Terraform state bucket (eap-platform-state-<account_id>) that integration pipelines read platform outputs from via terraform_remote_state. Passed from the root so it matches the bootstrapped bucket."
}

variable "lifecycle_table" {
  type        = string
  default     = ""
  description = "Single shared Agent School lifecycle DynamoDB table that every vended pipeline writes deployed-agent state to (BU recorded per-item). Passed to each pipeline module instance."
}

# --- Agent network posture (ADR-031) — threaded from the platform root ---

variable "agent_network_mode" {
  type        = string
  default     = "PUBLIC"
  description = "Network posture for pipeline-deployed agent runtimes ('VPC' | 'PUBLIC'). Resolved by the platform root (local.agent_effective_network_mode) and passed to every agent pipeline."
}

variable "agent_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Private subnet IDs for agent runtime ENIs in VPC mode (platform-resolved private subnets)."
}

variable "agent_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Security group IDs for agent runtime ENIs in VPC mode (platform agent SG or deployer-supplied)."
}

# --- Externalizable pipeline service roles (ADR-033) ---

variable "agent_pipeline_codebuild_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodeBuild service role ARN for agent pipelines (empty => module creates it)."
}

variable "agent_pipeline_codepipeline_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodePipeline service role ARN for agent pipelines (empty => module creates it)."
}

variable "integration_pipeline_codebuild_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodeBuild service role ARN for the integration (gateway) pipeline (empty => module creates it)."
}

variable "integration_pipeline_codepipeline_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodePipeline service role ARN for the integration (gateway) pipeline (empty => module creates it)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Pipeline instances — one per entry in var.pipelines
# ---------------------------------------------------------------------------
module "pipeline" {
  source   = "../../eap-terraform-modules/modules/pipeline"
  for_each = var.agent_pipelines

  name            = each.key
  domain          = each.value.domain
  repository_name = each.value.repository_name
  branch          = each.value.branch
  source_provider = each.value.source_provider
  lifecycle_table = var.lifecycle_table

  # ADR-048: manual approval before Deploy (on for the ADE's nocode-user repo).
  require_manual_approval = each.value.require_manual_approval

  ecr_repository_url      = var.ecr_repository_url
  base_image_ecr_repo_url = var.base_image_ecr_repo_url
  cognito_user_pool_id    = var.cognito_user_pool_id
  cognito_token_endpoint  = var.cognito_token_endpoint
  cognito_a2a_scope       = var.cognito_a2a_scope
  model_id                = coalesce(each.value.model_id, var.model_id)

  # Agent network posture (ADR-031) — every pipeline-deployed agent runtime
  # joins the enterprise VPC by default (PUBLIC only when no VPC resolves).
  agent_network_mode       = var.agent_network_mode
  agent_subnet_ids         = var.agent_subnet_ids
  agent_security_group_ids = var.agent_security_group_ids

  # ADR-033: bring-your-own pipeline service roles (empty => module creates).
  codebuild_role_arn    = var.agent_pipeline_codebuild_role_arn
  codepipeline_role_arn = var.agent_pipeline_codepipeline_role_arn

  tags = merge(var.tags, {
    eap_domain   = each.value.domain
    eap_pipeline = each.key
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "pipeline_names" {
  description = "Map of pipeline key to CodePipeline name"
  value       = { for k, v in module.pipeline : k => v.pipeline_name }
}

output "pipeline_arns" {
  description = "Map of pipeline key to CodePipeline ARN"
  value       = { for k, v in module.pipeline : k => v.pipeline_arn }
}

# ---------------------------------------------------------------------------
# Enterprise Integrations Pipeline instances
# ---------------------------------------------------------------------------
module "integration_pipeline" {
  source   = "../../eap-terraform-modules/modules/gateway-pipeline"
  for_each = var.integration_pipelines

  name            = each.key
  domain          = each.value.domain
  repository_name = each.value.repository_name
  branch          = each.value.branch
  # Per-entry override wins; otherwise use the platform-wide resolved OIDC URL.
  oidc_discovery_url    = each.value.oidc_discovery_url != "" ? each.value.oidc_discovery_url : var.oidc_discovery_url
  platform_state_bucket = var.platform_state_bucket
  platform_state_key    = "platform/terraform.tfstate"

  # ADR-033: bring-your-own pipeline service roles (empty => module creates).
  codebuild_role_arn    = var.integration_pipeline_codebuild_role_arn
  codepipeline_role_arn = var.integration_pipeline_codepipeline_role_arn

  tags = merge(var.tags, {
    eap_domain   = each.value.domain
    eap_pipeline = each.key
  })
}

output "integration_pipeline_names" {
  description = "Map of integration pipeline key to CodePipeline name"
  value       = { for k, v in module.integration_pipeline : k => v.pipeline_name }
}
