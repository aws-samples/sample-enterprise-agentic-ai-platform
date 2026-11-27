# EAP Deploy Template — Auto-provisions agents from agent.yaml
# This config is used by the pipeline's Deploy stage (CodeBuild).
# It discovers all agent.yaml manifests via fileset() and provisions
# AgentCore runtimes using the eap runtime module.
#
# Hierarchy: BU → Architecture Pattern → Application → Agent(s)
# - Standalone agents: agent folder = application (agent.yaml is sufficient)
# - Multi-agent apps: application.yaml defines topology, agents in subfolders
#
# Cognito app clients are created per application (user auth only).
# A2A communication is routed via AgentCore Gateway, not Cognito.
#
# All values are injected via TF_VAR_ environment variables from CodeBuild.
# App teams write YAML — this Terraform is platform-owned.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.37.0"
    }
  }

  # Backend configured dynamically via -backend-config in deploy buildspec.
  # State stored in the pipeline artifacts bucket under _tfstate/ prefix.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Content-driven discovery — folder names don't matter.
# Routing logic: application.yaml present = multi-agent app,
#                agent.yaml without sibling application.yaml = standalone agent.
# Scans all */*/ directories. Teams can use any folder naming convention.
# ---------------------------------------------------------------------------
locals {
  # --- Standalone agent discovery ---
  # Find all agent.yaml files, then exclude those inside multi-agent apps
  # (where a sibling or parent application.yaml exists)
  all_agent_yamls = toset(fileset(".", "**/agent.yaml"))
  all_app_yamls   = toset(fileset(".", "**/application.yaml"))

  # Directories that contain application.yaml (multi-agent app roots)
  app_root_dirs = toset([for f in local.all_app_yamls : dirname(f)])

  # Standalone agents: agent.yaml whose parent dir is NOT inside an app root
  # i.e., no application.yaml exists in the same dir or parent dir
  standalone_agent_yamls = toset([
    for f in local.all_agent_yamls : f
    if !contains(local.app_root_dirs, dirname(f)) &&
    !contains(local.app_root_dirs, dirname(dirname(f)))
  ])

  agent_dirs = toset([for f in local.standalone_agent_yamls : dirname(f)])

  agents = {
    for dir in local.agent_dirs : dir => merge(
      yamldecode(file("${dir}/agent.yaml")),
      {
        dir_name    = dir
        description = try(yamldecode(file("${dir}/agent-card.yaml")).description, "")
      }
    )
  }

  # Re-key by agent name for for_each
  agents_by_name = {
    for dir, agent in local.agents : agent.name => merge(agent, { dir_path = dir })
  }

  # Safe name for Terraform resource naming (underscores, no hyphens)
  agent_safe_names = {
    for name, agent in local.agents_by_name : name => replace(name, "-", "_")
  }

  # Map agent name → dir for cross-referencing
  name_to_dir = { for dir, agent in local.agents : agent.name => dir }

  # Collect all unique model IDs across agents (for IAM policy)
  all_model_ids = toset([
    for name, agent in local.agents_by_name : try(agent.model_id, var.model_id)
  ])

  # Agents that declare memory: in agent.yaml
  agents_with_memory = {
    for name, agent in local.agents_by_name : name => agent
    if try(agent.memory, null) != null
  }

  # Agents that declare evaluations: in agent.yaml
  agents_with_evaluations = {
    for name, agent in local.agents_by_name : name => agent
    if try(agent.evaluations, null) != null
  }

  # Agents that declare gateway_refs: in agent.yaml (stubbed — requires data-services)
  agents_with_gateway = {
    for name, agent in local.agents_by_name : name => agent
    if length(try(agent.gateway_refs, [])) > 0
  }

  # --- Agent School: OIDC authorizer config ---
  # When oidc_discovery_url is set, build an authorizer config for all runtimes.
  # This makes the platform IdP-agnostic — swap identity providers by changing one variable.
  oidc_authorizer_config = var.oidc_discovery_url != "" ? {
    discovery_url    = var.oidc_discovery_url
    allowed_audience = toset([])
    allowed_clients  = toset([])
    allowed_scopes   = null
  } : null

  # Enable auth when an OIDC URL is provided
  enable_runtime_auth = var.oidc_discovery_url != ""

  # Agent network posture (ADR-031). VPC mode only takes effect when subnets are
  # actually supplied; otherwise fall back to PUBLIC. vpc_config is null in
  # PUBLIC mode so the runtime module omits the network_mode_config block.
  agent_vpc_mode = var.agent_network_mode == "VPC" && length(var.agent_subnet_ids) > 0
  agent_net_mode = local.agent_vpc_mode ? "VPC" : "PUBLIC"
  agent_vpc_config = local.agent_vpc_mode ? {
    security_groups = var.agent_security_group_ids
    subnets         = var.agent_subnet_ids
  } : null

  # ADR-032: the SFN→AgentCore bridge Lambda also runs in-VPC when VPC mode is
  # in effect, so its InvokeAgentRuntime call resolves via the PrivateLink
  # endpoint. Lambda vpc_config uses subnet_ids/security_group_ids (distinct
  # attribute names from the runtime block). Null in PUBLIC mode.
  lambda_vpc_config = local.agent_vpc_mode ? {
    subnet_ids         = var.agent_subnet_ids
    security_group_ids = var.agent_security_group_ids
  } : null
}

