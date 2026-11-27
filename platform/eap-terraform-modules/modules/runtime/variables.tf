# EAP Runtime Module — Variables
# Maps 1:1 to aws_bedrockagentcore_agent_runtime
# Requirements: R1.5, R6.1, R6.4, R6.6, R12.3, R12.8, R15.7, R15.10, R15.12, R19.2, R20.1–R20.3

variable "name" {
  type        = string
  description = "Agent deployment name (AgentCore requires alphanumeric + underscores, starts with letter)"
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,47}$", var.name))
    error_message = "Name must match AgentCore regex: ^[a-zA-Z][a-zA-Z0-9_]{0,47}$"
  }
}

variable "domain" {
  type        = string
  description = "Domain this agent belongs to (used for identity grouping, tagging, env vars)"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.domain))
    error_message = "Domain must be lowercase alphanumeric with hyphens."
  }
}

variable "description" {
  type        = string
  default     = null
  description = "Description of the agent runtime"
}

variable "framework" {
  type        = string
  description = "Agent framework (strands, langgraph, crewai, custom)"
  validation {
    condition     = contains(["strands", "langgraph", "crewai", "custom"], var.framework)
    error_message = "Framework must be one of: strands, langgraph, crewai, custom."
  }
}

variable "container_image" {
  type        = string
  default     = null
  description = "ECR image URI for container-based deployment. Exactly one of container_image or code_package must be set."
}

variable "code_package" {
  type = object({
    s3_bucket     = string
    s3_key        = string
    s3_version_id = optional(string)
    runtime       = optional(string, "PYTHON_3_13")
    entry_point   = optional(list(string), ["main.py"])
  })
  default     = null
  description = "S3 code package for zip-based deployment. Exactly one of container_image or code_package must be set."
}

variable "protocols" {
  type        = list(string)
  default     = ["mcp", "a2a"]
  description = "Supported protocols: mcp, a2a, agui, http. MCP + A2A enabled by default (ADR-016)"
  validation {
    condition     = alltrue([for p in var.protocols : contains(["mcp", "a2a", "agui", "http"], p)])
    error_message = "Protocols must be from: mcp, a2a, agui, http."
  }
}

variable "scaling" {
  type = object({
    min_concurrency = number
    max_concurrency = number
  })
  default = {
    min_concurrency = 0
    max_concurrency = 10
  }
  validation {
    condition     = var.scaling.min_concurrency >= 0 && var.scaling.max_concurrency > var.scaling.min_concurrency
    error_message = "min_concurrency must be >= 0 and max_concurrency must be > min_concurrency."
  }
}

variable "session_config" {
  type = object({
    idle_timeout = optional(number, 3600)
    max_lifetime = optional(number, 28800)
  })
  default     = {}
  description = "Runtime session lifecycle configuration (seconds)"
}

variable "memory_ref" {
  type        = string
  default     = null
  description = "Memory resource ID to connect to this agent"
}

variable "gateway_refs" {
  type = list(object({
    gateway_id  = string
    mcp_servers = optional(list(string), [])
  }))
  default     = []
  description = "Gateway resource IDs and optional MCP server names for data/tool access"
}

variable "role_arn" {
  type        = string
  description = "IAM role ARN the agent runtime assumes to access AWS services"
}

variable "network_mode" {
  type        = string
  default     = "PUBLIC"
  description = "Network mode for the agent runtime"
  validation {
    condition     = contains(["PUBLIC", "VPC"], var.network_mode)
    error_message = "Network mode must be PUBLIC or VPC."
  }
}

variable "vpc_config" {
  type = object({
    security_groups = list(string)
    subnets         = list(string)
  })
  default     = null
  description = "VPC configuration. Required when network_mode is VPC."
}

variable "enable_auth" {
  type        = bool
  default     = false
  description = "Enable JWT authorizer on the runtime endpoint. When false, A2A communication is open (no token required). See docs/PARKED-cognito-a2a-auth.md for details."
}

variable "authorizer_config" {
  type = object({
    discovery_url    = string
    allowed_audience = optional(set(string))
    allowed_clients  = optional(set(string))
    allowed_scopes   = optional(set(string))
  })
  default     = null
  description = "Custom JWT authorizer configuration for incoming requests. Prefer using cognito_user_pool_id + cognito_app_client_id + allowed_callers for Cognito-based auth."
}

# --- Cognito Identity (Demo Tasks 18.2, 18.4) ---

variable "cognito_user_pool_id" {
  type        = string
  default     = null
  description = "Cognito User Pool ID. When set with cognito_app_client_id, auto-configures JWT authorizer using Cognito OIDC discovery."
}

variable "cognito_app_client_id" {
  type        = string
  default     = null
  description = "This agent's Cognito app client ID. Used as allowed_audience in JWT authorizer."
}

variable "allowed_callers" {
  type        = list(string)
  default     = []
  description = "List of Cognito app client IDs allowed to invoke this agent's A2A endpoint. Empty = deny all (default-deny)."
}

variable "model_id" {
  type        = string
  default     = null
  description = "Foundation model ID (e.g., anthropic.claude-sonnet-5). When set, injected as MODEL_ID env var."
}

variable "protocol_server_protocol" {
  type        = string
  default     = null
  description = "Server protocol for the agent runtime. Valid: HTTP, MCP, A2A. Derived from var.protocols[0] if not set."
}

variable "observability_config" {
  type = object({
    otel_endpoint       = optional(string, "")
    resource_attributes = optional(map(string), {})
    sampling_rate       = optional(number, 1.0)

    # --- Third-party observability leg (agentcore-observability feature) ---
    # OTLP receiver endpoint of the platform-owned OTel_Collector (Section 7).
    # When set, the runtime injects EAP_OTEL_COLLECTOR_ENDPOINT so the
    # base image's register_additional_span_exporter() (base-image, task 6.1)
    # registers an ADDITIONAL span exporter that sends a COPY of spans to the
    # collector. This is the THIRD-PARTY leg only — it never touches the
    # AWS-native leg. Empty (default) => no additional exporter is registered.
    # Requirements: R9.2, R12.4, R17.2, R17.3.
    collector_endpoint = optional(string, "")

    # Secrets Manager ARN of the per-Business_Unit third-party auth credential.
    # When set, injected as EAP_OTEL_COLLECTOR_HEADERS (the env var the
    # base image reads, task 6.1). NOTE: the AgentCore agent runtime resource
    # exposes only a plain string->string `environment_variables` map — it has
    # NO native Secrets Manager `valueFrom` resolution (unlike ECS task
    # definitions). This module therefore passes the credential BY REFERENCE
    # (the secret ARN as the env var value) following the module's established
    # plain-env pattern; concrete header material is resolved outside this
    # module (the per-BU Langfuse Basic-auth for the collector->Langfuse hop is
    # applied AT the collector, per design). Empty (default) => not injected.
    # Requirements: R17.3.
    collector_auth_secret_arn = optional(string, "")
  })
  default     = {}
  description = "Observability configuration injected as env vars. Defaults attached automatically (CP-4). collector_endpoint / collector_auth_secret_arn wire the additive third-party telemetry leg (agentcore-observability) and never affect the AWS-native leg."
}

variable "extra_environment_variables" {
  type        = map(string)
  default     = {}
  description = "Additional environment variables to pass to the container"
}

variable "tags" {
  type    = map(string)
  default = {}
}
