# Platform Console — S3 + CloudFront + Cognito Identity Pool
# Static site hosting for the unified React console.

# S3 bucket for static site hosting (private, no public access)
resource "aws_s3_bucket" "console" {
  # Account ID suffix keeps the globally unique name from being pre-registered
  # by another account (bucket squatting).
  bucket = "eap-console-${var.environment}-${var.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "console" {
  bucket                  = aws_s3_bucket.console.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront Origin Access Control
resource "aws_cloudfront_origin_access_control" "console" {
  name                              = "eap-console-oac-${var.environment}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Local to extract the API Gateway hostname from the full invoke URL
# Routing (evaluated in order of precedence):
#   /api/invoke  -> REST API origin        (buffered chat, timeout-bumpable)
#   /api/*       -> studio-read backend ALB (fast read-only routes)
# Both are same-origin behind this distribution, so no browser CORS is needed.
# The studio-read backend replaced the former HTTP API Gateway origin, so every
# console backend now runs on ALB/Fargate (locked to CloudFront via an origin
# secret header). The read routes self-validate the Cognito JWT in-service.
#
# Langfuse embedding (Requirements 13.1, 7.4): the embedded Langfuse trace/prompt/eval
# iframe in the ObservabilityWorkspace has its `src` set to var.langfuse_embed_origin
# (injected below as VITE_LANGFUSE_EMBED_ORIGIN). This console distribution
# deliberately sets NO restrictive response-headers policy — it emits neither
# `X-Frame-Options` nor a `Content-Security-Policy: frame-ancestors` — so it imposes
# no framing restriction. Whether Langfuse may be framed is governed on the
# Langfuse SIDE by its `Content-Security-Policy: frame-ancestors 'self'
# https://<console-domain>` response header (configured on the Langfuse_ALB/CloudFront
# in task 9.1), which names this console's origin as an allowed frame ancestor. If a
# CloudFront response-headers policy is ever added to this distribution, it MUST NOT
# set `X-Frame-Options`, and any CSP it introduces MUST include `frame-src`/
# `frame-ancestors` permitting the Langfuse origin so the embed keeps working.

# CloudFront distribution with SPA fallback
resource "aws_cloudfront_distribution" "console" {
  #checkov:skip=CKV_AWS_174:Uses the default *.cloudfront.net certificate, for which CloudFront always allows TLSv1; minimum_protocol_version only applies with a custom certificate. Use a custom domain and ACM certificate for production.
  origin {
    domain_name              = aws_s3_bucket.console.bucket_regional_domain_name
    origin_id                = "s3-console"
    origin_access_control_id = aws_cloudfront_origin_access_control.console.id
  }

  # studio-read backend ALB — /api/* origin (read routes). Internal ALB reached through a
  # CloudFront VPC origin, locked to CloudFront via the secret header the ALB listener requires
  # (same lockdown as the examples + ADE origins).
  dynamic "origin" {
    for_each = var.studio_read_backend_alb_dns != "" ? [1] : []
    content {
      domain_name = var.studio_read_backend_alb_dns
      origin_id   = "studio-read-api"

      vpc_origin_config {
        vpc_origin_id = var.studio_read_vpc_origin_id
        # SSE streams: per-packet read timeout above the 30s default; the backend
        # heartbeats every 10s.
        origin_read_timeout = 60
      }

      custom_header {
        name  = var.studio_read_origin_secret_header
        value = var.studio_read_origin_secret_value
      }
    }
  }

  # Examples backend ALB (ADR-037) — /examples-api/* origin. Internal ALB reached through a
  # CloudFront VPC origin, locked to CloudFront via the secret header the ALB listener requires.
  dynamic "origin" {
    for_each = var.examples_backend_alb_dns != "" ? [1] : []
    content {
      domain_name = var.examples_backend_alb_dns
      origin_id   = "examples-api"

      vpc_origin_config {
        vpc_origin_id = var.examples_vpc_origin_id
        # SSE streams: per-packet read timeout above the 30s default; the backend
        # heartbeats every 10s.
        origin_read_timeout = 60
      }

      custom_header {
        name  = var.examples_origin_secret_header
        value = var.examples_origin_secret_value
      }
    }
  }

  # ADE invoke-backend ALB (ADR-040) — /ade-api/* origin. Internal ALB reached through a
  # CloudFront VPC origin, locked to CloudFront via the secret header the ADE ALB listener requires.
  # /ade-api/invoke streams SSE; raise the per-packet origin read timeout above
  # the 30s default (backend heartbeats every 10s).
  dynamic "origin" {
    for_each = var.ade_backend_alb_dns != "" ? [1] : []
    content {
      domain_name = var.ade_backend_alb_dns
      origin_id   = "ade-api"

      vpc_origin_config {
        vpc_origin_id = var.ade_vpc_origin_id
        # SSE streams: per-packet read timeout above the 30s default; the backend
        # heartbeats every 10s.
        origin_read_timeout = 60
      }

      custom_header {
        name  = var.ade_origin_secret_header
        value = var.ade_origin_secret_value
      }
    }
  }

  enabled             = true
  default_root_object = "index.html"

  # ADR-037: attach the CLOUDFRONT-scope WAF WebACL when provided.
  web_acl_id = var.examples_waf_web_acl_arn != "" ? var.examples_waf_web_acl_arn : null

  # SPA fallback: serve index.html for React Router paths
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  # /examples-api/* -> examples Fargate backend ALB (ADR-037). No caching,
  # forward all viewer headers except Host. Distinct prefix so it never
  # collides with the API-Gateway /api/* behaviors below.
  dynamic "ordered_cache_behavior" {
    for_each = var.examples_backend_alb_dns != "" ? [1] : []
    content {
      path_pattern           = "/examples-api/*"
      target_origin_id       = "examples-api"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      viewer_protocol_policy = "https-only"
      compress               = false

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    }
  }

  # /ade-api/* -> ADE streaming invoke backend ALB (ADR-040). No caching, forward
  # all viewer headers except Host (the Authorization bearer token must reach the
  # backend for JWT validation). Distinct prefix so it never collides with the
  # examples or /api behaviors.
  dynamic "ordered_cache_behavior" {
    for_each = var.ade_backend_alb_dns != "" ? [1] : []
    content {
      path_pattern           = "/ade-api/*"
      target_origin_id       = "ade-api"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      viewer_protocol_policy = "https-only"
      compress               = false

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    }
  }

  # /api/* routes to the studio-read backend ALB (read-only Build-workspace
  # routes; same-origin, no caching, forward all viewer headers except Host so
  # the Authorization bearer reaches the backend for in-service JWT validation).
  # There is no /api/invoke behavior anymore: chat streams through the ADE
  # backend at /ade-api/* (ADR-041), so no API Gateway origin is fronted here.
  dynamic "ordered_cache_behavior" {
    for_each = var.studio_read_backend_alb_dns != "" ? [1] : []
    content {
      path_pattern           = "/api/*"
      target_origin_id       = "studio-read-api"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      viewer_protocol_policy = "https-only"
      compress               = false

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-console"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  logging_config {
    bucket          = var.access_log_bucket_domain
    prefix          = "console/"
    include_cookies = false
  }

  tags = var.tags
}

# S3 bucket policy allowing CloudFront OAC access
resource "aws_s3_bucket_policy" "console" {
  bucket = aws_s3_bucket.console.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.console.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.console.arn
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# Cognito Identity Pool for browser-based AWS SDK credential exchange
#
# Cognito-specific (ADR-028): only created when the platform provisions Cognito
# (cognito_app_client_id non-empty). Under an external OIDC IdP this browser
# AWS-credential-exchange path needs an OIDC-federated identity pool instead —
# tracked as follow-up — so the pool + its auth role are skipped rather than
# created with an empty client_id (which the API rejects).
# ---------------------------------------------------------------------------
locals {
  # Known at plan time (driven by whether the platform provisions Cognito),
  # NOT derived from the app client id which is unknown until apply.
  create_cognito_identity_pool = var.create_cognito_identity_pool

  # ADR-033: create the authenticated role + its policy only when the identity
  # pool is created AND no pre-created ARN is supplied. The identity-pool
  # attachment (which needs a role ARN whenever the pool exists) resolves to the
  # supplied ARN or the created role.
  create_console_role   = local.create_cognito_identity_pool && var.authenticated_role_arn == ""
  console_auth_role_arn = var.authenticated_role_arn != "" ? var.authenticated_role_arn : one(aws_iam_role.console_authenticated[*].arn)
}

resource "aws_cognito_identity_pool" "console" {
  count = local.create_cognito_identity_pool ? 1 : 0

  identity_pool_name               = "eap-console-${var.environment}"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = var.cognito_app_client_id
    provider_name           = "cognito-idp.${var.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"
    server_side_token_check = true
  }

  tags = var.tags
}

# IAM role for authenticated console users
resource "aws_iam_role" "console_authenticated" {
  count = local.create_console_role ? 1 : 0

  name = "eap-console-auth-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "cognito-identity.amazonaws.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.console[0].id
        }
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "authenticated"
        }
      }
    }]
  })

  tags = var.tags
}

