# KB Deploy Template — Provisions Bedrock Knowledge Bases, Data Sources,
# Gateway targets, and Cedar policies.
# This config runs inside CodeBuild during Plan and Apply stages.
# Reads kb.yaml and data-sources.yaml from each KB directory in source artifact.
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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Discover KB directories — each subdirectory with a kb.yaml
# ---------------------------------------------------------------------------
locals {
  # Discover KB directories by looking for kb.yaml files
  kb_yaml_files = fileset(path.module, "*/kb.yaml")

  # Parse each KB config
  kb_configs = {
    for kb_yaml in local.kb_yaml_files :
    dirname(kb_yaml) => yamldecode(file("${path.module}/${kb_yaml}"))
  }

  # Parse each data-sources config
  ds_configs = {
    for kb_dir, _ in local.kb_configs :
    kb_dir => yamldecode(file("${path.module}/${kb_dir}/data-sources.yaml"))
  }

  # Predefined interval to cron translation
  interval_to_cron = {
    daily   = "cron(0 0 * * ? *)"
    weekly  = "cron(0 0 ? * SUN *)"
    monthly = "cron(0 0 1 * ? *)"
  }

  # Platform defaults for retrieval
  default_search_type = "hybrid"
  default_max_results = 5

  # Flatten data sources into a map keyed by "{kb_dir}/{ds_name}"
  all_data_sources = merge([
    for kb_dir, ds_config in local.ds_configs : {
      for ds in ds_config.data_sources :
      "${kb_dir}/${ds.name}" => merge(ds, {
        kb_dir  = kb_dir
        kb_name = local.kb_configs[kb_dir].name
      })
    }
  ]...)

  # Data sources that need bucket creation
  create_bucket_sources = {
    for key, ds in local.all_data_sources :
    key => ds if ds.type == "s3" && try(ds.create_bucket, false) == true
  }
}

# ---------------------------------------------------------------------------
# IAM Role for Bedrock Knowledge Base
# ---------------------------------------------------------------------------
resource "aws_iam_role" "kb_role" {
  for_each = local.kb_configs

  name = "${var.domain}-${each.value.name}-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = merge(var.tags, {
    kb_name = each.value.name
    domain  = var.domain
  })
}

# Per-KB resource lists for the KB role policy, derived from data-sources.yaml.
# Bucket ARNs mirror the bucket_arn passed to aws_bedrockagent_data_source.
locals {
  kb_s3_bucket_arns = {
    for kb_dir, _ in local.kb_configs : kb_dir => distinct([
      for key, ds in local.all_data_sources :
      try(ds.create_bucket, false) ? aws_s3_bucket.datasource[key].arn : "arn:aws:s3:::${ds.bucket_name}"
      if ds.kb_dir == kb_dir && ds.type == "s3"
    ])
  }
  kb_secret_arns = {
    for kb_dir, _ in local.kb_configs : kb_dir => distinct([
      for key, ds in local.all_data_sources : ds.credential_arn
      if ds.kb_dir == kb_dir && try(ds.credential_arn, null) != null
    ])
  }
}
resource "aws_iam_role_policy" "kb_role_policy" {
  for_each = local.kb_configs

  name = "${var.domain}-${each.value.name}-kb-policy"
  role = aws_iam_role.kb_role[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["bedrock:InvokeModel"]
          Resource = ["arn:aws:bedrock:${var.aws_region}::foundation-model/${each.value.embedding_model}"]
        }
      ],
      # S3 read scoped to this KB's s3 data-source buckets (omitted if none).
      length(local.kb_s3_bucket_arns[each.key]) > 0 ? [
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = local.kb_s3_bucket_arns[each.key]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = [for arn in local.kb_s3_bucket_arns[each.key] : "${arn}/*"]
        }
      ] : [],
      # Connector credentials scoped to this KB's declared credential_arn
      # secrets (confluence / sharepoint / salesforce; omitted if none).
      length(local.kb_secret_arns[each.key]) > 0 ? [
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.kb_secret_arns[each.key]
        }
      ] : []
    )
  })
}

# ---------------------------------------------------------------------------
# S3 Buckets — provisioned when create_bucket: true
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "datasource" {
  for_each = local.create_bucket_sources

  # Account ID suffix keeps the globally unique name from being pre-registered.
  bucket = "${var.domain}-${each.value.kb_name}-datasource-${data.aws_caller_identity.current.account_id}"
  tags = merge(var.tags, {
    kb_name = each.value.kb_name
    domain  = var.domain
  })
}

