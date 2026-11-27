# ---------------------------------------------------------------------------
# AgentCore Observability — AWS-native (CloudWatch GenAI Observability + X-Ray)
# ---------------------------------------------------------------------------
# AgentCore Runtime auto-instruments agents (via ADOT in the base image) and
# ships GenAI spans/traces to CloudWatch. Those traces only become searchable
# in the CloudWatch GenAI Observability page once X-Ray Transaction Search is
# enabled for the account/region.
#
# Transaction Search is a SINGLETON, account+region-wide setting — enabled once
# per platform instance here (not per-agent). AWS exposes it as the
# AWS::XRay::TransactionSearchConfig CloudFormation resource; we drive it from
# Terraform via aws_cloudformation_stack so no additional provider is required
# and the config is applied automatically at platform deploy time.
#
# Ref: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search.html
# ---------------------------------------------------------------------------

resource "aws_cloudformation_stack" "transaction_search" {
  count = var.enable_transaction_search ? 1 : 0

  name = "eap-xray-transaction-search"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "EAP — enable X-Ray Transaction Search for AgentCore Observability (managed by Terraform)"
    Resources = {
      # PREREQUISITE for TransactionSearchConfig: X-Ray sends indexed spans to
      # CloudWatch Logs (log groups aws/spans + /aws/application-signals/data),
      # which requires a Logs resource policy granting the X-Ray service
      # principal logs:PutLogEvents on those groups. Without it the config
      # resource fails to create with a 403 (XRay PutLogEvents on aws/spans) and
      # the whole stack rolls back. Shape per AWS docs (Using Transaction Search
      # with CloudFormation); scoped by aws:SourceArn/SourceAccount to this acct.
      LogsResourcePolicy = {
        Type = "AWS::Logs::ResourcePolicy"
        Properties = {
          PolicyName = "TransactionSearchAccess"
          PolicyDocument = jsonencode({
            Version = "2012-10-17"
            Statement = [{
              Sid       = "TransactionSearchXRayAccess"
              Effect    = "Allow"
              Principal = { Service = "xray.amazonaws.com" }
              Action    = "logs:PutLogEvents"
              Resource = [
                "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
                "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data:*",
              ]
              Condition = {
                ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:xray:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
                StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
              }
            }]
          })
        }
      }
      TransactionSearchConfig = {
        Type      = "AWS::XRay::TransactionSearchConfig"
        DependsOn = "LogsResourcePolicy"
        Properties = {
          IndexingPercentage = var.transaction_search_indexing_percentage
        }
      }
    }
  })

  tags = merge(var.tags, {
    Component = "observability"
    ManagedBy = "eap-platform"
  })
}

# ---------------------------------------------------------------------------
# Third-party observability leg — OTel Collector (always-on) + optional Langfuse
# (ADR-030)
# ---------------------------------------------------------------------------
# STRUCTURALLY SEPARATE from the AWS-native leg above. The OTel_Collector sits
# on the third-party leg ONLY: the base-image Additional_Span_Exporter emits a
# COPY of agent spans to it, and it fans that copy out ONLY to the configured
# third-party OTLP backend(s). It NEVER exports to CloudWatch/X-Ray, and its
# task role holds ONLY Secrets Manager read for the third-party auth secret
# (no xray:PutTraceSegments, no logs:* write, no cloudwatch:PutMetricData/EMF).
#
# PRIVATE + PLUGGABLE (ADR-030):
#   - The collector is ALWAYS deployed (in the resolved VPC — created or
#     imported). It publishes its OTLP/HTTP endpoint to a fixed SSM param the
#     base image reads at boot.
#   - Langfuse is an OPTIONAL self-hosted default backend (deploy_langfuse,
#     default true), fully PRIVATE — internal HTTP ALB, NO public exposure, NO
#     ACM, NO CloudFront. Access is network-scoped (VPN/corp network) + Langfuse
#     app auth; the ALB-level Cognito SSO gate was removed for the private model.
#   - An external OTLP backend (Datadog/Fiddler/...) is supplied via
#     otel_backend_endpoint and fans out alongside Langfuse (mode=add) or in
#     place of it (mode=replace).
#   - Standing cost: because the collector (and, by default, Langfuse) are
#     always on, the default deploy carries a VPC + NAT + Fargate (and the
#     Langfuse datastores) — see the FinOps section of the runbook. Set
#     deploy_langfuse=false and/or import a VPC to control this.
# ---------------------------------------------------------------------------

