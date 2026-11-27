# ADE Invoke Backend module — variables (ADR-040)
#
# Always-on ECS/Fargate service that streams the Agent Deployment Engineer (ADE)
# console chat turn token-by-token (A2A message/stream), enforcing Cognito/OIDC
# JWT auth + the Requirement-11 runtime allow-list. Deployed in BOTH presets.
#
# Ingress posture is controlled by `public_edge`:
#   * public_edge = true  (demo)       — internal ALB + CloudFront VPC origin, locked to the demo
#     console CloudFront (origin-facing prefix list + secret header). CloudFront
#     adds an /ade-api/* behavior pointing at this ALB.
#   * public_edge = false (enterprise) — INTERNAL ALB (VPC-only). The customer's
#     BYO UI reaches it directly over the private network. No public edge.

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

# --- Ingress posture ---------------------------------------------------------
variable "public_edge" {
  type        = bool
  default     = false
  description = "true => internal ALB exposed to the demo CloudFront through a VPC origin (demo preset). false => INTERNAL ALB, VPC-only, for a BYO UI (enterprise preset, the safe default)."
}

# --- Networking (platform-resolved VPC) --------------------------------------
variable "vpc_id" {
  type        = string
  description = "VPC the Fargate backend + ALB run in (platform-created or imported)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Fargate tasks (and for an INTERNAL ALB)."
  validation {
    condition     = length(var.private_subnet_ids) >= 1
    error_message = "At least one private subnet is required for the Fargate backend."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  default     = []
  description = "Unused: the ALB is always internal in private subnets (CloudFront reaches it through a VPC origin). Kept for interface compatibility."
}

# --- Auth (ADR-028 — resolved OIDC) ------------------------------------------
variable "cognito_user_pool_id" {
  type        = string
  default     = ""
  description = "Platform Cognito user pool id — the backend validates the caller JWT's issuer against it. Empty when an external IdP is used (supply oidc_issuer instead)."
}

variable "oidc_issuer" {
  type        = string
  default     = ""
  description = "External OIDC issuer URL (ADR-028) the backend validates the caller JWT against. Empty => the platform Cognito issuer derived from cognito_user_pool_id. Exactly one of the two must be set."
}

# --- Requirement-11 allow-list source ----------------------------------------
variable "lifecycle_table_name" {
  type        = string
  description = "Name of the shared lifecycle DynamoDB table (single source of truth). The backend Scans it to build the authoritative runtime allow-list (Requirement 11)."
}

variable "lifecycle_table_arn" {
  type        = string
  description = "ARN of the shared lifecycle DynamoDB table, for scoping the task role's dynamodb:Scan (least-privilege)."
}

# --- Default ADE target ------------------------------------------------------
variable "ade_runtime_arn" {
  type        = string
  description = "The platform-owned Studio/ADE AgentCore runtime ARN — the default target when the caller sends no runtimeArn."
}

variable "ade_endpoint_qualifier" {
  type        = string
  default     = ""
  description = "Default endpoint qualifier for the ADE runtime."
}

# --- Demo CloudFront lockdown (public_edge only) -----------------------------
variable "cloudfront_origin_secret_header" {
  type        = string
  default     = "x-eap-origin"
  description = "Header name CloudFront injects and the ALB listener requires (public_edge only)."
}

variable "cloudfront_origin_secret_value" {
  type        = string
  default     = ""
  description = "Secret value CloudFront must send in the origin header (public_edge only). Empty => the module generates one and exposes it as an output for the console distribution to consume."
}

# --- Backend container -------------------------------------------------------
variable "backend_container_port" {
  type        = number
  default     = 8080
  description = "Port the ADE backend listens on."
}

variable "backend_task_cpu" {
  type        = number
  default     = 512
  description = "Fargate task CPU units."
}

variable "backend_task_memory" {
  type        = number
  default     = 1024
  description = "Fargate task memory (MiB)."
}

variable "backend_desired_count" {
  type        = number
  default     = 1
  description = "Desired number of backend tasks (always-on; no scale-to-zero — ADR-040)."
}

variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log retention (days) for the backend container."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all resources."
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection. The teardown scripts set this to false right before terraform destroy."
  type        = bool
  default     = true
}
