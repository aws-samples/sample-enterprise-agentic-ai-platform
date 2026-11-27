# EAP Policy Module — Main
# Manages Cedar policy registration for AgentCore Policy enforcement
# Requirements: R16.1, R16.2, R16.4, R16.7
#
# Cedar policies are stored in S3 and registered with AgentCore Policy.
# This module manages the policy definitions as Terraform resources.

locals {
  module_tags = merge(var.tags, {
    eap_module   = "policy"
    eap_domain   = var.domain
    policy_scope = var.scope
  })

  # Generate Cedar policy text from structured definitions
  generated_policies = { for p in var.cedar_policies : p.policy_id => join("\n", concat(
    [
      "// Policy: ${p.policy_id}",
      p.description != null ? "// ${p.description}" : "",
      "${p.effect} (",
      "  principal == ${p.principal},",
      "  action == ${p.action},",
      "  resource == ${p.resource}",
      ")",
    ],
    [for c in p.conditions : "when { ${c} };"],
    [";"]
  )) }

  # Read policy files from disk
  file_policies = { for f in var.cedar_policy_files : basename(f) => file(f) }

  # Combine all policies
  all_policies = merge(local.generated_policies, local.file_policies)

  # Combined policy document
  policy_document = join("\n\n", values(local.all_policies))
}

# ---------------------------------------------------------------------------
# S3 Policy Store — Cedar policies stored as versioned objects
# ---------------------------------------------------------------------------
resource "aws_s3_object" "policy_document" {
  bucket       = var.policy_store_bucket
  key          = "${var.domain}/policies/${var.name}/policy.cedar"
  content      = local.policy_document
  content_type = "text/plain"

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Policy metadata — tracks policy set configuration
# ---------------------------------------------------------------------------
resource "aws_s3_object" "policy_metadata" {
  bucket       = var.policy_store_bucket
  key          = "${var.domain}/policies/${var.name}/metadata.json"
  content_type = "application/json"

  content = jsonencode({
    name        = var.name
    domain      = var.domain
    scope       = var.scope
    description = var.description
    policy_ids  = [for p in var.cedar_policies : p.policy_id]
    file_count  = length(var.cedar_policy_files)
    updated_at  = timestamp()
  })

  tags = local.module_tags

  lifecycle {
    ignore_changes = [content] # timestamp changes every plan
  }
}