# Langfuse — OPTIONAL self-hosted default backend (ADR-030). Private: internal
# HTTP ALB, no public exposure / no ACM / no CloudFront (edge simplified in the
# langfuse module). Gated on deploy_langfuse (default true). Runs in the
# resolved VPC (platform-created or imported). Its OTLP endpoint is fed to the
# collector as the default backend.
module "langfuse" {
  source                  = "../eap-terraform-modules/modules/observability/langfuse"
  alb_deletion_protection = var.alb_deletion_protection
  count                   = local.deploy_langfuse ? 1 : 0

  name   = "langfuse"
  domain = "observability"

  vpc_id                  = local.vpc_id
  private_subnet_ids      = local.private_subnet_ids
  public_subnet_ids       = local.public_subnet_ids
  private_route_table_ids = local.private_route_table_ids

  # One Langfuse project per Business_Unit so agent spans arrive authenticated.
  # The `bu` values MUST equal the agents' `deployment.environment` resource
  # attribute — which the runtime module sets to the agent's DOMAIN
  # (modules/runtime/main.tf). So business_units = the platform's domains.
  # Without this, no project/keys are seeded and the collector would export to
  # Langfuse unauthenticated (rejected). The first entry is seeded via Langfuse
  # headless init; the collector routes each BU to its own project (ADR-030).
  business_units = [for bu in local.langfuse_business_units : { bu = bu }]

  # ADR-035: customer-managed KMS key for the Langfuse datastores/secrets/S3
  # (null => AWS-managed defaults).
  kms_key_arn = var.kms_key_arn

  # ADR-038 (demo only): expose the Langfuse ALB to the demo console CloudFront
  # so its UI can be embedded publicly. Gated on the demo console being deployed;
  # the ALB stays fully private (internal, VPC-only) otherwise. The origin secret
  # is generated by the examples_console module and shared with the console
  # distribution so all three (console, examples ALB, Langfuse ALB) agree.
  enable_cloudfront_origin        = var.deploy_console
  cloudfront_origin_secret_header = var.deploy_console ? module.examples_console[0].origin_secret_header_name : "x-eap-origin"
  cloudfront_origin_secret_value  = var.deploy_console ? module.examples_console[0].origin_secret_value : ""

  tags = merge(var.tags, {
    Component = "observability"
    ManagedBy = "eap-platform"
  })
}

# OTel Collector — ALWAYS deployed (ADR-030). Receives a COPY of agent spans and
# fans out to the third-party backend(s): Langfuse (when deploy_langfuse) and/or
# the external OTLP backend (otel_backend_endpoint). Third-party leg ONLY — never
# exports to CloudWatch/X-Ray (that is AgentCore's separate AWS-native leg).
module "otel_collector" {
  source                  = "../eap-terraform-modules/modules/observability/otel-collector"
  alb_deletion_protection = var.alb_deletion_protection

  name   = "otel-collector"
  domain = "observability"

  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids

  # Default backend = the in-stack Langfuse OTLP receiver when deployed; empty
  # otherwise (collector module skips the langfuse default exporter). Injected
  # from the Langfuse module output so the render is a pure function of inputs.
  default_langfuse_endpoint = local.deploy_langfuse ? module.langfuse[0].langfuse_otlp_endpoint : ""

