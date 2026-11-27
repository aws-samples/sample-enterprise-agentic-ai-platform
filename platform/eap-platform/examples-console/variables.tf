# Examples Console module — variables (ADR-037)
#
# Hardened CloudFront (WAF) -> [ S3 static SPA assets | ALB -> ECS Fargate /api/* ]
# for the demo console Examples surface. Created only in the demo preset
# (gated on deploy_console at the platform root). The generic Fargate backend
# (platform/examples-backend) SigV4-signs AgentCore invokes and drives Step
# Functions; the ALB is private and reachable only through CloudFront.

variable "environment" {
  type        = string
  description = "Deployment environment (e.g. dev)"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "account_id" {
  type        = string
  description = "AWS account id"
}

# --- Networking (platform-resolved VPC; demo VPC is platform-created) --------
variable "vpc_id" {
  type        = string
  description = "VPC the Fargate backend + ALB run in (the platform-created demo VPC)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Fargate tasks."
  validation {
    condition     = length(var.private_subnet_ids) >= 1
    error_message = "At least one private subnet is required for the Fargate backend."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Unused: the ALB is internal in private subnets (CloudFront reaches it through a VPC origin). Kept for interface compatibility."
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least two public subnets (distinct AZs) are required for the ALB."
  }
}

# --- Backend container -------------------------------------------------------
variable "backend_container_port" {
  type        = number
  default     = 8080
  description = "Port the examples backend listens on."
}

variable "backend_task_cpu" {
  type        = number
  default     = 512
  description = "Fargate task CPU units for the backend."
}

variable "backend_task_memory" {
  type        = number
  default     = 1024
  description = "Fargate task memory (MiB) for the backend."
}

variable "backend_desired_count" {
  type        = number
  default     = 1
  description = "Desired number of backend tasks (always-on; no scale-to-zero)."
}

# --- Target allow-list source (ADR-046) --------------------------------------
variable "lifecycle_table_name" {
  type        = string
  description = "Name of the shared lifecycle DynamoDB table. The backend Scans it so callers can only target deployed runtimes / state machines."
}

variable "lifecycle_table_arn" {
  type        = string
  description = "ARN of the shared lifecycle DynamoDB table, for scoping the task role's dynamodb:Scan (least privilege)."
}

# --- Caller auth (ADR-046, issuer resolution per ADR-028) --------------------
variable "cognito_user_pool_id" {
  type        = string
  default     = ""
  description = "Platform Cognito user pool id. The backend verifies the caller JWT signature against this pool. Empty when an external IdP is used (supply oidc_issuer instead)."
}

variable "cognito_app_client_id" {
  type        = string
  default     = ""
  description = "Console Cognito app client id. Tokens must be minted for this client. Required with cognito_user_pool_id."
}

variable "oidc_issuer" {
  type        = string
  default     = ""
  description = "External OIDC issuer URL (ADR-028). When set, the backend verifies tokens against this issuer's JWKS instead of Cognito."
}

variable "oidc_audience" {
  type        = string
  default     = ""
  description = "Expected token audience under an external IdP. Empty => audience not checked."
}

variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log retention (days) for the backend container."
}

# --- Langfuse public edge (ADR-039, supersedes ADR-038 subpath) --------------
variable "langfuse_alb_dns" {
  type        = string
  default     = ""
  description = "DNS name of the (CloudFront-facing) Langfuse ALB. When set, a dedicated hardened CloudFront distribution is created for Langfuse (its own root origin — no subpath) and its domain is emitted as langfuse_cloudfront_domain. Empty => no Langfuse distribution."
}

variable "langfuse_web_port" {
  type        = number
  default     = 3000
  description = "Port the Langfuse ALB HTTP listener serves on (web_container_port)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all resources."
}

variable "access_log_bucket_domain" {
  description = "Regional domain name of the S3 bucket that receives CloudFront standard access logs."
  type        = string
}

variable "langfuse_vpc_origin_id" {
  description = "CloudFront VPC origin ID for the internal Langfuse ALB. Required when langfuse_alb_dns is set."
  type        = string
  default     = ""
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection. The teardown scripts set this to false right before terraform destroy."
  type        = bool
  default     = true
}