# ---------------------------------------------------------------------------
# Multi-agent application discovery — content-driven.
# Any directory with application.yaml is a multi-agent app, regardless of
# parent folder name. Parses topology, flattens agents.
# Requirements: R30.1, R30.2, R30.3, R30.4, R30.9
# ---------------------------------------------------------------------------
locals {
  # Parse each application.yaml
  applications = {
    for dir in local.app_root_dirs : dir => merge(
      yamldecode(file("${dir}/application.yaml")),
      { dir_path = dir }
    )
  }

  # Re-key by application name
  apps_by_name = {
    for dir, app in local.applications : app.name => merge(app, { dir_path = dir })
  }

  # Detect duplicate application names — two application.yaml files declaring
  # the same name: would silently overwrite each other in apps_by_name.
  # Group by name and flag any with count > 1.
  _app_name_counts = {
    for dir, app in local.applications : app.name => dir...
  }
  _duplicate_app_names = [
    for name, dirs in local._app_name_counts : "${name} (in: ${join(", ", dirs)})"
    if length(dirs) > 1
  ]

  # Flatten all agents from all applications into a single map
  # Key: "{app_name}/{agent_name}" to avoid collisions across apps
  app_agents_list = flatten([
    for app_name, app in local.apps_by_name : [
      for agent in try(app.agents, app.steps, []) : {
        app_name      = app_name
        agent_name    = agent.name
        app_dir       = app.dir_path
        agent_dir     = "${app.dir_path}/${agent.name}"
        agent_yaml    = try(yamldecode(file("${app.dir_path}/${agent.name}/agent.yaml")), {})
        topology      = agent
        orchestration = try(app.orchestration, "none")
        architecture  = app.architecture
      }
    ]
  ])

  app_agents = {
    for a in local.app_agents_list :
    "${a.app_name}/${a.agent_name}" => a
  }

  # Runtime naming: {domain}_{app_name}_{agent_name} (hyphens → underscores)
  # AgentCore enforces max 48 chars on both runtime and endpoint names.
  # Endpoint name = runtime_name + "_endpoint" (9 chars), so max runtime name = 39.
  app_agent_runtime_names = {
    for key, a in local.app_agents :
    key => substr(replace("${var.domain}_${a.app_name}_${a.agent_name}", "-", "_"), 0, 39)
  }

  # Step Functions applications — need ASL generation
  sfn_apps = {
    for name, app in local.apps_by_name : name => app
    if try(app.orchestration, "none") == "step-functions"
  }

  # A2A mesh applications — need env var injection
  a2a_apps = {
    for name, app in local.apps_by_name : name => app
    if try(app.orchestration, "none") == "a2a"
  }

  # Multi-agent agents that declare memory
  app_agents_with_memory = {
    for key, a in local.app_agents : key => a
    if try(a.agent_yaml.memory, null) != null
  }

  # Multi-agent agents that declare evaluations
  app_agents_with_evaluations = {
    for key, a in local.app_agents : key => a
    if try(a.agent_yaml.evaluations, null) != null
  }
}

# ---------------------------------------------------------------------------
# Validation — fail fast on duplicate application or agent names
# ---------------------------------------------------------------------------
check "no_duplicate_app_names" {
  assert {
    condition     = length(local._duplicate_app_names) == 0
    error_message = "Duplicate application names detected — each application.yaml must have a unique name: within a domain. Duplicates: ${join("; ", local._duplicate_app_names)}"
  }
}