# Permissions: DynamoDB read, S3 read (graduation reports), CodePipeline ops
resource "aws_iam_role_policy" "console_permissions" {
  count = local.create_console_role ? 1 : 0

  name = "console-data-access"
  role = aws_iam_role.console_authenticated[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:Scan"]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/agent-school-lifecycle-*",
          "arn:aws:dynamodb:${var.aws_region}:${var.account_id}:table/agent-school-lifecycle-*/index/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::eap-graduation-reports-*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "codepipeline:ListPipelines"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "codepipeline:GetPipelineExecution",
          "codepipeline:ListPipelineExecutions",
          "codepipeline:StartPipelineExecution"
        ]
        Resource = "arn:aws:codepipeline:${var.aws_region}:${var.account_id}:*"
      }
      # Interactive chat no longer needs a browser IAM permission: the console
      # calls the same-origin /api/invoke (CloudFront -> REST API, Cognito-JWT
      # authorized). No SigV4 / lambda:InvokeFunctionUrl from the browser.
    ]
  })
}

# Attach authenticated role to Identity Pool
resource "aws_cognito_identity_pool_roles_attachment" "console" {
  count = local.create_cognito_identity_pool ? 1 : 0

  identity_pool_id = aws_cognito_identity_pool.console[0].id
  roles = {
    # ADR-033: supplied external role ARN wins, else the platform-created role.
    authenticated = local.console_auth_role_arn
  }
}

