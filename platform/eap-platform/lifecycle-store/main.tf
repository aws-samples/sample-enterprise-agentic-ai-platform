# Agent School Lifecycle State Store
# DynamoDB table tracking each agent's graduation state.
#
# Owner: Platform Operator
# Writers: Pipeline stages (evaluate, gate) update state on transitions
# Readers: Dashboards, trigger interfaces, governance audits

variable "environment" {
  description = "Platform environment"
  type        = string
  default     = "dev"
}

variable "domain" {
  description = "EAP domain"
  type        = string
  default     = "team-bu-1"
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for the lifecycle table's at-rest encryption (ADR-035). Null (default) => DynamoDB's service-managed (AWS-owned) encryption — always encrypted, no key in your account. When set => the supplied CMK. (DynamoDB has no separate 'AWS-managed key' tier reachable here; without a CMK it is the AWS-owned key.)"
  type        = string
  default     = null
}

resource "aws_dynamodb_table" "agent_lifecycle" {
  name         = "agent-school-lifecycle-${var.domain}-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "agent_name"

  attribute {
    name = "agent_name"
    type = "S"
  }

  # Application-level hierarchy: agents that belong to the same multi-agent
  # application share an app_name (e.g. all runtimes of a "research-assistant" app),
  # with the entrypoint agent flagged via is_entrypoint on the item. The
  # app-index GSI lets consumers list an application's agents (and find its
  # entrypoint) instead of the flat per-agent view. Only items that set
  # app_name appear in the index (sparse GSI), so legacy/standalone records are
  # unaffected.
  attribute {
    name = "app_name"
    type = "S"
  }

  global_secondary_index {
    name            = "app-index"
    hash_key        = "app_name"
    projection_type = "ALL"
  }

  # NOTE: `bu` (business-unit / domain) is written on every item as the single
  # shared-table discriminator, but it is NOT declared as a key attribute or
  # GSI here on purpose: DynamoDB is schemaless for non-key attributes, and the
  # console/studio-read read the table via Scan (filtering/grouping by `bu`
  # in-memory), so no index is required. Adding a `bu-index` GSI later must be
  # done as its own isolated change (DynamoDB permits only one GSI create/delete
  # per UpdateTable, and touching the live table's existing app-index is risky).

  # At-rest encryption (ADR-035). DynamoDB is ALWAYS encrypted. Without a CMK
  # this is the service-managed (AWS-owned) key — DynamoDB has no separate
  # "AWS-managed key" tier via this resource, so enabled=true + null key is the
  # AWS-owned key (same as the pre-ADR-035 default, i.e. a no-op). Supplying
  # kms_key_arn switches it to the customer-managed key. The block only takes
  # effect (enabled=true) when a CMK is supplied; otherwise it stays service-
  # managed with no dangling KMS association.
  dynamic "server_side_encryption" {
    for_each = var.kms_key_arn != null ? [1] : []
    content {
      enabled     = true
      kms_key_arn = var.kms_key_arn
    }
  }

  # Enable point-in-time recovery for audit trail
  point_in_time_recovery {
    enabled = true
  }

  # TTL not enabled — lifecycle records are permanent audit artifacts

  tags = {
    Platform    = "eap"
    Component   = "agent-school"
    Domain      = var.domain
    Environment = var.environment
  }
}

output "table_name" {
  value       = aws_dynamodb_table.agent_lifecycle.name
  description = "DynamoDB table name for agent lifecycle state"
}

output "table_arn" {
  value       = aws_dynamodb_table.agent_lifecycle.arn
  description = "DynamoDB table ARN for IAM policy references"
}
