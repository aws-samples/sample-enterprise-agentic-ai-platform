# EAP Langfuse_Stack Module — Variables
#
# Self-hosted Langfuse deployed as the platform's DEFAULT third-party OTLP
# backend (Requirements 11.1–11.7). Compute (ECS Fargate web + worker),
# datastores (Aurora PostgreSQL Serverless v2, ClickHouse on Fargate with an
# EBS-backed volume, ElastiCache Redis), an S3 bucket for event/media blobs, and
# the edge (CloudFront -> Langfuse_ALB -> web service, HTTPS only).
#
# SCOPE (task 8.1): module structure and resources for compute + datastores +
# edge, with sensible security defaults. The full least-privilege security
# posture (private-subnet enforcement, per-datastore SG isolation, per-service
# IAM least privilege, KMS-at-rest, HTTPS-only redirect, Secrets Manager wiring)
# is task 8.2; the ALB authenticate-cognito action + frame-ancestors CSP is task
# 9.1; per-BU Langfuse projects are task 10.1. Clearly-marked seams/TODOs are
# left for those.
# Requirements: R11.1, R11.2, R11.3, R11.4, R11.5, R11.6, R11.7

variable "name" {
  type        = string
  default     = "langfuse"
  description = "Name prefix for the Langfuse stack resources"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-32 chars."
  }
}

variable "domain" {
  type        = string
  default     = "observability"
  description = "Platform domain this stack belongs to (used for the eap_domain tag)"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

# ---------------------------------------------------------------------------
# Networking — datastores run in PRIVATE subnets; the ALB is internet-facing in
# PUBLIC subnets so CloudFront can reach it. Private-subnet enforcement of the
# datastores and per-datastore SG isolation are hardened in task 8.2.
# ---------------------------------------------------------------------------
variable "vpc_id" {
  type        = string
  description = "VPC in which the Langfuse stack runs"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for Fargate tasks and datastores (never public)"
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least two private subnets (distinct AZs) are required for Aurora/Redis."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Unused: the Langfuse ALB is internal in private subnets (CloudFront reaches it through a VPC origin). Kept for interface compatibility."
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least two public subnets (distinct AZs) are required for the ALB."
  }
}

variable "private_route_table_ids" {
  type        = list(string)
  default     = []
  description = "Private-subnet route table IDs to associate with the S3 gateway VPC endpoint so Langfuse S3 blob traffic stays on the AWS backbone (never traverses the internet). When empty, the gateway endpoint is not created and S3 access relies on the bucket policy + public-access block for private posture."
}

variable "restrict_alb_to_cloudfront_prefix_list" {
  type        = bool
  default     = true
  description = "When true (default), the Langfuse_ALB ingress is restricted to the AWS-managed CloudFront origin-facing prefix list (com.amazonaws.global.cloudfront.origin-facing) so only CloudFront can reach the ALB. When false, ingress is open to 0.0.0.0/0 (e.g. for local testing without CloudFront)."
}

# ---------------------------------------------------------------------------
# Optional CloudFront-facing exposure (ADR-038) — demo only.
# ---------------------------------------------------------------------------
variable "enable_cloudfront_origin" {
  type        = bool
  default     = false
  description = <<-EOT
    ADR-038: when true, make the Langfuse ALB reachable by the demo console
    CloudFront distribution so the Langfuse UI can be embedded publicly (exec
    demo, no VPN). The ALB becomes internet-facing and its ingress is restricted
    to the CloudFront origin-facing prefix list PLUS a required secret origin
    header (var.cloudfront_origin_secret_header / _value). The in-VPC ingress
    (VPC CIDR) is retained so the OTel Collector's OTLP path is unaffected.

    Default false preserves ADR-030's fully-private internal ALB for every
    non-demo deployment. Only set true where Langfuse holds non-sensitive demo
    telemetry.
  EOT
}

variable "cloudfront_origin_secret_header" {
  type        = string
  default     = "x-eap-origin"
  description = "Header name the demo console CloudFront injects and this ALB requires when enable_cloudfront_origin is true (origin lockdown, ADR-038)."
}

variable "cloudfront_origin_secret_value" {
  type        = string
  default     = ""
  description = "Secret value for the CloudFront origin header (ADR-038). Required (non-empty) when enable_cloudfront_origin is true."
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Edge / DNS / TLS — HTTPS only (Requirements 11.6, 15.6)
# ---------------------------------------------------------------------------
variable "dns_domain_name" {
  type        = string
  default     = null
  description = "Optional public hostname for Langfuse (e.g. langfuse.example.com). When set with cloudfront_certificate_arn, it is added as a CloudFront alias and used to build NEXTAUTH_URL. When null, the CloudFront default domain and certificate are used."
}

variable "acm_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate ARN for a PUBLIC Langfuse_ALB HTTPS listener. DEPRECATED / unused in the private model (ADR-030): the default deploy uses a private internal HTTP ALB with no ACM. Retained optional for a future public-exposure opt-in. Edge is simplified to internal HTTP in a follow-up commit."
}

variable "cloudfront_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate ARN in us-east-1 for the CloudFront distribution when a custom dns_domain_name is used. When null, the CloudFront default certificate is used."
}

