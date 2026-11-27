# Gateway Pipeline Module — Variables
# Simpler than agent pipeline: Source → Deploy → Verify (no Docker build)

variable "name" {
  type        = string
  description = "Pipeline name (e.g., 'mcp-integrations')"
}

variable "domain" {
  type    = string
  default = "shared-services"
}

variable "repository_name" {
  type        = string
  description = "CodeCommit repo name"
}

variable "branch" {
  type    = string
  default = "main"
}

variable "oidc_discovery_url" {
  type        = string
  default     = ""
  description = "OIDC discovery URL (legacy — gateway now reads from platform state)"
}

variable "platform_state_bucket" {
  type        = string
  description = "S3 bucket containing eap-platform terraform state"
}

variable "platform_state_key" {
  type        = string
  default     = "platform/terraform.tfstate"
  description = "Key of the eap-platform state object in platform_state_bucket. The gateway-deploy template reads this via terraform_remote_state to resolve gateway_id."
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ADR-033: bring-your-own service role ARNs (empty => module creates them).
variable "codebuild_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodeBuild service role ARN. Empty => the module creates the role + policy; supplied => neither is created and CodeBuild uses this ARN."
}

variable "codepipeline_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodePipeline service role ARN. Empty => the module creates the role + policy; supplied => neither is created and the CodePipeline uses this ARN."
}
