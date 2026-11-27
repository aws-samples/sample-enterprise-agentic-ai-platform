# KB Pipeline Module — Variables

variable "name" {
  type        = string
  description = "Pipeline name (e.g., 'kb-team-bu-1')"
}

variable "domain" {
  type        = string
  description = "Business unit domain (e.g., 'team-bu-1')"
}

variable "repository_name" {
  type        = string
  description = "CodeCommit repo name (e.g., 'knowledge-bases-team-bu-1')"
}

variable "branch" {
  type    = string
  default = "main"
}

variable "platform_state_bucket" {
  type        = string
  description = "S3 bucket for Terraform state storage"
}

variable "gateway_id" {
  type        = string
  description = "AgentCore Gateway ID for KB target registration"
}

variable "policy_engine_id" {
  type        = string
  description = "Gateway policy engine ID for Cedar policy generation"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Platform environment (dev, staging, prod)"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ADR-033: bring-your-own service role ARNs (empty => module creates them).
variable "codebuild_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodeBuild service role ARN. Empty => the module creates the role + policy; supplied => neither is created and all CodeBuild projects use this ARN."
}

variable "codepipeline_role_arn" {
  type        = string
  default     = ""
  description = "Pre-created CodePipeline service role ARN. Empty => the module creates the role + policy; supplied => neither is created and the CodePipeline uses this ARN."
}
