# EAP Runtime Module — Main
# Maps 1:1 to aws_bedrockagentcore_agent_runtime + endpoint
# Cross-cutting injection: identity auto-provisioning, observability defaults, protocol env vars
# Requirements: R1.5, R6.1, R6.4, R6.6, R12.3, R12.8, R15.7, R15.10, R15.12, R19.2, R20.1–R20.3

data "aws_region" "current" {}

locals {
  # Protocol env var — base image reads this to activate protocol listeners (ADR-016)
  protocols_csv = join(",", var.protocols)

  # Derive server_protocol from first declared protocol if not explicitly set
  protocol_map = {
    "mcp"  = "MCP"
    "a2a"  = "A2A"
    "agui" = "HTTP"
    "http" = "HTTP"
  }
  server_protocol = coalesce(var.protocol_server_protocol, lookup(local.protocol_map, var.protocols[0], "HTTP"))

  # --- Cognito JWT Authorizer (Task 18.3) ---
  # Auto-build authorizer config from Cognito variables when explicit authorizer_config is not set
  cognito_authorizer = var.cognito_user_pool_id != null && var.cognito_app_client_id != null ? {
    discovery_url    = "https://cognito-idp.${data.aws_region.current.id}.amazonaws.com/${var.cognito_user_pool_id}/.well-known/openid-configuration"
    allowed_audience = toset([var.cognito_app_client_id])
    allowed_clients  = length(var.allowed_callers) > 0 ? toset(var.allowed_callers) : toset([])
    allowed_scopes   = null
  } : null

  # Explicit authorizer_config takes precedence over Cognito auto-config
  # When enable_auth = false and no Cognito params, both can be null — that's fine,
  # the dynamic block below guards on enable_auth before reading this.
  effective_authorizer = try(coalesce(var.authorizer_config, local.cognito_authorizer), null)

  # Platform-injected environment variables (env var contract — design doc)
  platform_env_vars = merge(
    {
      EAP_PROTOCOLS            = local.protocols_csv
      EAP_DOMAIN               = var.domain
      EAP_AGENT_NAME           = var.name
      OTEL_RESOURCE_ATTRIBUTES = join(",", [for k, v in merge({ "service.name" = var.name, "deployment.environment" = var.domain }, var.observability_config.resource_attributes) : "${k}=${v}"])
    },
    # OTEL_EXPORTER_OTLP_ENDPOINT — AWS-native leg reconciliation (agentcore-observability R8.2, R17.5).
    #
    # The two-leg model (design.md "Existing Constraints") requires that the
    # platform does NOT override OTEL_EXPORTER_OTLP_ENDPOINT: AgentCore-managed
    # ADOT auto-instrumentation exports the AWS-native leg DIRECTLY to
    # CloudWatch/X-Ray and auto-configures its own endpoint. Unconditionally
    # setting this var (previously `= var.observability_config.otel_endpoint`,
    # which defaults to "") shadowed AgentCore's auto-config with an empty/foreign
    # endpoint and conflicts with that invariant.
    #
    # Minimal reconciliation: only inject OTEL_EXPORTER_OTLP_ENDPOINT when an
    # explicit non-empty otel_endpoint is supplied (mirrors the MODEL_ID
    # conditional pattern). The default deployment injects nothing, leaving
    # AgentCore's AWS-native export exactly as it configures it. The third-party
    # collector endpoint is NEVER routed through this var (it uses
    # EAP_OTEL_COLLECTOR_ENDPOINT below).
    var.observability_config.otel_endpoint != "" ? { OTEL_EXPORTER_OTLP_ENDPOINT = var.observability_config.otel_endpoint } : {},

    # Inject model ID when set (Task 19.1)
    var.model_id != null ? { MODEL_ID = var.model_id } : {},

    # --- Third-party telemetry leg (agentcore-observability, task 11.1) ---
    # Additive ONLY. When the platform-owned OTel_Collector endpoint is set, the
    # base image's register_additional_span_exporter() (task 6.1) reads
    # EAP_OTEL_COLLECTOR_ENDPOINT and adds a SECOND BatchSpanProcessor +
    # OTLPSpanExporter that sends a COPY of the spans to the collector. This is
    # the third-party leg only and MUST NOT set/override
    # OTEL_EXPORTER_OTLP_ENDPOINT. Requirements: R9.2, R12.4, R17.2, R17.3.
    var.observability_config.collector_endpoint != "" ? { EAP_OTEL_COLLECTOR_ENDPOINT = var.observability_config.collector_endpoint } : {},

    # Per-BU third-party auth credential. AgentCore runtime environment_variables
    # is a plain string map with no secret `valueFrom` resolution, so we pass the
    # Secrets Manager ARN BY REFERENCE as EAP_OTEL_COLLECTOR_HEADERS (the
    # env var the base image reads, task 6.1). Requirements: R17.3.
    var.observability_config.collector_auth_secret_arn != "" ? { EAP_OTEL_COLLECTOR_HEADERS = var.observability_config.collector_auth_secret_arn } : {},
  )

  # Merge platform env vars with user-supplied extras (user cannot override platform vars)
  all_env_vars = merge(var.extra_environment_variables, local.platform_env_vars)

  # Standard tags applied to all resources in this module
  module_tags = merge(var.tags, {
    eap_module = "runtime"
    eap_domain = var.domain
    eap_agent  = var.name
  })
}

