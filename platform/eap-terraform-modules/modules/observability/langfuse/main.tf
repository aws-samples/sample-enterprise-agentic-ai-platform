# EAP Langfuse_Stack Module — Main
#
# Self-hosted Langfuse, the platform's DEFAULT third-party OTLP backend
# (Requirement 11.7). Attribution: this Langfuse deployment pattern (ECS Fargate
# web+worker + Aurora PostgreSQL + ClickHouse + Redis + CloudFront/ALB) is
# adapted from the AWS-samples Agentic Value Accelerator (AVA), used under the
# Apache License 2.0 — see ATTRIBUTION added in task 8.4.
#
# Two-leg model reminder: this stack is a THIRD-PARTY OTLP backend only. It does
# NOT participate in the always-on AWS-native leg (AgentCore auto-instrumentation
# -> CloudWatch/X-Ray). The OTel_Collector (separate module) fans the duplicated
# span stream into this stack's per-BU Langfuse projects.
#
# ============================ TASK SCOPE (8.1) ============================
# This file provisions the STRUCTURE + resources for:
#   - Compute:    ECS Fargate Langfuse web + worker services and task defs
#   - Datastores: Aurora PostgreSQL Serverless v2, ClickHouse on Fargate (EBS),
#                 ElastiCache Redis, S3 event/media bucket
#   - Edge:       CloudFront -> Langfuse_ALB -> web target group (HTTPS only)
# with sensible security defaults.
#
# ============================ TASK SCOPE (8.2) ============================
# This file now also implements the least-privilege + private network posture
# (Requirements 15.1, 15.3, 15.4, 15.5, 15.6):
#   - Datastores (Aurora/ClickHouse/Redis) run in private subnets and S3 blob
#     access is kept on-backbone via an optional S3 gateway VPC endpoint plus a
#     TLS-only bucket policy (public access already fully blocked).
#   - Per-datastore security groups admit ingress ONLY from the web/worker SGs.
#   - The ALB ingress is restricted to the CloudFront origin-facing managed
#     prefix list by default (var.restrict_alb_to_cloudfront_prefix_list).
#   - Per-service execution roles read ONLY the secrets that service needs and
#     per-service task roles get only the blob-bucket access they need; KMS
#     grants are attached only when a customer-managed key is provided.
#   - Customer-managed KMS at-rest encryption (var.kms_key_arn) is wired for
#     Aurora, ClickHouse EBS, Redis, Secrets Manager, and S3 (aws:kms); a sane
#     AWS-managed default is kept when the key is null.
#   - HTTPS-only edge with HTTP->HTTPS redirect (verified).
# ============================ TASK SCOPE (9.1) ============================
# This file now also wires the Langfuse_ALB Cognito authentication and the
# iframe-embed allowance (Requirements 7.4, 13.2, 13.5, 15.2):
#   - The HTTPS listener prepends an `authenticate-cognito` default action
#     (order = 1) against the shared platform Cognito_User_Pool
#     (var.cognito_user_pool_arn / _client_id / _domain) so unauthenticated
#     requests are redirected to the hosted UI and denied unless authenticated;
#     the existing forward-to-web action runs second (order = 2). This is gated
#     on local.cognito_auth_enabled so the module still plans when the Cognito
#     inputs are null (local testing), falling back to forward-only.
#   - A CloudFront response-headers policy sets
#     `Content-Security-Policy: frame-ancestors 'self' https://<console-domain>`
#     (var.console_domain) and emits NO `X-Frame-Options`, so the EAP
#     console can iframe-embed the Langfuse UI. Gated on
#     local.frame_ancestors_enabled (created only when console_domain is set).
# ============================ TASK SCOPE (10.1) ===========================
# This file now also provisions one Langfuse_Project per Business_Unit
# (Requirement 14.1). For each entry in var.business_units the module:
#   - Derives a stable, per-BU projectId ("${name_prefix}-proj-<bu>").
#   - Generates a per-project public key (`pk-lf-...`) and secret key
#     (`sk-lf-...`) via random_password (Langfuse accepts pre-provisioned keys
#     through its headless init / Public API seeding).
#   - Stores the public key, secret key, and the base64(public:secret)
#     Basic-auth header value in three KMS-encrypted Secrets Manager secrets
#     (tagged with local.module_tags like every other secret here).
#   - Seeds the project into Langfuse: the FIRST BU is created by Langfuse
#     headless init (LANGFUSE_INIT_* on the web container, keys injected as
#     secret refs — never plaintext); any additional BUs are seeded by an
#     idempotent post-apply bootstrap (terraform_data + local-exec) that is
#     GATED on var.enable_project_bootstrap (default false) so `terraform
#     validate`/`plan` never need live Langfuse credentials.
#   - Emits a `LangfuseProjectBinding` per BU via the `langfuse_project_bindings`
#     output (bu -> projectId + publicKeyRef + secretKeyRef + otlpBasicAuthRef),
#     which the OTel_Collector per-BU routing (task 10.2) consumes alongside the
#     existing `langfuse_otlp_endpoint` output.
# No new provider is introduced: bootstrap uses the built-in `terraform_data`.
# ==========================================================================
# Requirements: R11.1, R11.2, R11.3, R11.4, R11.5, R11.6, R11.7,
#               R15.1, R15.3, R15.4, R15.5, R15.6, R14.1

