# EAP Browser Module — Main
# Maps 1:1 to aws_bedrockagentcore_browser
# Requirements: R5.1

locals {
  module_tags = merge(var.tags, {
    eap_module = "browser"
    eap_domain = var.domain
  })
}

# ---------------------------------------------------------------------------
# AgentCore Browser
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_browser" "this" {
  name               = var.name
  description        = var.description
  execution_role_arn = var.execution_role_arn

  network_configuration {
    network_mode = var.network_mode

    dynamic "vpc_config" {
      for_each = var.network_mode == "VPC" && var.vpc_config != null ? [var.vpc_config] : []
      content {
        security_groups = toset(vpc_config.value.security_groups)
        subnets         = toset(vpc_config.value.subnets)
      }
    }
  }

  dynamic "recording" {
    for_each = var.recording.enabled ? [var.recording] : []
    content {
      enabled = recording.value.enabled
      s3_location {
        bucket = recording.value.s3_bucket
        prefix = recording.value.s3_prefix
      }
    }
  }

  tags = local.module_tags
}
