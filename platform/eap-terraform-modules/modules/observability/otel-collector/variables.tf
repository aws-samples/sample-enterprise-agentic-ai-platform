# EAP OTel_Collector Module — Variables
# Central Gateway OpenTelemetry Collector (ADOT distribution) on ECS Fargate.
#
# THIRD-PARTY LEG ONLY. This is the platform's single third-party backend swap
# point: a COPY of agent telemetry is received over OTLP (from the base-image
# Additional_Span_Exporter) and (in Section 7) fanned out ONLY to the configured
# third-party OTLP backend(s) resolved from `third_party_backends` (Langfuse by
# default). It has NO AWS-native (awsxray / awsemf / awscloudwatchlogs)
# exporters and NEVER exports to CloudWatch or X-Ray. The AWS-native leg is
# delivered by AgentCore auto-instrumentation and does not traverse this
# collector.
# Requirements: R12.1

variable "name" {
  type        = string
  description = "Name of the OTel collector deployment"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-64 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this collector belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

# ---------------------------------------------------------------------------
# Networking — the collector runs as an ECS Fargate service in PRIVATE subnets
# ---------------------------------------------------------------------------
variable "vpc_id" {
  type        = string
  description = "VPC in which the collector service and its receiver endpoint run"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Fargate collector tasks (never public)"
  validation {
    condition     = length(var.private_subnet_ids) > 0
    error_message = "At least one private subnet must be provided."
  }
}

# ---------------------------------------------------------------------------
# ECS Fargate service shape
# ---------------------------------------------------------------------------
variable "ecs_cluster_arn" {
  type        = string
  default     = null
  description = "Existing ECS cluster ARN to run the collector in. When null, the module creates a dedicated cluster."
}

variable "collector_image" {
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
  description = "Container image for the ADOT collector distribution"
}

variable "task_cpu" {
  type        = number
  default     = 512
  description = "Fargate task CPU units for the collector"
}

variable "task_memory" {
  type        = number
  default     = 1024
  description = "Fargate task memory (MiB) for the collector"
}

variable "desired_count" {
  type        = number
  default     = 2
  description = "Desired number of collector tasks"
  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "execution_role_arn" {
  type        = string
  default     = null
  description = "ECS task execution role ARN (image pull + logs). When null, the module creates one."
}

variable "task_role_arn" {
  type        = string
  default     = null
  description = "ECS task role ARN used by the collector to export telemetry. When null, the module creates a stub role (permissions wired in task 6)."
}

# ---------------------------------------------------------------------------
# OTLP receiver endpoint — Cloud Map service discovery and/or internal NLB
# ---------------------------------------------------------------------------
variable "otlp_grpc_port" {
  type        = number
  default     = 4317
  description = "OTLP/gRPC receiver port"
}

variable "otlp_http_port" {
  type        = number
  default     = 4318
  description = "OTLP/HTTP receiver port"
}

variable "enable_service_discovery" {
  type        = bool
  default     = true
  description = "Register the collector in AWS Cloud Map private DNS for in-VPC service discovery"
}

variable "service_discovery_namespace" {
  type        = string
  default     = "otel.eap.internal"
  description = "Private DNS namespace name for Cloud Map service discovery of the collector"
}

variable "enable_internal_nlb" {
  type        = bool
  default     = false
  description = "Front the collector with an internal Network Load Balancer as an alternative OTLP receiver endpoint"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention (days) for the collector container logs"
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_group_retention_days)
    error_message = "Retention must be a valid CloudWatch retention value."
  }
}

