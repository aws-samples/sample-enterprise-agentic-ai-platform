# EAP Code Interpreter Module — Variables
# Maps 1:1 to aws_bedrockagentcore_code_interpreter
# Requirements: R4.1

variable "name" {
  type        = string
  description = "Name of the code interpreter"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-64 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this code interpreter belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "description" {
  type        = string
  default     = null
  description = "Description of the code interpreter"
}

variable "network_mode" {
  type        = string
  default     = "SANDBOX"
  description = "Network mode: PUBLIC, SANDBOX, or VPC"
  validation {
    condition     = contains(["PUBLIC", "SANDBOX", "VPC"], var.network_mode)
    error_message = "Network mode must be PUBLIC, SANDBOX, or VPC."
  }
}

variable "execution_role_arn" {
  type        = string
  default     = null
  description = "IAM role ARN for code execution. Required for SANDBOX mode."
}

variable "vpc_config" {
  type = object({
    security_groups = list(string)
    subnets         = list(string)
  })
  default     = null
  description = "VPC configuration. Required when network_mode is VPC."
}

variable "tags" {
  type    = map(string)
  default = {}
}
