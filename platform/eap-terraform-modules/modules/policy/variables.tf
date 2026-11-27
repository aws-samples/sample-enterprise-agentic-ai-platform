# EAP Policy Module — Variables
# Manages Cedar policy registration for AgentCore Policy enforcement
# Requirements: R16.1, R16.2, R16.4, R16.7
#
# NOTE: AgentCore Policy enforcement is a runtime service — Cedar policies are
# registered via the AgentCore API. This module manages the policy definitions
# as Terraform-managed resources (S3-backed policy store) and registers them
# via a Lambda-backed custom resource or the AgentCore API when available.

variable "name" {
  type        = string
  description = "Name of the policy set"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-64 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this policy applies to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "description" {
  type        = string
  default     = null
  description = "Description of the policy set"
}

variable "scope" {
  type        = string
  default     = "domain"
  description = "Policy scope: domain, agent, tool, or llm_provider"
  validation {
    condition     = contains(["domain", "agent", "tool", "llm_provider"], var.scope)
    error_message = "Scope must be: domain, agent, tool, or llm_provider."
  }
}

variable "cedar_policies" {
  type = list(object({
    policy_id   = string
    description = optional(string)
    effect      = string # permit or forbid
    principal   = optional(string, "Any")
    action      = optional(string, "Any")
    resource    = optional(string, "Any")
    conditions  = optional(list(string), [])
  }))
  default     = []
  description = "Cedar policy definitions"
}

variable "cedar_policy_files" {
  type        = list(string)
  default     = []
  description = "Paths to .cedar policy files to include"
}

variable "policy_store_bucket" {
  type        = string
  description = "S3 bucket for storing Cedar policy definitions"
}

variable "tags" {
  type    = map(string)
  default = {}
}
