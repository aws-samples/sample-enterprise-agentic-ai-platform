# Agent Deployment Engineer — Module Variables
# Platform-owned deployment of the agent (image build + AgentCore runtime).

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)"
  type        = string
}

variable "domain" {
  description = "Domain this Studio runtime belongs to (used for naming, tagging, env vars)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for the Studio runtime and ECR"
  type        = string
}

variable "account_id" {
  description = "AWS account ID (for ECR registry URL construction)"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL for agent images (Studio image is pushed here)"
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository name for agent images (used to resolve the image tag to an immutable digest)."
  type        = string
}

variable "model_id" {
  description = "Foundation model ID injected into the Studio runtime as MODEL_ID"
  type        = string
}

variable "agent_base_name" {
  description = "Base name for the Studio agent (used to derive runtime + memory names). Kept distinct from any pipeline-deployed Studio to avoid AgentCore name collisions."
  type        = string
  default     = "agent-deployment-engineer"
}

variable "image_tag" {
  description = "Image tag for the Agent Deployment Engineer container image in ECR"
  type        = string
  default     = "agent-deployment-engineer-latest"
}

variable "build_image" {
  description = <<-EOT
    Whether to build + push the Studio container image at apply time (via
    build-and-push.sh). When true, the deployed image is reproducible from
    studio/app/ in the codebase and is rebuilt automatically whenever that
    source changes. Requires a container builder (Docker/Lima) + AWS creds on
    the deploy host. Set to false to skip the build and reuse the existing
    ECR tag for a faster apply.
  EOT
  type        = bool
  default     = true
}

variable "enable_memory" {
  description = <<-EOT
    Whether to inject AGENTCORE_MEMORY_ID into the Studio runtime (enables the
    AgentCore Memory session manager). Requires a Studio image that passes
    session_id + actor_id to AgentCoreMemoryConfig (the default prebuilt image
    does). An image WITHOUT that fix throws at invocation time and surfaces as a
    JSON-RPC -32603 "Internal error"; set this to false if you must run such an
    image temporarily.
  EOT
  type        = bool
  default     = true
}

# --- Agent network posture (ADR-031) — passed through to the runtime ---

variable "network_mode" {
  description = "Network mode for the Studio/ADE agent runtime: 'VPC' (agent ENIs in the enterprise VPC) or 'PUBLIC'. Resolved by the platform root (local.agent_effective_network_mode) — 'VPC' only when a VPC is available."
  type        = string
  default     = "PUBLIC"
}

variable "vpc_config" {
  description = "VPC configuration for the Studio/ADE agent runtime when network_mode = VPC (private subnets + agent security groups). Null when PUBLIC. Passed straight to the runtime module's vpc_config."
  type = object({
    security_groups = list(string)
    subnets         = list(string)
  })
  default = null
}

variable "runtime_role_arn" {
  description = "Pre-created IAM role ARN for the Studio/ADE agent runtime (ADR-033). Empty (default) => the module creates the role + its policy; supplied => the module creates neither and the runtime uses this ARN."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to Studio resources"
  type        = map(string)
  default     = {}
}

variable "platform_gateway_url" {
  description = "URL of the platform's shared AgentCore Gateway (MCP endpoint). Injected into the Studio runtime as PLATFORM_GATEWAY_URL for the MCP catalog tool."
  type        = string
}