resource "aws_s3_bucket_versioning" "datasource" {
  for_each = local.create_bucket_sources

  bucket = aws_s3_bucket.datasource[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "datasource" {
  for_each = local.create_bucket_sources

  bucket = aws_s3_bucket.datasource[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base — one per KB directory
# ---------------------------------------------------------------------------
resource "aws_bedrockagent_knowledge_base" "this" {
  for_each = local.kb_configs

  name        = each.value.name
  description = each.value.description
  role_arn    = aws_iam_role.kb_role[each.key].arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/${each.value.embedding_model}"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = "arn:aws:aoss:${var.aws_region}:${data.aws_caller_identity.current.account_id}:collection/kb-${each.value.name}"
      vector_index_name = "bedrock-knowledge-base-default-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = merge(var.tags, {
    kb_name     = each.value.name
    domain      = var.domain
    commit_sha  = var.commit_sha
    search_type = try(each.value.retrieval.search_type, local.default_search_type)
    max_results = tostring(try(each.value.retrieval.max_results, local.default_max_results))
  })
}

# ---------------------------------------------------------------------------
# Bedrock Data Sources — one per declared data source
# ---------------------------------------------------------------------------
resource "aws_bedrockagent_data_source" "this" {
  for_each = local.all_data_sources

  name              = each.value.name
  knowledge_base_id = aws_bedrockagent_knowledge_base.this[each.value.kb_dir].id
  description       = try(each.value.description, "Data source: ${each.value.name}")

  data_source_configuration {
    type = upper(each.value.type == "s3" ? "S3" : each.value.type == "web_crawl" ? "WEB" : each.value.type == "confluence" ? "CONFLUENCE" : each.value.type == "sharepoint" ? "SHAREPOINT" : each.value.type == "salesforce" ? "SALESFORCE" : "S3")

    dynamic "s3_configuration" {
      for_each = each.value.type == "s3" ? [1] : []
      content {
        bucket_arn         = try(each.value.create_bucket, false) ? aws_s3_bucket.datasource[each.key].arn : "arn:aws:s3:::${each.value.bucket_name}"
        inclusion_prefixes = try(each.value.inclusion_prefixes, null)
      }
    }

    dynamic "web_configuration" {
      for_each = each.value.type == "web_crawl" ? [1] : []
      content {
        source_configuration {
          url_configuration {
            seed_urls {
              dynamic "url" {
                for_each = each.value.seed_urls
                content {
                  value = url.value
                }
              }
            }
          }
        }
        crawler_configuration {
          crawler_limits {
            rate_limit = try(each.value.rate_limit, 10)
          }
          scope = upper(each.value.scope)
        }
      }
    }

    dynamic "confluence_configuration" {
      for_each = each.value.type == "confluence" ? [1] : []
      content {
        source_configuration {
          host_url               = each.value.host_url
          host_type              = "SAAS"
          auth_type              = "OAUTH2_CLIENT_CREDENTIALS"
          credentials_secret_arn = each.value.credential_arn
        }
      }
    }

    dynamic "share_point_configuration" {
      for_each = each.value.type == "sharepoint" ? [1] : []
      content {
        source_configuration {
          site_urls              = [each.value.site_url]
          host_type              = "ONLINE"
          auth_type              = "OAUTH2_CLIENT_CREDENTIALS"
          credentials_secret_arn = each.value.credential_arn
        }
      }
    }

    dynamic "salesforce_configuration" {
      for_each = each.value.type == "salesforce" ? [1] : []
      content {
        source_configuration {
          host_url               = each.value.instance_url
          auth_type              = "OAUTH2_CLIENT_CREDENTIALS"
          credentials_secret_arn = each.value.credential_arn
        }
      }
    }
  }

  # Sync schedule — translate predefined intervals to cron
  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = upper(local.kb_configs[each.value.kb_dir].chunking_strategy.type == "none" ? "NONE" : local.kb_configs[each.value.kb_dir].chunking_strategy.type == "fixed_size" ? "FIXED_SIZE" : local.kb_configs[each.value.kb_dir].chunking_strategy.type == "semantic" ? "SEMANTIC" : "HIERARCHICAL")
    }
  }
}

# ---------------------------------------------------------------------------
# Gateway Target — register each KB as an MCP target
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway_target" "kb" {
  for_each = local.kb_configs

  name               = "kb-${each.value.name}"
  gateway_identifier = var.gateway_id
  description        = each.value.description

  target_configuration {
    mcp {
      smithy_model_endpoint = aws_bedrockagent_knowledge_base.this[each.key].arn
    }
  }
}

# ---------------------------------------------------------------------------
# Cedar Policy — access control for KB tools
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_policy_engine_policy" "kb" {
  for_each = local.kb_configs

  policy_engine_identifier = var.policy_engine_id

  # Generate policy based on access section presence
  policy_document = try(each.value.access, null) != null ? (
    # Explicit access control from kb.yaml access section
    join("\n", concat(
      [
        "// Auto-generated by KB pipeline for: ${each.value.name}",
        "permit(",
        "  principal is AgentCore::OAuthUser,",
        "  action == AgentCore::Action::\"kb-${each.value.name}___retrieve\",",
        "  resource",
        ")",
        "when {",
      ],
      try(each.value.access.allowed_domains, null) != null ? [
        "  principal.hasTag(\"domain\") &&",
        "  (${join(" || ", [for d in each.value.access.allowed_domains : "principal.getTag(\"domain\") == \"${d}\""])})",
      ] : [],
      try(each.value.access.allowed_agents, null) != null && try(each.value.access.allowed_domains, null) == null ? [
        "  principal.hasTag(\"agent_name\") &&",
        "  (${join(" || ", [for a in each.value.access.allowed_agents : "principal.getTag(\"agent_name\") == \"${a}\""])})",
      ] : [],
      [
        "};",
      ]
    ))
    ) : (
    # Default policy — same domain access
    join("\n", [
      "// Auto-generated default policy for: ${each.value.name}",
      "permit(",
      "  principal is AgentCore::OAuthUser,",
      "  action == AgentCore::Action::\"kb-${each.value.name}___retrieve\",",
      "  resource",
      ")",
      "when {",
      "  principal.hasTag(\"domain\") &&",
      "  principal.getTag(\"domain\") == \"${var.domain}\"",
      "};",
    ])
  )
}