# ---------------------------------------------------------------------------
# Build & Deploy Console — runs npm build + s3 sync as post-apply step
# Triggers on any change to the console source or infrastructure.
# ---------------------------------------------------------------------------
resource "null_resource" "console_deploy" {
  depends_on = [
    aws_s3_bucket.console,
    aws_cloudfront_distribution.console,
    aws_cognito_identity_pool.console,
  ]

  # Identity pool id is empty under an external IdP (pool not created).

  # Re-run when source changes (use a hash of package.json as trigger)
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../../console"
    command     = <<-EOT
      echo "=== Building Platform Console ==="
      npm install --prefer-offline --no-audit 2>/dev/null || npm install
      VITE_COGNITO_DOMAIN="${var.cognito_domain_prefix}-${var.environment}" \
      VITE_COGNITO_REGION="${var.aws_region}" \
      VITE_COGNITO_CLIENT_ID="${var.cognito_app_client_id}" \
      VITE_REDIRECT_URI="https://${aws_cloudfront_distribution.console.domain_name}/auth/callback" \
      VITE_USER_POOL_ID="${var.cognito_user_pool_id}" \
      VITE_IDENTITY_POOL_ID="${one(aws_cognito_identity_pool.console[*].id)}" \
      VITE_STATE_TABLE="agent-school-lifecycle-team-bu-1-${var.environment}" \
      VITE_LANGFUSE_EMBED_ORIGIN="${var.langfuse_embed_origin}" \
      VITE_EXAMPLES_PIPELINE="${var.examples_pipeline_name}" \
      npm run build

      echo "=== Uploading to S3 ==="
      aws s3 sync dist/ "s3://${aws_s3_bucket.console.id}/" --delete

      echo "=== Invalidating CloudFront ==="
      aws cloudfront create-invalidation \
        --distribution-id "${aws_cloudfront_distribution.console.id}" \
        --paths "/*" --output text

      echo "=== Console deployed at https://${aws_cloudfront_distribution.console.domain_name} ==="
    EOT
  }
}