locals {
  # KMS is customer-managed when an ARN is supplied; drives at-rest wiring and
  # whether per-service roles get KMS grants (Requirement 15.5).
  kms_enabled = var.kms_key_arn != null

  # ============================ TASK 9.1 gating ============================
  # The Langfuse_ALB `authenticate-cognito` action is wired ONLY when all three
  # shared-platform Cognito inputs are supplied. When any is null (e.g. local
  # testing without the platform user pool) the listener falls back to the
  # forward-only path so the module still validates/plans (Requirements 13.2,
  # 13.5, 15.2).
  module_tags = merge(var.tags, {
    eap_module = "langfuse"
    eap_domain = var.domain
  })

  name_prefix = "eap-${var.domain}-${var.name}"

  create_cluster = var.ecs_cluster_arn == null
  cluster_arn    = local.create_cluster ? aws_ecs_cluster.this[0].arn : var.ecs_cluster_arn

  # Cloud Map private DNS namespace for in-VPC datastore discovery (ClickHouse).
  service_discovery_namespace = "${var.name}.internal"
  clickhouse_host             = "clickhouse.${local.service_discovery_namespace}"

  # NEXTAUTH_URL is the Langfuse origin. ADR-030: private internal ALB over HTTP
  # on the web port — reachable within the VPC (on-network users via VPN/corp).
  # HTTP inside the VPC only. The ALB is internal, in private subnets, and its
  # security group admits only VPC traffic (enterprise) or CloudFront's
  # origin-facing prefix list through a VPC origin (demo, where TLS terminates
  # at CloudFront). Traffic between clients in the VPC and the ALB is not
  # encrypted. For production, add an HTTPS listener with an ACM certificate.
  nextauth_url = "http://${aws_lb.langfuse.dns_name}:${var.web_container_port}"

  # DATABASE_URL carries the master password; stored as a Secrets Manager secret
  # and injected as a container secret ref (never plaintext in the task def).
  database_url = "postgresql://${var.postgres_master_username}:${random_password.postgres.result}@${aws_rds_cluster.aurora.endpoint}:5432/${var.postgres_database_name}"

  # Non-secret env shared by the web and worker containers.
  common_environment = [
    { name = "CLICKHOUSE_MIGRATION_URL", value = "clickhouse://${local.clickhouse_host}:${var.clickhouse_native_port}" },
    { name = "CLICKHOUSE_URL", value = "http://${local.clickhouse_host}:${var.clickhouse_http_port}" },
    { name = "CLICKHOUSE_USER", value = var.clickhouse_user },
    { name = "CLICKHOUSE_CLUSTER_ENABLED", value = "false" },
    { name = "REDIS_HOST", value = aws_elasticache_replication_group.redis.primary_endpoint_address },
    { name = "REDIS_PORT", value = tostring(var.redis_port) },
    { name = "REDIS_TLS_ENABLED", value = "true" },
    { name = "LANGFUSE_S3_EVENT_UPLOAD_BUCKET", value = aws_s3_bucket.blobs.bucket },
    { name = "LANGFUSE_S3_EVENT_UPLOAD_REGION", value = data.aws_region.current.region },
    { name = "LANGFUSE_S3_EVENT_UPLOAD_ENABLED", value = "true" },
    { name = "LANGFUSE_S3_MEDIA_UPLOAD_BUCKET", value = aws_s3_bucket.blobs.bucket },
    { name = "LANGFUSE_S3_MEDIA_UPLOAD_REGION", value = data.aws_region.current.region },
    { name = "LANGFUSE_S3_MEDIA_UPLOAD_ENABLED", value = "true" },
    { name = "TELEMETRY_ENABLED", value = "false" },
  ]

  # Secret env shared by the web and worker containers (Secrets Manager refs).
  common_secrets = [
    { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn },
    { name = "CLICKHOUSE_PASSWORD", valueFrom = aws_secretsmanager_secret.clickhouse_password.arn },
    { name = "REDIS_AUTH", valueFrom = aws_secretsmanager_secret.redis_auth.arn },
    { name = "SALT", valueFrom = aws_secretsmanager_secret.langfuse_salt.arn },
    { name = "ENCRYPTION_KEY", valueFrom = aws_secretsmanager_secret.langfuse_encryption_key.arn },
  ]
}

