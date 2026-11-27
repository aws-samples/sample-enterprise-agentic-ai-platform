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
