variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cognito_user_pool_id" {
  description = "Cognito User Pool ID for authentication"
  type        = string
}

variable "cognito_app_client_id" {
  description = "Cognito App Client ID for the console. Empty when an external OIDC IdP is used."
  type        = string
}

variable "create_cognito_identity_pool" {
  description = "Whether to create the Cognito Identity Pool for browser AWS-credential exchange. True on the platform-Cognito path; false under an external OIDC IdP (ADR-028). Known at plan time (driven by oidc_discovery_url), unlike the app client id which is only known at apply."
  type        = bool
  default     = true
}

variable "authenticated_role_arn" {
  description = "Pre-created IAM role ARN for the Cognito authenticated console role (ADR-033). Empty (default) => the module creates the role + its policy (when the identity pool is created); supplied => the module creates neither and the identity-pool attachment uses this ARN."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account ID for resource ARN construction"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}

variable "cognito_domain_prefix" {
  description = "Cognito hosted UI domain prefix for auth redirects"
  type        = string
  default     = "eap-platform-bu-1-dev"
}

# Read routes (/api/*) — the studio-read backend ALB (replaces the former HTTP
# API Gateway origin). Locked to CloudFront via its own origin secret, same as
# the examples + ADE backends.
variable "studio_read_backend_alb_dns" {
  description = "DNS name of the studio-read backend ALB (from module.studio_read_backend). CloudFront routes /api/* here. Empty => the /api/* origin+behavior are not added."
  type        = string
  default     = ""
}

variable "studio_read_origin_secret_header" {
  description = "Header name CloudFront injects for the studio-read backend ALB origin lockdown."
  type        = string
  default     = "x-eap-origin"
}

variable "studio_read_origin_secret_value" {
  description = "Secret value CloudFront sends in the origin header to the studio-read backend ALB."
  type        = string
  default     = ""
  sensitive   = true
}

# Public origin of the self-hosted Langfuse stack (its CloudFront/ALB base URL),
# supplied by the Langfuse module output `langfuse_base_url`. The console SPA reads
# this at build time (VITE_LANGFUSE_EMBED_ORIGIN) as the src origin of the embedded
# Langfuse trace/prompt/eval iframe in the ObservabilityWorkspace (task 9.3/13.1).
# Empty string disables the embed (the workspace renders a "Langfuse unavailable"
# state). Embedding is permitted by the Langfuse-side response header
# `Content-Security-Policy: frame-ancestors 'self' https://<console-domain>`
# configured on the Langfuse_ALB/CloudFront (task 9.1); the console itself emits no
# frame-blocking header (see main.tf). _Requirements: 13.1, 7.4_
variable "langfuse_embed_origin" {
  description = "Public origin (scheme + host) of the self-hosted Langfuse stack (its CloudFront/ALB base URL, i.e. the Langfuse module's `langfuse_base_url` output). Injected into the SPA build as VITE_LANGFUSE_EMBED_ORIGIN and used as the embedded Langfuse iframe src origin. Empty string disables the in-console embed."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Examples surface (ADR-037) — hardened C2. The examples-console module builds
# the ALB→Fargate backend + WAF; this distribution adds it as a locked-down
# origin under /examples-api/*. All empty/false => the origin + behavior are
# omitted (the surface simply doesn't appear). Demo-preset only.
# ---------------------------------------------------------------------------
variable "examples_backend_alb_dns" {
  description = "DNS name of the examples backend ALB (from module.examples_console). Empty => the /examples-api/* origin+behavior are not added."
  type        = string
  default     = ""
}

variable "examples_origin_secret_header" {
  description = "Header name CloudFront injects for the examples ALB (and Langfuse ALB) origin lockdown."
  type        = string
  default     = "x-eap-origin"
}

variable "examples_origin_secret_value" {
  description = "Secret value CloudFront sends in the origin header to the examples/Langfuse ALBs."
  type        = string
  default     = ""
  sensitive   = true
}

variable "examples_waf_web_acl_arn" {
  description = "ARN of the CLOUDFRONT-scope WAF WebACL to attach to this distribution (from module.examples_console). Empty => no WAF attached."
  type        = string
  default     = ""
}

variable "examples_pipeline_name" {
  description = "Name of the deploy pipeline the Examples surface polls for the 'Deploying' card state (ADR-037). Injected as VITE_EXAMPLES_PIPELINE."
  type        = string
  default     = "team-bu-1-deploy-pipeline"
}

# ---------------------------------------------------------------------------
# ADE streaming invoke backend (ADR-040) — demo only. When set, this
# distribution adds the ADE backend ALB as a locked-down origin under
# /ade-api/*, so the Build-workspace chat streams token-by-token through the
# same hardened edge. Empty => the origin + behavior are omitted (enterprise
# reaches the internal ADE ALB directly, no CloudFront).
# ---------------------------------------------------------------------------
variable "ade_backend_alb_dns" {
  description = "DNS name of the ADE invoke-backend ALB (from module.ade_invoke_backend, demo/public_edge only). Empty => the /ade-api/* origin+behavior are not added."
  type        = string
  default     = ""
}

variable "ade_origin_secret_header" {
  description = "Header name CloudFront injects for the ADE ALB origin lockdown (ADR-040)."
  type        = string
  default     = "x-eap-origin"
}

variable "ade_origin_secret_value" {
  description = "Secret value CloudFront sends in the origin header to the ADE ALB (ADR-040)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "access_log_bucket_domain" {
  description = "Regional domain name of the S3 bucket that receives CloudFront standard access logs."
  type        = string
}

# CloudFront VPC origins for the internal backend ALBs (studio-read, examples,
# ADE). Each backend module creates its own aws_cloudfront_vpc_origin.
variable "studio_read_vpc_origin_id" {
  description = "CloudFront VPC origin ID for the studio-read ALB. Required when studio_read_backend_alb_dns is set."
  type        = string
  default     = ""
}

variable "examples_vpc_origin_id" {
  description = "CloudFront VPC origin ID for the examples ALB. Required when examples_backend_alb_dns is set."
  type        = string
  default     = ""
}

variable "ade_vpc_origin_id" {
  description = "CloudFront VPC origin ID for the ADE invoke-backend ALB. Required when ade_backend_alb_dns is set."
  type        = string
  default     = ""
}
