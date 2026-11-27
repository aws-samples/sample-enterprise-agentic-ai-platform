# EAP Pipeline Module — Variables
# Reusable CodePipeline for agent deployment: Source → Build → Deploy → Verify
# Platform_Admin provisions one pipeline per domain. The pipeline auto-discovers
# all uc*/ directories in the repo and builds/deploys every agent.

variable "name" {
  type        = string
  description = "Pipeline name suffix (e.g., 'a2a-demo')"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,48}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-50 chars."
  }
}

variable "domain" {
  type        = string
  description = "EAP domain this pipeline deploys for"
}

variable "source_provider" {
  type        = string
  default     = "CodeCommit"
  description = "Source provider: CodeCommit or CodeStarSourceConnection"
  validation {
    condition     = contains(["CodeCommit", "CodeStarSourceConnection"], var.source_provider)
    error_message = "source_provider must be CodeCommit or CodeStarSourceConnection."
  }
}

variable "repository_name" {
  type        = string
  description = "CodeCommit repo name or full repo ID for CodeStar"
}

variable "branch" {
  type        = string
  default     = "main"
  description = "Branch to trigger pipeline on push"
}

variable "codestar_connection_arn" {
  type        = string
  default     = ""
  description = "ARN of CodeStar connection (required for CodeStarSourceConnection)"
}

variable "ecr_repository_url" {
  type        = string
  description = "ECR repository URL for agent images"
}

variable "base_image_ecr_repo_url" {
  type        = string
  description = "ECR repository URL for the pre-built base image"
}

variable "agent_protocols" {
  type        = list(string)
  default     = ["a2a"]
  description = "Protocols to verify in post-deploy health check"
}

# --- Platform identity refs (passed from eap-platform) ---

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito User Pool ID for agent identity"
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

variable "model_id" {
  type        = string
  default     = "us.anthropic.claude-sonnet-5"
  description = "Bedrock foundation model ID (cross-region inference profile format for Claude Sonnet 5)"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Target environment for evaluation and gate stages"
  validation {
    condition     = contains(["dev", "qa", "uat", "prod"], var.environment)
    error_message = "environment must be one of: dev, qa, uat, prod."
  }
}

variable "lifecycle_table" {
  type        = string
  default     = ""
  description = "Name of the SINGLE shared Agent School lifecycle DynamoDB table that ALL vended pipelines write to (deployed-agent facts + stage transitions). The BU/domain is recorded on each item (the `bu` attribute) rather than in the table name. When empty, falls back to the legacy per-domain name for backward compatibility."
}

variable "governance_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket containing graduation-policy.yaml for the gate stage"
}

# --- Agent network posture (ADR-031) — passed to the deploy stage as TF_VAR ---

variable "agent_network_mode" {
  type        = string
  default     = "PUBLIC"
  description = "Network posture for agents this pipeline deploys: 'VPC' (agent ENIs in the enterprise VPC private subnets) or 'PUBLIC'. Injected as TF_VAR_agent_network_mode into the deploy CodeBuild stage. Resolved by the platform root."

  validation {
    condition     = contains(["VPC", "PUBLIC"], var.agent_network_mode)
    error_message = "agent_network_mode must be either \"VPC\" or \"PUBLIC\"."
  }
}

variable "agent_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Private subnet IDs for agent runtime ENIs in VPC mode. Injected (JSON-encoded) as TF_VAR_agent_subnet_ids into the deploy stage."
}

variable "agent_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Security group IDs for agent runtime ENIs in VPC mode. Injected (JSON-encoded) as TF_VAR_agent_security_group_ids into the deploy stage."
}

variable "codebuild_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodeBuild service role ARN (ADR-033). Empty => the module creates the role + policy; supplied => the module creates neither and all CodeBuild projects use this ARN."
}

variable "codepipeline_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodePipeline service role ARN (ADR-033). Empty => the module creates the role + policy; supplied => the module creates neither and the CodePipeline uses this ARN."
}

variable "red_team_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket containing red-team adversarial prompt sets"
}

variable "test_cases_bucket" {
  type        = string
  default     = ""
  description = "S3 bucket containing GenAI Tester curated scenarios (governance-owned)"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ADR-048: optional human approval between Build and Deploy. Turned on for the
# nocode-user pipeline, whose commits are model-generated by the Agent
# Deployment Engineer, so a person reviews the change before it is deployed.
variable "require_manual_approval" {
  type        = bool
  default     = false
  description = "Insert a CodePipeline manual approval stage (Approve) after Build and before Deploy. A reviewer approves or rejects the execution in the CodePipeline console."
}
