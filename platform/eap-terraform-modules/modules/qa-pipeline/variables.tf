# QA Pipeline Module — Variables

variable "name" {
  type        = string
  description = "Pipeline name (e.g., 'qa-team-bu-1')"
}

variable "domain" {
  type        = string
  description = "Business unit domain (e.g., 'team-bu-1')"
}

variable "repository_name" {
  type        = string
  description = "CodeCommit repo name (e.g., 'qa-team-bu-1')"
}

variable "branch" {
  type    = string
  default = "main"
}

variable "platform_state_bucket" {
  type        = string
  description = "S3 bucket containing eap-platform terraform state"
}

variable "platform_state_table" {
  type        = string
  description = "DynamoDB table name for Platform State Store"
}

variable "ground_truth_bucket" {
  type        = string
  description = "S3 bucket for ground truth datasets and red-team prompts"
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
