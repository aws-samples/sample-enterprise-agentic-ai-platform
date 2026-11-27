variable "aws_region" {
  description = "AWS region for platform resources"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account ID for the platform. Auto-resolved from caller identity if not provided."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "tags" {
  description = "Default tags applied to all platform resources"
  type        = map(string)
  default     = {}
}

# --- Demo console (ADR-034) --------------------------------------------------
# The bundled demo console (S3 + CloudFront SPA) and the backend services it
# depends on — the studio-read read routes and the ADE streaming invoke backend,
# both ALB/Fargate (ADR-041: no API Gateway anywhere) — are a SINGLE console
# stack. They exist ONLY to serve that CloudFront UI; nothing else in the
# platform consumes them. Enterprises that host their own UI internally (BYO UI)
# and want no public ingress set this to false, which removes CloudFront, the S3
# SPA bucket, and the public edge of those backends in one go. Left true so the
# out-of-the-box demo deploy keeps working.

variable "deploy_console" {
  description = <<-EOT
    Deploy the bundled demo console and its supporting backends as one unit:
    the S3 + CloudFront SPA (module.console), the studio-read read-only routes,
    and the ADE streaming invoke backend — all ALB/Fargate, no API Gateway
    (ADR-041). These are the ONLY components that serve that public CloudFront
    UI, so setting this to false removes the platform's entire public ingress.
    Set false for enterprise installs that host their own UI internally (BYO UI)
    and require no public access. Default true (demo works out-of-the-box).
  EOT
  type        = bool
  default     = true
}

# --- Encryption at rest — customer-managed KMS key (ADR-035) -----------------
# One platform-wide knob for data-at-rest encryption. NULL (default) => every
# resource uses its AWS-managed KMS key (aws/s3, aws/dynamodb, aws/secretsmanager,
# aws/rds, ...) — always encrypted, no customer key. Supply a customer-managed
# key (CMK) ARN => it is threaded to every resource that supports one: the
# lifecycle DynamoDB table, the Langfuse datastores/secrets/S3, the Gateway, and
# (via bootstrap.sh / the state-backend module) the Terraform state bucket. The
# key must live in the deploy account+region and its policy must allow the
# relevant service principals + the deploy/runtime roles to use it.

variable "kms_key_arn" {
  description = <<-EOT
    Customer-managed KMS key (CMK) ARN for data-at-rest encryption across the
    platform. NULL (default) => each resource's AWS-provided default encryption
    (always encrypted, no customer key): the AWS-managed aws/s3 key for the
    state bucket, DynamoDB's service-managed (AWS-owned) encryption for the
    lifecycle table, and the corresponding AWS-managed keys for the Langfuse
    datastores/secrets. When set, the CMK is threaded to every CMK-capable
    resource (lifecycle DynamoDB, Langfuse stack, Gateway, and — via bootstrap —
    the state bucket). NOTE: S3/DynamoDB SSE changes are not retroactive; set
    this at bootstrap/first-create time for the state bucket (see DEPLOY-RUNBOOK).
  EOT
  type        = string
  default     = null
}

# --- Observability (AgentCore Observability / CloudWatch GenAI + X-Ray) ---

variable "enable_transaction_search" {
  description = <<-EOT
    Enable CloudWatch/X-Ray Transaction Search for this platform instance
    (account + region wide, singleton). Required for AgentCore Observability
    spans/traces to be searchable in the CloudWatch GenAI Observability page.
    Enabled by default so observability works out-of-the-box at deploy time.
  EOT
  type        = bool
  default     = true
}

variable "transaction_search_indexing_percentage" {
  description = <<-EOT
    Percentage (0-100) of trace spans indexed from CloudWatch Logs to X-Ray for
    Transaction Search. Note: ingestion is billed on ALL spans regardless of
    this value; this only controls how many spans are indexed as queryable
    trace summaries (the first 1% is indexed free). Full end-to-end trace
    visibility comes from ingestion, not this percentage. Default 5 gives
    attribute-search headroom at near-zero extra cost; raise it only where
    high-volume span-attribute search is needed.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.transaction_search_indexing_percentage >= 0 && var.transaction_search_indexing_percentage <= 100
    error_message = "transaction_search_indexing_percentage must be between 0 and 100."
  }
}

variable "cognito_domain_prefix" {
  description = "Cognito domain prefix for the OAuth2 token endpoint (only used when the platform provisions Cognito, i.e. oidc_discovery_url is empty)"
  type        = string
  default     = "eap-platform-bu-1"
}

