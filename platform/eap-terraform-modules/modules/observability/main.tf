# EAP Observability Module — Main
# Manages CloudWatch log groups, dashboards, and OTel config for AgentCore agents
# Requirements: R19.1, R19.4, R19.7, R19.8

locals {
  module_tags = merge(var.tags, {
    eap_module = "observability"
    eap_domain = var.domain
  })

  # OTel resource attributes merged with defaults
  otel_resource_attributes = merge({
    "service.namespace"      = "eap"
    "deployment.environment" = var.domain
  }, var.resource_attributes)

  otel_resource_attributes_string = join(",", [
    for k, v in local.otel_resource_attributes : "${k}=${v}"
  ])
}

# ---------------------------------------------------------------------------
# CloudWatch Log Group — per-domain agent logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "agents" {
  name              = "/eap/${var.domain}/agents"
  retention_in_days = var.log_group_retention_days

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard — domain-level agent metrics
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "eap-${var.domain}-${var.name}"
  dashboard_body = jsonencode({
    widgets = length(var.dashboard_widgets) > 0 ? [
      for w in var.dashboard_widgets : {
        type   = w.type
        width  = w.width
        height = w.height
        properties = merge(w.properties, {
          title = w.title
        })
      }
      ] : [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title   = "Agent Invocations"
          metrics = [["EAP", "AgentInvocations", "Domain", var.domain]]
          period  = 300
          stat    = "Sum"
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title   = "Agent Latency (p99)"
          metrics = [["EAP", "AgentLatency", "Domain", var.domain]]
          period  = 300
          stat    = "p99"
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title   = "Agent Errors"
          metrics = [["EAP", "AgentErrors", "Domain", var.domain]]
          period  = 300
          stat    = "Sum"
        }
      }
    ]
  })
}