# ---------------------------------------------------------------------------
# Cognito callback sync (durable fix for the stale-callback issue).
#
# The console SPA is built with VITE_REDIRECT_URI = https://<live-cloudfront>/
# auth/callback, but the Cognito console app client's callback_urls are set in
# the identity module from var.console_url (empty by default) — so on a fresh
# deploy the CloudFront callback is NOT in the allow-list and Cognito rejects
# the login redirect. The distribution's random dXXXX.cloudfront.net domain is
# only known after it's created, so it can't be baked into the client at plan
# time.
#
# This resource closes that gap: after the deploy it merges the LIVE CloudFront
# callback + logout URLs into the console app client via update-user-pool-client
# (preserving the localhost dev URLs and the OAuth flows/scopes). The identity
# module ignores out-of-band changes to callback_urls/logout_urls (lifecycle),
# so this sync is authoritative for the CloudFront entry and a clean single
# apply yields a working login — no manual console_url re-apply. Cognito-only
# (skipped under an external IdP, where cognito_app_client_id is empty).
# ---------------------------------------------------------------------------
resource "null_resource" "console_callback_sync" {
  count = var.cognito_app_client_id != "" ? 1 : 0

  depends_on = [aws_cloudfront_distribution.console]

  triggers = {
    domain    = aws_cloudfront_distribution.console.domain_name
    client_id = var.cognito_app_client_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      DOMAIN="${aws_cloudfront_distribution.console.domain_name}"
      CB="https://$DOMAIN/auth/callback"
      LO="https://$DOMAIN/"
      echo "=== Syncing Cognito callback for console client (${var.cognito_app_client_id}) ==="
      echo "    callback: $CB"

      # Merge the live CloudFront URLs with whatever the client already has
      # (localhost dev URLs), de-duplicated. update-user-pool-client REPLACES
      # the client config, so re-supply the OAuth flags to preserve them.
      # Pass the existing JSON to Python via env vars (NOT string interpolation)
      # so multi-line JSON arrays don't break the parser.
      DESC=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "${var.cognito_user_pool_id}" \
        --client-id "${var.cognito_app_client_id}" \
        --region "${var.aws_region}" --output json 2>/dev/null || echo '{}')

      CB_LIST=$(EXISTING="$DESC" NEW="$CB" python3 -c 'import json,os; d=json.loads(os.environ.get("EXISTING") or "{}").get("UserPoolClient",{}); e=d.get("CallbackURLs",[]); e.append(os.environ["NEW"]); print(" ".join(sorted(set(e))))')
      LO_LIST=$(EXISTING="$DESC" NEW="$LO" python3 -c 'import json,os; d=json.loads(os.environ.get("EXISTING") or "{}").get("UserPoolClient",{}); e=d.get("LogoutURLs",[]); e.append(os.environ["NEW"]); print(" ".join(sorted(set(e))))')

      aws cognito-idp update-user-pool-client \
        --user-pool-id "${var.cognito_user_pool_id}" \
        --client-id "${var.cognito_app_client_id}" \
        --region "${var.aws_region}" \
        --callback-urls $CB_LIST \
        --logout-urls $LO_LIST \
        --allowed-o-auth-flows code implicit \
        --allowed-o-auth-scopes openid profile email \
        --allowed-o-auth-flows-user-pool-client \
        --supported-identity-providers COGNITO \
        --explicit-auth-flows ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH \
        --output text >/dev/null

      echo "=== Cognito callback synced: $CB ==="
    EOT
  }
}