# ---------------------------------------------------------------------------
# Cognito — shared-platform user pool for the ALB authenticate-cognito action
# (task 9.1). When all three inputs are supplied the HTTPS listener requires an
# authenticated Cognito session before forwarding to the Langfuse web target
# group; when any is null the listener falls back to forward-only (local
# testing). Requirements 13.2, 13.5, 15.2.
# ---------------------------------------------------------------------------
variable "cognito_user_pool_arn" {
  type        = string
  default     = null
  description = "Shared platform Cognito user pool ARN for the Langfuse_ALB authenticate-cognito action. When null (with the other Cognito inputs), the listener falls back to forward-only for local testing."
}

variable "cognito_user_pool_client_id" {
  type        = string
  default     = null
  description = "Cognito app client ID for the Langfuse_ALB authenticate-cognito action. Must be set (together with the pool ARN and domain) to enable ALB Cognito authentication."
}

variable "cognito_user_pool_domain" {
  type        = string
  default     = null
  description = "Cognito hosted-UI domain for the Langfuse_ALB authenticate-cognito action. Must be set (together with the pool ARN and client ID) to enable ALB Cognito authentication."
}

variable "console_domain" {
  type        = string
  default     = null
  description = "Console origin permitted to iframe-embed Langfuse via a Content-Security-Policy `frame-ancestors 'self' https://<console-domain>` response header (CloudFront response-headers policy). When null, no policy is attached and CloudFront emits no frame-denying header."
}

# ---------------------------------------------------------------------------
# ECS Fargate compute (Requirement 11.2)
# ---------------------------------------------------------------------------
variable "ecs_cluster_arn" {
  type        = string
  default     = null
  description = "Existing ECS cluster ARN to run the Langfuse services in. When null, the module creates a dedicated cluster."
}

variable "langfuse_web_image" {
  type        = string
  default     = "langfuse/langfuse:3"
  description = "Container image for the Langfuse web service"
}

variable "langfuse_worker_image" {
  type        = string
  default     = "langfuse/langfuse-worker:3"
  description = "Container image for the Langfuse worker service"
}

variable "web_container_port" {
  type        = number
  default     = 3000
  description = "Port the Langfuse web container listens on"
}

variable "web_task_cpu" {
  type        = number
  default     = 1024
  description = "Fargate task CPU units for the Langfuse web service"
}

variable "web_task_memory" {
  type        = number
  default     = 2048
  description = "Fargate task memory (MiB) for the Langfuse web service"
}

variable "web_desired_count" {
  type        = number
  default     = 2
  description = "Desired number of Langfuse web tasks"
  validation {
    condition     = var.web_desired_count >= 1
    error_message = "web_desired_count must be at least 1."
  }
}

variable "worker_task_cpu" {
  type        = number
  default     = 1024
  description = "Fargate task CPU units for the Langfuse worker service"
}

variable "worker_task_memory" {
  type        = number
  default     = 2048
  description = "Fargate task memory (MiB) for the Langfuse worker service"
}

variable "worker_desired_count" {
  type        = number
  default     = 1
  description = "Desired number of Langfuse worker tasks"
  validation {
    condition     = var.worker_desired_count >= 1
    error_message = "worker_desired_count must be at least 1."
  }
}

# ---------------------------------------------------------------------------
# Aurora PostgreSQL Serverless v2 — transactional store (Requirement 11.3)
# ---------------------------------------------------------------------------
variable "postgres_engine_version" {
  type = string
  # 16.4 was retired from Aurora PostgreSQL (only 16.4-limitless remains); use
  # the lowest currently-available standard 16.x. Langfuse supports PG 16.x.
  default     = "16.8"
  description = "Aurora PostgreSQL engine version"
}

variable "postgres_database_name" {
  type        = string
  default     = "langfuse"
  description = "Initial database name created in the Aurora cluster"
}

variable "postgres_master_username" {
  type        = string
  default     = "langfuse"
  description = "Master username for the Aurora PostgreSQL cluster"
}

variable "aurora_min_capacity" {
  type        = number
  default     = 0.5
  description = "Aurora Serverless v2 minimum capacity (ACUs)"
}

variable "aurora_max_capacity" {
  type        = number
  default     = 4
  description = "Aurora Serverless v2 maximum capacity (ACUs)"
}

# ---------------------------------------------------------------------------
# ClickHouse on Fargate with an EBS-backed volume — analytical store (11.4)
# ---------------------------------------------------------------------------
variable "clickhouse_image" {
  type        = string
  default     = "clickhouse/clickhouse-server:24.12"
  description = "Container image for the ClickHouse server"
}

variable "clickhouse_task_cpu" {
  type        = number
  default     = 2048
  description = "Fargate task CPU units for ClickHouse"
}

variable "clickhouse_task_memory" {
  type        = number
  default     = 4096
  description = "Fargate task memory (MiB) for ClickHouse"
}

variable "clickhouse_data_volume_size_gb" {
  type        = number
  default     = 50
  description = "Size (GiB) of the EBS-backed data volume attached to the ClickHouse Fargate task"
  validation {
    condition     = var.clickhouse_data_volume_size_gb >= 20
    error_message = "ClickHouse data volume must be at least 20 GiB."
  }
}

