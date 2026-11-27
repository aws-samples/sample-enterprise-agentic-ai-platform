# Governance Pipeline Module — Variables

variable "name" {
  type        = string
  description = "Pipeline name (e.g., 'governance')"
}

variable "repository_name" {
  type        = string
  description = "CodeCommit repo name"
}

variable "branch" {
  type    = string
  default = "main"
}

variable "platform_state_bucket" {
  type        = string
  description = "S3 bucket containing eap-platform terraform state"
}

variable "policy_engine_id" {
  type        = string
  description = "Policy engine ID for Cedar policy deployment via AWS CLI"
  default     = ""
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
