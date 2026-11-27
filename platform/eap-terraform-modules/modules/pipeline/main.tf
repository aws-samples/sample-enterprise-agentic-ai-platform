# EAP Pipeline Module — Main
# Reusable CodePipeline: Source → Build (ARM64 Docker + ECR) → Deploy (runtime module) → Verify (A2A health)
# Platform_Admin instantiates one pipeline per domain.
# The pipeline discovers ALL use case directories (uc*/) in the repo automatically.
# The Deploy stage reads agent.yaml manifests and provisions AgentCore runtimes
# via the eap runtime module — app teams write YAML, platform owns all Terraform.
# Buildspecs are external YAML files loaded via file() — no heredocs.
# Requirements: R1.1, R1.2, R1.3, R1.10, R1.11, R20.12

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.id
  partition  = data.aws_partition.current.partition
  prefix     = "${var.domain}-${var.name}"

  # CodePipeline name is aligned to the source repo/folder: <repo>-deploy-pipeline
  # (e.g. team-bu-1 -> team-bu-1-deploy-pipeline). Other pipeline resources
  # (artifact bucket, IAM roles, CodeBuild projects) keep local.prefix.
  pipeline_name = "${var.repository_name}-deploy-pipeline"

  # SINGLE shared lifecycle table all vended pipelines write to. The platform
  # root injects var.lifecycle_table; the coalesce keeps backward compatibility
  # with the legacy per-domain name until every caller passes it.
  lifecycle_table = coalesce(var.lifecycle_table, "agent-school-lifecycle-${var.domain}-${var.environment}")

  tags = merge(var.tags, {
    "eap:domain"   = var.domain
    "eap:pipeline" = var.name
    "eap:managed"  = "true"
  })

  # ADR-033: create each service role only when no pre-created ARN is supplied.
  create_codebuild_role = var.codebuild_role_arn == ""
  create_pipeline_role  = var.codepipeline_role_arn == ""
  codebuild_role_arn    = local.create_codebuild_role ? aws_iam_role.codebuild[0].arn : var.codebuild_role_arn
  codepipeline_role_arn = local.create_pipeline_role ? aws_iam_role.pipeline[0].arn : var.codepipeline_role_arn
}

