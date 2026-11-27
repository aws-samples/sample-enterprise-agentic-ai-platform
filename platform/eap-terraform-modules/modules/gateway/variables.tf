# EAP Gateway Module — Variables
# Maps 1:1 to aws_bedrockagentcore_gateway + aws_bedrockagentcore_gateway_target
# Requirements: R8.1, R8.2, R8.3, R8.4, R8.6, R9.1, R9.2, R9.7

variable "name" {
  type        = string
  description = "Name of the gateway"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-64 chars."
  }
}

variable "domain" {
  type        = string
  description = "Domain this gateway belongs to"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "description" {
  type        = string
  default     = null
  description = "Description of the gateway"
}

variable "role_arn" {
  type        = string
  description = "IAM role ARN the gateway assumes to access AWS services"
}

variable "authorizer_type" {
  type        = string
  default     = "AWS_IAM"
  description = "Type of authorizer: CUSTOM_JWT or AWS_IAM"
  validation {
    condition     = contains(["CUSTOM_JWT", "AWS_IAM"], var.authorizer_type)
    error_message = "Authorizer type must be CUSTOM_JWT or AWS_IAM."
  }
}

variable "jwt_authorizer_config" {
  type = object({
    discovery_url    = string
    allowed_audience = optional(set(string))
    allowed_clients  = optional(set(string))
    allowed_scopes   = optional(set(string))
  })
  default     = null
  description = "JWT authorizer configuration. Required when authorizer_type is CUSTOM_JWT."
}

variable "mcp_config" {
  type = object({
    instructions       = optional(string)
    search_type        = optional(string, "SEMANTIC")
    supported_versions = optional(set(string))
  })
  default     = {}
  description = "MCP protocol configuration for the gateway"
}

variable "kms_key_arn" {
  type        = string
  default     = null
  description = "KMS key ARN for gateway data encryption"
}

variable "exception_level" {
  type        = string
  default     = null
  description = "Exception level: INFO, WARN, ERROR"
}

variable "targets" {
  type = list(object({
    name        = string
    description = optional(string)
    # Lambda-backed MCP target
    lambda_arn = optional(string)
    # Remote MCP server target
    mcp_server_endpoint = optional(string)
    # Credential config
    credential_type = optional(string, "gateway_iam_role") # gateway_iam_role, api_key, oauth
    credential_config = optional(object({
      # api_key fields
      provider_arn              = optional(string)
      credential_location       = optional(string)
      credential_parameter_name = optional(string)
      credential_prefix         = optional(string)
      # oauth fields
      scopes             = optional(set(string))
      grant_type         = optional(string)
      default_return_url = optional(string)
      custom_parameters  = optional(map(string))
    }))
    # Tool schema for lambda targets
    tool_schemas = optional(list(object({
      name              = string
      description       = string
      input_schema_json = optional(string) # JSON-encoded schema for complex inputs
    })), [])
    # Header propagation
    allowed_request_headers  = optional(set(string))
    allowed_response_headers = optional(set(string))
    allowed_query_parameters = optional(set(string))
  }))
  default     = []
  description = "Gateway targets (MCP servers) to register"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_policy_engine" {
  type        = bool
  default     = true
  description = "Whether to create a Cedar policy engine for this gateway"
}

variable "policy_engine_mode" {
  type        = string
  default     = "ENFORCE"
  description = "Policy engine mode: ENFORCE or LOG_ONLY"
  validation {
    condition     = contains(["ENFORCE", "LOG_ONLY"], var.policy_engine_mode)
    error_message = "Policy engine mode must be ENFORCE or LOG_ONLY."
  }
}
