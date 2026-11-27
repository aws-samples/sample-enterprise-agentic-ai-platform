# =============================================================================
# Agent Deployment Engineer — Platform-owned deployment
#
# The Agent Deployment Engineer is a platform capability (like the console +
# invoke-proxy), available by default on every platform apply. This module:
#   1. Builds + pushes the agent container image from studio/app/ at apply
#      time (null_resource.studio_image_build → build-and-push.sh), so the
#      deployed image is reproducible from the codebase and rebuilt whenever
#      the source changes. No CI/CD pipeline required.
#   2. Provisions an IAM execution role, AgentCore Memory, and the runtime via
#      the shared runtime module.
#   3. Exposes the runtime ARN + endpoint qualifier so the invoke-proxy can
#      target the agent directly (no stale hardcoded ARN, no runtime lookup).
#
# Customizing: edit studio/app/ and re-apply — the image rebuilds
# automatically (source is hashed). Set var.build_image = false to skip the
# build and reuse the existing ECR tag.
#
# Deploy host requirements: AWS CLI + a container builder (Docker/Lima).
# =============================================================================

data "aws_partition" "current" {}

locals {
  runtime_name   = replace("${var.domain}_${var.agent_base_name}", "-", "_")
  studio_tag_uri = "${var.ecr_repository_url}:${var.image_tag}"
  app_dir        = "${path.module}/app"

  # Deploy target the ADE writes to. ADE runs under var.domain (team-bu-1) but
  # DEPLOYS user-built agents into the dedicated nocode-user repo/pipeline, so
  # Studio-generated agents stay isolated from developer-managed ones. These
  # match the pipeline_trigger / pipeline_status tool defaults and the pipeline
  # provisioned by the platform (nocode-user-deploy-pipeline — named after the
  # source repo per the <repo>-deploy-pipeline convention).
  deploy_repo     = "nocode-user"
  deploy_domain   = "nocode-user"
  deploy_pipeline = "nocode-user-deploy-pipeline"

  # Hash every file under app/ so the image is rebuilt whenever the Studio
  # source changes. This makes the deployed image reproducible from the
  # codebase rather than a manually-pushed ECR tag.
  app_source_hash = sha1(join("", [
    for f in sort(fileset(local.app_dir, "**")) :
    filesha1("${local.app_dir}/${f}")
  ]))
}

# ---------------------------------------------------------------------------
# Studio Image Build — build + push the Studio container at apply time
#
# Studio is platform-owned and has no CI/CD pipeline, so the platform apply is
# responsible for producing its image. This runs build-and-push.sh, which logs
# in to ECR, builds studio/app/ on top of the base image, and pushes the
# result to `${ecr_repository_url}:${image_tag}`.
#
# Requires a working container builder (Docker/Lima) + AWS creds on the deploy
# host. Set var.build_image = false to skip (e.g. when the tag already exists
# and you want a faster apply).
# ---------------------------------------------------------------------------
resource "null_resource" "studio_image_build" {
  count = var.build_image ? 1 : 0

  triggers = {
    app_source_hash = local.app_source_hash
    image_uri       = local.studio_tag_uri
  }

  provisioner "local-exec" {
    command     = "./build-and-push.sh ${var.image_tag}"
    working_dir = path.module
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_REGION = var.aws_region
    }
  }
}

# ---------------------------------------------------------------------------
# Resolve the mutable tag to an immutable digest AFTER the build/push, so the
# runtime is pinned to repo@sha256:... A rebuild+push (same tag, new digest)
# then produces a Terraform diff and rolls the runtime onto the new image.
# Without this, AgentCore pins the digest at create time and an unchanged tag
# string means Terraform never triggers an update.
# ---------------------------------------------------------------------------
data "aws_ecr_image" "studio" {
  repository_name = var.ecr_repository_name
  image_tag       = var.image_tag

  depends_on = [null_resource.studio_image_build]
}

locals {
  studio_image_uri = "${var.ecr_repository_url}@${data.aws_ecr_image.studio.image_digest}"
}

# ---------------------------------------------------------------------------
# IAM Execution Role — AgentCore Runtime
# AWS-documented least-privilege execution role for AgentCore Runtime.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "runtime_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

# ADR-033: create the role + policy only when no pre-created ARN is supplied.
locals {
  create_runtime_role = var.runtime_role_arn == ""
  runtime_role_arn    = local.create_runtime_role ? aws_iam_role.studio_runtime[0].arn : var.runtime_role_arn
}