# ---------------------------------------------------------------------------
# IAM Role — shared by all agent runtimes in this domain
# TODO: Replace AdministratorAccess with least-privilege managed policy.
#       Current blockers: model ID ARN patterns, AgentCore-specific permissions
#       not yet fully documented.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "runtime_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.domain}-runtime-role"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
}

# Memory ARNs created by this template (standalone + multi-agent).
locals {
  runtime_memory_arns = concat(
    [for m in module.memory : m.arn],
    [for m in module.app_memory : m.arn]
  )
}
resource "aws_iam_role_policy" "runtime" {
  name = "${var.domain}-runtime-policy"
  role = aws_iam_role.runtime.id

  # AWS-documented least-privilege execution role for AgentCore Runtime.
  # Reference: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ECRImageAccess"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/*"]
      },
      {
        Sid      = "ECRTokenAccess"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "LogsCreateGroup"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:CreateLogGroup"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"]
      },
      {
        Sid      = "LogsDescribeGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:*"]
      },
      {
        Sid      = "LogsWriteEvents"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"]
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = ["*"]
      },
      {
        Sid       = "CloudWatchMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" } }
      },
      {
        Sid    = "WorkloadIdentityTokens"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/*"
        ]
      },
      {
        Sid    = "BedrockModelInvocation"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
        ]
      },
      ],
      # AgentCore Memory data-plane access, scoped to the memories this template
      # creates (module.memory + module.app_memory). Actions are the calls made by
      # the Strands AgentCoreMemorySessionManager (bedrock-agentcore SDK).
      # Statement omitted when no agent declares memory: (IAM rejects an empty
      # Resource list).
      length(local.runtime_memory_arns) > 0 ? [
        {
          Sid    = "AgentCoreMemory"
          Effect = "Allow"
          Action = [
            "bedrock-agentcore:CreateEvent",
            "bedrock-agentcore:GetEvent",
            "bedrock-agentcore:ListEvents",
            "bedrock-agentcore:DeleteEvent",
            "bedrock-agentcore:RetrieveMemoryRecords"
          ]
          Resource = local.runtime_memory_arns
        }
      ] : [],
      [
        {
          Sid    = "AgentCoreInvokePeers"
          Effect = "Allow"
          Action = ["bedrock-agentcore:InvokeAgentRuntime"]
          Resource = [
            "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:runtime/*",
            "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:runtime/*/runtime-endpoint/*"
          ]
        },
        {
          # ListAgentRuntimes has no resource type in the Service Authorization
          # Reference; the API requires Resource "*". Used by agents to resolve
          # peer runtime ARNs from the injected *_RUNTIME_NAME env vars.
          Sid      = "AgentCoreListRuntimes"
          Effect   = "Allow"
          Action   = ["bedrock-agentcore:ListAgentRuntimes"]
          Resource = ["*"]
        },
        {
          Sid    = "CodeCommitForStudio"
          Effect = "Allow"
          Action = [
            "codecommit:GetBranch",
            "codecommit:CreateCommit",
            "codecommit:GetRepository",
            "codecommit:GitPull"
          ]
          Resource = ["arn:aws:codecommit:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:nocode-user"]
        },
        {
          Sid      = "CodePipelineForStudio"
          Effect   = "Allow"
          Action   = ["codepipeline:GetPipelineExecution", "codepipeline:GetPipelineState", "codepipeline:ListPipelineExecutions"]
          Resource = ["arn:aws:codepipeline:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:nocode-user-*"]
        },
        {
          # Third-party observability leg (agentcore-observability, task 15.2):
          # the base image resolves the OTel_Collector endpoint from this single
          # SSM parameter at boot. Scoped to EXACTLY that parameter ARN — no
          # wildcard. Additive third-party leg only; grants no CloudWatch/X-Ray
          # write and cannot affect the AWS-native leg.
          Sid      = "OtelCollectorEndpointSsmRead"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter"]
          Resource = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/eap/observability/collector-endpoint"]
        }
    ])
  })
}

# ---------------------------------------------------------------------------
# Per-Application Cognito App Client (User Authentication Only)
# ---------------------------------------------------------------------------
# Each standalone agent gets its own Cognito app client for user→agent auth.
# Multi-agent apps (supervisor, workflow) will get app clients when
# application.yaml processing is implemented.
# A2A communication is routed via AgentCore Gateway, not Cognito.
# See: docs/adr/017-identity-architecture.md, docs/adr/018-platform-vending-model.md
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "app" {
  for_each = local.agents_by_name

  name         = "${var.domain}-${each.key}"
  user_pool_id = var.cognito_user_pool_id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]

  # OAuth flows for gateway scope-based access
  # Convention: callback URL derived from agent name + domain
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["implicit"]
  allowed_oauth_scopes                 = ["openid", "gateway/tools.invoke", "gateway/tools.read", "agent/invoke"]
  callback_urls = [
    "https://${each.key}.${var.domain}.platform.example.com/auth/callback",
    "http://localhost:5175/auth/callback",
    "http://localhost:5178/auth/callback"
  ]
  supported_identity_providers = ["COGNITO"]
}

# ---------------------------------------------------------------------------
# Agent Runtimes — one per agent, using the eap runtime module
# ---------------------------------------------------------------------------
module "runtime" {
  source   = "./runtime"
  for_each = local.agents_by_name

  name        = replace("${var.domain}_${each.key}", "-", "_")
  domain      = var.domain
  description = each.value.description
  framework   = try(each.value.framework, "strands")
  protocols   = try(each.value.protocols, ["a2a"])
  role_arn    = aws_iam_role.runtime.arn
  model_id    = try(each.value.model_id, var.model_id)

  container_image = "${var.ecr_repo_url}:${each.key}-latest"

  # Auth disabled — A2A routed via Gateway, not Cognito M2M.
  # JWT authorizer retained for user→agent auth only (Layer 1).
  # See: docs/adr/017-identity-architecture.md (Layer 3 decision, 2026-03-30)
  # When oidc_discovery_url is set, auth is enabled with IdP-agnostic JWT validation.
  enable_auth       = local.enable_runtime_auth
  authorizer_config = local.oidc_authorizer_config

  # Network posture (ADR-031) — VPC-mode ENIs in the enterprise private subnets
  # when the pipeline injects a VPC posture; PUBLIC otherwise.
  network_mode = local.agent_net_mode
  vpc_config   = local.agent_vpc_config

  extra_environment_variables = merge(
    # Inject memory ID for agents that declare memory: in agent.yaml
    try(each.value.memory, null) != null ? {
      AGENTCORE_MEMORY_ID = module.memory[each.key].id
    } : {},
    # Inject callee runtime names — agents resolve endpoints at runtime via AgentCore API.
    # Using names instead of endpoint ARNs avoids a Terraform cycle (runtime A env vars →
    # runtime B endpoint → runtime B resource → runtime B env vars → ...).
    {
      for callee_name in try(each.value.calls, []) :
      "${upper(replace(callee_name, "-", "_"))}_RUNTIME_NAME" =>
      replace("${var.domain}_${callee_name}", "-", "_")
    }
  )
}

# ---------------------------------------------------------------------------
# Agent Memory — one per agent that declares memory: in agent.yaml
# ---------------------------------------------------------------------------
module "memory" {
  source   = "./memory"
  for_each = local.agents_with_memory

  name        = replace("${var.domain}_${each.key}_memory", "-", "_")
  domain      = var.domain
  description = "Memory for ${each.key} in domain ${var.domain}"
  memory_type = try(each.value.memory.type, "long-term")
  retention   = try(each.value.memory.retention, "90d")
}

# ---------------------------------------------------------------------------
# Agent Evaluations — one per agent that declares evaluations: in agent.yaml
# Stores eval config in SSM + creates CloudWatch schedule.
# ---------------------------------------------------------------------------
module "evaluations" {
  source   = "./evaluations"
  for_each = local.agents_with_evaluations

  name       = replace("${var.domain}_${each.key}_eval", "-", "_")
  domain     = var.domain
  runtime_id = module.runtime[each.key].id

  evaluators = [
    for e in try(each.value.evaluations.evaluators, ["correctness", "helpfulness", "safety"]) : {
      name      = e
      threshold = try(each.value.evaluations.thresholds[e], null)
      enabled   = true
    }
  ]
}

# ---------------------------------------------------------------------------
# Gateway Refs — STUBBED (requires eap-data-services, post-MVP)
# Agents that declare gateway_refs: in agent.yaml will get gateway connectivity
# once the data-services repo provisions MCP server gateways.
# ---------------------------------------------------------------------------
# TODO: Wire up gateway module when eap-data-services is available.
# Agents with gateway_refs: ${jsonencode(keys(local.agents_with_gateway))}
# Each agent.yaml can declare:
#   gateway_refs:
#     - mcp_servers: [snowflake-warehouse, sharepoint-docs]
# The deploy-template will resolve gateway IDs and pass them to the runtime module.

# ===========================================================================
# MULTI-AGENT APPLICATION RESOURCES
# Provisions runtimes, memory, evaluations for agents discovered from
# application.yaml manifests (supervisor, sequential-workflow, parallel,
# router, swarm patterns). Standalone agents above remain untouched.
# Requirements: R30.3, R30.5, R30.6, R30.9, R33.1, R33.7, R33.8, R35.5
# ===========================================================================

# ---------------------------------------------------------------------------
# Multi-Agent Runtimes — one per agent in each application
# ---------------------------------------------------------------------------
module "app_runtime" {
  source   = "./runtime"
  for_each = local.app_agents

  name        = local.app_agent_runtime_names[each.key]
  domain      = var.domain
  description = coalesce(try(each.value.agent_yaml.description, ""), try(each.value.topology.description, ""), "${each.value.agent_name} agent in ${each.value.app_name}")
  framework   = try(each.value.agent_yaml.framework, "strands")
  protocols   = try(each.value.agent_yaml.protocols, ["a2a"])
  role_arn    = aws_iam_role.runtime.arn
  model_id    = try(each.value.agent_yaml.model_id, var.model_id)

  container_image = "${var.ecr_repo_url}:${each.value.app_name}-${each.value.agent_name}-latest"

  enable_auth       = local.enable_runtime_auth
  authorizer_config = local.oidc_authorizer_config

  # Network posture (ADR-031) — same VPC/PUBLIC resolution as standalone agents.
  network_mode = local.agent_net_mode
  vpc_config   = local.agent_vpc_config

  extra_environment_variables = merge(
    # Force container restart on every deploy (workaround for :latest tag caching)
    {
      DEPLOY_TIMESTAMP = timestamp()
    },
    # Memory ID injection (conditional — only if agent declares memory: in agent.yaml)
    try(each.value.agent_yaml.memory, null) != null ? {
      AGENTCORE_MEMORY_ID = module.app_memory[each.key].id
    } : {},
    # Application-level metadata — always present
    {
      APPLICATION_NAME   = each.value.app_name
      ORCHESTRATION_MODE = each.value.orchestration
    },
    # A2A mesh env vars (swarm/choreography pattern — can_call peers)
    # Inject runtime name — entrypoint resolves full ARN at startup via AgentCore API
    (each.value.orchestration == "a2a" || try(each.value.architecture, "") == "swarm") ? {
      for peer_name in try(each.value.topology.can_call, []) :
      "${upper(replace(peer_name, "-", "_"))}_RUNTIME_NAME" =>
      replace("${var.domain}_${each.value.app_name}_${peer_name}", "-", "_")
    } : {},
    # Step Functions callee runtime names (supervisor/sequential/router)
    each.value.orchestration == "step-functions" ? {
      for callee_name in try(each.value.topology.calls, []) :
      "${upper(replace(callee_name, "-", "_"))}_RUNTIME_NAME" =>
      replace("${var.domain}_${each.value.app_name}_${callee_name}", "-", "_")
    } : {},
    # Cognito app client ID (shared per application, not per agent)
    {
      COGNITO_APP_CLIENT_ID = aws_cognito_user_pool_client.multi_agent_app[each.value.app_name].id
    }
  )
}

# ---------------------------------------------------------------------------
# Multi-Agent Memory — one per agent that declares memory: in agent.yaml
# ---------------------------------------------------------------------------
module "app_memory" {
  source   = "./memory"
  for_each = local.app_agents_with_memory

  name        = substr(replace("${var.domain}_${each.value.app_name}_${each.value.agent_name}_mem", "-", "_"), 0, 39)
  domain      = var.domain
  description = "Memory for ${each.value.agent_name} in app ${each.value.app_name}, domain ${var.domain}"
  memory_type = try(each.value.agent_yaml.memory.type, "long-term")
  retention   = try(each.value.agent_yaml.memory.retention, "90d")
}

# ---------------------------------------------------------------------------
# Multi-Agent Evaluations — one per agent that declares evaluations:
# ---------------------------------------------------------------------------
module "app_evaluations" {
  source   = "./evaluations"
  for_each = local.app_agents_with_evaluations

  name       = substr(replace("${var.domain}_${each.value.app_name}_${each.value.agent_name}_eval", "-", "_"), 0, 39)
  domain     = var.domain
  runtime_id = module.app_runtime[each.key].id

  evaluators = [
    for e in try(each.value.agent_yaml.evaluations.evaluators, ["correctness", "helpfulness", "safety"]) : {
      name      = e
      threshold = try(each.value.agent_yaml.evaluations.thresholds[e], null)
      enabled   = true
    }
  ]
}

# ===========================================================================
# ASL GENERATION — Step Functions state machine definitions
# Each architecture pattern has its own ASL generation logic.
# Generated ASL is passed to the orchestration module's `definition` variable.
# Requirements: R32.1–R32.12
# ===========================================================================

locals {
  # Lambda bridge ARN for SFN → AgentCore invocation (TEMPORARY)
  bridge_lambda_arn = length(local.sfn_apps) > 0 ? aws_lambda_function.invoke_bridge[0].arn : ""

  # ---------------------------------------------------------------------------
  # Sequential Workflow ASL — linear chain from steps order
  # Each step invokes an AgentCore Runtime, chained via Next/End.
  # Requirements: R32.1, R32.5, R32.6, R32.7, R32.8, R32.10, R32.12
  # ---------------------------------------------------------------------------
  sequential_asl = {
    for app_name, app in local.sfn_apps : app_name => jsonencode({
      Comment = "Sequential workflow: ${app_name}"
      StartAt = try(app.steps[0].name, app.agents[0].name)
      States = merge(
        {
          for i, step in try(app.steps, app.agents) : step.name => merge(
            {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                "FunctionName" = local.bridge_lambda_arn
                "Payload" = {
                  "AgentRuntimeEndpointArn" = module.app_runtime["${app_name}/${step.name}"].endpoint_arn
                  "Payload.$"               = "$"
                }
              }
              TimeoutSeconds = try(step.timeout, 300)
              Retry = [{
                ErrorEquals     = ["States.TaskFailed", "States.Timeout"]
                IntervalSeconds = 2
                MaxAttempts     = 2
                BackoffRate     = 2.0
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                Next        = "${step.name}_failed"
                ResultPath  = "$.error"
              }]
            },
            # Last step ends the state machine; others chain to next
            i < length(try(app.steps, app.agents)) - 1 ? {
              Next = try(app.steps, app.agents)[i + 1].name
            } : { End = true }
          )
        },
        # Failure handler states — one per step
        {
          for step in try(app.steps, app.agents) : "${step.name}_failed" => {
            Type  = "Fail"
            Error = "${step.name}Failed"
            Cause = "Agent ${step.name} failed in application ${app_name}"
          }
        }
      )
    })
    if app.architecture == "sequential-workflow"
  }

  # ---------------------------------------------------------------------------
  # Supervisor ASL — orchestrator dispatch → Parallel(workers) → aggregation
  # Requirements: R32.2, R32.5, R32.6, R32.7, R32.8, R32.10, R32.12
  # ---------------------------------------------------------------------------
  supervisor_asl = {
    for app_name, app in local.sfn_apps : app_name => jsonencode({
      Comment = "Supervisor: ${app_name}"
      StartAt = "orchestrator_dispatch"
      States = {
        orchestrator_dispatch = {
          Type     = "Task"
          Resource = "arn:aws:states:::lambda:invoke"
          Parameters = {
            "FunctionName" = local.bridge_lambda_arn
            "Payload" = {
              "AgentRuntimeEndpointArn" = module.app_runtime[
                "${app_name}/${[for a in app.agents : a.name if a.role == "orchestrator"][0]}"
              ].endpoint_arn
              "Payload.$" = "$"
            }
          }
          TimeoutSeconds = 300
          Retry = [{
            ErrorEquals     = ["States.TaskFailed", "States.Timeout"]
            IntervalSeconds = 2
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }]
          Catch = [{
            ErrorEquals = ["States.ALL"]
            Next        = "execution_failed"
            ResultPath  = "$.error"
          }]
          Next = "parallel_workers"
        }
        parallel_workers = {
          Type = "Parallel"
          Branches = [
            for a in app.agents : {
              StartAt = a.name
              States = {
                (a.name) = {
                  Type     = "Task"
                  Resource = "arn:aws:states:::lambda:invoke"
                  Parameters = {
                    "FunctionName" = local.bridge_lambda_arn
                    "Payload" = {
                      "AgentRuntimeEndpointArn" = module.app_runtime["${app_name}/${a.name}"].endpoint_arn
                      "Payload.$"               = "$"
                    }
                  }
                  TimeoutSeconds = try(a.timeout, 300)
                  Retry = [{
                    ErrorEquals     = ["States.TaskFailed", "States.Timeout"]
                    IntervalSeconds = 2
                    MaxAttempts     = 2
                    BackoffRate     = 2.0
                  }]
                  End = true
                }
              }
            }
            if a.role == "worker"
          ]
          Catch = [{
            ErrorEquals = ["States.ALL"]
            Next        = "execution_failed"
            ResultPath  = "$.error"
          }]
          Next = "orchestrator_aggregate"
        }
        orchestrator_aggregate = {
          Type     = "Task"
          Resource = "arn:aws:states:::lambda:invoke"
          Parameters = {
            "FunctionName" = local.bridge_lambda_arn
            "Payload" = {
              "AgentRuntimeEndpointArn" = module.app_runtime[
                "${app_name}/${[for a in app.agents : a.name if a.role == "orchestrator"][0]}"
              ].endpoint_arn
              "Payload.$" = "$"
            }
          }
          TimeoutSeconds = 300
          End            = true
        }
        execution_failed = {
          Type  = "Fail"
          Error = "ExecutionFailed"
          Cause = "Supervisor application ${app_name} failed"
        }
      }
    })
    if app.architecture == "supervisor"
  }

  # ---------------------------------------------------------------------------
  # Router ASL — classifier → Choice → handler tasks
  # Requirements: R32.4, R32.5, R32.6, R32.7, R32.8, R32.10, R32.12
  # ---------------------------------------------------------------------------
  router_asl = {
    for app_name, app in local.sfn_apps : app_name => jsonencode({
      Comment = "Router: ${app_name}"
      StartAt = "classify"
      States = merge(
        {
          classify = {
            Type     = "Task"
            Resource = "arn:aws:states:::lambda:invoke"
            Parameters = {
              "FunctionName" = local.bridge_lambda_arn
              "Payload" = {
                "AgentRuntimeEndpointArn" = module.app_runtime[
                  "${app_name}/${[for a in app.agents : a.name if a.role == "classifier"][0]}"
                ].endpoint_arn
                "Payload.$" = "$"
              }
            }
            TimeoutSeconds = 300
            Retry = [{
              ErrorEquals     = ["States.TaskFailed", "States.Timeout"]
              IntervalSeconds = 2
              MaxAttempts     = 2
              BackoffRate     = 2.0
            }]
            Catch = [{
              ErrorEquals = ["States.ALL"]
              Next        = "routing_failed"
              ResultPath  = "$.error"
            }]
            Next = "route_decision"
          }
          route_decision = {
            Type = "Choice"
            Choices = [
              for a in app.agents : {
                Variable     = "$.classification"
                StringEquals = a.name
                Next         = "handle_${a.name}"
              }
              if a.role == "handler"
            ]
            Default = "routing_failed"
          }
        },
        # Handler task states — one per handler agent
        {
          for a in app.agents : "handle_${a.name}" => {
            Type     = "Task"
            Resource = "arn:aws:states:::lambda:invoke"
            Parameters = {
              "FunctionName" = local.bridge_lambda_arn
              "Payload" = {
                "AgentRuntimeEndpointArn" = module.app_runtime["${app_name}/${a.name}"].endpoint_arn
                "Payload.$"               = "$"
              }
            }
            TimeoutSeconds = try(a.timeout, 300)
            Retry = [{
              ErrorEquals     = ["States.TaskFailed", "States.Timeout"]
              IntervalSeconds = 2
              MaxAttempts     = 2
              BackoffRate     = 2.0
            }]
            End = true
          }
          if a.role == "handler"
        },
        {
          routing_failed = {
            Type  = "Fail"
            Error = "RoutingFailed"
            Cause = "Router application ${app_name} — classification did not match any handler"
          }
        }
      )
    })
    if app.architecture == "router"
  }

  # Merge all ASL definitions into a single map keyed by app_name
  all_asl = merge(
    local.sequential_asl,
    local.supervisor_asl,
    local.router_asl
  )
}

# ===========================================================================
# LAMBDA BRIDGE — Step Functions → AgentCore Runtime invocation
# TEMPORARY: AgentCore invokeAgentRuntime is streaming-only. Step Functions
# doesn't support streaming SDK integrations. This Lambda consumes the stream
# and returns a complete JSON response. Remove when AWS adds native SFN
# integration for AgentCore. Deployed once per domain, shared by all SFN apps.
# ===========================================================================

data "archive_file" "invoke_bridge" {
  type        = "zip"
  source_file = "${path.module}/../../orchestration/lambda/invoke_bridge.py"
  output_path = "${path.module}/../../orchestration/lambda/invoke_bridge.zip"
}

resource "aws_lambda_function" "invoke_bridge" {
  count = length(local.sfn_apps) > 0 ? 1 : 0

  function_name = "${var.domain}-agentcore-invoke-bridge"
  description   = "TEMPORARY: Bridges Step Functions → AgentCore Runtime (streaming → sync). Remove when native SFN integration available."
  role          = aws_iam_role.invoke_bridge[0].arn
  handler       = "invoke_bridge.handler"
  runtime       = "python3.13"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.invoke_bridge.output_path
  source_code_hash = data.archive_file.invoke_bridge.output_base64sha256

  # ADR-032: run in the enterprise VPC when VPC mode is in effect so the
  # InvokeAgentRuntime call resolves via the PrivateLink endpoint. Omitted in
  # PUBLIC mode.
  dynamic "vpc_config" {
    for_each = local.lambda_vpc_config != null ? [local.lambda_vpc_config] : []
    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }
}

resource "aws_iam_role" "invoke_bridge" {
  count = length(local.sfn_apps) > 0 ? 1 : 0

  name = "${var.domain}-invoke-bridge-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "invoke_bridge" {
  count = length(local.sfn_apps) > 0 ? 1 : 0

  name = "${var.domain}-invoke-bridge-policy"
  role = aws_iam_role.invoke_bridge[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:runtime/*",
          "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:runtime/*/runtime-endpoint/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:*"]
      }
      ],
      # ADR-032: ENI-management permissions for the Lambda when it runs in-VPC.
      # Added only in VPC mode; EC2 network-interface actions are not
      # resource-scopable, so Resource = "*".
      local.lambda_vpc_config != null ? [{
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = ["*"]
    }] : [])
  })
}

