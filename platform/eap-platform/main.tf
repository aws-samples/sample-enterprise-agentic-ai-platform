# EAP Platform — Root Module
#
# Manages cross-cutting governance, identity, and domain provisioning.
# Demo: Cognito identity, ECR, state backend, domain provisioning, Bedrock model access.
# Post-MVP: Config Rules, SCPs, IAM Access Analyzer.
#
# Requirements: R15.1, R15.2, R17.1, R18.1–R18.6

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      managed_by  = "terraform"
      platform    = "eap"
      environment = var.environment
    })
  }
}

# Auto-resolve account ID from caller identity
data "aws_caller_identity" "current" {}

# Partition (aws / aws-us-gov / aws-cn) for constructing ARNs portably.
data "aws_partition" "current" {}

locals {
  account_id = var.account_id != "" ? var.account_id : data.aws_caller_identity.current.account_id

  # Account-scoped Terraform state bucket (S3 names are globally unique). Must
  # match the bucket bootstrap.sh creates and the -backend-config passed at init.
  # Downstream pipelines read platform outputs from this bucket via
  # terraform_remote_state, so the name is threaded to every pipeline module.
  platform_state_bucket = "eap-platform-state-${local.account_id}"

  # ---- Identity provider (OIDC) resolution — ADR-028 ------------------------
  # The platform provisions Cognito ONLY when no external IdP is supplied.
  create_cognito = var.oidc_discovery_url == ""

  # Single source of truth for the OIDC discovery URL every consumer uses:
  # the external IdP when supplied, otherwise the platform-created Cognito pool.
  oidc_discovery_url = local.create_cognito ? module.identity[0].oidc_discovery_url : var.oidc_discovery_url

  # Audience/allowed-scope: external override when supplied, else the Cognito
  # gateway scope (gateway/tools.invoke).
  oidc_audience = var.oidc_audience != "" ? var.oidc_audience : (local.create_cognito ? module.identity[0].gateway_scope_invoke : "")

  # Console app client id (Cognito only — empty under an external IdP, where the
  # deployer registers their own client and supplies it out of band).
  console_client_id = local.create_cognito ? module.identity[0].console_client_id : ""

  # Cognito user pool id / arn (empty strings under an external IdP).
  cognito_user_pool_id  = local.create_cognito ? module.identity[0].user_pool_id : ""
  cognito_user_pool_arn = local.create_cognito ? module.identity[0].user_pool_arn : ""

  # ---- VPC: import-or-create (ADR-030) --------------------------------------
  # The platform creates a VPC (with full egress: IGW + NAT + private routes)
  # ONLY when no vpc_id is supplied. When importing, the deployer supplies
  # vpc_id + private_subnet_ids (+ public_subnet_ids for the internal ALB's AZ
  # coverage). Explicit subnet IDs (not inferred) so governed enterprise VPCs
  # with isolated/egress tiers are used unambiguously.
  create_vpc = var.vpc_id == ""

  vpc_id             = local.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  private_subnet_ids = local.create_vpc ? module.vpc[0].private_subnet_ids : var.private_subnet_ids
  public_subnet_ids  = local.create_vpc ? module.vpc[0].public_subnet_ids : var.public_subnet_ids
  # Private route table IDs are only known for a platform-created VPC (used for
  # the S3 gateway endpoint association). Empty for an imported VPC — the
  # deployer's VPC owns its own endpoints/routing.
  private_route_table_ids = local.create_vpc ? module.vpc[0].private_route_table_ids : []

  # ---- Agent network posture (ADR-031) --------------------------------------
  # VPC mode is the enterprise default, but it only takes effect when a VPC is
  # actually resolvable (imported vpc_id OR platform-created). If VPC is asked
  # for but none resolves, we fall back to PUBLIC so a deploy never wedges on a
  # missing network — the agent_network_posture output + a plan-time check make
  # that fallback visible (see outputs.tf).
  agent_vpc_requested = var.agent_network_mode == "VPC"

  # A VPC is ALWAYS resolvable: either the deployer imports one (var.vpc_id set)
  # or the platform creates one (local.create_vpc). Both are PLAN-TIME-KNOWN
  # inputs, so this boolean is known at plan even on a clean single-shot apply
  # (where module.vpc[0].vpc_id is not yet computed). Gating agent-network
  # resource counts on this — instead of on the created VPC's (unknown) outputs
  # like local.vpc_id — lets `terraform apply` plan a platform-created-VPC
  # deployment in ONE shot without -target. (Previously `local.vpc_id != ""`
  # made the count unknown at plan for a created VPC.)
  agent_vpc_resolvable = var.vpc_id != "" || local.create_vpc
  agent_vpc_enabled    = local.agent_vpc_requested && local.agent_vpc_resolvable

  # The mode actually handed to every agent runtime. When VPC can't be honored
  # this resolves to "PUBLIC" (matching the pre-ADR-031 behavior).
  agent_effective_network_mode = local.agent_vpc_enabled ? "VPC" : "PUBLIC"

  # Security groups for the agent ENIs in VPC mode: deployer-supplied when given,
  # else the platform-created dedicated agent SG (created only in VPC mode).
  agent_security_group_ids = local.agent_vpc_enabled ? (
    length(var.agent_security_group_ids) > 0 ? var.agent_security_group_ids : [aws_security_group.agents[0].id]
  ) : []

  # The vpc_config object AgentCore runtimes take in VPC mode (private subnets +
  # resolved SGs); null in PUBLIC mode so the runtime module omits the block.
  agent_vpc_config = local.agent_vpc_enabled ? {
    subnets         = local.private_subnet_ids
    security_groups = local.agent_security_group_ids
  } : null

  # The vpc_config object the platform Lambdas take in VPC mode (ADR-032). Note
  # the Lambda vpc_config block uses subnet_ids/security_group_ids (distinct
  # attribute names from the AgentCore runtime's subnets/security_groups). Null
  # in PUBLIC mode so each Lambda module omits the block and runs unchanged.
  lambda_vpc_config = local.agent_vpc_enabled ? {
    subnet_ids         = local.private_subnet_ids
    security_group_ids = [aws_security_group.lambdas[0].id]
  } : null

  # ---- Observability third-party leg (ADR-030) ------------------------------
  # The OTel collector is ALWAYS deployed (in the resolved VPC). Langfuse is an
  # OPTIONAL self-hosted default backend (deploy_langfuse). An external OTLP
  # backend (Datadog/Fiddler) can be supplied to fan out to (mode=add) or
  # replace (mode=replace) the Langfuse default.
  deploy_langfuse = var.deploy_langfuse

  # Business_Units that each get their own Langfuse project. These MUST match the
  # agents' `deployment.environment` resource attribute, which the runtime module
  # sets to the agent's DOMAIN. Agents run under both the platform domains
  # (var.domains) and the agent-pipeline domains, so union them (distinct) so
  # every agent's spans have a matching authenticated Langfuse project. Used only
  # when deploy_langfuse is true.
  langfuse_business_units = distinct(concat(
    keys(var.domains),
    [for p in var.agent_pipelines : p.domain],
  ))

  # External backend passed to the collector's third_party_backends (empty list
  # when no external endpoint is configured).
  otel_external_backends = var.otel_backend_endpoint == "" ? [] : [{
    name            = "external"
    otlp_endpoint   = var.otel_backend_endpoint
    auth_secret_arn = var.otel_backend_auth_secret_arn
    mode            = var.otel_backend_mode
    enabled         = true
  }]
}