data "aws_region" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# ===========================================================================
# Per-BU Langfuse projects (task 10.1 — Requirement 14.1)
# ===========================================================================
locals {
  # Keyed by BU so every project resource uses a stable, per-BU for_each key —
  # this makes one-project-per-BU with distinct keys a structural guarantee
  # (two BUs can never collide onto the same instance address). The
  # business_units validation additionally rejects duplicate `bu` values.
  business_unit_map = { for u in var.business_units : u.bu => u }

  # Stable, distinct-per-BU project id (no random needed — derived from the
  # module name prefix + BU so it is known at plan time and never collides).
  langfuse_project_ids = {
    for bu, u in local.business_unit_map : bu => "${local.name_prefix}-proj-${bu}"
  }

  # Friendly project name (defaults to the BU identifier).
  langfuse_project_names = {
    for bu, u in local.business_unit_map : bu => coalesce(u.name, bu)
  }

  # Pre-provisioned per-project Langfuse keys (Langfuse public/secret key
  # convention: `pk-lf-...` / `sk-lf-...`). Kept in Secrets Manager (below);
  # these locals only assemble the prefixed values for the secret versions.
  langfuse_project_public_keys = {
    for bu, u in local.business_unit_map : bu => "pk-lf-${random_password.langfuse_project_public_key[bu].result}"
  }
  langfuse_project_secret_keys = {
    for bu, u in local.business_unit_map : bu => "sk-lf-${random_password.langfuse_project_secret_key[bu].result}"
  }

  # The primary BU is seeded by Langfuse headless init (LANGFUSE_INIT_*) on the
  # web container; the rest (if any) by the optional post-apply bootstrap.
  langfuse_bootstrap_bu        = length(var.business_units) > 0 ? var.business_units[0].bu : null
  langfuse_headless_init       = local.langfuse_bootstrap_bu != null
  langfuse_public_api_base_url = coalesce(var.langfuse_admin_api_base_url, local.nextauth_url)

  # LANGFUSE_INIT_* env/secret injected into the web container for the primary
  # project. Non-secret ids/names go via `environment`; the pre-provisioned
  # public/secret keys go via `secrets` (Secrets Manager refs — never plaintext).
  # Headless init has a dependency hierarchy (Langfuse docs): a PROJECT requires
  # an ORG, and an ORG requires an initial USER (the org owner). So the USER_*
  # vars are REQUIRED — without them Langfuse creates NOTHING (no org => no
  # project). Email is a config value; password is a generated secret (never
  # plaintext). This is the initial admin/owner login for the Langfuse UI.
  langfuse_headless_init_environment = local.langfuse_headless_init ? [
    { name = "LANGFUSE_INIT_ORG_ID", value = "${var.name}-org" },
    { name = "LANGFUSE_INIT_ORG_NAME", value = "EAP" },
    { name = "LANGFUSE_INIT_PROJECT_ID", value = local.langfuse_project_ids[local.langfuse_bootstrap_bu] },
    { name = "LANGFUSE_INIT_PROJECT_NAME", value = local.langfuse_project_names[local.langfuse_bootstrap_bu] },
    { name = "LANGFUSE_INIT_USER_EMAIL", value = var.langfuse_init_user_email },
    { name = "LANGFUSE_INIT_USER_NAME", value = "EAP Admin" },
  ] : []

  langfuse_headless_init_secrets = local.langfuse_headless_init ? [
    { name = "LANGFUSE_INIT_PROJECT_PUBLIC_KEY", valueFrom = aws_secretsmanager_secret.langfuse_project_public_key[local.langfuse_bootstrap_bu].arn },
    { name = "LANGFUSE_INIT_PROJECT_SECRET_KEY", valueFrom = aws_secretsmanager_secret.langfuse_project_secret_key[local.langfuse_bootstrap_bu].arn },
    { name = "LANGFUSE_INIT_USER_PASSWORD", valueFrom = aws_secretsmanager_secret.langfuse_init_user_password.arn },
  ] : []

  # Secret ARNs the web execution role must additionally read to inject the
  # LANGFUSE_INIT_* primary-project keys (least privilege — only the primary BU).
  langfuse_headless_init_secret_arns = local.langfuse_headless_init ? [
    aws_secretsmanager_secret.langfuse_init_user_password.arn,
    aws_secretsmanager_secret.langfuse_project_public_key[local.langfuse_bootstrap_bu].arn,
    aws_secretsmanager_secret.langfuse_project_secret_key[local.langfuse_bootstrap_bu].arn,
  ] : []
}

# Per-project keys — 40/48 hex-ish random bodies with the Langfuse pk-/sk- prefix
# applied in locals above. `special = false` keeps them URL/Basic-auth safe.
resource "random_password" "langfuse_project_public_key" {
  for_each = local.business_unit_map
  length   = 36
  special  = false
}

resource "random_password" "langfuse_project_secret_key" {
  for_each = local.business_unit_map
  length   = 44
  special  = false
}

# Per-BU Secrets Manager secrets: public key, secret key, and the
# base64(public:secret) Basic-auth header value the collector sends to the
# Langfuse OTLP receiver. KMS-encrypted (var.kms_key_arn) and tagged like every
# other secret in this module (Requirement 15.4).
resource "aws_secretsmanager_secret" "langfuse_project_public_key" {
  for_each   = local.business_unit_map
  name       = "${local.name_prefix}-project-${each.key}-public-key"
  kms_key_id = var.kms_key_arn
  tags       = merge(local.module_tags, { eap_bu = each.key })
}

resource "aws_secretsmanager_secret_version" "langfuse_project_public_key" {
  for_each      = local.business_unit_map
  secret_id     = aws_secretsmanager_secret.langfuse_project_public_key[each.key].id
  secret_string = local.langfuse_project_public_keys[each.key]
}

resource "aws_secretsmanager_secret" "langfuse_project_secret_key" {
  for_each   = local.business_unit_map
  name       = "${local.name_prefix}-project-${each.key}-secret-key"
  kms_key_id = var.kms_key_arn
  tags       = merge(local.module_tags, { eap_bu = each.key })
}

resource "aws_secretsmanager_secret_version" "langfuse_project_secret_key" {
  for_each      = local.business_unit_map
  secret_id     = aws_secretsmanager_secret.langfuse_project_secret_key[each.key].id
  secret_string = local.langfuse_project_secret_keys[each.key]
}

