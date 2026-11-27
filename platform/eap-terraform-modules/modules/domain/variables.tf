# EAP Domain Module — Variables
# Federated administration boundary for multi-tenancy
# Requirements: R17.1, R17.2, R17.3, R17.6, R17.7, R15.9, R13.1

variable "name" {
  type        = string
  description = "Domain name (e.g., support, sales, finance)"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "Domain name must be lowercase alphanumeric with hyphens, 3-32 chars."
  }
}

variable "idp_config" {
  type = object({
    provider_type              = string # okta, entra, cognito
    group_name                 = optional(string)
    api_credentials_secret_arn = string
  })
  description = "Identity provider configuration for Domain IdP group (ADR-014)"

  validation {
    condition     = contains(["okta", "entra", "cognito"], var.idp_config.provider_type)
    error_message = "provider_type must be one of: okta, entra, cognito."
  }
}

variable "iam_boundary" {
  type = object({
    policy_arn = optional(string)
    create     = optional(bool, true)
  })
  default     = {}
  description = "IAM permission boundary config. Set create=true to auto-generate, or supply policy_arn."
}

variable "workspace_config" {
  type = object({
    backend      = optional(string, "s3")
    tf_cloud_org = optional(string)
  })
  default     = {}
  description = "Terraform state backend config. Defaults to S3; set backend='terraform-cloud' for TFC."

  validation {
    condition     = contains(["s3", "terraform-cloud"], var.workspace_config.backend)
    error_message = "backend must be 's3' or 'terraform-cloud'."
  }
}

variable "ecr_config" {
  type = object({
    create_repo             = optional(bool, true)
    lifecycle_days          = optional(number, 90)
    scan_on_push            = optional(bool, true) # deprecated: scan on push is always enabled
    cross_account_pull_arns = optional(list(string), [])
  })
  default     = {}
  description = "ECR repository configuration for this domain's container images."
}

variable "admin_users" {
  type        = list(string)
  default     = []
  description = "IAM ARNs or IdP user IDs to grant Domain_Admin role."
}

variable "policy_store_bucket" {
  type        = string
  description = "S3 bucket for Cedar policy storage (shared across domains)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