  # Per-BU Langfuse routing: feed the Langfuse module's project bindings so the
  # collector renders one authenticated otlphttp/langfuse-<bu> exporter per BU,
  # routed by the `deployment.environment` (=domain) resource attribute. Each
  # exporter presents that project's base64(pk:sk) Basic-auth header (injected
  # from Secrets Manager). Empty when Langfuse is off => no per-BU routing.
  #
  # Iterate the PLAN-KNOWN BU list (local.langfuse_business_units), not the
  # module's bindings MAP: that map's values carry to-be-created secret ARNs
  # (known-after-apply), so iterating it makes the list LENGTH unknown at plan
  # and breaks the collector's count = length(auth_secret_arns) guard. Iterating
  # the known BU list fixes the cardinality; each element's ARN VALUE (looked up
  # from the map by bu) can still resolve at apply.
  langfuse_project_bindings = local.deploy_langfuse ? [
    for bu in local.langfuse_business_units : {
      bu                         = bu
      otlp_basic_auth_secret_arn = module.langfuse[0].langfuse_project_bindings[bu].otlpBasicAuthRef
    }
  ] : []

  # External third-party OTLP backend (Datadog/Fiddler/...). Empty list when no
  # otel_backend_endpoint is configured. mode=add fans out alongside Langfuse;
  # mode=replace drops the Langfuse default. auth_secret_arn is granted to the
  # collector task role as secretsmanager:GetSecretValue ONLY and injected as
  # EAP_OTLP_AUTH_<NAME>.
  third_party_backends = local.otel_external_backends

  tags = merge(var.tags, {
    Component = "observability"
    ManagedBy = "eap-platform"
  })
}

# ---------------------------------------------------------------------------
# Collector endpoint SSM parameter (task 15.1 / 15.2 — deploy-time indirection
# + redeploy-free runtime resolution)
# ---------------------------------------------------------------------------
# Publish the OTel_Collector's STABLE Cloud Map OTLP/HTTP endpoint to a fixed,
# well-known SSM parameter path. The parameter NAME is a stable constant, so:
#   - Deploy paths (developer pipeline, agent-deploy, no-code Studio) only grant
#     the agent runtime role scoped `ssm:GetParameter` on this fixed path; they
#     never read or hardcode the endpoint value (task 15.1).
#   - The Strands base image reads this parameter directly at container boot from
#     the same hardcoded constant path, so a changed endpoint VALUE takes effect
#     on an agent restart with NO Terraform apply (task 15.2).
#
# THIRD-PARTY LEG ONLY. This is purely the additive collector endpoint; it does
# NOT touch OTEL_EXPORTER_OTLP_ENDPOINT and cannot affect the AWS-native leg.
#
# Gated by the same condition as the collector. otlp_http_endpoint can be null
# when service discovery is disabled on the collector — guard on that so we
# never write a null-valued parameter (fail safe: no param => base image no-ops
# the third-party leg).
locals {
  collector_endpoint_ssm_param_name = "/eap/observability/collector-endpoint"

  # The collector is always deployed (ADR-030); publish its endpoint whenever it
  # exposes a resolvable Cloud Map OTLP/HTTP endpoint. Guard on non-null so we
  # never write a null-valued parameter (fail safe: no param => base image
  # no-ops the third-party leg).
  publish_collector_endpoint = try(module.otel_collector.otlp_http_endpoint, null) != null
}

resource "aws_ssm_parameter" "collector_endpoint" {
  count = local.publish_collector_endpoint ? 1 : 0

  name        = local.collector_endpoint_ssm_param_name
  description = "Stable OTLP/HTTP endpoint of the platform OTel_Collector (third-party observability leg). Read by agent base images at boot and by deploy paths. Never affects the AWS-native CloudWatch/X-Ray leg."
  type        = "String"
  value       = module.otel_collector.otlp_http_endpoint

  tags = merge(var.tags, {
    Component = "observability"
    ManagedBy = "eap-platform"
  })
}
