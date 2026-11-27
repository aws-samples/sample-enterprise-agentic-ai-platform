# Gateway Deploy Template — Adds targets to the platform-owned gateway
# This config is used by the mcp-integrations pipeline's Deploy stage.
# It discovers all targets/*.yaml files and registers them as gateway targets.
#
# The gateway itself is deployed by eap-platform (horizontal infra).
# This template only manages targets (vertical/team-owned content).
#
# All values are injected via TF_VAR_ environment variables from CodeBuild.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Read platform state to get gateway_id (horizontal infra)
# ---------------------------------------------------------------------------
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = var.platform_state_bucket
    key    = var.platform_state_key
    region = var.aws_region
  }
}

locals {
  gateway_id = data.terraform_remote_state.platform.outputs.gateway_id

  # Auto-discover YAML files from mcp/, rest-api/, and lambda/ subfolders
  mcp_files  = [for f in fileset("${path.module}/mcp", "*.yaml") : f if !startswith(f, "_")]
  rest_files = [for f in fileset("${path.module}/rest-api", "*.yaml") : f if !startswith(f, "_")]

  mcp_targets = {
    for f in local.mcp_files : trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/mcp/${f}"))
  }
  rest_targets = {
    for f in local.rest_files : trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/rest-api/${f}"))
  }
}

# ---------------------------------------------------------------------------
# Gateway Targets — Remote MCP servers (from mcp/*.yaml)
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway_target" "mcp" {
  for_each = local.mcp_targets

  name               = each.value.name
  gateway_identifier = local.gateway_id
  description        = try(each.value.description, "")

  target_configuration {
    mcp {
      mcp_server {
        endpoint = each.value.endpoint
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Gateway Targets — REST API servers (from rest-api/*.yaml)
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway_target" "rest" {
  for_each = {
    for k, t in local.rest_targets : k => t
    if try(t.endpoint, null) != null
  }

  name               = each.value.name
  gateway_identifier = local.gateway_id
  description        = try(each.value.description, "")

  target_configuration {
    mcp {
      mcp_server {
        endpoint = each.value.endpoint
      }
    }
  }
}
