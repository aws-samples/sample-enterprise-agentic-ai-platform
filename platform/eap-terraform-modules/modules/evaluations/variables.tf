# EAP Evaluations Module — Variables
# Manages agent quality evaluation configuration
# Requirements: R7.1, R7.2, R7.3
#
# NOTE: AgentCore Evaluations is a runtime service. This module manages the
# evaluation configuration as SSM parameters that the evaluation service reads.

variable "name" {
  type        = string
  description = "Name of the evaluation configuration — must match AgentCore naming conventions."
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,47}$", var.name))
    error_message = "Name must match AgentCore regex: start with letter, alphanumeric + underscores, max 48 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this evaluation config belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "runtime_id" {
  type        = string
  description = "AgentCore Runtime ID to evaluate"
}

variable "evaluators" {
  type = list(object({
    name      = string
    threshold = optional(number)
    enabled   = optional(bool, true)
  }))
  default = [
    { name = "correctness" },
    { name = "helpfulness" },
    { name = "safety", threshold = 0.95 },
  ]
  description = "Built-in evaluators: correctness, helpfulness, safety, goal_success_rate"
  validation {
    condition = alltrue([
      for e in var.evaluators : contains(["correctness", "helpfulness", "safety", "goal_success_rate"], e.name)
    ])
    error_message = "Evaluator name must be: correctness, helpfulness, safety, or goal_success_rate."
  }
}

variable "custom_evaluators" {
  type = list(object({
    name        = string
    lambda_arn  = string
    description = optional(string)
    threshold   = optional(number)
  }))
  default     = []
  description = "Custom evaluator Lambda functions"
}

variable "schedule" {
  type        = string
  default     = "rate(1 hour)"
  description = "Evaluation schedule expression (CloudWatch Events syntax)"
}

variable "tags" {
  type    = map(string)
  default = {}
}
