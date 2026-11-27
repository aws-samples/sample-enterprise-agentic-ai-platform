# EAP Browser Module — Variables
# Maps 1:1 to aws_bedrockagentcore_browser
# Requirements: R5.1

variable "name" {
  type        = string
  description = "Name of the browser"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-64 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this browser belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "description" {
  type        = string
  default     = null
  description = "Description of the browser"
}

variable "network_mode" {
  type        = string
  default     = "PUBLIC"
  description = "Network mode: PUBLIC or VPC"
  validation {
    condition     = contains(["PUBLIC", "VPC"], var.network_mode)
    error_message = "Network mode must be PUBLIC or VPC."
  }
}

variable "execution_role_arn" {
  type        = string
  default     = null
  description = "IAM role ARN for browser execution"
}

variable "vpc_config" {
  type = object({
    security_groups = list(string)
    subnets         = list(string)
  })
  default     = null
  description = "VPC configuration. Required when network_mode is VPC."
}

variable "recording" {
  type = object({
    enabled   = optional(bool, false)
    s3_bucket = optional(string)
    s3_prefix = optional(string, "browser-sessions/")
  })
  default     = {}
  description = "Browser session recording configuration"
}

variable "tags" {
  type    = map(string)
  default = {}
}
