# Gateway Pipeline Module
# Source → Deploy → Verify
# No Docker build — just reads YAML sources and runs TF plan/apply.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix = "${var.domain}-${var.name}"

  # CodePipeline name aligned to the source repo/folder: <repo>-deploy-pipeline
  # (e.g. mcp-integrations -> mcp-integrations-deploy-pipeline).
  # Other resources (artifact bucket, IAM roles, CodeBuild) keep local.prefix.
  pipeline_name = "${var.repository_name}-deploy-pipeline"

  # ADR-033: create each service role only when no pre-created ARN is supplied.
  create_codebuild_role = var.codebuild_role_arn == ""
  create_pipeline_role  = var.codepipeline_role_arn == ""
  codebuild_role_arn    = local.create_codebuild_role ? aws_iam_role.codebuild[0].arn : var.codebuild_role_arn
  codepipeline_role_arn = local.create_pipeline_role ? aws_iam_role.pipeline[0].arn : var.codepipeline_role_arn
}

# ---------------------------------------------------------------------------
# S3 Artifacts Bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  # Account-scoped (S3 names are globally unique) — avoids BucketAlreadyExists.
  bucket        = "${local.prefix}-deploy-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

# Upload gateway-deploy template to S3 for CodeBuild to consume
resource "aws_s3_object" "gateway_deploy_template" {
  for_each = fileset("${path.module}/../../deploy-templates/gateway-deploy", "**/*")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/gateway-deploy-template/${each.value}"
  source = "${path.module}/../../deploy-templates/gateway-deploy/${each.value}"
  etag   = filemd5("${path.module}/../../deploy-templates/gateway-deploy/${each.value}")
}

# Upload the gateway module to S3 so the deploy-template can reference it
resource "aws_s3_object" "gateway_module" {
  for_each = fileset("${path.module}/../../modules/gateway", "**/*")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/gateway-deploy-template/modules/gateway/${each.value}"
  source = "${path.module}/../../modules/gateway/${each.value}"
  etag   = filemd5("${path.module}/../../modules/gateway/${each.value}")
}

# ---------------------------------------------------------------------------
# IAM Role — CodeBuild
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
  tags               = var.tags
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.create_codebuild_role ? 1 : 0

  name = "${local.prefix}-codebuild-policy"
  role = aws_iam_role.codebuild[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Sid      = "ReadPlatformState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.platform_state_bucket}", "arn:aws:s3:::${var.platform_state_bucket}/*"]
      },
      {
        # CodeBuild build logs for this project only.
        Sid    = "CodeBuildLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.prefix}-deploy",
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.prefix}-deploy:log-stream:*",
        ]
      },
      {
        # gateway-deploy only manages aws_bedrockagentcore_gateway_target on the
        # platform-owned gateway. Create/Update also authorize SynchronizeGatewayTargets.
        Sid    = "AgentCoreGatewayTargets"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateGatewayTarget",
          "bedrock-agentcore:GetGatewayTarget",
          "bedrock-agentcore:UpdateGatewayTarget",
          "bedrock-agentcore:DeleteGatewayTarget",
          "bedrock-agentcore:ListGatewayTargets",
          "bedrock-agentcore:SynchronizeGatewayTargets",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:gateway/*"]
      },
      # No IAM statement: gateway-deploy creates no IAM roles and passes none
      # (the gateway and its role are owned by eap-platform).
      # No Lambda statement: gateway-deploy defines no Lambda targets, and the
      # gateway invokes Lambda targets with its own role, not this one.
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = ["*"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CodeBuild — Deploy (TF plan + apply)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "deploy" {
  name           = "${local.prefix}-deploy"
  description    = "Deploy gateway — reads sources/*.yaml with yamldecode()"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS-managed CodeBuild image (ships aws-cli v2 + python3 + git). Replaces the
    # custom eap-terraform:1.5 ECR image so the pipeline needs no bootstrapped
    # build image and no ECR-pull permission. Terraform is installed at build time by
    # the gateway-deploy buildspec (curl the pinned version).
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = false
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = aws_s3_bucket.artifacts.id
    }
    environment_variable {
      name  = "TF_VAR_aws_region"
      value = data.aws_region.current.name
    }
    environment_variable {
      name  = "TF_VAR_domain"
      value = var.domain
    }
    environment_variable {
      name  = "TF_VAR_environment"
      value = var.environment
    }
    environment_variable {
      name  = "TF_VAR_platform_state_bucket"
      value = var.platform_state_bucket
    }
    # Without this the gateway-deploy template's terraform_remote_state.platform
    # falls back to key "terraform.tfstate" and fails to find gateway_id, since
    # the platform state actually lives at "platform/terraform.tfstate".
    environment_variable {
      name  = "TF_VAR_platform_state_key"
      value = var.platform_state_key
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/../../deploy-templates/gateway-deploy/buildspecs/deploy.yaml")
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# IAM Role — CodePipeline
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
  tags               = var.tags
}

resource "aws_iam_role_policy" "pipeline" {
  count = local.create_pipeline_role ? 1 : 0

  name = "${local.prefix}-pipeline-policy"
  role = aws_iam_role.pipeline[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codecommit:GetBranch", "codecommit:GetCommit", "codecommit:UploadArchive", "codecommit:GetUploadArchiveStatus", "codecommit:CancelUploadArchive"]
        Resource = ["arn:aws:codecommit:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.repository_name}"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [aws_codebuild_project.deploy.arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CodePipeline — Source → Deploy
# ---------------------------------------------------------------------------
resource "aws_codepipeline" "this" {
  name     = local.pipeline_name
  role_arn = local.codepipeline_role_arn

  artifact_store {
    location = aws_s3_bucket.artifacts.id
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
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        RepositoryName = var.repository_name
        BranchName     = var.branch
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }

  tags = var.tags
}