# ---------------------------------------------------------------------------
# Identity — Cognito User Pool for agent identity (Task 20.1)
#
# Conditional (ADR-028): created ONLY when no external OIDC provider is
# supplied (var.oidc_discovery_url == ""). When an external IdP is used, this
# module is skipped and consumers read local.oidc_discovery_url (= the external
# URL) instead of module.identity outputs.
# ---------------------------------------------------------------------------
module "identity" {
  source = "./identity"
  count  = local.create_cognito ? 1 : 0

  environment   = var.environment
  domain_prefix = var.cognito_domain_prefix
  console_url   = var.console_url
  tags          = var.tags
}

# ---------------------------------------------------------------------------
# ECR — Image repositories for agent images, base image, and build image
# ---------------------------------------------------------------------------
module "ecr" {
  source = "./ecr"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Domains — per-domain Cognito group + IAM permission boundary (Task 20.2)
# ---------------------------------------------------------------------------
module "domains" {
  source = "./domains"

  environment = var.environment
  # Per-domain Cognito user group + IAM boundary. The Cognito group is only
  # meaningful when the platform provisions Cognito; under an external IdP the
  # pool id is empty and group creation is skipped inside the module (the IAM
  # permission boundary, which is IdP-independent, still applies). See ADR-028.
  cognito_user_pool_id = local.cognito_user_pool_id
  create_cognito_group = local.create_cognito
  domains              = var.domains
  tags                 = var.tags
}

# ---------------------------------------------------------------------------
# Bedrock Model Access — IAM for foundation model invocation (Task 20.3)
# ---------------------------------------------------------------------------
module "bedrock_model_access" {
  source = "./bedrock-model-access"