# ---------------------------------------------------------------------------
# Demo console admin user (Cognito path only).
#
# The demo console is a "show it works" surface, but a fresh Cognito pool has NO
# users (allow_admin_create_user_only = true) — so out of the box you can't log
# in. Seed a single admin user (admin@eap.ai) with a generated password
# stored in Secrets Manager, mirroring how the Langfuse module seeds its own
# admin. Same username as Langfuse's init user for a consistent demo identity;
# the credentials remain independent (separate stores/passwords).
#
# Gated to the Cognito path (create_cognito_identity_pool && a client id exists)
# — under an external IdP (enterprise) this is skipped: the deployer's IdP owns
# users. The password meets the pool policy (>=16 chars, upper/lower/number/
# symbol). Idempotent: re-applies re-assert the user + permanent password.
# ---------------------------------------------------------------------------
locals {
  create_console_admin   = var.create_cognito_identity_pool && var.cognito_app_client_id != ""
  console_admin_username = "admin@eap.ai"
}

resource "random_password" "console_admin" {
  count            = local.create_console_admin ? 1 : 0
  length           = 20
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*-_" # Cognito-safe symbols
}

# Customer managed key for the admin secret. The default key policy delegates to
# IAM, so whoever deploys (and can read the secret) also needs kms:Decrypt.
resource "aws_kms_key" "console_admin" {
  count                   = local.create_console_admin ? 1 : 0
  description             = "Demo console admin secret (${var.environment})"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministration"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
  tags = var.tags
}

resource "aws_secretsmanager_secret" "console_admin" {
  count       = local.create_console_admin ? 1 : 0
  name        = "eap-console-admin-${var.environment}"
  kms_key_id  = aws_kms_key.console_admin[0].arn
  description = "Demo console Cognito admin login (username + password). Log in at the CloudFront console URL."
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "console_admin" {
  count     = local.create_console_admin ? 1 : 0
  secret_id = aws_secretsmanager_secret.console_admin[0].id
  secret_string = jsonencode({
    username = local.console_admin_username
    password = random_password.console_admin[0].result
  })
}

# Create the user + set the permanent password + add to the BU group. Uses a
# null_resource (not aws_cognito_user) because the provider resource can't set a
# PERMANENT password (it would force a change-password challenge on first login).
resource "null_resource" "console_admin_user" {
  count = local.create_console_admin ? 1 : 0

  triggers = {
    username = local.console_admin_username
    # re-run if the password rotates
    password_version = aws_secretsmanager_secret_version.console_admin[0].version_id
    pool             = var.cognito_user_pool_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      POOL="${var.cognito_user_pool_id}"
      USER="${local.console_admin_username}"
      REGION="${var.aws_region}"
      PASS=$(aws secretsmanager get-secret-value --secret-id "${aws_secretsmanager_secret.console_admin[0].arn}" \
        --region "$REGION" --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

      echo "=== Seeding demo console admin user ($USER) ==="
      # Create (idempotent — ignore 'already exists'); suppress the invite email.
      aws cognito-idp admin-create-user \
        --user-pool-id "$POOL" --username "$USER" \
        --user-attributes Name=email,Value="$USER" Name=email_verified,Value=true \
        --message-action SUPPRESS --region "$REGION" >/dev/null 2>&1 || true
      # Set a PERMANENT password (no forced change on first login).
      aws cognito-idp admin-set-user-password \
        --user-pool-id "$POOL" --username "$USER" \
        --password "$PASS" --permanent --region "$REGION"
      # Add to the team-bu-1 group (idempotent).
      aws cognito-idp admin-add-user-to-group \
        --user-pool-id "$POOL" --username "$USER" \
        --group-name team-bu-1 --region "$REGION" >/dev/null 2>&1 || true
      echo "=== Console admin ready: $USER (password in Secrets Manager: eap-console-admin-${var.environment}) ==="
    EOT
  }
}