# ---------------------------------------------------------------------------
# AgentCore Agent Runtime
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = var.name
  description        = var.description
  role_arn           = var.role_arn

  agent_runtime_artifact {
    dynamic "container_configuration" {
      for_each = var.container_image != null ? [1] : []
      content {
        container_uri = var.container_image
      }
    }

    dynamic "code_configuration" {
      for_each = var.code_package != null ? [var.code_package] : []
      content {
        runtime     = code_configuration.value.runtime
        entry_point = code_configuration.value.entry_point
        code {
          s3 {
            bucket     = code_configuration.value.s3_bucket
            prefix     = code_configuration.value.s3_key
            version_id = code_configuration.value.s3_version_id
          }
        }
      }
    }
  }

  network_configuration {
    network_mode = var.network_mode

    dynamic "network_mode_config" {
      for_each = var.network_mode == "VPC" && var.vpc_config != null ? [var.vpc_config] : []
      content {
        security_groups = network_mode_config.value.security_groups
        subnets         = network_mode_config.value.subnets
      }
    }
  }

  environment_variables = local.all_env_vars

  dynamic "authorizer_configuration" {
    for_each = var.enable_auth && local.effective_authorizer != null ? [local.effective_authorizer] : []
    content {
      custom_jwt_authorizer {
        discovery_url    = authorizer_configuration.value.discovery_url
        allowed_audience = authorizer_configuration.value.allowed_audience
        allowed_clients  = authorizer_configuration.value.allowed_clients
        allowed_scopes   = authorizer_configuration.value.allowed_scopes
      }
    }
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.session_config.idle_timeout
    max_lifetime                 = var.session_config.max_lifetime
  }

  protocol_configuration {
    server_protocol = local.server_protocol
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Agent Runtime Endpoint — network-accessible interface
# ---------------------------------------------------------------------------
resource "aws_bedrockagentcore_agent_runtime_endpoint" "this" {
  name             = "${var.name}_endpoint"
  agent_runtime_id = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
  description      = "Endpoint for ${var.name} in domain ${var.domain}"

  # Track the runtime's current version. AgentCore runtime versions are
  # immutable; any change (image, env vars, config) mints a new version. Without
  # pinning this, the endpoint stays on the version it was created with (V1) and
  # never serves later updates — invocations keep hitting stale code/config.
  agent_runtime_version = aws_bedrockagentcore_agent_runtime.this.agent_runtime_version

  tags = local.module_tags
}