# ===========================================================================
# ORCHESTRATION MODULE — Step Functions state machines
# One per application with orchestration: step-functions.
# Uses Lambda bridge to invoke AgentCore runtimes (streaming → sync).
# Requirements: R30.5, R31.3, R31.5
# ===========================================================================

module "orchestration" {
  source   = "../../orchestration"
  for_each = local.sfn_apps

  name     = replace("${var.domain}_${each.key}_orchestration", "-", "_")
  domain   = var.domain
  app_name = each.key

  definition = local.all_asl[each.key]

  runtime_arns = [
    for agent in try(each.value.agents, each.value.steps, []) :
    module.app_runtime["${each.key}/${agent.name}"].endpoint_arn
  ]

  invoke_bridge_lambda_arn = aws_lambda_function.invoke_bridge[0].arn
}

# ===========================================================================
# COGNITO APP CLIENT — Per Multi-Agent Application
# One client per application (not per agent). All agents in the app share it.
# Existing standalone aws_cognito_user_pool_client.app remains unchanged.
# Requirements: R35.1, R35.2, R35.3, R35.4, R35.5, R35.6, R35.7
# ===========================================================================

resource "aws_cognito_user_pool_client" "multi_agent_app" {
  for_each = local.apps_by_name

  name         = "${var.domain}-${each.key}"
  user_pool_id = var.cognito_user_pool_id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["implicit"]
  allowed_oauth_scopes                 = ["openid", "gateway/tools.invoke", "gateway/tools.read", "agent/invoke"]
  callback_urls = [
    "https://${each.key}.${var.domain}.platform.example.com/auth/callback",
    "http://localhost:5175/auth/callback"
  ]
  supported_identity_providers = ["COGNITO"]
}
