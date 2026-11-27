# ADE Invoke Backend (ADR-040) — always-on streaming invoke for the ADE chat.
#
# ECS/Fargate service (platform/ade-invoke-backend) behind an ALB, deployed in
# BOTH presets. It SigV4-signs AgentCore InvokeAgentRuntime with A2A
# message/stream so the ADE turn streams token-by-token, and enforces
# Cognito/OIDC JWT auth + the Requirement-11 runtime allow-list in-service
# (parity with the invoke-proxy Lambda it replaces for the ADE chat).
#
# Ingress (var.public_edge):
#   * true  (demo)       — internal ALB behind a CloudFront VPC origin, locked to the demo console
#     CloudFront (origin-facing prefix list + secret origin header). The console
#     module adds an /ade-api/* behavior pointing at this ALB's DNS.
#   * false (enterprise) — INTERNAL ALB (VPC-only); the BYO UI reaches it over
#     the private network. No public edge.

locals {
  name_prefix = "eap-ade-${var.environment}"
  tags = merge(var.tags, {
    "eap:component" = "ade-invoke-backend"
    "eap:managed"   = "true"
  })

  # Origin secret is only meaningful for the public (CloudFront-fronted) edge.
  # Generate one when public_edge and no value supplied; empty otherwise.
  need_origin_secret = var.public_edge
  origin_secret_value = var.public_edge ? (
    var.cloudfront_origin_secret_value != "" ? var.cloudfront_origin_secret_value : random_password.origin_secret[0].result
  ) : ""
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# Only used by the public edge. CloudFront's origin-facing managed prefix list.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.public_edge ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_password" "origin_secret" {
  count   = local.need_origin_secret && var.cloudfront_origin_secret_value == "" ? 1 : 0
  length  = 40
  special = false
}

# ---------------------------------------------------------------------------
# ECR repository + image build/push
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

# Build + push the backend image on any source change (local Docker daemon —
# same pattern as examples-console). NOTE (ADR-040 / same-tag caveat): the ECS
# service must be force-redeployed to pick up a new :latest with an unchanged
# task definition. The root wires a redeploy trigger; see main.tf.
#
# The image is rebuilt only when the backend SOURCE changes (source hash), not
# on every apply — so an unrelated `terraform apply` is a no-op here. `src`,
# server.ts, the Dockerfile, and the package/tsconfig files are all hashed;
# node_modules is excluded (rebuilt from the lockfile inside the image).
locals {
  ade_backend_src = "${path.module}/../../ade-invoke-backend"
  # Hash the backend sources that go into the image. Top-level files (Dockerfile,
  # server.ts, package/tsconfig, run.sh) + everything under src/. node_modules is
  # deliberately NOT globbed (it's rebuilt from the lockfile inside the image, and
  # walking ~4k files on every plan would be needlessly slow).
  ade_backend_files = sort(setunion(
    fileset(local.ade_backend_src, "*"),
    fileset(local.ade_backend_src, "src/**"),
  ))
  ade_backend_source_hash = sha1(join("", [
    for f in local.ade_backend_files : filesha256("${local.ade_backend_src}/${f}")
  ]))
}

