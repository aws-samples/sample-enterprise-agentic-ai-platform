# EAP Memory Module — Variables
# Maps 1:1 to aws_bedrockagentcore_memory + aws_bedrockagentcore_memory_strategy
# Requirements: R2.1, R2.2, R2.3, R2.5, R2.6

variable "name" {
  type        = string
  description = "Name of the memory — must match AgentCore regex: alphanumeric + underscores, 1-48 chars."
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,47}$", var.name))
    error_message = "Name must match AgentCore regex: start with letter, alphanumeric + underscores, max 48 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this memory belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "description" {
  type        = string
  default     = null
  description = "Description of the memory"
}

variable "memory_type" {
  type        = string
  description = "Memory type: short-term (7d), long-term (90d+), or episodic (session-scoped)"
  validation {
    condition     = contains(["short-term", "long-term", "episodic"], var.memory_type)
    error_message = "Memory type must be: short-term, long-term, or episodic."
  }
}

variable "retention" {
  type        = string
  default     = "30d"
  description = "Retention period (e.g., 7d, 30d, 90d, 365d). Parsed to days for event_expiry_duration."
  validation {
    condition     = can(regex("^[0-9]+d$", var.retention))
    error_message = "Retention must be in format Nd (e.g., 30d, 90d)."
  }
}

variable "encryption_key_arn" {
  type        = string
  default     = null
  description = "ARN of KMS key for encryption. If not provided, AWS managed encryption is used."
}

variable "memory_execution_role_arn" {
  type        = string
  default     = null
  description = "IAM role ARN for memory operations. Required for custom memory strategies."
}

variable "strategies" {
  type = list(object({
    name        = string
    type        = string # SEMANTIC, SUMMARIZATION, USER_PREFERENCE, CUSTOM
    description = optional(string)
    namespaces  = list(string)
    configuration = optional(object({
      type = string # SEMANTIC_OVERRIDE, SUMMARY_OVERRIDE, USER_PREFERENCE_OVERRIDE
      consolidation = optional(object({
        append_to_prompt = string
        model_id         = string
      }))
      extraction = optional(object({
        append_to_prompt = string
        model_id         = string
      }))
    }))
  }))
  default     = []
  description = "Memory strategies to attach. Max 6 total, max 1 per built-in type."
}

variable "tags" {
  type    = map(string)
  default = {}
}
