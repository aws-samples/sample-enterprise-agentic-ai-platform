# EAP Memory Module — Main
# Maps 1:1 to aws_bedrockagentcore_memory + aws_bedrockagentcore_memory_strategy
# Requirements: R2.1, R2.2, R2.3, R2.5, R2.6

locals {
  # Parse retention string (e.g., "30d") to integer days
  retention_days = tonumber(regex("^([0-9]+)d$", var.retention)[0])

  # Memory type to default retention mapping
  default_retention = {
    "short-term" = 7
    "long-term"  = 90
    "episodic"   = 30
  }

  # Use parsed retention or fall back to memory_type default
  event_expiry_duration = local.retention_days > 0 ? local.retention_days : local.default_retention[var.memory_type]

  module_tags = merge(var.tags, {
    eap_module  = "memory"
    eap_domain  = var.domain
    memory_type = var.memory_type
  })
}

# ---------------------------------------------------------------------------
# AgentCore Memory
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_memory" "this" {
  name                      = var.name
  description               = var.description
  event_expiry_duration     = local.event_expiry_duration
  encryption_key_arn        = var.encryption_key_arn
  memory_execution_role_arn = var.memory_execution_role_arn

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Memory Strategies (optional)
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_memory_strategy" "this" {
  for_each = { for idx, s in var.strategies : s.name => s }

  name        = each.value.name
  memory_id   = aws_bedrockagentcore_memory.this.id
  type        = each.value.type
  description = each.value.description
  namespaces  = toset(each.value.namespaces)

  dynamic "configuration" {
    for_each = each.value.configuration != null ? [each.value.configuration] : []
    content {
      type = configuration.value.type

      dynamic "consolidation" {
        for_each = configuration.value.consolidation != null ? [configuration.value.consolidation] : []
        content {
          append_to_prompt = consolidation.value.append_to_prompt
          model_id         = consolidation.value.model_id
        }
      }

      dynamic "extraction" {
        for_each = configuration.value.extraction != null ? [configuration.value.extraction] : []
        content {
          append_to_prompt = extraction.value.append_to_prompt
          model_id         = extraction.value.model_id
        }
      }
    }
  }
}