resource "null_resource" "backend_image" {
  triggers = {
    source_hash = local.ade_backend_source_hash
  }

  provisioner "local-exec" {
    working_dir = local.ade_backend_src
    # Isolate Docker's config into a throwaway dir and embed the ECR auth
    # directly (see command) so `docker login`'s keychain save path — which
    # races with -25299 when parallel builds hit the same registry — is never
    # invoked. Self-contained: no dependency on any pre-existing ~/.docker.
    environment = {
      # abspath() so the throwaway config lands next to THIS module — not
      # relative to working_dir (the backend source dir), which previously
      # created a stray nested `.docker-*` dir inside the source tree.
      DOCKER_CONFIG = "${abspath(path.module)}/.docker-ade"
    }
    command = <<-EOT
      set -euo pipefail
      mkdir -p "$DOCKER_CONFIG"
      REGISTRY="${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
      REPO="${aws_ecr_repository.backend.repository_url}"
      echo "=== Building ade-invoke-backend image ==="
      # Write the ECR auth straight into the throwaway config.json instead of
      # `docker login`. `docker login` invokes the OS credential helper to SAVE
      # the token, which on macOS races the keychain when several backend
      # builds run in parallel against the SAME registry (-25299 "item already
      # exists"). Embedding the auth here touches no credential store at all, so
      # parallel builds can never collide.
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
  name              = "/eap/ade-invoke-backend/${var.environment}"
  retention_in_days = var.log_group_retention_days
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# IAM — execution role (pull image, write logs) + task role (sign/invoke/read)
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

# Task permissions: invoke AgentCore runtimes (the agent runs as THIS role,
# never the caller), and Scan the lifecycle table to build the Requirement-11
# allow-list. Least-privilege: DynamoDB scoped to the single lifecycle table
# (+ its indexes), AgentCore scoped to runtimes in this region/account.
data "aws_iam_policy_document" "task" {
  statement {
    sid       = "InvokeAgentCore"
    effect    = "Allow"
    actions   = ["bedrock-agentcore:InvokeAgentRuntime"]
    resources = ["arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:runtime/*"]
  }

  statement {
    sid     = "LifecycleAllowListRead"
    effect  = "Allow"
    actions = ["dynamodb:Scan"]
    resources = [
      var.lifecycle_table_arn,
      "${var.lifecycle_table_arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "ade-invoke-backend"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ---------------------------------------------------------------------------
# Security groups — ALB + backend
# ---------------------------------------------------------------------------
# ALB ingress differs by edge posture:
#   * public_edge  — 80 from the CloudFront origin-facing prefix list only.
#   * internal     — the backend port from within the VPC CIDR (BYO UI / VPN).
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = var.public_edge ? "ADE ALB - ingress only from the CloudFront origin-facing prefix list (ADR-040 demo edge)." : "ADE internal ALB - ingress only from within the VPC (ADR-040 enterprise edge)."
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.public_edge ? [1] : []
    content {
      description     = "HTTP from CloudFront edge only"
      from_port       = 80
      to_port         = 80
      protocol        = "tcp"
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
    }
  }

  dynamic "ingress" {
    for_each = var.public_edge ? [] : [1]
    content {
      description = "HTTP from within the VPC (internal BYO-UI path)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [data.aws_vpc.this.cidr_block]
    }
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
  description = "ADE backend Fargate - ingress only from the ALB."
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
# ALB — always internal; the demo adds a CloudFront VPC origin
# ---------------------------------------------------------------------------
resource "aws_lb" "backend" {
  enable_deletion_protection = var.alb_deletion_protection
  name                       = substr("${local.name_prefix}-alb", 0, 32)
  # Always internal (private subnets). In the demo, CloudFront reaches it
  # through a VPC origin, so the ALB has no public address.
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  # /ade-api/invoke streams SSE; the backend heartbeats every 10s. Raise the
  # idle timeout well above that so a slow tool-heavy turn is never severed
  # mid-stream (default is 60s).
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

# Public edge: default 403 unless the CloudFront secret header is present
# (defense in depth on top of the prefix-list SG). Internal edge: forward
# directly (the VPC-only SG is the boundary).
resource "aws_lb_listener" "backend" {
  #checkov:skip=CKV_AWS_2:Internal ALB in private subnets. Demo: reached only by CloudFront through a VPC origin (AWS network); enterprise: VPC-only. Add an HTTPS listener with an ACM certificate for production.
  load_balancer_arn = aws_lb.backend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    # Internal edge forwards; public edge defaults to 403 and forwards only via
    # the secret-header rule below.
    type             = var.public_edge ? "fixed-response" : "forward"
    target_group_arn = var.public_edge ? null : aws_lb_target_group.backend.arn

    dynamic "fixed_response" {
      for_each = var.public_edge ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }
}

resource "aws_lb_listener_rule" "cloudfront_only" {
  count        = var.public_edge ? 1 : 0
  listener_arn = aws_lb_listener.backend.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    http_header {
      http_header_name = var.cloudfront_origin_secret_header
      values           = [local.origin_secret_value]
    }
  }
}

# ---------------------------------------------------------------------------
# ECS Fargate — cluster + task + service (always-on; desired_count >= 1)
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
        # Auth (ADR-028): platform Cognito pool id OR external OIDC issuer.
        { name = "COGNITO_USER_POOL_ID", value = var.cognito_user_pool_id },
        { name = "OIDC_ISSUER", value = var.oidc_issuer },
        # Requirement-11 allow-list source (single source of truth).
        { name = "LIFECYCLE_TABLE", value = var.lifecycle_table_name },
        # Default ADE target when the caller sends no runtimeArn.
        { name = "ADE_RUNTIME_ARN", value = var.ade_runtime_arn },
        { name = "ADE_ENDPOINT_QUALIFIER", value = var.ade_endpoint_qualifier },
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

  # Same-tag :latest pushes need a rolled deployment to take effect. Trigger a
  # new deployment whenever the image build re-runs (its id changes each apply).
  force_new_deployment = true
  triggers = {
    image_build = null_resource.backend_image.id
  }

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
# CloudFront VPC origin (demo / public_edge only). CloudFront connects to the
# internal ALB over the AWS network through service-managed ENIs in the VPC.
# The ALB security group still admits only the CloudFront origin-facing prefix
# list, and the listener still requires the secret origin header.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_vpc_origin" "alb" {
  count = var.public_edge ? 1 : 0

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
