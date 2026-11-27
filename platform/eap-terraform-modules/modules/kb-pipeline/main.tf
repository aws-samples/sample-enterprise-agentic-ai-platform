# KB Pipeline Module
# Source → Validate → Plan → Apply
# Follows qa-pipeline pattern. Provisions Bedrock Knowledge Bases via Terraform.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix = var.name

  # ADR-033: create each service role only when no pre-created ARN is supplied.
  create_codebuild_role = var.codebuild_role_arn == ""
  create_pipeline_role  = var.codepipeline_role_arn == ""
  codebuild_role_arn    = local.create_codebuild_role ? aws_iam_role.codebuild[0].arn : var.codebuild_role_arn
  codepipeline_role_arn = local.create_pipeline_role ? aws_iam_role.pipeline[0].arn : var.codepipeline_role_arn
}

# ---------------------------------------------------------------------------
# CodeCommit Repository
# ---------------------------------------------------------------------------
resource "aws_codecommit_repository" "this" {
  repository_name = var.repository_name
  description     = "Knowledge Base repo for ${var.domain} — KB configurations, data source declarations"
  tags            = var.tags
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

# Upload kb-deploy template to S3 for CodeBuild to consume
resource "aws_s3_object" "kb_deploy_template" {
  for_each = fileset("${path.module}/../../deploy-templates/kb-deploy", "**/*")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/kb-deploy-template/${each.value}"
  source = "${path.module}/../../deploy-templates/kb-deploy/${each.value}"
  etag   = filemd5("${path.module}/../../deploy-templates/kb-deploy/${each.value}")
}

# Upload buildspecs to S3
resource "aws_s3_object" "buildspecs" {
  for_each = fileset("${path.module}/buildspecs", "*.yaml")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/buildspecs/${each.value}"
  source = "${path.module}/buildspecs/${each.value}"
  etag   = filemd5("${path.module}/buildspecs/${each.value}")
}

# ---------------------------------------------------------------------------
# Upload validation scripts to S3
# These are referenced from CodeBuild buildspecs during pipeline execution.
# ---------------------------------------------------------------------------
resource "aws_s3_object" "validate_kb_repo" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_kb_repo.py"
  source = "${path.module}/../pipeline/scripts/validate_kb_repo.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_kb_repo.py")
}

resource "aws_s3_object" "validate_kb_yaml" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_kb_yaml.py"
  source = "${path.module}/../pipeline/scripts/validate_kb_yaml.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_kb_yaml.py")
}

resource "aws_s3_object" "validate_data_sources_yaml" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_data_sources_yaml.py"
  source = "${path.module}/../pipeline/scripts/validate_data_sources_yaml.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_data_sources_yaml.py")
}