  environment    = var.environment
  allowed_models = var.allowed_models
  tags           = var.tags
}

# ---------------------------------------------------------------------------
# Source Repos — CodeCommit repositories for app team agent code
# Platform_Admin provisions repos; app teams push code.
# ---------------------------------------------------------------------------
module "source_repos" {
  source = "./source-repos"

  repositories = var.source_repositories
  tags         = var.tags
}

# ---------------------------------------------------------------------------
# Commit Validation — Conventional Commits enforcement on CodeCommit pushes
# Fail-open Lambda trigger attached to all source repositories.
# ---------------------------------------------------------------------------
module "commit_validation" {
  source = "../eap-terraform-modules/modules/pipeline/commit-validation"

  codecommit_repo_arns = values(module.source_repos.repository_arns)
  tags                 = var.tags

  # ADR-032: run the Lambda in the enterprise VPC when in VPC mode (null in
  # PUBLIC mode).
  vpc_config = local.lambda_vpc_config

  # ADR-033: bring-your-own role ARN (empty => module creates it).
  role_arn = var.commit_validation_role_arn
}

# ---------------------------------------------------------------------------
# Pipelines — per-domain/use-case CodePipeline provisioning (Task 4)
# Platform owns all pipelines. App teams write agent.yaml, platform deploys.
# ---------------------------------------------------------------------------
module "pipelines" {
  source = "./pipelines"

  environment = var.environment
  # Cognito-derived inputs are empty under an external IdP; the agent runtime
  # A2A/token wiring only applies to the Cognito path.
  cognito_user_pool_id   = local.cognito_user_pool_id
  cognito_token_endpoint = local.create_cognito ? module.identity[0].token_endpoint : ""
  cognito_a2a_scope      = local.oidc_audience
  # Platform-wide OIDC discovery URL injected into integration pipelines'
  # gateway JWT authorizer (ADR-028) instead of a hardcoded per-entry default.
  oidc_discovery_url      = local.oidc_discovery_url
  platform_state_bucket   = local.platform_state_bucket
  ecr_repository_url      = module.ecr.repository_url
  base_image_ecr_repo_url = module.ecr.base_image_repository_url
  model_id                = var.allowed_models[0]
  agent_pipelines         = var.agent_pipelines
  integration_pipelines   = var.integration_pipelines
  tags                    = var.tags

  # Single shared lifecycle table — every vended pipeline records deployed-agent
  # state here (BU recorded per-item), keeping DynamoDB the single source of truth.
  lifecycle_table = module.lifecycle_store.table_name

  # Agent network posture (ADR-031) — resolved once at the root and threaded
  # into every agent pipeline so pipeline-deployed agents join the enterprise
  # VPC by default (PUBLIC only when no VPC resolves).
  agent_network_mode       = local.agent_effective_network_mode
  agent_subnet_ids         = local.private_subnet_ids
  agent_security_group_ids = local.agent_security_group_ids