# --- Identity provider (OIDC) — deployer-supplied, IdP-agnostic (ADR-028) ---
#
# The platform integrates an external OIDC identity provider BY REFERENCE. Set
# oidc_discovery_url to your IdP's discovery document (Cognito or any external OIDC provider)
# and it propagates to every consumer (AgentCore Gateway CUSTOM_JWT authorizer,
# integration pipelines, the studio-read + ADE invoke backends, console).
#
# LEAVE EMPTY (default) to have the platform provision an Amazon Cognito user
# pool for you (the zero-config default). When set to a non-empty value, the
# platform SKIPS Cognito creation entirely and uses the supplied IdP.

variable "oidc_discovery_url" {
  description = <<-EOT
    External OIDC discovery URL for the identity provider (e.g.
    https://<idp>/.well-known/openid-configuration). EMPTY (default) => the
    platform provisions a Cognito user pool and derives the discovery URL from
    it. NON-EMPTY => Cognito is not created and this external IdP is used
    everywhere. Swapping IdPs is a single-variable change.
  EOT
  type        = string
  default     = ""
}

variable "oidc_issuer" {
  description = <<-EOT
    Optional OIDC issuer (iss) override for JWT validation. Empty (default) =>
    derived from the platform-created Cognito pool (or inferred by consumers
    from oidc_discovery_url). Set only when your IdP's issuer differs from the
    discovery URL host.
  EOT
  type        = string
  default     = ""
}

variable "oidc_audience" {
  description = <<-EOT
    Optional OIDC audience (aud)/allowed-scope override for JWT validation.
    Empty (default) => the platform uses the Cognito gateway scope
    (gateway/tools.invoke). Set to your IdP's audience/scope when using an
    external IdP.
  EOT
  type        = string
  default     = ""
}

variable "console_url" {
  description = <<-EOT
    Public base URL of the platform console, used to build the OAuth callback
    (<console_url>/auth/callback) and logout URLs. EMPTY (default) => derived
    from the platform-created CloudFront distribution domain. Set this when you
    front the console with a custom domain, or when using an external IdP (so
    the callback the runbook tells you to register matches what the console
    build uses).
  EOT
  type        = string
  default     = ""
}

# --- Third-party observability leg (Langfuse_Stack + OTel_Collector) ---
#
# The third-party telemetry leg (self-hosted Langfuse as the default backend,
# fed by the platform OTel_Collector) is OPT-IN and DISABLED BY DEFAULT (the
# flag below defaults to false). Even when the flag is turned on, the modules
# are only instantiated once the networking they require is supplied (a VPC,
# private + public subnets, and an ACM cert for the Langfuse_ALB HTTPS
# listener). eap-platform does not manage its own VPC, so those inputs
# default empty. With the default-off flag AND empty networking the
# Langfuse/OTel_Collector modules stay at count=0 — `terraform validate`/`plan`
# stay green out of the box. To bring the third-party leg online, set
# enable_langfuse_observability=true AND provide the networking inputs. This
# never affects the AWS-native leg (CloudWatch/X-Ray), which is delivered by
# AgentCore auto-instrumentation and is structurally independent of this
# collector.
#
# Status: parked for future enablement.

# --- Third-party observability leg (OTel Collector + backend) — ADR-030 ------
#
# The OTel Collector is ALWAYS deployed (in-VPC) and receives a COPY of agent
# spans, fanning them out to a third-party OTLP backend. This is fully PRIVATE
# (no public endpoints, no ACM, no CloudFront) — the enterprise posture.
# The AWS-native leg (CloudWatch/X-Ray) is separate and always on regardless.
#
# Backend resolution:
#   deploy_langfuse=true,  otel_backend_endpoint=""   => Langfuse only (default)
#   deploy_langfuse=true,  otel_backend_endpoint set  => Langfuse + external (mode=add) / external only (mode=replace)
#   deploy_langfuse=false, otel_backend_endpoint set  => external only
#   deploy_langfuse=false, otel_backend_endpoint=""   => collector up, no third-party exporters

variable "deploy_langfuse" {
  description = <<-EOT
    Deploy the self-hosted Langfuse stack as the default third-party OTLP
    backend (private: internal HTTP ALB, no public exposure / no ACM). Default
    true. Set false to rely solely on an external backend (otel_backend_endpoint)
    or to run the collector with no third-party exporters. Does not affect the
    always-on AWS-native (CloudWatch/X-Ray) leg.
  EOT
  type        = bool
  default     = true
}

variable "otel_backend_endpoint" {
  description = <<-EOT
    External third-party OTLP/HTTP backend endpoint (Datadog/Fiddler/Langfuse
    Cloud/...) the collector exports to. Empty (default) => no external backend
    (Langfuse only, if deploy_langfuse). When set, combined with deploy_langfuse
    per otel_backend_mode.
  EOT
  type        = string
  default     = ""
}

variable "otel_backend_auth_secret_arn" {
  description = "Secrets Manager ARN holding the Authorization header/token for otel_backend_endpoint. Granted to the collector task role as secretsmanager:GetSecretValue ONLY. Empty => no auth header."
  type        = string
  default     = ""
}

variable "otel_backend_mode" {
  description = "How the external backend relates to the Langfuse default: \"add\" (fan out to both) or \"replace\" (external instead of Langfuse). Only meaningful when deploy_langfuse=true and otel_backend_endpoint is set."
  type        = string
  default     = "add"

  validation {
    condition     = contains(["add", "replace"], var.otel_backend_mode)
    error_message = "otel_backend_mode must be \"add\" or \"replace\"."
  }
}

# --- VPC: import-or-create (ADR-030) -----------------------------------------
#
# The third-party observability leg runs in-VPC. Supply an existing VPC to run
# inside your governed network, or leave empty to have the platform create one
# (with full egress: IGW + NAT gateway + private route tables). When importing,
# supply the subnet IDs explicitly — they are NOT inferred, so governed VPCs
# with isolated/egress subnet tiers are used unambiguously (the supplied private
# subnets MUST have egress to ECR + AWS APIs via NAT or VPC endpoints).

variable "vpc_id" {
  description = "Existing VPC ID to run the observability leg in. Empty (default) => the platform creates a VPC with full egress."
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (>=2 distinct AZs, with egress) for Fargate tasks + datastores. Required when vpc_id is set; ignored when the platform creates the VPC."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Subnet IDs for the internal ALB across >=2 AZs. Required when vpc_id is set; ignored when the platform creates the VPC. (Internal ALB — these need not be internet-facing; any subnets with the right AZ coverage work.)"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Agent network posture (ADR-031)
# ---------------------------------------------------------------------------
# Enterprise default: every AgentCore agent workload (runtimes, and the
# built-in Browser/Code-Interpreter tools if/when instantiated) runs INSIDE the
# resolved VPC — AgentCore attaches ENIs in the private subnets so agent egress
# stays within the enterprise network boundary (VPC-mode is the posture the AWS
# Config rule BEDROCKAGENTCORE_RUNTIME_PRIVATE_NETWORK_REQUIRED expects).
#
# Fallback: if agent_network_mode = "PUBLIC", OR "VPC" is requested but no VPC
# is resolvable (no vpc_id imported and none created), agents fall back to
# AgentCore-managed PUBLIC endpoints — surfaced via the agent_network_posture
# output and a plan-time check (see outputs.tf).
variable "agent_network_mode" {
  description = "Network posture for AgentCore agent workloads (runtimes + built-in tools). 'VPC' (default) runs agents inside the resolved VPC (private subnets) so egress stays in the enterprise boundary. 'PUBLIC' runs them on AgentCore-managed public endpoints (the pre-VPC behavior). VPC mode requires a resolvable VPC (imported vpc_id or platform-created); if none resolves, the platform falls back to PUBLIC with a note."
  type        = string
  default     = "VPC"

  validation {
    condition     = contains(["VPC", "PUBLIC"], var.agent_network_mode)
    error_message = "agent_network_mode must be either \"VPC\" or \"PUBLIC\"."
  }
}

variable "agent_security_group_ids" {
  description = "Optional deployer-supplied security group IDs for the AgentCore agent ENIs (VPC mode). When empty (default), the platform creates a dedicated agent security group in the resolved VPC (egress-only: 443 to AWS APIs + intra-VPC; no inbound, since runtimes only initiate outbound connections). Supply your own to attach governed SGs instead."
  type        = list(string)
  default     = []
}

variable "allowed_models" {
  description = "List of Bedrock foundation model IDs allowed for invocation. Claude Sonnet 5 is only invokable via its cross-region inference profile (the us. prefix, e.g. us.anthropic.claude-sonnet-5); the bare foundation-model id is not valid for on-demand Converse/ConverseStream and yields ValidationException: The provided model identifier is invalid."
  type        = list(string)
  default     = ["us.anthropic.claude-sonnet-5"]
}

variable "domains" {
  description = "Map of domain names to their configuration"
  type = map(object({
    description    = optional(string, "")
    allowed_models = optional(list(string), [])
  }))
  default = {
    team-bu-1 = {
      description    = "Business Unit 1 — Agentic AI agents"
      allowed_models = ["us.anthropic.claude-sonnet-5"]
    }
  }
}

# --- Pipeline provisioning ---

# NOTE: The agent + base-image ECR repository URLs are NOT root variables. They
# are taken directly from the platform-created ECR module outputs
# (module.ecr.repository_url / module.ecr.base_image_repository_url) and passed
# to the pipelines and studio modules in main.tf, so they always reflect the
# current account/region. (Former hardcoded ecr_repository_url /
# base_image_ecr_repo_url variables were removed — they were unused and carried
# a stale account id.)

variable "agent_pipelines" {
  description = "Map of agent pipeline name to configuration. One CodePipeline per entry."
  type = map(object({
    domain          = string
    repository_name = string
    branch          = optional(string, "main")
    source_provider = optional(string, "CodeCommit")
    model_id        = optional(string, "")
    protocols       = optional(list(string), ["a2a"])
    # ADR-048: insert a manual approval stage before Deploy.
    require_manual_approval = optional(bool, false)
  }))
  default = {
    a2a-demo = {
      domain          = "team-bu-1"
      repository_name = "team-bu-1"
    }
    # No-code-user (Studio/ADE) deployment pipeline. Adopted into the platform
    # remote state so it inherits the shared-table deployed-agent recorder.
    # Commits here are model-generated, so a person approves each one before
    # it is deployed (ADR-048).
    nocode-user-deploy = {
      domain                  = "nocode-user"
      repository_name         = "nocode-user"
      require_manual_approval = true
    }
  }
}

variable "integration_pipelines" {
  description = <<-EOT
    Map of integration pipeline name to configuration. Deploys Gateway from YAML
    sources. The OIDC discovery URL is NOT set here — it is injected from the
    platform-wide oidc_discovery_url (external IdP) or the platform-created
    Cognito pool, so all consumers share one identity source (ADR-028). An
    optional per-pipeline oidc_discovery_url override is available but should be
    left empty in normal use.
  EOT
  type = map(object({
    domain             = string
    repository_name    = string
    branch             = optional(string, "main")
    oidc_discovery_url = optional(string, "")
  }))
  default = {
    mcp-integrations = {
      domain          = "shared-services"
      repository_name = "mcp-integrations"
    }
  }
}

variable "source_repositories" {
  description = "Map of CodeCommit repository name to configuration."
  type = map(object({
    description = optional(string, "")
  }))
  default = {
    team-bu-1 = {
      description = "Agentic AI agents for Business Unit 1"
    }
    mcp-integrations = {
      description = "MCP server + tool/data integrations — Gateway YAML sources"
    }
    governance = {
      description = "Governance policies — Cedar authorization, graduation policy, red-team prompts"
    }
    # Dedicated repo the Agent Deployment Engineer (Studio) commits generated
    # agents into. The ADE runtime role (studio-runtime-role) is scoped to
    # codecommit:CreateCommit on this repo, and the nocode-user-deploy pipeline
    # watches it. Provisioned here so the repo is created by Terraform rather
    # than out-of-band.
    nocode-user = {
      description = "No-code / Studio-generated agents — committed by the Agent Deployment Engineer"
    }
  }
}

# --- QA Evaluation Pipelines ---

variable "qa_pipelines" {
  description = "Map of QA pipeline name to configuration. One QA evaluation pipeline per entry."
  type = map(object({
    domain               = string
    repository_name      = string
    branch               = optional(string, "main")
    platform_state_table = string
    ground_truth_bucket  = string
  }))
  default = {}
}

# --- KB Pipelines ---

variable "kb_pipelines" {
  description = "Map of KB pipeline name to configuration. One Knowledge Base pipeline per entry."
  type = map(object({
    domain          = string
    repository_name = string
    branch          = optional(string, "main")
  }))
  default = {
    kb-team-bu-1 = {
      domain          = "team-bu-1"
      repository_name = "knowledge-bases-team-bu-1"
    }
  }
}

variable "studio_build_image" {
  description = <<-EOT
    Whether the platform apply builds + pushes the Agent Deployment Engineer image
    (via studio/build-and-push.sh) before creating its runtime. Requires a
    container builder (Docker/Lima) + AWS creds on the deploy host. Set to
    false to reuse the image already in ECR for a faster, Docker-free apply.
  EOT
  type        = bool
  default     = true
}

variable "alb_deletion_protection" {
  description = "Enable deletion protection on the platform's ALBs. Set false (targeted apply on the aws_lb resources) before terraform destroy; the testbed 99-teardown.sh scripts do this."
  type        = bool
  default     = true
}
