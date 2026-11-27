# EAP Identity Module — Variables
# Maps to aws_bedrockagentcore_workload_identity + aws_bedrockagentcore_oauth2_credential_provider
# Requirements: R15.1, R15.2, R15.5, R15.11

variable "name" {
  type        = string
  description = "Name of the workload identity"
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9._-]{1,253}[a-zA-Z0-9]$", var.name))
    error_message = "Name must be 3-255 chars, alphanumeric with hyphens, periods, underscores."
  }
}

variable "domain" {
  type        = string
  description = "Domain this identity configuration belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "allowed_oauth2_return_urls" {
  type        = list(string)
  default     = []
  description = "Allowed OAuth2 return URLs for resources associated with this workload identity"
}

variable "oauth2_providers" {
  type = list(object({
    name   = string
    vendor = string # CustomOauth2, GithubOauth2, GoogleOauth2, Microsoft, SalesforceOauth2, SlackOauth2
    # For custom providers
    client_id     = optional(string)
    client_secret = optional(string)
    discovery_url = optional(string)
    # For custom providers with manual metadata
    authorization_server_metadata = optional(object({
      issuer                 = string
      authorization_endpoint = string
      token_endpoint         = string
      response_types         = optional(set(string))
    }))
  }))
  default     = []
  description = "OAuth2 credential providers to configure for this identity"
}

variable "api_key_providers" {
  type = list(object({
    name    = string
    api_key = string
  }))
  default     = []
  sensitive   = true
  description = "API key credential providers"
}

variable "tags" {
  type    = map(string)
  default = {}
}