resource "aws_iam_role" "studio_runtime" {
  count = local.create_runtime_role ? 1 : 0

  name               = "studio-runtime-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "studio_runtime" {
  count = local.create_runtime_role ? 1 : 0

  name = "studio-runtime-policy"
  role = aws_iam_role.studio_runtime[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRImageAccess"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = ["arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${var.account_id}:repository/*"]
      },
      {
        Sid      = "ECRTokenAccess"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "LogsCreateGroup"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
        Resource = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"]
      },
      {
        Sid      = "LogsDescribeGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.account_id}:log-group:*"]
      },
      {
        Sid      = "LogsWriteEvents"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = ["*"]
      },
      {
        Sid       = "CloudWatchMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" } }
      },
      {
        Sid    = "WorkloadIdentityTokens"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.aws_region}:${var.account_id}:workload-identity-directory/default",
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.aws_region}:${var.account_id}:workload-identity-directory/default/workload-identity/*"
        ]
      },
      {
        Sid    = "BedrockModelInvocation"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
          "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}:${var.account_id}:*"
        ]
      },
      {
        # Data-plane calls made by the Strands AgentCoreMemorySessionManager
        # (app/main.py), scoped to the Studio's own memory (module.memory).
        Sid    = "AgentCoreMemory"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:DeleteEvent",
          "bedrock-agentcore:RetrieveMemoryRecords"
        ]
        Resource = [module.memory.arn]
      },
      {
        # pipeline_trigger commits the generated agent files to the nocode-user
        # CodeCommit repo; the deploy pipeline auto-triggers on push. Scoped to
        # the single deploy repo (least privilege).
        Sid    = "StudioDeployCodeCommit"
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetFolder",
          "codecommit:GetFile",
          "codecommit:GetRepository",
          "codecommit:CreateCommit"
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:codecommit:${var.aws_region}:${var.account_id}:${local.deploy_repo}"]
      },
      {
        # pipeline_trigger / pipeline_status read the deploy pipeline's
        # executions to return the execution id and surface status.
        Sid    = "StudioDeployPipelineRead"
        Effect = "Allow"
        Action = [
          "codepipeline:ListPipelineExecutions",
          "codepipeline:GetPipelineExecution"
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:codepipeline:${var.aws_region}:${var.account_id}:${local.deploy_pipeline}"]
      },
      {
        # pipeline_trigger resolves the deployed agent's runtime ARN from the
        # AgentCore control plane after the pipeline succeeds.
        Sid      = "StudioResolveRuntimes"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:ListAgentRuntimes"]
        Resource = ["*"]
      },
      {
        # Third-party observability leg (agentcore-observability, task 15.2):
        # the base image resolves the OTel_Collector endpoint from this single
        # SSM parameter at boot. Scoped to EXACTLY that parameter ARN — no
        # wildcard. Additive third-party leg only; grants no CloudWatch/X-Ray
        # write and cannot affect the AWS-native leg.
        Sid      = "OtelCollectorEndpointSsmRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${var.account_id}:parameter/eap/observability/collector-endpoint"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Studio Memory — long-term (matches agent.yaml: type long-term, 90d)
# ---------------------------------------------------------------------------
module "memory" {
  source = "../../eap-terraform-modules/modules/memory"

  name        = replace("${local.runtime_name}_memory", "-", "_")
  domain      = var.domain
  description = "Long-term memory for Agent Deployment Engineer design sessions"
  memory_type = "long-term"
  retention   = "90d"
  tags        = var.tags
}

# ---------------------------------------------------------------------------
# Studio Runtime — references the prebuilt image in ECR
# ---------------------------------------------------------------------------
module "runtime" {
  source = "../../eap-terraform-modules/modules/runtime"

  # Ensure the image is built + pushed before the runtime references it.
  depends_on = [null_resource.studio_image_build]

  name            = local.runtime_name
  domain          = var.domain
  description     = "Agent Deployment Engineer — conversational no-code agent builder"
  framework       = "strands"
  protocols       = ["a2a"]
  role_arn        = local.runtime_role_arn
  model_id        = var.model_id
  container_image = local.studio_image_uri

  # Auth disabled — per-agent Cognito auth is not enabled, consistent
  # with the agent deploy-template.
  enable_auth = false

  # Network posture (ADR-031). VPC-mode by default when the platform resolves a
  # VPC; vpc_config carries the private subnets + agent SG. PUBLIC + null when
  # no VPC is available (matches the pre-ADR-031 behavior).
  network_mode = var.network_mode
  vpc_config   = var.vpc_config

  # Deploy target env for the pipeline_trigger / pipeline_status tools. These
  # match the tool defaults but are set explicitly so a future default change
  # can't silently point ADE at the wrong repo/pipeline. The memory ID is only
  # injected when the deployed image is known to handle it (var.enable_memory —
  # an image without the session_id/actor_id fix throws at invoke time,
  # JSON-RPC -32603).
  extra_environment_variables = merge(
    {
      STUDIO_TARGET_REPO   = local.deploy_repo
      STUDIO_PIPELINE_NAME = local.deploy_pipeline
      STUDIO_DEPLOY_DOMAIN = local.deploy_domain
      PLATFORM_GATEWAY_URL = var.platform_gateway_url
    },
    var.enable_memory ? { AGENTCORE_MEMORY_ID = module.memory.id } : {},
  )

  tags = var.tags
}
