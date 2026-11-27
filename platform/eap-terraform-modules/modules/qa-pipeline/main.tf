# QA Pipeline Module
# Source → Validate → Plan → Apply
# Follows governance-pipeline pattern. Provisions AgentCore Evaluators via Terraform.

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
  description     = "QA evaluation repo for ${var.domain} — evaluator definitions, ground truth, red-team prompts"
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

# Upload qa-deploy template to S3 for CodeBuild to consume
resource "aws_s3_object" "qa_deploy_template" {
  for_each = fileset("${path.module}/../../deploy-templates/qa-deploy", "**/*")

  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/qa-deploy-template/${each.value}"
  source = "${path.module}/../../deploy-templates/qa-deploy/${each.value}"
  etag   = filemd5("${path.module}/../../deploy-templates/qa-deploy/${each.value}")
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
# Upload validation and registration scripts to S3 (Task 10.2)
# These are referenced from CodeBuild buildspecs during pipeline execution.
# ---------------------------------------------------------------------------

# Core validation entrypoint
resource "aws_s3_object" "validate_qa_repo" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_qa_repo.py"
  source = "${path.module}/../pipeline/scripts/validate_qa_repo.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_qa_repo.py")
}

# Individual validator scripts
resource "aws_s3_object" "validate_evaluation_yaml" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_evaluation_yaml.py"
  source = "${path.module}/../pipeline/scripts/validate_evaluation_yaml.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_evaluation_yaml.py")
}

resource "aws_s3_object" "validate_evaluator_yaml" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_evaluator_yaml.py"
  source = "${path.module}/../pipeline/scripts/validate_evaluator_yaml.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_evaluator_yaml.py")
}

resource "aws_s3_object" "validate_jsonl" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_jsonl.py"
  source = "${path.module}/../pipeline/scripts/validate_jsonl.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_jsonl.py")
}

resource "aws_s3_object" "validate_placeholders" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_placeholders.py"
  source = "${path.module}/../pipeline/scripts/validate_placeholders.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_placeholders.py")
}

resource "aws_s3_object" "validate_red_team" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_red_team.py"
  source = "${path.module}/../pipeline/scripts/validate_red_team.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_red_team.py")
}

resource "aws_s3_object" "validate_conventions" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/validate_conventions.py"
  source = "${path.module}/../pipeline/scripts/validate_conventions.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/validate_conventions.py")
}

resource "aws_s3_object" "qa_repo_paths" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/qa_repo_paths.py"
  source = "${path.module}/../pipeline/scripts/qa_repo_paths.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/qa_repo_paths.py")
}

# State store registration script
resource "aws_s3_object" "register_qa_evaluators" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "_platform/scripts/register_qa_evaluators.py"
  source = "${path.module}/../pipeline/scripts/register_qa_evaluators.py"
  etag   = filemd5("${path.module}/../pipeline/scripts/register_qa_evaluators.py")
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
        Sid      = "GroundTruthBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${var.ground_truth_bucket}", "arn:aws:s3:::${var.ground_truth_bucket}/*"]
      },
      {
        Sid      = "ReadPlatformState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.platform_state_bucket}", "arn:aws:s3:::${var.platform_state_bucket}/*"]
      },
      {
        Sid      = "DynamoDBStateStore"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = ["arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.platform_state_table}"]
      },
      # bedrock-agentcore:CreateEvaluator has no resource type; the API requires Resource "*".
      {
        Sid      = "AgentCoreEvaluatorCreateRequiresWildcard"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:CreateEvaluator"]
        Resource = ["*"]
      },
      {
        Sid    = "AgentCoreEvaluators"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetEvaluator",
          "bedrock-agentcore:UpdateEvaluator",
          "bedrock-agentcore:DeleteEvaluator",
          "bedrock-agentcore:TagResource",
          "bedrock-agentcore:UntagResource",
          "bedrock-agentcore:ListTagsForResource",
        ]
        Resource = ["arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:evaluator/*"]
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
# CodeBuild — Validate (schema validation of QA repo content)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "validate" {
  name           = "${local.prefix}-validate"
  description    = "QA pipeline — validate evaluator definitions and ground truth schemas"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS-managed CodeBuild image (ships aws-cli v2 + python3 + pip). Replaces the
    # custom eap-terraform:1.5 ECR image. Validate runs the python schema
    # checkers only — no Terraform required.
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
# CodeBuild — Plan (terraform plan for evaluator resources)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "plan" {
  name           = "${local.prefix}-plan"
  description    = "QA pipeline — terraform plan for evaluator provisioning"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS-managed CodeBuild image (ships aws-cli v2 + python3 + pip). Replaces the
    # custom eap-terraform:1.5 ECR image; Terraform is installed at build time
    # by the plan buildspec (curl the pinned version).
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
      name  = "TF_VAR_ground_truth_bucket"
      value = var.ground_truth_bucket
    }
    environment_variable {
      name  = "TF_VAR_repository_name"
      value = var.repository_name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/plan.yaml")
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# CodeBuild — Apply (terraform apply + state store registration)
# ---------------------------------------------------------------------------
resource "aws_codebuild_project" "apply" {
  name           = "${local.prefix}-apply"
  description    = "QA pipeline — terraform apply + register evaluators in state store"
  service_role   = local.codebuild_role_arn
  encryption_key = aws_kms_key.artifacts.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS-managed CodeBuild image (ships aws-cli v2 + python3 + pip). Replaces the
    # custom eap-terraform:1.5 ECR image; Terraform is installed at build time
    # by the apply buildspec (curl the pinned version).
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
      name  = "TF_VAR_ground_truth_bucket"
      value = var.ground_truth_bucket
    }
    environment_variable {
      name  = "TF_VAR_repository_name"
      value = var.repository_name
    }
    environment_variable {
      name  = "PLATFORM_STATE_TABLE"
      value = var.platform_state_table
    }
    environment_variable {
      name  = "GROUND_TRUTH_BUCKET"
      value = var.ground_truth_bucket
    }
    environment_variable {
      name  = "DOMAIN"
      value = var.domain
    }
    environment_variable {
      name  = "REPOSITORY_NAME"
      value = var.repository_name
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