  # ADR-033: bring-your-own pipeline service roles for the agent + integration
  # pipelines (empty => the pipeline modules create them).
  agent_pipeline_codebuild_role_arn          = var.agent_pipeline_codebuild_role_arn
  agent_pipeline_codepipeline_role_arn       = var.agent_pipeline_codepipeline_role_arn
  integration_pipeline_codebuild_role_arn    = var.integration_pipeline_codebuild_role_arn
  integration_pipeline_codepipeline_role_arn = var.integration_pipeline_codepipeline_role_arn
}

# ---------------------------------------------------------------------------
# Gateway — AgentCore Gateway (horizontal platform infra)
# The gateway itself is platform-owned. Teams add targets via their pipelines.
# ---------------------------------------------------------------------------
# ADR-033: created only when no pre-created ARN is supplied. When
# var.gateway_role_arn is set, the platform creates no role and uses it.
resource "aws_iam_role" "gateway" {
  count = var.gateway_role_arn == "" ? 1 : 0

  name = "eap-gateway-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

module "gateway" {
  source = "../eap-terraform-modules/modules/gateway"

  name        = "eap-shared"
  domain      = keys(var.domains)[0]
  description = "Shared enterprise gateway — tools accessed via MCP protocol"
  role_arn    = local.gateway_role_arn

  authorizer_type = "CUSTOM_JWT"
  jwt_authorizer_config = {
    discovery_url    = local.oidc_discovery_url
    allowed_audience = [local.oidc_audience]
    allowed_clients  = null
    allowed_scopes   = [local.oidc_audience]
  }

  targets = [] # Targets managed by integration pipeline, not platform

  # ADR-035: customer-managed KMS key (null => AWS-managed default).
  kms_key_arn = var.kms_key_arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Governance Pipeline — deploys Cedar policies from governance repo
# Governance team pushes .cedar files, pipeline runs terraform apply.
# ---------------------------------------------------------------------------
module "governance_pipeline" {
  source = "../eap-terraform-modules/modules/governance-pipeline"

  name                  = "governance"
  repository_name       = "governance"
  branch                = "main"
  platform_state_bucket = local.platform_state_bucket
  policy_engine_id      = module.gateway.policy_engine_id

  # ADR-033: bring-your-own pipeline service roles (empty => module creates).
  codebuild_role_arn    = var.governance_pipeline_codebuild_role_arn
  codepipeline_role_arn = var.governance_pipeline_codepipeline_role_arn

  tags = merge(var.tags, {
    eap_domain   = "governance"
    eap_pipeline = "governance"
  })
}

# ---------------------------------------------------------------------------
# Agent Deployment Engineer — platform-owned agent (built + deployed by default)
# It is a platform capability, not an app-team agent. The platform builds
# its image, provisions its runtime, and feeds the ARN to the invoke proxy.
# ---------------------------------------------------------------------------
module "studio" {
  source = "./studio"

  platform_gateway_url = module.gateway.url

  environment         = var.environment
  domain              = keys(var.domains)[0]
  aws_region          = var.aws_region
  account_id          = local.account_id
  ecr_repository_url  = module.ecr.repository_url
  ecr_repository_name = module.ecr.repository_name
  model_id            = var.allowed_models[0]
  build_image         = var.studio_build_image
  # The ADE image is published to ECR under this tag (the runtime already runs
  # its digest). The module default was renamed to agent-deployment-engineer-*
  # but the image was never retagged, so pin the tag that actually exists to
  # keep the data.aws_ecr_image lookup + runtime digest stable. Follow-up:
  # retag/rebuild under agent-deployment-engineer-latest, then drop this.
  image_tag = "agent-builder-studio-latest"

  # Agent network posture (ADR-031) — the platform-owned ADE runtime joins the
  # enterprise VPC by default (PUBLIC only when no VPC resolves).
  network_mode = local.agent_effective_network_mode
  vpc_config   = local.agent_vpc_config

  # ADR-033: bring-your-own runtime role ARN (empty => module creates it).
  runtime_role_arn = var.studio_runtime_role_arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Invoke Proxy — API Gateway + Lambda for browser-to-AgentCore agent invocation
# Defaults to the platform-owned Studio runtime (Build workspace chat target).
# ---------------------------------------------------------------------------
# Studio-Read Backend — read-only Backend_Services routes for the Console Build
# workspace (Deployed_Agents, Deployment_Status, Pattern_Resolver,
# Latest_Deployment, Gateway_Proxy, Agent_Card + config). Always-on ECS/Fargate
# service behind an ALB, self-validating the Cognito/OIDC JWT (no API Gateway
# authorizer). Replaces the studio-read Lambda + HTTP API path, so every console
# backend now runs on ALB/Fargate (same pattern as the ADE invoke backend).
#   * demo (deploy_console=true)  — internal ALB + CloudFront VPC origin, locked to the demo
#     CloudFront; the console routes /api/* to this ALB.
#   * enterprise (deploy_console=false) — INTERNAL ALB, VPC-only, for a BYO UI.
#
# Requirements: 12.1, 15.2, 15.3
# ---------------------------------------------------------------------------
module "studio_read_backend" {
  source                  = "./studio-read-backend"
  alb_deletion_protection = var.alb_deletion_protection

  # ADR-034: part of the demo console stack — created only when the console is
  # deployed. Its read routes back the console Build workspace and are reachable
  # only through the CloudFront /api/* path.
  count = var.deploy_console ? 1 : 0

  environment = var.environment
  aws_region  = var.aws_region
  account_id  = local.account_id

  # Demo fronts the ALB with the public CloudFront; enterprise keeps it internal.
  public_edge = var.deploy_console

  # Resolved network (platform-created or imported).
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  public_subnet_ids  = local.public_subnet_ids

  # Studio deploy pipeline + discovery scope (ADE deploy constants).
  deploy_domain        = "nocode-user"
  target_repo          = "nocode-user"
  studio_pipeline_name = "nocode-user-nocode-user-deploy-deploy"

  # AgentCore Gateway MCP endpoint the Gateway_Proxy forwards tools/list and
  # tools/call to (with the user's Bearer JWT).
  gateway_url = module.gateway.url

  # Auth (ADR-028): platform Cognito pool id, or the external OIDC issuer when
  # an external IdP is supplied. Exactly one is non-empty. The app client id +
  # domain are surfaced by GET /api/config for the SPA.
  cognito_user_pool_id  = local.cognito_user_pool_id
  oidc_issuer           = var.oidc_issuer
  cognito_app_client_id = local.console_client_id
  cognito_domain        = var.cognito_domain_prefix

  # Lifecycle DynamoDB store — single source of truth Deployed_Agents_Service
  # reads instead of reverse-engineering runtime names.
  lifecycle_table_name = module.lifecycle_store.table_name
  lifecycle_table_arn  = module.lifecycle_store.table_arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Console UI — S3 + CloudFront static site for the unified platform console
# ---------------------------------------------------------------------------
# Examples backend (ADR-037) — ALB→Fargate signer + WAF for the demo console
# Examples surface. Created only in the demo path (deploy_console). It generates
# the shared origin secret consumed by both the console distribution and the
# CloudFront-facing Langfuse ALB (ADR-038).
# ---------------------------------------------------------------------------
module "examples_console" {
  source                  = "./examples-console"
  alb_deletion_protection = var.alb_deletion_protection
  count                   = var.deploy_console ? 1 : 0

  environment        = var.environment
  aws_region         = var.aws_region
  account_id         = local.account_id
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  public_subnet_ids  = local.public_subnet_ids

  # ADR-046: caller auth (resolved OIDC, ADR-028) + lifecycle-table allow-list.
  cognito_user_pool_id  = local.cognito_user_pool_id
  cognito_app_client_id = local.console_client_id
  oidc_issuer           = var.oidc_issuer
  oidc_audience         = var.oidc_audience
  lifecycle_table_name  = module.lifecycle_store.table_name
  lifecycle_table_arn   = module.lifecycle_store.table_arn

  # ADR-039: when Langfuse is deployed, give it its OWN hardened CloudFront
  # (root origin — no subpath). This module owns the WAF + origin secret and the
  # Langfuse ALB is already CloudFront-facing (ADR-038 lockdown retained).
  langfuse_alb_dns         = local.deploy_langfuse ? module.langfuse[0].alb_dns_name : ""
  langfuse_vpc_origin_id   = local.deploy_langfuse ? module.langfuse[0].vpc_origin_id : ""
  langfuse_web_port        = 3000
  access_log_bucket_domain = local.cloudfront_log_bucket_domain

  tags = var.tags
}

# ---------------------------------------------------------------------------
module "console" {
  source = "./console"

  # ADR-034: the bundled demo console (S3 + CloudFront SPA). Created only when
  # deploy_console is true. Enterprises hosting their own UI internally set
  # deploy_console=false to remove all public ingress.
  count = var.deploy_console ? 1 : 0

  environment = var.environment
  # OIDC config the console SPA uses for login. Cognito path: derived pool/client.
  # External-IdP path: pool/client empty; the console build should be pointed at
  # the external IdP via its own VITE_* config (follow-up, see ADR-028).
  cognito_user_pool_id         = local.cognito_user_pool_id
  cognito_app_client_id        = local.console_client_id
  create_cognito_identity_pool = local.create_cognito
  cognito_domain_prefix        = var.cognito_domain_prefix
  aws_region                   = var.aws_region
  account_id                   = local.account_id

  # ADR-033: bring-your-own authenticated console role ARN (empty => created).
  authenticated_role_arn = var.console_authenticated_role_arn

  # Read routes (/api/*): the studio-read backend ALB, locked to CloudFront via
  # its own origin secret (same pattern as the examples + ADE backends). In demo
  # the backend runs public_edge=true, exposing a CloudFront-facing ALB DNS +
  # secret here. studio_read_backend is gated by the same deploy_console flag,
  # so it is present ([0]) whenever this module is.
  studio_read_backend_alb_dns      = module.studio_read_backend[0].alb_dns_name
  studio_read_origin_secret_header = module.studio_read_backend[0].origin_secret_header_name
  studio_read_origin_secret_value  = module.studio_read_backend[0].origin_secret_value
  studio_read_vpc_origin_id        = module.studio_read_backend[0].vpc_origin_id

  # Embedded-Langfuse iframe origin. ADR-039 (supersedes ADR-038 subpath): when
  # Langfuse is deployed it gets its OWN hardened CloudFront (root origin), and
  # the console embeds that ABSOLUTE URL. Langfuse serves at root — no subpath
  # rewriting. Empty when Langfuse is off (ObservabilityWorkspace degrades).
  langfuse_embed_origin = local.deploy_langfuse ? "https://${module.examples_console[0].langfuse_cloudfront_domain}" : ""

  # ADR-037: hardened C2 — add the examples ALB origin (/examples-api/*), attach
  # the WAF, and inject the shared origin secret. examples_console is gated by
  # the same deploy_console flag, so it is present ([0]) whenever this module is.
  examples_backend_alb_dns      = module.examples_console[0].alb_dns_name
  examples_origin_secret_header = module.examples_console[0].origin_secret_header_name
  examples_origin_secret_value  = module.examples_console[0].origin_secret_value
  examples_waf_web_acl_arn      = module.examples_console[0].waf_web_acl_arn
  examples_vpc_origin_id        = module.examples_console[0].vpc_origin_id

  # ADR-040: add the ADE streaming invoke backend ALB origin (/ade-api/*),
  # locked to CloudFront via the ADE backend's own origin secret. In demo the
  # ADE backend runs with public_edge=true, so it exposes a CloudFront-facing
  # ALB DNS + secret here; the Build-workspace chat streams through this edge.
  ade_backend_alb_dns      = module.ade_invoke_backend.alb_dns_name
  ade_origin_secret_header = module.ade_invoke_backend.origin_secret_header_name
  ade_origin_secret_value  = module.ade_invoke_backend.origin_secret_value
  ade_vpc_origin_id        = module.ade_invoke_backend.vpc_origin_id

  access_log_bucket_domain = local.cloudfront_log_bucket_domain

  tags = var.tags
}

# ---------------------------------------------------------------------------
# ADE Invoke Backend (ADR-040) — always-on ECS/Fargate service that STREAMS the
# Agent Deployment Engineer console chat turn (A2A message/stream), with
# Cognito/OIDC JWT auth + the Requirement-11 runtime allow-list enforced
# in-service. Unlike the invoke-proxy Lambda (API Gateway REST → buffered), this
# path streams token-by-token. Deployed in BOTH presets:
#   * demo (deploy_console=true)  — internal ALB + CloudFront VPC origin, locked to the demo
#     CloudFront (public_edge=true); the console adds an /ade-api/* behavior.
#   * enterprise (deploy_console=false) — INTERNAL ALB (public_edge=false),
#     VPC-only, reached by the customer's BYO UI. No public edge.
# NOTE (ADR-040 consequences): this is always-on Fargate + an ALB, so it adds
# standing cost — see the FinOps section of the runbook.
# ---------------------------------------------------------------------------
module "ade_invoke_backend" {
  source                  = "./ade-invoke-backend"
  alb_deletion_protection = var.alb_deletion_protection

  environment = var.environment
  aws_region  = var.aws_region
  account_id  = local.account_id

  # Demo fronts the ALB with the public CloudFront; enterprise keeps it internal.
  public_edge = var.deploy_console

  # Resolved network (platform-created or imported).
  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids
  public_subnet_ids  = local.public_subnet_ids

  # Auth (ADR-028): platform Cognito pool id, or the external OIDC issuer when
  # an external IdP is supplied. Exactly one is non-empty.
  cognito_user_pool_id = local.cognito_user_pool_id
  oidc_issuer          = var.oidc_issuer

  # Requirement-11 allow-list source (single source of truth, ADR-026).
  lifecycle_table_name = module.lifecycle_store.table_name
  lifecycle_table_arn  = module.lifecycle_store.table_arn

  # Default target when the caller sends no runtimeArn: the platform-owned ADE.
  ade_runtime_arn        = module.studio.runtime_arn
  ade_endpoint_qualifier = module.studio.endpoint_qualifier

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Platform VPC ("eap") — network for the third-party observability leg
# (OTel Collector + optional Langfuse). The AWS-native leg needs no VPC.
#
# Import-or-create (ADR-030): created ONLY when no vpc_id is supplied. Provides
# full egress (IGW + NAT gateway + private route tables) so in-VPC Fargate tasks
# can pull images from ECR and reach AWS APIs. When a vpc_id is supplied, this
# module is skipped and the deployer's VPC + subnets are used instead.
# ---------------------------------------------------------------------------
module "vpc" {
  source = "./vpc"
  count  = local.create_vpc ? 1 : 0

  name        = "eap"
  environment = var.environment
  tags        = var.tags
}

# ---------------------------------------------------------------------------
# Lifecycle Store — DynamoDB table for Agent School state tracking
# ---------------------------------------------------------------------------
module "lifecycle_store" {
  source = "./lifecycle-store"

  environment = var.environment
  domain      = keys(var.domains)[0]

  # ADR-035: customer-managed KMS key (null => AWS-managed aws/dynamodb key).
  kms_key_arn = var.kms_key_arn
}

# ---------------------------------------------------------------------------
# Post-MVP — uncomment when implemented
# ---------------------------------------------------------------------------
# module "config_rules" {
#   source      = "./config-rules"
#   environment = var.environment
#   tags        = var.tags
# }

# module "scps" {
#   source      = "./scps"
#   environment = var.environment
# }

# module "iam_access_analyzer" {
#   source      = "./iam-access-analyzer"
#   environment = var.environment
# }

# ---------------------------------------------------------------------------
# QA Pipelines — per-domain QA evaluation pipelines (qa-{bu} repos)
# QA teams push evaluator definitions, ground truth, and red-team prompts.
# Pipeline validates, provisions AgentCore evaluators, and registers in state store.
# ---------------------------------------------------------------------------
module "qa_pipelines" {
  source   = "../eap-terraform-modules/modules/qa-pipeline"
  for_each = var.qa_pipelines

  name                  = each.key
  domain                = each.value.domain
  repository_name       = each.value.repository_name
  branch                = each.value.branch
  platform_state_bucket = local.platform_state_bucket
  platform_state_table  = each.value.platform_state_table
  ground_truth_bucket   = each.value.ground_truth_bucket
  environment           = var.environment

  # ADR-033: bring-your-own pipeline service roles (empty => module creates).
  codebuild_role_arn    = var.qa_pipeline_codebuild_role_arn
  codepipeline_role_arn = var.qa_pipeline_codepipeline_role_arn

  tags = merge(var.tags, {
    eap_domain   = each.value.domain
    eap_pipeline = "qa-evaluation"
  })
}

# ---------------------------------------------------------------------------
# KB Pipelines — per-domain Knowledge Base pipelines (kb-{bu} repos)
# GenAI Data Engineers push KB configurations, pipeline validates,
# provisions Bedrock KBs, and registers them on the Gateway.
# ---------------------------------------------------------------------------
module "kb_pipelines" {
  source   = "../eap-terraform-modules/modules/kb-pipeline"
  for_each = var.kb_pipelines

  name                  = each.key
  domain                = each.value.domain
  repository_name       = each.value.repository_name
  branch                = each.value.branch
  platform_state_bucket = local.platform_state_bucket
  gateway_id            = module.gateway.id
  policy_engine_id      = module.gateway.policy_engine_id
  environment           = var.environment

  # ADR-033: bring-your-own pipeline service roles (empty => module creates).
  codebuild_role_arn    = var.kb_pipeline_codebuild_role_arn
  codepipeline_role_arn = var.kb_pipeline_codepipeline_role_arn

  tags = merge(var.tags, {
    eap_domain   = each.value.domain
    eap_pipeline = "knowledge-base"
  })
}
