# QA Deploy Template — Provisions AgentCore Evaluators and uploads ground truth
# This config runs inside CodeBuild during Plan and Apply stages.
# Reads evaluation.yaml from source to determine evaluator bindings.
#
# All values are injected via TF_VAR_ environment variables from CodeBuild.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Read evaluation.yaml to determine bindings
# ---------------------------------------------------------------------------
locals {
  evaluation_config = yamldecode(file("${path.module}/evaluation.yaml"))
  business_unit     = local.evaluation_config.business_unit

  # Flatten bindings into a map keyed by "{app_name}/{evaluator_dir_name}"
  evaluator_bindings = {
    for binding in local.evaluation_config.bindings : binding.app_name => {
      app_name       = binding.app_name
      evaluator_path = binding.evaluators[0].path
      evaluator_yaml = yamldecode(file("${path.module}/${binding.evaluators[0].path}/evaluator.yaml"))
    }
  }
}

# ---------------------------------------------------------------------------
# AgentCore Evaluators — one per binding
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_evaluator" "qa_evaluator" {
  for_each = local.evaluator_bindings

  name        = each.value.evaluator_yaml.name
  description = try(each.value.evaluator_yaml.description, "QA evaluator for ${each.value.app_name}")

  evaluator_config {
    evaluator_model_id = each.value.evaluator_yaml.model_id
    eval_template      = each.value.evaluator_yaml.scoring_rubric
    score_range {
      min_score = try(each.value.evaluator_yaml.score_range.min, 0.0)
      max_score = try(each.value.evaluator_yaml.score_range.max, 1.0)
    }
  }

  tags = merge(var.tags, {
    business_unit = var.domain
    app_name      = each.value.app_name
    source_repo   = var.repository_name
  })
}

# ---------------------------------------------------------------------------
# S3 Objects — Ground truth JSONL files
# ---------------------------------------------------------------------------
resource "aws_s3_object" "ground_truth" {
  for_each = local.evaluator_bindings

  bucket = var.ground_truth_bucket
  key    = "ground-truth/${local.business_unit}/${each.value.app_name}/test-cases.jsonl"
  source = "${path.module}/${each.value.evaluator_path}/test-cases.jsonl"
  etag   = filemd5("${path.module}/${each.value.evaluator_path}/test-cases.jsonl")

  metadata = {
    commit_sha       = var.commit_sha
    upload_timestamp = timestamp()
    qa_repo_name     = var.repository_name
  }
}

# ---------------------------------------------------------------------------
# S3 Objects — Red-team prompts (if red-team/ directory exists)
# ---------------------------------------------------------------------------
resource "aws_s3_object" "red_team" {
  for_each = toset([
    for f in fileset("${path.module}/red-team", "*.json") : f
    if length(fileset("${path.module}/red-team", "*.json")) > 0
  ])

  bucket = var.ground_truth_bucket
  key    = "red-team/${local.business_unit}/${each.value}"
  source = "${path.module}/red-team/${each.value}"
  etag   = filemd5("${path.module}/red-team/${each.value}")

  metadata = {
    commit_sha       = var.commit_sha
    upload_timestamp = timestamp()
    qa_repo_name     = var.repository_name
  }
}