# ---------------------------------------------------------------------------
# Artifact Store
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  # Account-scoped: S3 bucket names are globally unique, so include the account
  # id to avoid BucketAlreadyExists collisions across accounts.
  bucket        = "${local.prefix}-pipeline-artifacts-${local.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM — CodePipeline service role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  count = local.create_pipeline_role ? 1 : 0

  name               = "${local.prefix}-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "pipeline_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.source_provider == "CodeStarSourceConnection" ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["codestar-connections:UseConnection"]
      resources = [var.codestar_connection_arn]
    }
  }

  dynamic "statement" {
    for_each = var.source_provider == "CodeCommit" ? [1] : []
    content {
      effect = "Allow"
      actions = [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:UploadArchive",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:CancelUploadArchive",
      ]
      resources = ["arn:aws:codecommit:${local.region}:${local.account_id}:${var.repository_name}"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]
    resources = [
      aws_codebuild_project.build.arn,
      aws_codebuild_project.deploy.arn,
      aws_codebuild_project.verify.arn,
      aws_codebuild_project.evaluate.arn,
      aws_codebuild_project.gate.arn,
    ]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  count = local.create_pipeline_role ? 1 : 0

  name   = "${local.prefix}-pipeline-policy"
  role   = aws_iam_role.pipeline[0].id
  policy = data.aws_iam_policy_document.pipeline_policy.json
}

# ---------------------------------------------------------------------------
# IAM — CodeBuild service role (shared by all stages)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  count = local.create_codebuild_role ? 1 : 0

  name               = "${local.prefix}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "codebuild_policy" {
  # CloudWatch Logs
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/${local.prefix}-*"]
  }

  # S3 artifacts
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # ECR — push/pull images
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${local.region}:${local.account_id}:repository/*"]
  }

  # Cognito — create/manage app clients and digital worker users
  statement {
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:AdminDeleteUserAttributes",
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:AdminRemoveUserFromGroup",
      "cognito-idp:AdminListGroupsForUser",
    ]
    resources = ["arn:aws:cognito-idp:${local.region}:${local.account_id}:userpool/${var.cognito_user_pool_id}"]
  }

  # IAM — create/manage agent runtime roles scoped to domain
  # Supports both hyphenated (team-bu-1-*) and underscored (team_bu_1_*) naming
  statement {
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.domain}-*",
      "arn:aws:iam::${local.account_id}:role/${replace(var.domain, "-", "_")}_*",
    ]
  }

  # IAM — service-linked role for Bedrock AgentCore
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }

  # Step Functions — manage the per-application orchestration state machines
  # (aws_sfn_state_machine in modules/orchestration). The deploy-template names
  # them "<domain_underscored>_<app>_orchestration"; the trailing * also covers
  # version/alias ARNs (stateMachine:<name>:<qualifier>).
  statement {
    sid    = "StepFunctionsStateMachines"
    effect = "Allow"
    actions = [
      "states:CreateStateMachine",
      "states:DescribeStateMachine",
      "states:UpdateStateMachine",
      "states:DeleteStateMachine",
      "states:ListStateMachineVersions",
      "states:TagResource",
      "states:UntagResource",
      "states:ListTagsForResource",
    ]
    resources = [
      "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${replace(var.domain, "-", "_")}_*",
    ]
  }

  # CloudWatch Logs — Step Functions + AgentCore log groups
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/states/*",
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/states/*:*",
    ]
  }

  # CloudWatch Logs — DescribeLogGroups is a list-level API requiring resource: *
  statement {
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  # Bedrock AgentCore — create actions have no resource type; the API requires Resource "*".
  statement {
    sid    = "AgentCoreCreateRequiresWildcard"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateAgentRuntime",
      "bedrock-agentcore:CreateMemory",
    ]
    resources = ["*"]
  }

  # Bedrock AgentCore — manage agent runtimes, runtime endpoints, memories and
  # memory strategies (modules/runtime + modules/memory). runtime/* also matches
  # endpoint ARNs (runtime/<id>/runtime-endpoint/<name>).
  statement {
    sid    = "AgentCoreRuntimesAndMemory"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:GetAgentRuntime",
      "bedrock-agentcore:UpdateAgentRuntime",
      "bedrock-agentcore:DeleteAgentRuntime",
      "bedrock-agentcore:CreateAgentRuntimeEndpoint",
      "bedrock-agentcore:GetAgentRuntimeEndpoint",
      "bedrock-agentcore:UpdateAgentRuntimeEndpoint",
      "bedrock-agentcore:DeleteAgentRuntimeEndpoint",
      "bedrock-agentcore:GetMemory",
      "bedrock-agentcore:UpdateMemory",
      "bedrock-agentcore:DeleteMemory",
      "bedrock-agentcore:TagResource",
      "bedrock-agentcore:UntagResource",
      "bedrock-agentcore:ListTagsForResource",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:runtime/*",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:memory/*",
    ]
  }

  # Bedrock AgentCore — CreateAgentRuntime/DeleteAgentRuntime also create/delete
  # the runtime's workload identity in the default directory.
  statement {
    sid    = "AgentCoreRuntimeWorkloadIdentity"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateWorkloadIdentity",
      "bedrock-agentcore:GetWorkloadIdentity",
      "bedrock-agentcore:DeleteWorkloadIdentity",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/*",
    ]
  }

  # Lambda — create/manage the invoke bridge function for SFN → AgentCore
  statement {
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:${local.region}:${local.account_id}:function:${var.domain}-*"]
  }

  # EC2 — required to create/manage the VPC-attached invoke-bridge Lambda in
  # VPC mode (ADR-032). Creating a Lambda with a vpc_config makes the Lambda
  # service (and the AWS provider) validate the target subnets/security groups,
  # which needs these read-only, list-level Describe APIs (resource "*"), plus
  # the ENI lifecycle actions Lambda uses to attach into the VPC. Harmless in
  # PUBLIC mode where the bridge has no vpc_config.
  # Describe* actions have no resource type, so the API requires "*".
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
    ]
    resources = ["*"]
  }
  statement {
    effect  = "Allow"
    actions = ["ec2:CreateNetworkInterface"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:subnet/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/*",
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["ec2:DeleteNetworkInterface"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*"]
  }

  # SSM — evaluations module stores eval config as SSM parameters
  statement {
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DeleteParameter",
      "ssm:GetParametersByPath",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = ["arn:aws:ssm:${local.region}:${local.account_id}:parameter/eap/${var.domain}/*"]
  }

  # SSM — DescribeParameters is a list-level API that requires resource: *
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # CloudWatch Events — evaluations module creates scheduled evaluation rules
  statement {
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTagsForResource",
      "events:TagResource",
      "events:UntagResource",
    ]
    resources = ["arn:aws:events:${local.region}:${local.account_id}:rule/eap-eval-*"]
  }

  # DynamoDB — lifecycle state store for Agent School
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.lifecycle_table}",
      "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.lifecycle_table}/index/*",
    ]
  }

  # CodeCommit source permissions
  dynamic "statement" {
    for_each = var.source_provider == "CodeCommit" ? [1] : []
    content {
      effect = "Allow"
      actions = [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:UploadArchive",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:CancelUploadArchive",
      ]
      resources = ["arn:aws:codecommit:${local.region}:${local.account_id}:${var.repository_name}"]
    }
  }

  # CodeStar connection
  dynamic "statement" {
    for_each = var.source_provider == "CodeStarSourceConnection" ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["codestar-connections:UseConnection"]
      resources = [var.codestar_connection_arn]
    }
  }
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.create_codebuild_role ? 1 : 0

  name   = "${local.prefix}-codebuild-policy"
  role   = aws_iam_role.codebuild[0].id
  policy = data.aws_iam_policy_document.codebuild_policy.json
}

# ---------------------------------------------------------------------------
# CodeBuild — Stage 1: Build (ARM64 Docker + ECR Push)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "build" {
  #checkov:skip=CKV_AWS_316:Privileged mode is required to run docker build for agent container images.
  name           = "${local.prefix}-build"
  description    = "Build ARM64 agent images and push to ECR"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    type                        = "ARM_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "BASE_IMAGE_ECR_URL"
      value = var.base_image_ecr_repo_url
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
    }

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/build.yaml")
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# S3 — Deploy template + runtime module uploaded for CodeBuild to consume
# The deploy-template uses native yamldecode() — no Python needed.
# ---------------------------------------------------------------------------
resource "aws_s3_object" "deploy_template" {
  for_each = fileset("${path.module}/deploy-template", "**/*.tf")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/deploy-template/${each.value}"
  source = "${path.module}/deploy-template/${each.value}"
  etag   = filemd5("${path.module}/deploy-template/${each.value}")
}

