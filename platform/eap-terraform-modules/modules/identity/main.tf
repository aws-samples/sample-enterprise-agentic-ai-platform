# EAP Identity Module — Main
# Maps to aws_bedrockagentcore_workload_identity + credential providers
# Requirements: R15.1, R15.2, R15.5, R15.11

locals {
  module_tags = merge(var.tags, {
    eap_module = "identity"
    eap_domain = var.domain
  })
}

# ---------------------------------------------------------------------------
# AgentCore Workload Identity
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_workload_identity" "this" {
  name = var.name

  allowed_resource_oauth2_return_urls = length(var.allowed_oauth2_return_urls) > 0 ? toset(var.allowed_oauth2_return_urls) : null
}

# ---------------------------------------------------------------------------
# OAuth2 Credential Providers
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_oauth2_credential_provider" "this" {
  for_each = { for p in var.oauth2_providers : p.name => p }

  name                       = each.value.name
  credential_provider_vendor = each.value.vendor

  oauth2_provider_config {
    dynamic "custom_oauth2_provider_config" {
      for_each = each.value.vendor == "CustomOauth2" ? [each.value] : []
      content {
        client_id     = custom_oauth2_provider_config.value.client_id
        client_secret = custom_oauth2_provider_config.value.client_secret

        dynamic "oauth_discovery" {
          for_each = custom_oauth2_provider_config.value.discovery_url != null ? [1] : []
          content {
            discovery_url = custom_oauth2_provider_config.value.discovery_url
          }
        }

        dynamic "oauth_discovery" {
          for_each = custom_oauth2_provider_config.value.authorization_server_metadata != null ? [custom_oauth2_provider_config.value.authorization_server_metadata] : []
          content {
            authorization_server_metadata {
              issuer                 = oauth_discovery.value.issuer
              authorization_endpoint = oauth_discovery.value.authorization_endpoint
              token_endpoint         = oauth_discovery.value.token_endpoint
              response_types         = oauth_discovery.value.response_types
            }
          }
        }
      }
    }

    dynamic "github_oauth2_provider_config" {
      for_each = each.value.vendor == "GithubOauth2" ? [each.value] : []
      content {
        client_id     = github_oauth2_provider_config.value.client_id
        client_secret = github_oauth2_provider_config.value.client_secret
      }
    }

    dynamic "google_oauth2_provider_config" {
      for_each = each.value.vendor == "GoogleOauth2" ? [each.value] : []
      content {
        client_id     = google_oauth2_provider_config.value.client_id
        client_secret = google_oauth2_provider_config.value.client_secret
      }
    }

    dynamic "microsoft_oauth2_provider_config" {
      for_each = each.value.vendor == "Microsoft" ? [each.value] : []
      content {
        client_id     = microsoft_oauth2_provider_config.value.client_id
        client_secret = microsoft_oauth2_provider_config.value.client_secret
      }
    }

    dynamic "salesforce_oauth2_provider_config" {
      for_each = each.value.vendor == "SalesforceOauth2" ? [each.value] : []
      content {
        client_id     = salesforce_oauth2_provider_config.value.client_id
        client_secret = salesforce_oauth2_provider_config.value.client_secret
      }
    }

    dynamic "slack_oauth2_provider_config" {
      for_each = each.value.vendor == "SlackOauth2" ? [each.value] : []
      content {
        client_id     = slack_oauth2_provider_config.value.client_id
        client_secret = slack_oauth2_provider_config.value.client_secret
      }
    }
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# API Key Credential Providers
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_api_key_credential_provider" "this" {
  for_each = { for p in var.api_key_providers : p.name => p }

  name    = each.value.name
  api_key = each.value.api_key

  tags = local.module_tags
}
