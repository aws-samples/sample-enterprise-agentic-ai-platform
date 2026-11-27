# QA Deploy Template — Variables
# Injected via TF_VAR_ environment variables from CodeBuild.

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "domain" {
  type        = string
  description = "Business unit domain (e.g., 'team-bu-1')"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Platform environment"
}

variable "platform_state_bucket" {
  type        = string
  description = "S3 bucket containing eap-platform state"
}

variable "ground_truth_bucket" {
  type        = string
  description = "S3 bucket for ground truth datasets"
}

variable "repository_name" {
  type        = string
  description = "QA CodeCommit repository name"
}

variable "commit_sha" {
  type        = string
  default     = "unknown"
  description = "Source commit SHA (set by buildspec from CODEBUILD_RESOLVED_SOURCE_VERSION)"
}

variable "tags" {
  type    = map(string)
  default = {}
}