resource "aws_s3_object" "runtime_module" {
  for_each = fileset("${path.module}/../runtime", "*.tf")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/deploy-template/runtime/${each.value}"
  source = "${path.module}/../runtime/${each.value}"
  etag   = filemd5("${path.module}/../runtime/${each.value}")
}

resource "aws_s3_object" "memory_module" {
  for_each = fileset("${path.module}/../memory", "*.tf")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/deploy-template/memory/${each.value}"
  source = "${path.module}/../memory/${each.value}"
  etag   = filemd5("${path.module}/../memory/${each.value}")
}

resource "aws_s3_object" "evaluations_module" {
  for_each = fileset("${path.module}/../evaluations", "*.tf")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/deploy-template/evaluations/${each.value}"
  source = "${path.module}/../evaluations/${each.value}"
  etag   = filemd5("${path.module}/../evaluations/${each.value}")
}

resource "aws_s3_object" "orchestration_module" {
  for_each = fileset("${path.module}/../orchestration", "**/*")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/orchestration/${each.value}"
  source = "${path.module}/../orchestration/${each.value}"
  etag   = filemd5("${path.module}/../orchestration/${each.value}")
}

# ---------------------------------------------------------------------------
# S3 — Pipeline scripts (Evaluate/Gate consume these at runtime)
# The Evaluate and Gate buildspecs call python3 scripts/*.py, but the platform
# scripts do not travel in the app source artifact. Upload the whole scripts/
# directory (all .py so cross-imports like semver_utils / lifecycle_state
# resolve) to S3; the buildspecs `aws s3 cp` them into ./scripts before use.
# ---------------------------------------------------------------------------
resource "aws_s3_object" "pipeline_scripts" {
  for_each = fileset("${path.module}/scripts", "*.py")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/${each.value}"
  source = "${path.module}/scripts/${each.value}"
  etag   = filemd5("${path.module}/scripts/${each.value}")
}

