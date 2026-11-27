# Examples Console backend (ADR-037) — backend-only module.
#
# Provisions the generic examples Fargate backend (ECR + ECS Fargate + ALB) and
# the WAF WebACL, all locked down so the ALB is reachable ONLY through the demo
# console CloudFront distribution (origin-facing prefix list + secret origin
# header). The distribution itself lives in the `console` module (Path 1 / C2):
# this module exposes the ALB DNS, the secret header value, and the WAF ARN as
# outputs for the console distribution to consume. Created only in the demo
# preset (gated on deploy_console at the platform root).

locals {
  name_prefix = "eap-examples-${var.environment}"
  tags = merge(var.tags, {
    "eap:component" = "examples-console"
    "eap:managed"   = "true"
  })

  # Secret header CloudFront injects and the ALB requires — defense in depth on
  # top of the CloudFront origin-facing prefix list.
  origin_secret_header = "x-eap-origin"
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_password" "origin_secret" {
  length  = 40
  special = false
}

# ---------------------------------------------------------------------------
# ECR repository + image build/push for the examples backend
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "backend" {
  name                 = "${local.name_prefix}-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS" # AWS-managed aws/ecr key
  }

  tags = local.tags
}

# Build + push the backend image only when the backend SOURCE changes (source
# hash), not on every apply. Uses the local Docker daemon (same pattern as the
# console's npm build/sync null_resource). node_modules is excluded (rebuilt
# from the lockfile inside the image).
locals {
  examples_backend_src = "${path.module}/../../examples-backend"
  # Hash the backend sources that go into the image: top-level files + src/**.
  # node_modules is NOT globbed (rebuilt from the lockfile inside the image;
  # walking ~4k files on every plan would be needlessly slow).
  examples_backend_files = sort(setunion(
    fileset(local.examples_backend_src, "*"),
    fileset(local.examples_backend_src, "src/**"),
  ))
  examples_backend_source_hash = sha1(join("", [
    for f in local.examples_backend_files : filesha256("${local.examples_backend_src}/${f}")
  ]))
}

resource "null_resource" "backend_image" {
  triggers = {
    source_hash = local.examples_backend_source_hash
  }

  provisioner "local-exec" {
    working_dir = local.examples_backend_src
    # Isolate Docker's config into a throwaway dir and embed the ECR auth
    # directly (see command) so `docker login`'s keychain save path — which
    # races with -25299 when parallel builds hit the same registry — is never
    # invoked.
    environment = {
      # abspath() so the throwaway config lands next to THIS module — not
      # relative to working_dir (the backend source dir).
      DOCKER_CONFIG = "${abspath(path.module)}/.docker-examples"
    }
    command = <<-EOT
      set -euo pipefail
      mkdir -p "$DOCKER_CONFIG"
      REGISTRY="${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
      REPO="${aws_ecr_repository.backend.repository_url}"
      echo "=== Building examples-backend image ==="
      # Embed ECR auth directly (no `docker login` → no keychain race). See the
      # ade-invoke-backend module for the full rationale.
      TOKEN=$(aws ecr get-login-password --region ${var.aws_region})
      AUTH=$(printf 'AWS:%s' "$TOKEN" | base64 | tr -d '\n')
      printf '{"auths":{"%s":{"auth":"%s"}}}' "$REGISTRY" "$AUTH" > "$DOCKER_CONFIG/config.json"
      docker build --platform linux/amd64 -t "$REPO:latest" .
      docker push "$REPO:latest"
      echo "=== Pushed $REPO:latest ==="
    EOT
  }
}

# ---------------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "backend" {
  name              = "/eap/examples-backend/${var.environment}"
  retention_in_days = var.log_group_retention_days
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# IAM — execution role (pull image, write logs) + task role (sign/invoke)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