resource "aws_s3_object" "validate_sync_schedule" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_sync_schedule.py"
  source = "${path.module}/../pipeline/scripts/validate_sync_schedule.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_sync_schedule.py")
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
        Sid      = "ArtifactsBucket"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Sid      = "PlatformStateBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${var.platform_state_bucket}", "arn:aws:s3:::${var.platform_state_bucket}/*"]
      },
      {
        Sid      = "DatasourceBuckets"
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration", "s3:GetBucketLocation", "s3:ListBucket", "s3:PutObject", "s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.domain}-*-datasource-${data.aws_caller_identity.current.account_id}", "arn:aws:s3:::${var.domain}-*-datasource-${data.aws_caller_identity.current.account_id}/*"]
      },
      # bedrock:CreateKnowledgeBase has no resource type; the API requires Resource "*".
      {
        Sid      = "BedrockKnowledgeBaseCreateRequiresWildcard"
        Effect   = "Allow"
        Action   = ["bedrock:CreateKnowledgeBase"]
        Resource = ["*"]
      },
      {
        Sid    = "BedrockKnowledgeBases"
        Effect = "Allow"
        Action = [
          "bedrock:GetKnowledgeBase",
          "bedrock:UpdateKnowledgeBase",
          "bedrock:DeleteKnowledgeBase",
          "bedrock:CreateDataSource",
          "bedrock:GetDataSource",
          "bedrock:UpdateDataSource",
          "bedrock:DeleteDataSource",
          "bedrock:ListDataSources",
          "bedrock:StartIngestionJob",
          "bedrock:TagResource",
          "bedrock:UntagResource",
          "bedrock:ListTagsForResource",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"]
      },
      {
        Sid    = "AgentCoreGatewayTargets"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreateGatewayTarget",
          "bedrock-agentcore:GetGatewayTarget",
          "bedrock-agentcore:UpdateGatewayTarget",
          "bedrock-agentcore:DeleteGatewayTarget",
          "bedrock-agentcore:SynchronizeGatewayTargets",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:gateway/*"]
      },
      {
        Sid    = "AgentCorePolicyEnginePolicies"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:CreatePolicy",
          "bedrock-agentcore:GetPolicy",
          "bedrock-agentcore:UpdatePolicy",
          "bedrock-agentcore:DeletePolicy",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:policy-engine/*",
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:policy-engine/*/policy/*",
        ]
      },
      {
        Sid      = "SecretsManagerRead"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = ["arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:eap-*"]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.prefix}-*",
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.prefix}-*:log-stream:*",
        ]
      },
      {
        Sid      = "ECRPull"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid      = "ECRImage"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = ["*"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM — Repository access boundary (genai-data-engineers)
# NOTE: aws_codecommit_repository_policy is not a valid AWS provider resource.
# Enforce access boundaries via IAM group/role policies instead.
# ---------------------------------------------------------------------------
# Placeholder: Enforce via IAM group policies attached to genai-data-engineers group.

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
        Resource = [aws_codecommit_repository.this.arn]
      },
      {
        Effect = "Allow"
        Action = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [
          aws_codebuild_project.validate.arn,
          aws_codebuild_project.plan.arn,
          aws_codebuild_project.apply.arn,
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CodeBuild — Validate (schema validation of KB repo content)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "validate" {
  name           = "${local.prefix}-validate"
  description    = "KB pipeline — validate KB configurations and data source schemas"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  # Managed CodeBuild image (aws CLI v2 + python3 + pip preinstalled). The
  # eap-terraform image ships terraform only — no aws/python — so the
  # python-based validator + `aws s3 cp` fail there. Validate needs no terraform.
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = false
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = aws_s3_bucket.artifacts.id
    }
    environment_variable {
      name  = "DOMAIN"
      value = var.domain
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/validate.yaml")
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# CodeBuild — Plan (terraform plan for KB resources)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "plan" {
  name           = "${local.prefix}-plan"
  description    = "KB pipeline — terraform plan for Knowledge Base provisioning"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  # Managed CodeBuild image (aws CLI v2 + python3 + pip). terraform is installed
  # at runtime in the buildspec install phase (the managed image has no terraform).
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
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
    environment_variable {
      name  = "GATEWAY_ID"
      value = var.gateway_id
    }
    environment_variable {
      name  = "POLICY_ENGINE_ID"
      value = var.policy_engine_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/plan.yaml")
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# CodeBuild — Apply (terraform apply + trigger initial sync)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "apply" {
  name           = "${local.prefix}-apply"
  description    = "KB pipeline — terraform apply + trigger initial data source sync"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  # Managed CodeBuild image (aws CLI v2 + python3 + pip). terraform is installed
  # at runtime in the buildspec install phase (the managed image has no terraform).
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
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
    environment_variable {
      name  = "GATEWAY_ID"
      value = var.gateway_id
    }
    environment_variable {
      name  = "POLICY_ENGINE_ID"
      value = var.policy_engine_id
    }
    environment_variable {
      name  = "DOMAIN"
      value = var.domain
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/apply.yaml")
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# CodePipeline V2 — Source → Validate → Plan → Apply
# ---------------------------------------------------------------------------
resource "aws_codepipeline" "this" {
  name          = "${local.prefix}-deploy"
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
    name = "Validate"
    action {
      name            = "Validate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      configuration = {
        ProjectName = aws_codebuild_project.validate.name
      }
    }
  }

  stage {
    name = "Plan"
    action {
      name            = "Plan"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  stage {
    name = "Apply"
    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      configuration = {
        ProjectName = aws_codebuild_project.apply.name
      }
    }
  }

  tags = var.tags
}
