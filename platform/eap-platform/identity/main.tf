# EAP Platform — Identity (Cognito)
# Provisions a Cognito User Pool for user authentication.
# Cognito is restricted to user→agent and user→gateway auth only.
# A2A communication is routed via AgentCore Gateway, not Cognito.
# Resource servers: gateway (tools.invoke, tools.read), agent (invoke)
# Requirements: R15.1, R15.2, R15.5, R15.11

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment"
}

variable "domain_prefix" {
  type        = string
  default     = "eap-agents"
  description = "Cognito domain prefix for the OAuth2 token endpoint"
}

variable "console_url" {
  type        = string
  default     = ""
  description = "Public base URL of the platform console (e.g. https://console.example.com). When set, its /auth/callback + logout URLs are added to the app client's allow-list. Empty => only local-dev callbacks are registered; the deployer adds the CloudFront callback after first apply (see DEPLOY-RUNBOOK)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # Local-dev callback/logout URLs (always allowed for the dev SPA). Standardized
  # on the /auth/callback path the console SPA actually uses.
  dev_callback_urls = [
    "http://localhost:5173/auth/callback",
    "http://localhost:3000/auth/callback",
  ]
  dev_logout_urls = [
    "http://localhost:5173/",
    "http://localhost:3000/",
  ]

  # Production callback/logout derived from the supplied console_url (no
  # hardcoded domains). Empty console_url => none added here; the CloudFront
  # callback is registered post-apply per the runbook.
  prod_callback_urls = var.console_url != "" ? ["${var.console_url}/auth/callback"] : []
  prod_logout_urls   = var.console_url != "" ? ["${var.console_url}/"] : []

  callback_urls = concat(local.dev_callback_urls, local.prod_callback_urls)
  logout_urls   = concat(local.dev_logout_urls, local.prod_logout_urls)
}

# ---------------------------------------------------------------------------
# Cognito User Pool — agent identity store
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "agents" {
  name = "eap-agents-${var.environment}"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Custom attribute to tag agents with their EAP domain
  schema {
    name                     = "eap_domain"
    attribute_data_type      = "String"
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  password_policy {
    minimum_length    = 16
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  deletion_protection = "INACTIVE"

  tags = merge(var.tags, {
    eap_module = "identity"
    eap_role   = "agent-identity"
  })
}

# ---------------------------------------------------------------------------
# Cognito Domain — enables OAuth2 token endpoint
# Token URL: https://{domain_prefix}.auth.{region}.amazoncognito.com/oauth2/token
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_domain" "agents" {
  domain       = "${var.domain_prefix}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.agents.id
}

# ---------------------------------------------------------------------------
# Resource Servers — define custom scopes for platform services
# Gateway: agents request tools via gateway
# Agent: users invoke agents
# ---------------------------------------------------------------------------
resource "aws_cognito_resource_server" "gateway" {
  identifier   = "gateway"
  name         = "AgentCore Gateway"
  user_pool_id = aws_cognito_user_pool.agents.id

  scope {
    scope_name        = "tools.invoke"
    scope_description = "Invoke tools via AgentCore Gateway"
  }

  scope {
    scope_name        = "tools.read"
    scope_description = "List and discover tools via AgentCore Gateway"
  }
}

resource "aws_cognito_resource_server" "agent" {
  identifier   = "agent"
  name         = "Agent Runtime"
  user_pool_id = aws_cognito_user_pool.agents.id

  scope {
    scope_name        = "invoke"
    scope_description = "Invoke an agent runtime"
  }
}

# ---------------------------------------------------------------------------
# Console App Client — public client for the platform console SPA
# Uses Authorization Code flow with PKCE (no client secret).
# Callback URLs are configured for local dev; update for production.
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_client" "console" {
  name         = "eap-console-${var.environment}"
  user_pool_id = aws_cognito_user_pool.agents.id

  generate_secret = false # SPA client — PKCE only

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_scopes                 = ["openid", "profile", "email"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = local.callback_urls
  logout_urls   = local.logout_urls

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  # The console module syncs the LIVE CloudFront callback into this client
  # post-deploy (null_resource.console_callback_sync) — the distribution's
  # random dXXXX.cloudfront.net domain isn't known at plan time, so it can't be
  # baked into callback_urls here. Ignore out-of-band changes to the URL lists
  # so a subsequent `terraform apply` doesn't revert that sync. The localhost
  # dev URLs above are still applied on create; the sync ADDS the CloudFront one.
  lifecycle {
    ignore_changes = [callback_urls, logout_urls]
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.agents.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.agents.arn
}

output "oidc_discovery_url" {
  description = "OIDC discovery URL for JWT validation"
  value       = "https://${aws_cognito_user_pool.agents.endpoint}/.well-known/openid-configuration"
}

output "token_endpoint" {
  description = "OAuth2 token endpoint for client credentials flow"
  value       = "https://${aws_cognito_user_pool_domain.agents.domain}.auth.${data.aws_region.current.id}.amazoncognito.com/oauth2/token"
}

output "gateway_resource_server_identifier" {
  description = "Resource server identifier for gateway scopes"
  value       = aws_cognito_resource_server.gateway.identifier
}

output "gateway_scope_invoke" {
  description = "Full scope identifier for gateway tools invoke (gateway/tools.invoke)"
  value       = "gateway/tools.invoke"
}

output "gateway_scope_read" {
  description = "Full scope identifier for gateway tools read (gateway/tools.read)"
  value       = "gateway/tools.read"
}

output "agent_resource_server_identifier" {
  description = "Resource server identifier for agent scopes"
  value       = aws_cognito_resource_server.agent.identifier
}

output "agent_scope_invoke" {
  description = "Full scope identifier for agent invoke (agent/invoke)"
  value       = "agent/invoke"
}

output "console_client_id" {
  description = "Cognito App Client ID for the platform console"
  value       = aws_cognito_user_pool_client.console.id
}
