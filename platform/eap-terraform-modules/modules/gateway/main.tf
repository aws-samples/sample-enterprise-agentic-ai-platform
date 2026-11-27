# EAP Gateway Module — Main
# Maps 1:1 to aws_bedrockagentcore_gateway + aws_bedrockagentcore_gateway_target
# Requirements: R8.1, R8.2, R8.3, R8.4, R8.6, R9.1, R9.2, R9.7

data "aws_region" "current" {}

locals {
  module_tags = merge(var.tags, {
    eap_module = "gateway"
    eap_domain = var.domain
  })

  # Separate targets by type for dynamic blocks
  lambda_targets     = { for t in var.targets : t.name => t if t.lambda_arn != null }
  mcp_server_targets = { for t in var.targets : t.name => t if t.mcp_server_endpoint != null }
}

# ---------------------------------------------------------------------------
# AgentCore Gateway
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway" "this" {
  name            = var.name
  description     = var.description
  role_arn        = var.role_arn
  authorizer_type = var.authorizer_type
  protocol_type   = "MCP"
  kms_key_arn     = var.kms_key_arn
  exception_level = var.exception_level

  dynamic "authorizer_configuration" {
    for_each = var.authorizer_type == "CUSTOM_JWT" && var.jwt_authorizer_config != null ? [var.jwt_authorizer_config] : []
    content {
      custom_jwt_authorizer {
        discovery_url    = authorizer_configuration.value.discovery_url
        allowed_audience = authorizer_configuration.value.allowed_audience
        allowed_clients  = authorizer_configuration.value.allowed_clients
        allowed_scopes   = authorizer_configuration.value.allowed_scopes
      }
    }
  }

  protocol_configuration {
    mcp {
      instructions       = var.mcp_config.instructions
      search_type        = var.mcp_config.search_type
      supported_versions = var.mcp_config.supported_versions
    }
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Gateway Targets — Lambda-backed MCP servers (FUTURE)
# ---------------------------------------------------------------------------
# Lambda targets require tool_schema with input_schema blocks that map
# each tool's parameters. This needs per-tool schema definitions in the
# YAML manifests. Parked until we define the schema format.
# See the Terraform provider docs for
# aws_bedrockagentcore_gateway_target lambda block.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Policy Engine — Cedar authorization for the gateway
# Platform creates this; governance repo attaches policies to it.
# The policy engine is a standalone resource. Attachment to gateway is
# configured on the gateway resource via policy_engine_configuration.
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_policy_engine" "this" {
  count = var.enable_policy_engine ? 1 : 0

  name        = "${replace(var.name, "-", "_")}_policy_engine"
  description = "Cedar policy engine for ${var.name} gateway"
  tags        = local.module_tags
}

# TODO: Associate policy engine with gateway
# The Terraform provider does not yet expose policy_engine_configuration on the
# gateway resource. Manually associate via AWS Console or CLI:
#   aws bedrock-agentcore-control update-gateway \
#     --gateway-identifier <gateway_id> \
#     --policy-engine-configuration '{"arn":"<policy_engine_arn>","mode":"ENFORCE"}'
# Once the provider adds this attribute, replace with a native resource reference.

# ---------------------------------------------------------------------------
# Gateway Targets — Remote MCP servers
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway_target" "mcp_server" {
  for_each = local.mcp_server_targets

  name               = each.value.name
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = each.value.description

  target_configuration {
    mcp {
      mcp_server {
        endpoint = each.value.mcp_server_endpoint
      }
    }
  }

  dynamic "metadata_configuration" {
    for_each = (each.value.allowed_request_headers != null || each.value.allowed_response_headers != null || each.value.allowed_query_parameters != null) ? [1] : []
    content {
      allowed_request_headers  = each.value.allowed_request_headers
      allowed_response_headers = each.value.allowed_response_headers
      allowed_query_parameters = each.value.allowed_query_parameters
    }
  }
}