# The backend's runtime permissions: invoke AgentCore runtimes, drive Step
# Functions, and read CloudWatch logs. Scoped to the region/account.
data "aws_iam_policy_document" "task" {
  statement {
    sid    = "InvokeAgentCore"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:InvokeAgentRuntime",
    ]
    resources = ["arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:runtime/*"]
  }

  statement {
    sid    = "StepFunctions"
    effect = "Allow"
    actions = [
      "states:StartExecution",
      "states:DescribeExecution",
      "states:GetExecutionHistory",
    ]
    resources = [
      "arn:aws:states:${var.aws_region}:${var.account_id}:stateMachine:*",
      "arn:aws:states:${var.aws_region}:${var.account_id}:execution:*:*",
    ]
  }

  # ADR-046 target allow-list: read the lifecycle table (deployed runtimes and
  # state machines). Read-only, table-scoped.
  statement {
    sid       = "LifecycleAllowListRead"
    effect    = "Allow"
    actions   = ["dynamodb:Scan"]
    resources = [var.lifecycle_table_arn]
  }

  # DescribeLogGroups is a LIST action that does not act on a specific
  # log-group resource — IAM evaluates it against the region/account, not a
  # log-group ARN, so it CANNOT be prefix-scoped and must be granted on "*".
  # (Scoping it to a log-group ARN is why it was silently denied.) The
  # logGroupNamePrefix request parameter still limits what readAgentLogs
  # actually enumerates to the bedrock-agentcore runtime groups.
  statement {
    sid       = "DiscoverAgentLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  # The per-group reads DO act on specific resources, so keep them scoped to the
  # AgentCore runtime log groups (and their streams).
  statement {
    sid    = "ReadAgentLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
    ]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "examples-backend"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ---------------------------------------------------------------------------
# Security groups — ALB (from CloudFront prefix list) + backend (from ALB)
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Examples ALB - ingress only from the CloudFront origin-facing prefix list (ADR-037)."
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from CloudFront edge only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "backend" {
  name        = "${local.name_prefix}-backend"
  description = "Examples backend Fargate - ingress only from the ALB."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Backend port from ALB"
    from_port       = var.backend_container_port
    to_port         = var.backend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# ALB — internal (private subnets), reached only by CloudFront through a VPC
# origin; HTTP:80 origin listener
# ---------------------------------------------------------------------------
resource "aws_lb" "backend" {
  enable_deletion_protection = var.alb_deletion_protection
  name                       = substr("${local.name_prefix}-alb", 0, 32)
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.private_subnet_ids

  # The /invoke route streams SSE for long agent turns. The backend emits a
  # heartbeat every 10s, but raise the idle timeout well above that so a slow
  # tool-heavy turn is never severed by the ALB mid-stream (default is 60s).
  idle_timeout = 300

  tags = local.tags
}

resource "aws_lb_target_group" "backend" {
  name        = substr("${local.name_prefix}-tg", 0, 32)
  port        = var.backend_container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

# Default action returns 403 unless the CloudFront secret header is present —
# defense in depth on top of the SG prefix-list restriction.
resource "aws_lb_listener" "backend" {
  #checkov:skip=CKV_AWS_2:Internal ALB in private subnets, reached only by CloudFront through a VPC origin (AWS network). Add an HTTPS listener with an ACM certificate for production.
  load_balancer_arn = aws_lb.backend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "cloudfront_only" {
  listener_arn = aws_lb_listener.backend.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    http_header {
      http_header_name = local.origin_secret_header
      values           = [random_password.origin_secret.result]
    }
  }
}

# ---------------------------------------------------------------------------
# ECS Fargate — cluster + task + service
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = local.name_prefix
  tags = local.tags
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.name_prefix}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.backend_task_cpu)
  memory                   = tostring(var.backend_task_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = "${aws_ecr_repository.backend.repository_url}:latest"
      essential = true
      portMappings = [
        { containerPort = var.backend_container_port, protocol = "tcp" }
      ]
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "PORT", value = tostring(var.backend_container_port) },
        # ADR-046 caller auth: platform Cognito pool + console client, OR an
        # external OIDC issuer (ADR-028). The backend refuses to start if
        # neither is set.
        { name = "COGNITO_USER_POOL_ID", value = var.cognito_user_pool_id },
        { name = "COGNITO_APP_CLIENT_ID", value = var.cognito_app_client_id },
        { name = "OIDC_ISSUER", value = var.oidc_issuer },
        { name = "OIDC_AUDIENCE", value = var.oidc_audience },
        # ADR-046 target allow-list source.
        { name = "LIFECYCLE_TABLE", value = var.lifecycle_table_name },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "backend" {
  name            = "${local.name_prefix}-backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = var.backend_container_port
  }

  depends_on = [aws_lb_listener.backend, null_resource.backend_image]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# WAF — managed rule sets, attached by the console distribution (global scope).
# CLOUDFRONT-scope WAF must live in us-east-1; the platform deploys in us-east-1
# (default provider), so no separate provider alias is needed.
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "cloudfront" {
  name  = "${local.name_prefix}-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # The Common rule set's SizeRestrictions_BODY rule blocks any request
        # body over 8 KB (the WAF body-inspection default). The console's
        # backends legitimately POST large JSON bodies — streamed chat turns and
        # (ADR: ADE file upload) base64-inlined image/PDF/text attachments — so
        # an 827 KB PNG (~1.1 MB base64) was 403'd by WAF and the SPA served
        # index.html. Count (don't block) this specific sub-rule; all other
        # Common rules (SQLi, XSS, LFI, etc.) and KnownBadInputs stay enforcing.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-badinputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Langfuse public edge (ADR-039, supersedes the ADR-038 /langfuse subpath).
#
# Langfuse is a Next.js app that serves at ROOT (/) and does not cooperate with
# being served under a /langfuse subpath of the console (it 308-redirects
# /langfuse/ -> /langfuse and links assets at /, so the console distribution's
# /langfuse/* behavior fell through to the S3 SPA -> the console nested itself).
#
# Fix: give Langfuse its OWN hardened CloudFront distribution — a single origin
# at the Langfuse ALB root, so Langfuse serves normally with no subpath. Locked
# down identically (CloudFront origin-facing prefix list on the ALB SG + the
# secret origin header this module already manages + the same WAF WebACL). The
# console embeds this distribution's absolute URL. Created only when a
# CloudFront-facing Langfuse ALB DNS is supplied (demo + deploy_langfuse).
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "langfuse" {
  #checkov:skip=CKV_AWS_305:Single origin to the Langfuse web app, which serves its own routes at /; a default root object would rewrite / to a file that does not exist.
  #checkov:skip=CKV_AWS_174:Uses the default *.cloudfront.net certificate, for which CloudFront always allows TLSv1; minimum_protocol_version only applies with a custom certificate. Use a custom domain and ACM certificate for production.
  count = var.langfuse_alb_dns != "" ? 1 : 0

  enabled    = true
  web_acl_id = aws_wafv2_web_acl.cloudfront.arn

  origin {
    domain_name = var.langfuse_alb_dns
    origin_id   = "langfuse-alb"

    vpc_origin_config {
      vpc_origin_id = var.langfuse_vpc_origin_id
    }

    # Same secret header the Langfuse ALB listener rule requires (origin lockdown).
    custom_header {
      name  = local.origin_secret_header
      value = random_password.origin_secret.result
    }
  }

  # Single default behavior — everything goes to Langfuse at root, no caching,
  # forward all viewer headers except Host so Langfuse app auth + routing work.
  default_cache_behavior {
    target_origin_id       = "langfuse-alb"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "https-only"
    compress               = false

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = var.access_log_bucket_domain
    prefix          = "langfuse/"
    include_cookies = false
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CloudFront VPC origin for the examples ALB. CloudFront connects to the
# internal ALB over the AWS network through service-managed ENIs in the VPC.
# The ALB security group still admits only the CloudFront origin-facing prefix
# list, and the listener still requires the secret origin header.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = substr("${local.name_prefix}-vpc-origin", 0, 64)
    arn                    = aws_lb.backend.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = local.tags
}
