# ===========================================================================
# Externalizable IAM roles (ADR-033) — bring-your-own role ARNs
# ===========================================================================
# Enterprises where humans/deployers may NOT create IAM roles can pre-create the
# platform's root-apply roles (their IAM team owns naming + policy) and supply
# the ARNs here. For each *_role_arn:
#   - empty (default) => the platform CREATES the role and its policies exactly
#     as before (no behavior change).
#   - supplied        => the platform creates NOTHING for that role (no
#     aws_iam_role, no inline policy, no attachment) and wires the supplied ARN
#     into the consuming resource instead.
#
# The exact trust + permission policy JSON each pre-created role must carry is
# published under docs/iam/ (a verbatim mirror of what the platform creates).
# Pipelines are still allowed to create roles, so the per-agent runtime / SFN /
# invoke-bridge roles created INSIDE a vended pipeline are NOT externalized here.
#
# Scope note: the optional self-hosted observability stack (Langfuse +
# otel-collector, deploy_langfuse) creates its own ECS execution/task roles;
# those are NOT externalized in this pass (opt-in, rarely used in enterprise).
# ---------------------------------------------------------------------------

# --- Root-created roles ---

variable "gateway_role_arn" {
  description = "Pre-created IAM role ARN for the AgentCore Gateway (trusts bedrock-agentcore.amazonaws.com). Empty => platform creates it. See docs/iam/roles/gateway/."
  type        = string
  default     = ""
}

variable "observability_role_arn" {
  description = "Pre-created IAM role ARN for the read-only console Observability role. Empty => platform creates it (only when enable_observability_role = true). See docs/iam/roles/observability/."
  type        = string
  default     = ""
}

# --- Child-module roles (threaded into their modules) ---

variable "studio_runtime_role_arn" {
  description = "Pre-created IAM role ARN for the Studio/ADE agent runtime (trusts bedrock-agentcore.amazonaws.com). Empty => platform creates it. See docs/iam/roles/studio-runtime/."
  type        = string
  default     = ""
}

variable "commit_validation_role_arn" {
  description = "Pre-created IAM role ARN for the commit-validation Lambda (trusts lambda.amazonaws.com). Empty => platform creates it. See docs/iam/roles/commit-validation/."
  type        = string
  default     = ""
}

variable "console_authenticated_role_arn" {
  description = "Pre-created IAM role ARN for the Cognito authenticated console role (trusts cognito-identity.amazonaws.com). Empty => platform creates it (only when the Cognito identity pool is created). See docs/iam/roles/console-authenticated/."
  type        = string
  default     = ""
}

# --- Pipeline service roles (threaded through module.pipelines / directly) ---
# Each pipeline has a CodeBuild service role and a CodePipeline service role.
# NOTE: these carry the platform's evolving CI/CD permissions; their published
# JSON is marked "evolving" (expect updates as the architecture changes).

variable "agent_pipeline_codebuild_role_arn" {
  description = "Pre-created CodeBuild service role ARN for agent pipelines. Empty => platform creates it. See docs/iam/roles/agent-pipeline-codebuild/ (evolving)."
  type        = string
  default     = ""
}

variable "agent_pipeline_codepipeline_role_arn" {
  description = "Pre-created CodePipeline service role ARN for agent pipelines. Empty => platform creates it. See docs/iam/roles/agent-pipeline-codepipeline/ (evolving)."
  type        = string
  default     = ""
}

variable "integration_pipeline_codebuild_role_arn" {
  description = "Pre-created CodeBuild service role ARN for the integration (gateway) pipeline. Empty => platform creates it. See docs/iam/roles/integration-pipeline-codebuild/ (evolving)."
  type        = string
  default     = ""
}

variable "integration_pipeline_codepipeline_role_arn" {
  description = "Pre-created CodePipeline service role ARN for the integration (gateway) pipeline. Empty => platform creates it. See docs/iam/roles/integration-pipeline-codepipeline/ (evolving)."
  type        = string
  default     = ""
}

variable "governance_pipeline_codebuild_role_arn" {
  description = "Pre-created CodeBuild service role ARN for the governance pipeline. Empty => platform creates it. See docs/iam/roles/governance-pipeline-codebuild/ (evolving)."
  type        = string
  default     = ""
}

variable "governance_pipeline_codepipeline_role_arn" {
  description = "Pre-created CodePipeline service role ARN for the governance pipeline. Empty => platform creates it. See docs/iam/roles/governance-pipeline-codepipeline/ (evolving)."
  type        = string
  default     = ""
}

variable "kb_pipeline_codebuild_role_arn" {
  description = "Pre-created CodeBuild service role ARN for KB pipelines. Empty => platform creates it. See docs/iam/roles/kb-pipeline-codebuild/ (evolving)."
  type        = string
  default     = ""
}

variable "kb_pipeline_codepipeline_role_arn" {
  description = "Pre-created CodePipeline service role ARN for KB pipelines. Empty => platform creates it. See docs/iam/roles/kb-pipeline-codepipeline/ (evolving)."
  type        = string
  default     = ""
}

variable "qa_pipeline_codebuild_role_arn" {
  description = "Pre-created CodeBuild service role ARN for QA pipelines. Empty => platform creates it. See docs/iam/roles/qa-pipeline-codebuild/ (evolving)."
  type        = string
  default     = ""
}

variable "qa_pipeline_codepipeline_role_arn" {
  description = "Pre-created CodePipeline service role ARN for QA pipelines. Empty => platform creates it. See docs/iam/roles/qa-pipeline-codepipeline/ (evolving)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Resolution locals for the ROOT-created roles (gateway, observability).
# Child-module roles resolve inside their own modules from the *_role_arn var
# threaded in via main.tf.
# ---------------------------------------------------------------------------
locals {
  # Gateway: supplied ARN wins, else the platform-created role.
  gateway_role_arn = var.gateway_role_arn != "" ? var.gateway_role_arn : one(aws_iam_role.gateway[*].arn)

  # Observability: supplied ARN wins, else the platform-created role (which is
  # itself only created when enable_observability_role = true). Null when
  # neither applies (role disabled and no ARN) — consumers already handle null.
  observability_role_arn = var.observability_role_arn != "" ? var.observability_role_arn : one(aws_iam_role.observability[*].arn)

  # Whether the platform should CREATE the observability role: only when enabled
  # AND no external ARN was supplied.
  create_observability_role = var.enable_observability_role && var.observability_role_arn == ""
}
