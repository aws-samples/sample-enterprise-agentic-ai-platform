# Deploy Template Variables — all injected via TF_VAR_ env vars from CodeBuild

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain" {
  type        = string
  description = "EAP domain"
}

variable "ecr_repo_url" {
  type        = string
  description = "ECR repository URL for agent images"
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito User Pool ID"
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
  description = "Default Bedrock model ID (inference profile format for newer models)"
}

# --- Agent School: Environment-Aware Variables ---

variable "environment" {
  description = "Target environment: dev, qa, uat, prod"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "qa", "uat", "prod"], var.environment)
    error_message = "Environment must be one of: dev, qa, uat, prod"
  }
}

variable "oidc_discovery_url" {
  description = "OIDC discovery URL for JWT validation (IdP-agnostic). Swap identity providers by changing this one variable."
  type        = string
  default     = ""
}

variable "mcp_server_endpoints" {
  description = "MCP server endpoints (environment-specific). Keys are server names, values are endpoint URLs."
  type        = map(string)
  default     = {}
}

variable "governance_bucket" {
  description = "S3 bucket name containing governance artifacts (graduation-policy.yaml). Read at pipeline runtime."
  type        = string
  default     = ""
}

# --- Agent network posture (ADR-031) — injected by the pipeline via TF_VAR ---
# The platform root resolves these and the pipeline CodeBuild project sets them
# as TF_VAR_agent_* (lists are passed as JSON strings). Defaults keep the
# pre-ADR-031 PUBLIC behavior when the pipeline injects nothing.

variable "agent_network_mode" {
  description = "Network posture for pipeline-deployed agent runtimes: 'VPC' runs agent ENIs in the enterprise VPC private subnets; 'PUBLIC' uses AgentCore-managed public endpoints. Injected from the platform root's resolved posture."
  type        = string
  default     = "PUBLIC"

  validation {
    condition     = contains(["VPC", "PUBLIC"], var.agent_network_mode)
    error_message = "agent_network_mode must be either \"VPC\" or \"PUBLIC\"."
  }
}

variable "agent_subnet_ids" {
  description = "Private subnet IDs for agent runtime ENIs when agent_network_mode = VPC. Passed as a JSON list via TF_VAR_agent_subnet_ids."
  type        = list(string)
  default     = []
}

variable "agent_security_group_ids" {
  description = "Security group IDs for agent runtime ENIs when agent_network_mode = VPC. Passed as a JSON list via TF_VAR_agent_security_group_ids."
  type        = list(string)
  default     = []
}
