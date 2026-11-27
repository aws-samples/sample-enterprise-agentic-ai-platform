# Studio-Read Backend module — variables
#
# Always-on ECS/Fargate service serving the Console Build workspace read-only
# routes (deployed agents, deployment status, pattern resolve, latest
# deployment, gateway proxy, agent card, config). Replaces the studio-read
# Lambda + HTTP API Gateway path; the service self-validates the Cognito/OIDC
# JWT (parity with the ADE invoke backend). Deployed only with the demo console
# stack (gated on deploy_console at the platform root), mirroring the studio-read
# Lambda it replaces.
#
# Ingress posture is controlled by `public_edge`:
#   * public_edge = true  (demo)       — internal ALB + CloudFront VPC origin, locked to the demo
#     console CloudFront (origin-facing prefix list + secret header). CloudFront
#     routes /api/* to this ALB.
#   * public_edge = false (enterprise) — INTERNAL ALB (VPC-only). No public edge.

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
  description = "true => internal ALB exposed to the demo CloudFront through a VPC origin (demo preset). false => INTERNAL ALB, VPC-only (enterprise preset, the safe default)."
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
  description = "External OIDC issuer URL (ADR-028) the backend validates the caller JWT against. Empty => the platform Cognito issuer derived from cognito_user_pool_id."
}

# --- Cognito settings surfaced by GET /api/config ----------------------------
variable "cognito_app_client_id" {
  type        = string
  default     = ""
  description = "Console Cognito app client id, returned by GET /api/config for the SPA."
}

variable "cognito_domain" {
  type        = string
  default     = ""
  description = "Cognito hosted-UI domain prefix, returned by GET /api/config."
}

variable "cognito_callback_url" {
  type        = string
  default     = ""
  description = "OAuth callback URL, returned by GET /api/config."
}

variable "cognito_scopes" {
  type        = string
  default     = "openid gateway/tools.invoke"
  description = "OAuth scopes, returned by GET /api/config."
}

# --- Read-route data sources -------------------------------------------------
variable "gateway_url" {
  type        = string
  description = "AgentCore Gateway MCP endpoint the Gateway_Proxy (POST /api/gateway) forwards tools/list + tools/call to, with the caller's Bearer JWT."
}

variable "studio_pipeline_name" {
  type        = string
  default     = "nocode-user-nocode-user-deploy-deploy"
  description = "CodePipeline name the Deployment_Status / Latest_Deployment routes read."
}

variable "deploy_domain" {
  type        = string
  default     = "nocode-user"
  description = "Deploy domain prefixed onto AgentCore runtime names (runtime->app matching needle)."
}

variable "target_repo" {
  type        = string
  default     = "nocode-user"
  description = "CodeCommit repo the read routes walk for application.yaml + discovery. Injected as both TARGET_REPO and STUDIO_TARGET_REPO."
}

# --- Requirement-11 allow-list / lifecycle store -----------------------------
variable "lifecycle_table_name" {
  type        = string
  description = "Name of the shared lifecycle DynamoDB table (single source of truth). The Deployed_Agents_Service Scans it."
}

variable "lifecycle_table_arn" {
  type        = string
  description = "ARN of the shared lifecycle DynamoDB table, for scoping the task role's DynamoDB reads (least-privilege)."
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
  description = "Port the studio-read backend listens on."
}

variable "backend_task_cpu" {
  type        = number
  default     = 256
  description = "Fargate task CPU units (read routes are light)."
}

variable "backend_task_memory" {
  type        = number
  default     = 512
  description = "Fargate task memory (MiB)."
}

variable "backend_desired_count" {
  type        = number
  default     = 1
  description = "Desired number of backend tasks (always-on)."
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