# Initial admin/owner user password for Langfuse headless init (org owner).
# Generated (never plaintext); read this from Secrets Manager to log into the UI.
resource "random_password" "langfuse_init_user" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "langfuse_init_user_password" {
  name       = "${local.name_prefix}-init-user-password"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "langfuse_init_user_password" {
  secret_id     = aws_secretsmanager_secret.langfuse_init_user_password.id
  secret_string = random_password.langfuse_init_user.result
}

resource "aws_secretsmanager_secret" "langfuse_project_otlp_basic_auth" {
  for_each   = local.business_unit_map
  name       = "${local.name_prefix}-project-${each.key}-otlp-basic-auth"
  kms_key_id = var.kms_key_arn
  tags       = merge(local.module_tags, { eap_bu = each.key })
}

resource "aws_secretsmanager_secret_version" "langfuse_project_otlp_basic_auth" {
  for_each  = local.business_unit_map
  secret_id = aws_secretsmanager_secret.langfuse_project_otlp_basic_auth[each.key].id
  # base64(publicKey:secretKey) — the Basic-auth credential the OTel_Collector
  # otlphttp exporter presents to Langfuse `/api/public/otel` for this BU.
  secret_string = base64encode("${local.langfuse_project_public_keys[each.key]}:${local.langfuse_project_secret_keys[each.key]}")
}

# Optional, idempotent per-BU project seeding beyond the headless-init primary.
# GATED on var.enable_project_bootstrap (default false) so validate/plan never
# require live Langfuse credentials. Uses the built-in `terraform_data` resource
# (no new provider). The local-exec is a create-if-absent call to the Langfuse
# Public API `POST /api/public/projects`; it is safe to re-run.
resource "terraform_data" "langfuse_project_bootstrap" {
  for_each = var.enable_project_bootstrap ? local.business_unit_map : {}

  triggers_replace = {
    project_id = local.langfuse_project_ids[each.key]
    api_base   = local.langfuse_public_api_base_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      LANGFUSE_API_BASE   = local.langfuse_public_api_base_url
      LANGFUSE_PROJECT_ID = local.langfuse_project_ids[each.key]
      LANGFUSE_PROJECT_NM = local.langfuse_project_names[each.key]
      # LANGFUSE_ADMIN_API_KEY is expected in the caller's environment at apply
      # time; the script no-ops (without failing the apply) when it is absent.
    }
    command = <<-EOT
      set -euo pipefail
      if [ -z "$${LANGFUSE_ADMIN_API_KEY:-}" ]; then
        echo "[langfuse-bootstrap] LANGFUSE_ADMIN_API_KEY not set — skipping API seed for $${LANGFUSE_PROJECT_ID} (headless init covers the primary project)."
        exit 0
      fi
      echo "[langfuse-bootstrap] Ensuring Langfuse project $${LANGFUSE_PROJECT_ID} exists (idempotent)."
      curl -sS -X POST "$${LANGFUSE_API_BASE}/api/public/projects" \
        -H "Authorization: Bearer $${LANGFUSE_ADMIN_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$${LANGFUSE_PROJECT_ID}\",\"name\":\"$${LANGFUSE_PROJECT_NM}\"}" \
        -o /dev/null -w "%%{http_code}" || true
    EOT
  }
}

# ===========================================================================
# Secrets — DB creds, ClickHouse/Redis auth, Langfuse SALT/ENCRYPTION_KEY.
# Never plaintext in task defs; injected as container secret refs (15.4). Each
# secret is encrypted with the customer-managed KMS key when var.kms_key_arn is
# set (kms_key_id below), otherwise the Secrets Manager AWS-managed key is used.
# Least-privilege read grants are scoped per service in the IAM section below.
# ===========================================================================
resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "clickhouse" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "random_password" "salt" {
  length  = 32
  special = false
}

resource "random_password" "nextauth" {
  length  = 32
  special = false
}

# ENCRYPTION_KEY must be a 256-bit key encoded as 64 hex chars.
resource "random_id" "encryption_key" {
  byte_length = 32
}

resource "aws_secretsmanager_secret" "database_url" {
  name       = "${local.name_prefix}-database-url"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id     = aws_secretsmanager_secret.database_url.id
  secret_string = local.database_url
}

resource "aws_secretsmanager_secret" "clickhouse_password" {
  name       = "${local.name_prefix}-clickhouse-password"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "clickhouse_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_password.id
  secret_string = random_password.clickhouse.result
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name       = "${local.name_prefix}-redis-auth"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis.result
}

