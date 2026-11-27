# EAP Orchestration Module — Variables
# Creates an AWS Step Functions state machine for multi-agent orchestration.
# Requirements: R31.1, R31.2, R31.9

variable "name" {
  type        = string
  description = "State machine name (e.g., {domain}_{app_name}_orchestration)"
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_-]{0,79}$", var.name))
    error_message = "Name must start with a letter, contain only alphanumeric/hyphens/underscores, max 80 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain identifier for tagging and log group naming"
}

variable "app_name" {
  type        = string
  description = "Application name for tagging and log group naming"
}

variable "definition" {
  type        = string
  description = "ASL JSON string defining the state machine"
  validation {
    condition     = can(jsondecode(var.definition))
    error_message = "Definition must be valid JSON (ASL)."
  }
}

variable "runtime_arns" {
  type        = list(string)
  description = "List of AgentCore Runtime endpoint ARNs the state machine invokes"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "invoke_bridge_lambda_arn" {
  type        = string
  description = "ARN of the Lambda bridge function that invokes AgentCore runtimes on behalf of Step Functions. Temporary — remove when AWS adds native SFN integration for AgentCore."
}

variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention (days) for the Step Functions execution logs"
}