# ---------------------------------------------------------------------------
# CodeBuild — Stage 2: Deploy (native yamldecode from agent.yaml + apply)
# Downloads platform-owned deploy-template from S3, copies agent YAML from
# build artifacts, runs terraform init/plan/apply. Pure Terraform, no Python.
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "deploy" {
  name           = "${local.prefix}-deploy"
  description    = "Deploy agents via runtime module — reads agent.yaml with yamldecode()"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS-managed CodeBuild image (ships aws-cli, python3, git, jq). Terraform is
    # installed at build time by the deploy buildspec (curl the pinned version).
    # Replaces the custom eap-terraform:1.5 ECR image so Deploy needs no
    # bootstrapped build image and no ECR-pull permission on the CodeBuild role.
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }

    environment_variable {
      name  = "TF_VAR_domain"
      value = var.domain
    }

    environment_variable {
      name  = "TF_VAR_ecr_repo_url"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "TF_VAR_cognito_user_pool_id"
      value = var.cognito_user_pool_id
    }

    environment_variable {
      name  = "TF_VAR_cognito_token_endpoint"
      value = var.cognito_token_endpoint
    }

    environment_variable {
      name  = "TF_VAR_cognito_a2a_scope"
      value = var.cognito_a2a_scope
    }

    environment_variable {
      name  = "TF_VAR_model_id"
      value = var.model_id
    }

    # Single shared lifecycle table + BU discriminator — the Deploy stage
    # records deployed-agent facts (runtime ARN, topology, entrypoint) here so
    # the console's "My Deployed Agents" view stays authoritative for every BU.
    environment_variable {
      name  = "LIFECYCLE_TABLE"
      value = local.lifecycle_table
    }

    environment_variable {
      name  = "BU"
      value = var.domain
    }

    # Agent network posture (ADR-031) — the platform root resolves the posture
    # and passes it down; the deploy-template puts every pipeline-deployed agent
    # runtime in the enterprise VPC when mode = VPC. List vars are passed as JSON
    # strings (Terraform accepts TF_VAR_x='["a","b"]' for list(string)).
    environment_variable {
      name  = "TF_VAR_agent_network_mode"
      value = var.agent_network_mode
    }

    environment_variable {
      name  = "TF_VAR_agent_subnet_ids"
      value = jsonencode(var.agent_subnet_ids)
    }

    environment_variable {
      name  = "TF_VAR_agent_security_group_ids"
      value = jsonencode(var.agent_security_group_ids)
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/deploy.yaml")
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CodeBuild — Stage 3: Verify (A2A health check)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "verify" {
  name           = "${local.prefix}-verify"
  description    = "Verify A2A endpoints respond after deployment"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "PROTOCOLS"
      value = join(",", var.agent_protocols)
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/verify.yaml")
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CodeBuild — Stage 4: Evaluate (AgentCore Evaluations + Red-Team)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "evaluate" {
  name           = "${local.prefix}-evaluate"
  description    = "Run AgentCore evaluations and optional red-team suite"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }

    environment_variable {
      name  = "DOMAIN"
      value = var.domain
    }

    environment_variable {
      name  = "RED_TEAM_REQUIRED"
      value = contains(["qa", "prod"], var.environment) ? "true" : "false"
    }

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }

    environment_variable {
      name  = "RED_TEAM_BUCKET"
      value = var.red_team_bucket
    }

    environment_variable {
      name  = "TEST_CASES_BUCKET"
      value = var.test_cases_bucket
    }

    environment_variable {
      name  = "LIFECYCLE_TABLE"
      value = local.lifecycle_table
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/evaluate.yaml")
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CodeBuild — Stage 5: Gate (Graduation Policy Check)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "gate" {
  name           = "${local.prefix}-gate"
  description    = "Compare evaluation scores against graduation policy thresholds"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "GOVERNANCE_BUCKET"
      value = var.governance_bucket
    }

    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }

    environment_variable {
      name  = "DOMAIN"
      value = var.domain
    }

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }

    environment_variable {
      name  = "REPORTS_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }

    environment_variable {
      name  = "LIFECYCLE_TABLE"
      value = local.lifecycle_table
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/gate.yaml")
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CodePipeline — V2: Source → Build → Deploy → Verify → Evaluate → Gate
# ---------------------------------------------------------------------------
resource "aws_codepipeline" "agent_deploy" {
  name          = local.pipeline_name
  role_arn      = local.codepipeline_role_arn
  pipeline_type = "V2"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
    encryption_key {
      id   = aws_kms_key.artifacts.arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = var.source_provider
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = var.source_provider == "CodeCommit" ? {
        RepositoryName = var.repository_name
        BranchName     = var.branch
        } : {
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = var.repository_name
        BranchName       = var.branch
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "DockerBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  # ADR-048: human review of the change before anything is deployed. Needed
  # where commits are model-generated (the ADE's nocode-user pipeline): the
  # Evaluate/Gate stages run only after Deploy, so they cannot stop a bad
  # change from running.
  dynamic "stage" {
    for_each = var.require_manual_approval ? [1] : []
    content {
      name = "Approve"

      action {
        name     = "ReviewChange"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"

        configuration = {
          CustomData = "Review the commit in ${var.repository_name} before it is deployed. Changes in this repository may be generated by the Agent Deployment Engineer."
        }
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "TerraformDeploy"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["build_output"]
      output_artifacts = ["deploy_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }

  stage {
    name = "Verify"

    action {
      name            = "A2AHealthCheck"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["deploy_output"]

      configuration = {
        ProjectName = aws_codebuild_project.verify.name
      }
    }
  }

  stage {
    name = "Evaluate"

    action {
      name             = "AgentEvaluations"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["deploy_output"]
      output_artifacts = ["evaluate_output"]

      configuration = {
        ProjectName = aws_codebuild_project.evaluate.name
      }
    }
  }

  stage {
    name = "Gate"

    action {
      name            = "GraduationGate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["evaluate_output"]

      configuration = {
        ProjectName = aws_codebuild_project.gate.name
      }
    }
  }

  dynamic "trigger" {
    for_each = var.source_provider == "CodeStarSourceConnection" ? [1] : []
    content {
      provider_type = "CodeStarSourceConnection"

      git_configuration {
        source_action_name = "Source"

        push {
          branches {
            includes = [var.branch]
          }
          file_paths {
            includes = ["uc*/**"]
          }
        }
      }
    }
  }

  tags = local.tags
}
