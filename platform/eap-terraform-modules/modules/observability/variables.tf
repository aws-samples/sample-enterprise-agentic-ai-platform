# EAP Observability Module — Variables
# Manages OTel export config and CloudWatch dashboards for AgentCore agents
# Requirements: R19.1, R19.4, R19.7, R19.8
#
# NOTE: AgentCore auto-attaches observability to runtimes. This module manages
# the platform-level observability infrastructure: CloudWatch log groups,
# OTLP collector config, and dashboards.

variable "name" {
  type        = string
  description = "Name of the observability configuration"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-64 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this observability config applies to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention in days"
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_group_retention_days)
    error_message = "Retention must be a valid CloudWatch retention value."
  }
}

variable "otel_endpoint" {
  type        = string
  default     = ""
  description = "OTLP exporter endpoint. Empty string uses AWS default."
}

variable "sampling_rate" {
  type        = number
  default     = 1.0
  description = "Trace sampling rate (0.0 to 1.0)"
  validation {
    condition     = var.sampling_rate >= 0 && var.sampling_rate <= 1
    error_message = "Sampling rate must be between 0.0 and 1.0."
  }
}

variable "resource_attributes" {
  type        = map(string)
  default     = {}
  description = "Additional OTel resource attributes"
}

variable "create_dashboard" {
  type        = bool
  default     = true
  description = "Whether to create a CloudWatch dashboard for this domain"
}

variable "dashboard_widgets" {
  type = list(object({
    title      = string
    type       = string # metric, log, text
    width      = optional(number, 12)
    height     = optional(number, 6)
    properties = optional(map(string), {})
  }))
  default     = []
  description = "Custom dashboard widgets. If empty, default agent metrics widgets are created."
}

variable "alarm_config" {
  type = object({
    error_rate_threshold  = optional(number, 5)
    latency_p99_threshold = optional(number, 30)
    sns_topic_arn         = optional(string)
  })
  default     = {}
  description = "CloudWatch alarm configuration for agent health"
}

variable "tags" {
  type    = map(string)
  default = {}
}