# ---------------------------------------------------------------------------
# Backend_Configuration — the third-party OTLP backend swap point.
#
# Empty (the default) => the collector exports third-party telemetry to the
# default Langfuse backend only. `mode` selects how a configured backend relates
# to the default Langfuse export ("replace" swaps it out, "add" runs alongside).
#
# NOTE: The AWS-native export (X-Ray + CloudWatch) is NOT part of this collector
# at all — it is delivered by a separate AgentCore-managed pipeline that never
# traverses this collector. There is therefore no value of this variable that
# can add, remove, reroute, or disable AWS-native export; that independence is
# structural. The third-party-only render logic that consumes this variable is
# implemented in Section 7 (see the stub in main.tf).
# Requirements: R12.1 (scaffold); R12.3, R16.* (render — Section 7)
# ---------------------------------------------------------------------------
variable "third_party_backends" {
  type = list(object({
    name            = string # "langfuse" | "fiddler" | "datadog" | ...
    otlp_endpoint   = string # https URL of the third-party OTLP receiver
    auth_secret_arn = string # Secrets Manager ARN holding the auth header/token
    mode            = string # "replace" | "add" (relative to the default Langfuse)
    enabled         = bool
  }))
  default     = []
  description = "Configured third-party OTLP backends. Empty => default Langfuse only. AWS-native export is never gated by this variable."

  validation {
    condition     = alltrue([for b in var.third_party_backends : contains(["replace", "add"], b.mode)])
    error_message = "Each third_party_backends entry must set mode to \"replace\" or \"add\"."
  }
}

# ---------------------------------------------------------------------------
# Per-BU Langfuse routing (task 10.4, R14.4).
#
# Deploy-time mirror of the per-BU routing branch in the canonical TS render
# `renderCollectorConfig(..., { langfuseProjectBindings, langfuseOtelEndpoint })`
# (eap-platform/observability/src/lib/collectorConfig.ts). When a
# non-empty set of bindings is supplied together with `default_langfuse_endpoint`
# (reused as the SHARED Langfuse OTLP endpoint), the collector routes each BU's
# telemetry to its own Langfuse project via a `routing` connector keyed on the
# `deployment.environment` (BU) resource attribute — each BU getting its own
# `otlphttp/langfuse-<bu>` exporter carrying that project's Basic-auth header.
#
# Empty (the default) => today's single-pipeline behavior is preserved.
#
# STILL third-party only: every rendered exporter is `otlphttp` — NO awsxray /
# awsemf / awscloudwatchlogs — and the per-BU auth secrets are the ONLY thing
# added to the collector's secrets-read grant (no CloudWatch/X-Ray/Logs write).
# ---------------------------------------------------------------------------
variable "langfuse_project_bindings" {
  type = list(object({
    bu                         = string # Business_Unit (matches the deployment.environment resource attribute)
    otlp_basic_auth_secret_arn = string # Secrets Manager ARN holding base64(public:secret) for this BU's Langfuse project
  }))
  default     = []
  description = "Per-BU Langfuse project bindings. Empty => single default third-party pipeline (no per-BU routing). When set, each BU's telemetry is routed to its own Langfuse project via a routing connector, using default_langfuse_endpoint as the shared Langfuse OTLP endpoint."
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Rendered-config coordinates (tasks 7.3 + 7.6).
#
# These feed the third-party-only collector config render (see the
# `collector_config` local in main.tf), mirroring the pure reference function
# `renderCollectorConfig(backendConfiguration, options)` in
# eap-platform/observability/src/lib/collectorConfig.ts. The default
# Langfuse endpoint is INJECTED (never hardcoded) so the render stays a pure,
# deterministic function of its inputs.
# ---------------------------------------------------------------------------
variable "default_langfuse_endpoint" {
  type        = string
  default     = ""
  description = "In-stack Langfuse OTLP receiver URL (e.g. http://<internal-alb>/api/public/otel) used as the default third-party exporter. Injected by the platform at render time; never hardcoded. EMPTY (default) => no Langfuse default exporter is rendered (collector runs with only the external backend, or with no third-party exporters at all)."
}

variable "default_langfuse_auth_secret_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager ARN holding the default Langfuse OTLP auth header. When empty, no Authorization header seam is rendered for the default Langfuse exporter."
}

variable "sending_queue_size" {
  type        = number
  default     = 1000
  description = "Per-exporter non-blocking sending_queue depth (task 7.6). Each third-party exporter gets its own queue so a stalled endpoint drops/queues only within this collector."
  validation {
    condition     = var.sending_queue_size >= 1
    error_message = "sending_queue_size must be at least 1."
  }
}

variable "retry_max_elapsed_time" {
  type        = string
  default     = "300s"
  description = "Per-exporter retry_on_failure max_elapsed_time (task 7.6)."
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection. The teardown scripts set this to false right before terraform destroy."
  type        = bool
  default     = true
}
