# Governance Pipeline Module
# Source (CodeCommit) → Deploy (CodeBuild)
# Deploys Cedar policies from the governance repo via AWS CLI.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
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
  bucket        = "${var.name}-deploy-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

# Note: No deploy-template upload needed — buildspec uses AWS CLI directly.
# The buildspec is embedded inline in the CodeBuild project via `file()` below.

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

  name               = "${var.name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.create_codebuild_role ? 1 : 0

  name = "${var.name}-codebuild-policy"
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
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}-deploy",
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}-deploy:log-stream:*",
        ]
      },
      {
        # buildspec runs `aws bedrock-agentcore-control create-policy` / `update-policy`.
        Sid    = "AgentCoreCedarPolicies"
        Effect = "Allow"
        Action = ["bedrock-agentcore:CreatePolicy", "bedrock-agentcore:UpdatePolicy"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:policy-engine/*",
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:policy-engine/*/policy/*",
        ]
      },
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
# CodeBuild — Deploy (Cedar policies via AWS CLI)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "deploy" {
  name           = "${var.name}-deploy"
  description    = "Deploy governance — syncs red-team prompts and applies Cedar policies via AWS CLI"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS-managed CodeBuild image (ships aws-cli v2 + python3). Replaces the custom
    # eap-terraform:1.5 ECR image so the pipeline needs no bootstrapped build
    # image and no ECR-pull permission. Governance deploys Cedar via AWS CLI only —
    # no Terraform required.
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
      name  = "TF_VAR_platform_state_bucket"
      value = var.platform_state_bucket
    }
    environment_variable {
      name  = "POLICY_ENGINE_ID"
      value = var.policy_engine_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/../../deploy-templates/governance-deploy/buildspecs/deploy.yaml")
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

  name               = "${var.name}-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "pipeline" {
  count = local.create_pipeline_role ? 1 : 0

  name = "${var.name}-pipeline-policy"
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
  name          = "${var.name}-deploy"
  role_arn      = local.codepipeline_role_arn
  pipeline_type = "V2"

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