resource "aws_secretsmanager_secret" "langfuse_salt" {
  name       = "${local.name_prefix}-salt"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "langfuse_salt" {
  secret_id     = aws_secretsmanager_secret.langfuse_salt.id
  secret_string = random_password.salt.result
}

resource "aws_secretsmanager_secret" "langfuse_encryption_key" {
  name       = "${local.name_prefix}-encryption-key"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "langfuse_encryption_key" {
  secret_id     = aws_secretsmanager_secret.langfuse_encryption_key.id
  secret_string = random_id.encryption_key.hex
}

resource "aws_secretsmanager_secret" "nextauth_secret" {
  name       = "${local.name_prefix}-nextauth-secret"
  kms_key_id = var.kms_key_arn
  tags       = local.module_tags
}

resource "aws_secretsmanager_secret_version" "nextauth_secret" {
  secret_id     = aws_secretsmanager_secret.nextauth_secret.id
  secret_string = random_password.nextauth.result
}

# ===========================================================================
# S3 bucket — Langfuse event/media blob storage (SSE-encrypted, private).
# ===========================================================================
resource "aws_s3_bucket" "blobs" {
  bucket        = "${local.name_prefix}-blobs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.module_tags
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "blobs" {
  bucket                  = aws_s3_bucket.blobs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "blobs" {
  bucket = aws_s3_bucket.blobs.id

  rule {
    apply_server_side_encryption_by_default {
      # aws:kms with the customer-managed key when supplied (Requirement 15.5);
      # otherwise SSE-S3 (AES256) as a sane always-encrypted default.
      sse_algorithm     = local.kms_enabled ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# TLS-only bucket policy — deny any non-HTTPS access to the blob bucket so it is
# never reachable in the clear (Requirements 15.1, 15.6). Combined with the
# public-access block above and the private-subnet S3 gateway endpoint below,
# this keeps blob traffic on the AWS backbone and off the public internet.
data "aws_iam_policy_document" "blobs_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.blobs.arn,
      "${aws_s3_bucket.blobs.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  policy = data.aws_iam_policy_document.blobs_bucket.json
}

# S3 gateway VPC endpoint — keeps Langfuse blob traffic from the private-subnet
# web/worker tasks on the AWS backbone (never the public internet). Created only
# when private route table IDs are supplied (Requirement 15.1).
resource "aws_vpc_endpoint" "s3" {
  count             = length(var.private_route_table_ids) > 0 ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids
  tags              = local.module_tags
}

# ===========================================================================
# Security groups — per-service and per-datastore isolation (Requirement 15.3).
# Datastores accept ingress ONLY from the Langfuse web/worker services, and the
# ALB accepts ingress only from CloudFront (managed prefix list) by default.
# ===========================================================================

# AWS-managed CloudFront origin-facing prefix list — the set of CloudFront edge
# CIDRs that originate requests to the ALB. Used to restrict ALB ingress so only
# Internal ALB (ADR-030) — reachable only from within the VPC. Ingress is the
# VPC CIDR on the web port (see aws_security_group_rule.alb_http_from_vpc).
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Langfuse internal ALB (private, HTTP)"
  vpc_id      = var.vpc_id

  egress {
    description     = "Forward to Langfuse web service"
    from_port       = var.web_container_port
    to_port         = var.web_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  tags = local.module_tags
}

# ADR-030: the ALB is INTERNAL and HTTP-only (no public exposure, no ACM, no
# CloudFront). It accepts HTTP on the web port from within the VPC — the OTel
# collector (span ingestion) and on-network humans (VPN/corp) reach it via the
# VPC CIDR. No :443, no 0.0.0.0/0 ingress.
resource "aws_security_group_rule" "alb_http_from_vpc" {
  type              = "ingress"
  description       = "HTTP in from within the VPC (collector + on-network users)"
  from_port         = var.web_container_port
  to_port           = var.web_container_port
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = [data.aws_vpc.this.cidr_block]
}

# ADR-038 (demo only): when CloudFront-facing, also admit the CloudFront
# origin-facing prefix list on the web port. This is additive to the VPC-CIDR
# rule above (the OTLP collector path is unaffected). Traffic must still carry
# the secret origin header the listener rule requires (see below).
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.enable_cloudfront_origin ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group_rule" "alb_http_from_cloudfront" {
  count             = var.enable_cloudfront_origin ? 1 : 0
  type              = "ingress"
  description       = "HTTP in from the CloudFront edge (ADR-038, demo only)"
  from_port         = var.web_container_port
  to_port           = var.web_container_port
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
}

# Langfuse web service — receives traffic from the ALB only.
resource "aws_security_group" "web" {
  name        = "${local.name_prefix}-web"
  description = "Langfuse web service (from ALB only)"
  vpc_id      = var.vpc_id

  egress {
    description = "Web egress (datastores + image pull + AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.module_tags
}

resource "aws_security_group_rule" "web_from_alb" {
  type                     = "ingress"
  description              = "Langfuse web port from the ALB"
  from_port                = var.web_container_port
  to_port                  = var.web_container_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.web.id
  source_security_group_id = aws_security_group.alb.id
}

# Langfuse worker service — no inbound; egress to datastores.
resource "aws_security_group" "worker" {
  name        = "${local.name_prefix}-worker"
  description = "Langfuse worker service (no inbound)"
  vpc_id      = var.vpc_id

  egress {
    description = "Worker egress (datastores + image pull + AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.module_tags
}

# Aurora PostgreSQL — ingress only from web + worker.
resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-aurora"
  description = "Aurora PostgreSQL (from Langfuse services only)"
  vpc_id      = var.vpc_id
  tags        = local.module_tags
}

resource "aws_security_group_rule" "aurora_from_web" {
  type                     = "ingress"
  description              = "PostgreSQL from web"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "aurora_from_worker" {
  type                     = "ingress"
  description              = "PostgreSQL from worker"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.worker.id
}

# ClickHouse — ingress (HTTP + native) only from web + worker.
resource "aws_security_group" "clickhouse" {
  name        = "${local.name_prefix}-clickhouse"
  description = "ClickHouse (from Langfuse services only)"
  vpc_id      = var.vpc_id

  egress {
    description = "ClickHouse egress (image pull + AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.module_tags
}

resource "aws_security_group_rule" "clickhouse_http_from_web" {
  type                     = "ingress"
  description              = "ClickHouse HTTP from web"
  from_port                = var.clickhouse_http_port
  to_port                  = var.clickhouse_http_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clickhouse.id
  source_security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "clickhouse_http_from_worker" {
  type                     = "ingress"
  description              = "ClickHouse HTTP from worker"
  from_port                = var.clickhouse_http_port
  to_port                  = var.clickhouse_http_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clickhouse.id
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "clickhouse_native_from_web" {
  type                     = "ingress"
  description              = "ClickHouse native from web"
  from_port                = var.clickhouse_native_port
  to_port                  = var.clickhouse_native_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clickhouse.id
  source_security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "clickhouse_native_from_worker" {
  type                     = "ingress"
  description              = "ClickHouse native from worker"
  from_port                = var.clickhouse_native_port
  to_port                  = var.clickhouse_native_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.clickhouse.id
  source_security_group_id = aws_security_group.worker.id
}

# ElastiCache Redis — ingress only from web + worker.
resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis"
  description = "ElastiCache Redis (from Langfuse services only)"
  vpc_id      = var.vpc_id
  tags        = local.module_tags
}

resource "aws_security_group_rule" "redis_from_web" {
  type                     = "ingress"
  description              = "Redis from web"
  from_port                = var.redis_port
  to_port                  = var.redis_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "redis_from_worker" {
  type                     = "ingress"
  description              = "Redis from worker"
  from_port                = var.redis_port
  to_port                  = var.redis_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.worker.id
}

# ===========================================================================
# Aurora PostgreSQL Serverless v2 — transactional store (Requirement 11.3).
# Runs in PRIVATE subnets, KMS-encrypted at rest.
# ===========================================================================
resource "aws_db_subnet_group" "aurora" {
  name       = "${local.name_prefix}-aurora"
  subnet_ids = var.private_subnet_ids
  tags       = local.module_tags
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${local.name_prefix}-pg"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # required for Serverless v2 scaling
  engine_version     = var.postgres_engine_version

  database_name   = var.postgres_database_name
  master_username = var.postgres_master_username
  master_password = random_password.postgres.result

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  # IAM database auth available alongside the master password (Langfuse itself
  # still uses the password from Secrets Manager).
  iam_database_authentication_enabled = true

  backup_retention_period = 7
  skip_final_snapshot     = true

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }

  tags = local.module_tags
}

resource "aws_rds_cluster_instance" "aurora" {
  identifier          = "${local.name_prefix}-pg-1"
  cluster_identifier  = aws_rds_cluster.aurora.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.aurora.engine
  engine_version      = aws_rds_cluster.aurora.engine_version
  publicly_accessible = false

  # 7-day retention is in the Performance Insights free tier.
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn

  tags = local.module_tags
}

# ===========================================================================
# ElastiCache Redis — cache/queue store (Requirement 11.5).
# Runs in PRIVATE subnets, at-rest + in-transit encrypted with an AUTH token.
# ===========================================================================
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = var.private_subnet_ids
  tags       = local.module_tags
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "Langfuse cache/queue (${var.name})"

  engine         = "redis"
  engine_version = var.redis_engine_version
  node_type      = var.redis_node_type
  port           = var.redis_port

  num_cache_clusters = 1

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  # Encryption: at-rest + in-transit; the AUTH token guards access (15.5).
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis.result
  kms_key_id                 = var.kms_key_arn

  tags = local.module_tags
}

# ===========================================================================
# ECS cluster + logging + service discovery
# ===========================================================================
resource "aws_ecs_cluster" "this" {
  count = local.create_cluster ? 1 : 0
  name  = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.module_tags
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/eap/${var.domain}/langfuse/web"
  retention_in_days = var.log_group_retention_days
  tags              = local.module_tags
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/eap/${var.domain}/langfuse/worker"
  retention_in_days = var.log_group_retention_days
  tags              = local.module_tags
}

resource "aws_cloudwatch_log_group" "clickhouse" {
  name              = "/eap/${var.domain}/langfuse/clickhouse"
  retention_in_days = var.log_group_retention_days
  tags              = local.module_tags
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = local.service_discovery_namespace
  description = "Langfuse in-VPC datastore discovery (${var.domain})"
  vpc         = var.vpc_id
  tags        = local.module_tags
}

resource "aws_service_discovery_service" "clickhouse" {
  name = "clickhouse"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# IAM — ECS assume-role trust, PER-SERVICE execution roles, and per-service task
# roles, each granted only the permissions that service requires (15.4).
#
# Least-privilege model:
#   - Each service has its OWN execution role that reads ONLY the secrets it
#     injects (web reads all app secrets incl. NEXTAUTH_SECRET; worker reads the
#     app secrets minus NEXTAUTH_SECRET; clickhouse reads only its password).
#   - web/worker task roles get blob-bucket access; clickhouse needs none.
#   - KMS grants (decrypt for secrets, decrypt+generate-data-key for S3) are
#     attached ONLY when a customer-managed key is provided.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Managed policy ARN reused by every per-service execution role (image pull +
# CloudWatch Logs write).
locals {
  ecs_task_execution_policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

  # Secret ARNs each execution role is allowed to read (least privilege).
  # The web role additionally reads the PRIMARY BU's pre-provisioned project
  # keys so it can inject LANGFUSE_INIT_* for headless project seeding (10.1).
  web_secret_arns = concat([
    aws_secretsmanager_secret.database_url.arn,
    aws_secretsmanager_secret.clickhouse_password.arn,
    aws_secretsmanager_secret.redis_auth.arn,
    aws_secretsmanager_secret.langfuse_salt.arn,
    aws_secretsmanager_secret.langfuse_encryption_key.arn,
    aws_secretsmanager_secret.nextauth_secret.arn,
  ], local.langfuse_headless_init_secret_arns)
  worker_secret_arns = [
    aws_secretsmanager_secret.database_url.arn,
    aws_secretsmanager_secret.clickhouse_password.arn,
    aws_secretsmanager_secret.redis_auth.arn,
    aws_secretsmanager_secret.langfuse_salt.arn,
    aws_secretsmanager_secret.langfuse_encryption_key.arn,
  ]
  clickhouse_secret_arns = [
    aws_secretsmanager_secret.clickhouse_password.arn,
  ]
}

# --- Per-service secret-read policy documents ------------------------------
data "aws_iam_policy_document" "web_exec_secrets" {
  statement {
    sid       = "ReadWebSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.web_secret_arns
  }
}

data "aws_iam_policy_document" "worker_exec_secrets" {
  statement {
    sid       = "ReadWorkerSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.worker_secret_arns
  }
}

data "aws_iam_policy_document" "clickhouse_exec_secrets" {
  statement {
    sid       = "ReadClickHouseSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.clickhouse_secret_arns
  }
}

# --- KMS decrypt for execution roles (only when a CMK is provided) ----------
# Needed so the execution role can decrypt CMK-encrypted Secrets Manager values.
data "aws_iam_policy_document" "kms_secret_decrypt" {
  count = local.kms_enabled ? 1 : 0
  statement {
    sid       = "DecryptLangfuseSecretsKms"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

# --- KMS access for task roles that read/write CMK-encrypted S3 objects -----
data "aws_iam_policy_document" "kms_s3" {
  count = local.kms_enabled ? 1 : 0
  statement {
    sid    = "LangfuseBlobKms"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]
  }
}

# --- Web execution role -----------------------------------------------------
resource "aws_iam_role" "web_execution" {
  name               = "${local.name_prefix}-web-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy_attachment" "web_execution" {
  role       = aws_iam_role.web_execution.name
  policy_arn = local.ecs_task_execution_policy_arn
}

resource "aws_iam_role_policy" "web_execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.web_execution.id
  policy = data.aws_iam_policy_document.web_exec_secrets.json
}

resource "aws_iam_role_policy" "web_execution_kms" {
  count  = local.kms_enabled ? 1 : 0
  name   = "decrypt-secrets-kms"
  role   = aws_iam_role.web_execution.id
  policy = data.aws_iam_policy_document.kms_secret_decrypt[0].json
}

# --- Worker execution role --------------------------------------------------
resource "aws_iam_role" "worker_execution" {
  name               = "${local.name_prefix}-worker-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy_attachment" "worker_execution" {
  role       = aws_iam_role.worker_execution.name
  policy_arn = local.ecs_task_execution_policy_arn
}

resource "aws_iam_role_policy" "worker_execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.worker_execution.id
  policy = data.aws_iam_policy_document.worker_exec_secrets.json
}

resource "aws_iam_role_policy" "worker_execution_kms" {
  count  = local.kms_enabled ? 1 : 0
  name   = "decrypt-secrets-kms"
  role   = aws_iam_role.worker_execution.id
  policy = data.aws_iam_policy_document.kms_secret_decrypt[0].json
}

# --- ClickHouse execution role ----------------------------------------------
resource "aws_iam_role" "clickhouse_execution" {
  name               = "${local.name_prefix}-ch-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy_attachment" "clickhouse_execution" {
  role       = aws_iam_role.clickhouse_execution.name
  policy_arn = local.ecs_task_execution_policy_arn
}

resource "aws_iam_role_policy" "clickhouse_execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.clickhouse_execution.id
  policy = data.aws_iam_policy_document.clickhouse_exec_secrets.json
}

resource "aws_iam_role_policy" "clickhouse_execution_kms" {
  count  = local.kms_enabled ? 1 : 0
  name   = "decrypt-secrets-kms"
  role   = aws_iam_role.clickhouse_execution.id
  policy = data.aws_iam_policy_document.kms_secret_decrypt[0].json
}

# --- Blob-bucket access shared by the web + worker task roles ---------------
data "aws_iam_policy_document" "blob_access" {
  statement {
    sid       = "LangfuseBlobBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.blobs.arn]
  }
  statement {
    sid    = "LangfuseBlobObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.blobs.arn}/*"]
  }
}

# Web task role.
resource "aws_iam_role" "web_task" {
  name               = "${local.name_prefix}-web-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy" "web_blob" {
  name   = "blob-access"
  role   = aws_iam_role.web_task.id
  policy = data.aws_iam_policy_document.blob_access.json
}

resource "aws_iam_role_policy" "web_blob_kms" {
  count  = local.kms_enabled ? 1 : 0
  name   = "blob-kms"
  role   = aws_iam_role.web_task.id
  policy = data.aws_iam_policy_document.kms_s3[0].json
}

# Worker task role.
resource "aws_iam_role" "worker_task" {
  name               = "${local.name_prefix}-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy" "worker_blob" {
  name   = "blob-access"
  role   = aws_iam_role.worker_task.id
  policy = data.aws_iam_policy_document.blob_access.json
}

resource "aws_iam_role_policy" "worker_blob_kms" {
  count  = local.kms_enabled ? 1 : 0
  name   = "blob-kms"
  role   = aws_iam_role.worker_task.id
  policy = data.aws_iam_policy_document.kms_s3[0].json
}

# ClickHouse task role (no extra AWS access needed beyond its execution role).
resource "aws_iam_role" "clickhouse_task" {
  name               = "${local.name_prefix}-clickhouse-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

# ECS infrastructure role — lets ECS manage the ClickHouse EBS data volume.
data "aws_iam_policy_document" "ecs_infra_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "${local.name_prefix}-ecs-infra"
  assume_role_policy = data.aws_iam_policy_document.ecs_infra_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRolePolicyForVolumes"
}

# ===========================================================================
# ClickHouse on Fargate with an EBS-backed data volume (Requirement 11.4).
# Single node (single-attach EBS). The volume is provisioned per-task by ECS
# (managed EBS) and mounted at /var/lib/clickhouse for persistence.
# ===========================================================================
resource "aws_ecs_task_definition" "clickhouse" {
  #checkov:skip=CKV_AWS_336:The official ClickHouse image writes generated user config under /etc/clickhouse-server, plus logs and temp files, at startup. Data lives on the encrypted ECS-managed EBS volume; the task runs in private subnets with security-group-restricted access.
  family                   = "${local.name_prefix}-clickhouse"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.clickhouse_task_cpu)
  memory                   = tostring(var.clickhouse_task_memory)
  execution_role_arn       = aws_iam_role.clickhouse_execution.arn
  task_role_arn            = aws_iam_role.clickhouse_task.arn

  # ECS-managed EBS volume, configured at launch on the service (see below).
  volume {
    name                = "clickhouse-data"
    configure_at_launch = true
  }

  container_definitions = jsonencode([
    {
      name      = "clickhouse"
      image     = var.clickhouse_image
      essential = true

      environment = [
        { name = "CLICKHOUSE_DB", value = "default" },
        { name = "CLICKHOUSE_USER", value = var.clickhouse_user },
        { name = "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT", value = "1" },
      ]

      secrets = [
        { name = "CLICKHOUSE_PASSWORD", valueFrom = aws_secretsmanager_secret.clickhouse_password.arn },
      ]

      mountPoints = [
        {
          sourceVolume  = "clickhouse-data"
          containerPath = "/var/lib/clickhouse"
          readOnly      = false
        }
      ]

      portMappings = [
        { containerPort = var.clickhouse_http_port, protocol = "tcp" },
        { containerPort = var.clickhouse_native_port, protocol = "tcp" },
      ]

      ulimits = [
        { name = "nofile", softLimit = 262144, hardLimit = 262144 }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.clickhouse.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "clickhouse"
        }
      }
    }
  ])

  tags = local.module_tags
}

resource "aws_ecs_service" "clickhouse" {
  name            = "${var.name}-clickhouse"
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.clickhouse.arn
  desired_count   = 1 # single-node ClickHouse (single-attach EBS)
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.clickhouse.id]
    assign_public_ip = false
  }

  # ECS-managed EBS data volume, KMS-encrypted at rest (Requirement 15.5).
  volume_configuration {
    name = "clickhouse-data"
    managed_ebs_volume {
      role_arn    = aws_iam_role.ecs_infrastructure.arn
      size_in_gb  = var.clickhouse_data_volume_size_gb
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = var.kms_key_arn
    }
  }

  service_registries {
    registry_arn = aws_service_discovery_service.clickhouse.arn
  }

  tags = local.module_tags
}

# ===========================================================================
# Edge (ADR-030) — PRIVATE internal ALB -> web target group. HTTP only.
# No CloudFront, no HTTPS/ACM, no Cognito auth-action. Reachable only from
# within the VPC (OTel collector for OTLP ingestion; on-network humans via
# VPN/corp network for the UI). Access control = network isolation + Langfuse's
# own app auth.
# ===========================================================================
resource "aws_lb" "langfuse" {
  enable_deletion_protection = var.alb_deletion_protection
  name                       = "${var.name}-alb"
  # ADR-030: always internal, in private subnets. ADR-038: when
  # enable_cloudfront_origin is set (demo only), CloudFront reaches it through a
  # VPC origin (aws_cloudfront_vpc_origin.alb) over the AWS network. Ingress is
  # still locked to the CloudFront prefix list + a secret origin header (see
  # aws_security_group_rule.alb_http_from_cloudfront).
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = local.module_tags
}

resource "aws_lb_target_group" "web" {
  name        = "${var.name}-web"
  port        = var.web_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/api/public/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = local.module_tags
}

# HTTP listener on the web port -> forward to the Langfuse web target group.
# ADR-030: private internal ALB, HTTP only. No HTTPS/ACM redirect and no
# ALB-level Cognito authenticate action — access is gated by network isolation
# (VPN/corp network) plus Langfuse's own application login. The OTel collector
# reaches this same listener for OTLP span ingestion (/api/public/otel).
resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:Internal ALB in private subnets (ADR-030). Demo: reached by CloudFront only through a VPC origin. Add an HTTPS listener with an ACM certificate for production.
  load_balancer_arn = aws_lb.langfuse.arn
  port              = var.web_container_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ADR-038 (demo only): when CloudFront-facing, require the secret origin header
# on the CloudFront path as defense-in-depth on top of the prefix-list SG rule,
# so another account's CloudFront (allowed by the shared prefix list) cannot
# reach Langfuse. VPC-internal traffic (the OTLP collector) uses the listener's
# default forward action and needs no header, so the collector path is intact.
resource "aws_lb_listener_rule" "cloudfront_secret_header" {
  count        = var.enable_cloudfront_origin ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  condition {
    http_header {
      http_header_name = var.cloudfront_origin_secret_header
      values           = [var.cloudfront_origin_secret_value]
    }
  }
}

# ===========================================================================
# Langfuse web + worker on ECS Fargate (Requirement 11.2).
# Container env wires DATABASE_URL, CLICKHOUSE_*, REDIS_*, S3/blob, NEXTAUTH_URL,
# SALT/ENCRYPTION_KEY — secrets by ref, never plaintext (Secrets Manager).
# ===========================================================================
resource "aws_ecs_task_definition" "web" {
  family                   = "${local.name_prefix}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.web_task_cpu)
  memory                   = tostring(var.web_task_memory)
  execution_role_arn       = aws_iam_role.web_execution.arn
  task_role_arn            = aws_iam_role.web_task.arn

  container_definitions = jsonencode([
    {
      name      = "langfuse-web"
      image     = var.langfuse_web_image
      essential = true

      environment = concat(local.common_environment, [
        { name = "NEXTAUTH_URL", value = local.nextauth_url },
        { name = "HOSTNAME", value = "0.0.0.0" },
        { name = "PORT", value = tostring(var.web_container_port) },
      ], local.langfuse_headless_init_environment)

      secrets = concat(local.common_secrets, [
        { name = "NEXTAUTH_SECRET", valueFrom = aws_secretsmanager_secret.nextauth_secret.arn },
      ], local.langfuse_headless_init_secrets)

      portMappings = [
        { containerPort = var.web_container_port, protocol = "tcp" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.web.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "web"
        }
      }
    }
  ])

  tags = local.module_tags
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name_prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.worker_task_cpu)
  memory                   = tostring(var.worker_task_memory)
  execution_role_arn       = aws_iam_role.worker_execution.arn
  task_role_arn            = aws_iam_role.worker_task.arn

  container_definitions = jsonencode([
    {
      name      = "langfuse-worker"
      image     = var.langfuse_worker_image
      essential = true

      environment = local.common_environment
      secrets     = local.common_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = local.module_tags
}

resource "aws_ecs_service" "web" {
  name            = "${var.name}-web"
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = var.web_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "langfuse-web"
    container_port   = var.web_container_port
  }

  depends_on = [aws_lb_listener.http]

  tags = local.module_tags
}

resource "aws_ecs_service" "worker" {
  name            = "${var.name}-worker"
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# CloudFront VPC origin (demo only, enable_cloudfront_origin). Lets the
# examples-console Langfuse distribution reach the internal ALB without a
# public address.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_vpc_origin" "alb" {
  count = var.enable_cloudfront_origin ? 1 : 0

  vpc_origin_endpoint_config {
    name                   = substr("${var.name}-vpc-origin", 0, 64)
    arn                    = aws_lb.langfuse.arn
    http_port              = var.web_container_port
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = local.module_tags
}