variable "clickhouse_user" {
  type        = string
  default     = "langfuse"
  description = "ClickHouse username used by the Langfuse services"
}

variable "clickhouse_native_port" {
  type        = number
  default     = 9000
  description = "ClickHouse native protocol port"
}

variable "clickhouse_http_port" {
  type        = number
  default     = 8123
  description = "ClickHouse HTTP protocol port"
}

# ---------------------------------------------------------------------------
# ElastiCache Redis — cache/queue store (Requirement 11.5)
# ---------------------------------------------------------------------------
variable "redis_node_type" {
  type        = string
  default     = "cache.t4g.small"
  description = "ElastiCache Redis node type"
}

variable "redis_engine_version" {
  type        = string
  default     = "7.1"
  description = "ElastiCache Redis engine version"
}

variable "redis_port" {
  type        = number
  default     = 6379
  description = "ElastiCache Redis port"
}

# ---------------------------------------------------------------------------
# Encryption — customer-managed KMS at-rest (Requirement 15.5).
# When an ARN is supplied, Aurora, the ClickHouse EBS volume, ElastiCache Redis,
# every Secrets Manager secret, and the S3 blob bucket (aws:kms) are encrypted
# with this customer-managed key, and the per-service task/execution roles are
# granted the minimal KMS actions they need. When null, AWS-managed keys /
# service defaults are used and no KMS grants are attached (a sane default that
# still encrypts at rest via AWS-owned/managed keys).
# ---------------------------------------------------------------------------
variable "kms_key_arn" {
  type        = string
  default     = null
  description = "Customer-managed KMS key ARN for at-rest encryption of Aurora, ClickHouse EBS, Redis, Secrets Manager secrets, and the S3 blob bucket. When null, AWS-managed keys / service defaults are used."
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention (days) for the Langfuse containers"
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_group_retention_days)
    error_message = "Retention must be a valid CloudWatch retention value."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all resources"
}

# ---------------------------------------------------------------------------
# Per-BU Langfuse projects (task 10.1 — Requirement 14.1)
#
# One Langfuse_Project is provisioned per Business_Unit so each BU's traces,
# prompts, and evaluations are isolated in its own project (R14.1). Langfuse has
# no native Terraform resource — projects/keys are created via Langfuse's
# headless init (LANGFUSE_INIT_*) on first boot and/or its Public API. This
# module pre-provisions a per-project public/secret key pair (stored in Secrets
# Manager, KMS-encrypted like the other secrets) and emits a
# `LangfuseProjectBinding` per BU (bu -> projectId + key refs + base64
# Basic-auth ref) that the OTel_Collector per-BU routing (task 10.2) consumes.
# ---------------------------------------------------------------------------
variable "business_units" {
  type = list(object({
    # Business_Unit identifier (the tenant boundary; matches the collector's
    # `deployment.environment` (BU) resource attribute used for routing).
    bu = string
    # Optional human-friendly project name; defaults to the `bu` value.
    name = optional(string)
  }))
  default     = []
  description = "Business_Units that each get their own Langfuse_Project. One project + per-project public/secret key pair (in Secrets Manager) + a LangfuseProjectBinding output is provisioned per entry. Empty (default) provisions no per-BU projects."

  validation {
    # Fail closed on duplicate BUs so two entries can never collide onto one
    # project or share a key set (per-BU isolation — R14.1).
    condition     = length(var.business_units) == length(distinct([for u in var.business_units : u.bu]))
    error_message = "business_units must have distinct `bu` values (one Langfuse project per Business_Unit)."
  }
}

variable "langfuse_init_user_email" {
  type = string
  # Must pass Langfuse's email validator. Langfuse rejects `.local` TLDs and has
  # been observed rejecting `example.com`/subdomain-y addresses too, silently
  # failing headless init. Use a plain, real-looking domain with no subdomain.
  default     = "admin@eap.ai"
  description = "Email of the initial Langfuse admin/owner user created by headless init (REQUIRED: a project needs an org, and an org needs an owning user). Must satisfy Langfuse's email validator — use a plain real domain (avoid .local and example.com). Override if your instance is pickier. Password is generated and stored in Secrets Manager (<name>-init-user-password)."
}

variable "enable_project_bootstrap" {
  type        = bool
  default     = false
  description = "When true, run an idempotent post-apply bootstrap (local-exec) that seeds any per-BU Langfuse projects beyond the headless-init primary via the Langfuse Public API. Defaults to false so `terraform validate`/`plan` never require live Langfuse credentials; the primary project is always seeded by Langfuse headless init (LANGFUSE_INIT_*)."
}

variable "langfuse_admin_api_base_url" {
  type        = string
  default     = null
  description = "Base URL of the Langfuse Public API used by the optional project bootstrap (var.enable_project_bootstrap). When null, the module uses the stack's own public HTTPS origin (NEXTAUTH_URL)."
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection. The teardown scripts set this to false right before terraform destroy."
  type        = bool
  default     = true
}
