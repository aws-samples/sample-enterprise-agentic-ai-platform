# EAP Code Interpreter Module — Main
# Maps 1:1 to aws_bedrockagentcore_code_interpreter
# Requirements: R4.1

locals {
  module_tags = merge(var.tags, {
    eap_module = "code-interpreter"
    eap_domain = var.domain
  })
}

# ---------------------------------------------------------------------------
# AgentCore Code Interpreter
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_code_interpreter" "this" {
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

  tags = local.module_tags
}
