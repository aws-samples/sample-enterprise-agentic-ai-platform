# EAP OTel_Collector Module — Main
#
# THIRD-PARTY LEG ONLY. This collector sits exclusively on the platform's
# third-party telemetry leg. It has NO AWS-native (awsxray / awsemf /
# awscloudwatchlogs) receivers or exporters, and it NEVER exports to CloudWatch
# or X-Ray. The AWS-native leg is delivered by AgentCore-managed ADOT
# auto-instrumentation exporting DIRECTLY to CloudWatch GenAI Observability and
# X-Ray Transaction Search — it does not traverse this collector at all
# (design: "OTel_Collector — third-party leg only").
#
# Central Gateway OpenTelemetry Collector (ADOT distribution) on ECS Fargate,
# running in private subnets and reachable in-VPC via a Cloud Map service
# discovery endpoint and/or an internal Network Load Balancer. The base-image
# Additional_Span_Exporter sends a COPY of the agent's spans here via the
# EAP_OTEL_COLLECTOR_ENDPOINT env var (set by the runtime module in
# Section 6 — no agent code change). This module NEVER sets or overrides
# OTEL_EXPORTER_OTLP_ENDPOINT (that would divert AgentCore's own export away
# from CloudWatch/X-Ray).
#
# SCOPE (task 1.4 — SCAFFOLD ONLY): this file stands up the Fargate service and
# the OTLP receiver endpoint. The collector config template and third-party
# exporter wiring (the OTLP receiver + third-party pipeline(s) rendered from
# var.third_party_backends, Langfuse by default, each with its own non-blocking
# sending_queue + retry_on_failure) are intentionally left as clearly marked
# STUBS to be filled by Section 7 (tasks 7.3, 7.6, 7.8, 10.4). Do not implement
# render/fan-out logic here.
# Requirements: R12.1

locals {
  module_tags = merge(var.tags, {
    eap_module = "otel-collector"
    eap_domain = var.domain
  })

  create_cluster        = var.ecs_cluster_arn == null
  create_execution_role = var.execution_role_arn == null
  create_task_role      = var.task_role_arn == null

  cluster_arn        = local.create_cluster ? aws_ecs_cluster.this[0].arn : var.ecs_cluster_arn
  execution_role_arn = local.create_execution_role ? aws_iam_role.execution[0].arn : var.execution_role_arn
  task_role_arn      = local.create_task_role ? aws_iam_role.task[0].arn : var.task_role_arn

  log_group_name = "/eap/${var.domain}/otel-collector/${var.name}"

  # ==========================================================================
  # Rendered collector configuration — THIRD-PARTY LEG ONLY (tasks 7.3 + 7.6).
  #
  # This HCL render is the deploy-time mirror of the pure, property-tested
  # reference implementation `renderCollectorConfig(backendConfiguration,
  # options)` in
  # `eap-platform/observability/src/lib/collectorConfig.ts`. The TS
  # function is the canonical spec (exercised by the tasks 7.4/7.5/7.7 property
  # tests); this local reproduces the SAME structure so the running collector is
  # configured identically without a build step. Keep the two in sync.
  #
  # It contains: an OTLP receiver (gRPC + HTTP), a `batch` processor, one
  # `otlphttp/<name>` exporter per resolved third-party backend — each with its
  # OWN non-blocking `sending_queue` (enabled, blocking=false) and
  # `retry_on_failure` (task 7.6, R9.4/R12.5) — and a single `traces/thirdparty`
  # pipeline.
  #
  # HARD INVARIANT (R12.2, R12.3, R16.5, R16.6): ZERO AWS-native exporters or
  # pipelines. No awsxray / awsemf / awscloudwatchlogs exporter, and no
  # traces/aws / metrics/aws / logs/aws pipeline. The AWS-native leg is a
  # separate AgentCore-managed pipeline that never enters this collector.
  # ==========================================================================

  # Backend_Configuration resolution — mirrors `resolveBackends` (task 7.1):
  #   - only strictly-enabled backends participate;
  #   - if any enabled backend uses mode="replace", the default Langfuse
  #     exporter is dropped; otherwise Langfuse is kept alongside the alternates;
  #   - no enabled backends => default Langfuse only (R16.4).
  enabled_backends = [for b in var.third_party_backends : b if b.enabled]

  langfuse_replaced = anytrue([for b in local.enabled_backends : b.mode == "replace"])

  # Ordered resolved exporter set: [Langfuse (unless replaced/absent), then alternates].
  # The default Langfuse exporter is included only when a Langfuse endpoint is
  # actually supplied (deploy_langfuse=true at the platform layer) AND no enabled
  # backend uses mode="replace". When default_langfuse_endpoint is "" the
  # collector renders with only the external backend(s) — or with no third-party
  # exporters at all (collector up, third-party leg dormant).
  resolved_exporters = concat(
    (var.default_langfuse_endpoint != "" && (length(local.enabled_backends) == 0 || !local.langfuse_replaced)) ? [{
      name            = "langfuse"
      otlp_endpoint   = var.default_langfuse_endpoint
      auth_secret_arn = var.default_langfuse_auth_secret_arn
    }] : [],
    [for b in local.enabled_backends : {
      name            = b.name
      otlp_endpoint   = b.otlp_endpoint
      auth_secret_arn = b.auth_secret_arn
    }],
  )

  # Env var name carrying each exporter's injected auth header value. Kept
  # consistent between the collector-config header render (below) and the
  # container `secrets` injection (task 7.8) so the `${env:...}` placeholder in
  # the rendered config resolves to the Secrets Manager value at runtime.
  exporter_env_names = {
    for e in local.resolved_exporters :
    e.name => "EAP_OTLP_AUTH_${upper(replace(e.name, "/[^A-Za-z0-9]/", "_"))}"
  }

  # Default (no per-BU routing) third-party exporter set. Used only when
  # var.langfuse_project_bindings is empty (backward-compatible single pipeline).
  collector_exporters = {
    for e in local.resolved_exporters :
    "otlphttp/${e.name}" => merge(
      {
        endpoint = e.otlp_endpoint
        # Task 7.6 — per-exporter failure isolation. Non-blocking is the default
        # queue behavior; the (removed) `blocking` key is no longer valid in the
        # ADOT collector's exporterhelper queue-batch config and crashes config
        # load if present, so we omit it and rely on the non-blocking default.
        sending_queue = {
          enabled    = true
          queue_size = var.sending_queue_size
        }
        retry_on_failure = {
          enabled          = true
          max_elapsed_time = var.retry_max_elapsed_time
        }
      },
      # Auth-header seam only when the backend declares an auth secret; the
      # secret value is injected into the env var at deploy time (task 7.8).
      e.auth_secret_arn != "" ? {
        headers = {
          Authorization = "$${env:${local.exporter_env_names[e.name]}}"
        }
      } : {},
    )
  }

  # ==========================================================================
  # Third-party auth secret injection (task 7.8, R16.5).
  #
  # For every resolved third-party exporter that declares an auth secret, inject
  # the secret VALUE into the collector container as the EAP_OTLP_AUTH_<NAME>
  # env var the rendered config's `${env:...}` Authorization header references.
  # This is done via ECS container `secrets` valueFrom pointing at the per-BU /
  # third-party auth Secrets Manager ARN — the render itself stays secret-free
  # (only placeholders; done in task 7.3).
  #
  # THIRD-PARTY AUTH ONLY: these ARNs are the collector's ENTIRE AWS permission
  # surface. There is NO xray:PutTraceSegments, NO logs:* write, and NO
  # cloudwatch:PutMetricData / EMF anywhere on this collector.
  # ==========================================================================
  default_container_secrets = [
    for e in local.resolved_exporters : {
      name      = local.exporter_env_names[e.name]
      valueFrom = e.auth_secret_arn
    } if e.auth_secret_arn != ""
  ]

  # Auth-secret ARNs for the least-privilege secrets-read grant + container
  # secret injection. Computed directly from the auth-secret INPUTS (Langfuse
  # default + third-party backends) rather than from local.resolved_exporters.
  # This matters because the presence of the Langfuse element in
  # resolved_exporters is gated on var.default_langfuse_endpoint != "", and that
  # endpoint is the Langfuse ALB DNS (known-after-apply) — so deriving the list
  # from resolved_exporters makes its LENGTH unknown at plan time and breaks the
  # count = length(local.auth_secret_arns) > 0 guards below. The auth-secret
  # ARNs, by contrast, are pure plan-known inputs, so the count is stable. The
  # unknown endpoint value is still used freely in the config render (where a
  # known-after-apply string is fine) — only the count decisions are decoupled.
  default_auth_secret_arns = [
    for arn in concat(
      [var.default_langfuse_auth_secret_arn],
      [for b in local.enabled_backends : b.auth_secret_arn],
    ) : arn if arn != ""
  ]

  # ==========================================================================
  # PER-BU ROUTING (task 10.4, R14.4) — deploy-time mirror of the per-BU branch
  # of `renderCollectorConfig(..., { langfuseProjectBindings, langfuseOtelEndpoint })`
  # / `buildPerBuLangfuse` in
  # eap-platform/observability/src/lib/collectorConfig.ts.
  #
  # When var.langfuse_project_bindings is non-empty and default_langfuse_endpoint
  # (the SHARED Langfuse OTLP endpoint) is set, route each BU's telemetry to its
  # own Langfuse project: one `otlphttp/langfuse-<bu>` exporter per resolvable BU,
  # a `routing` connector keyed on the `deployment.environment` (BU) resource
  # attribute, and one `traces/langfuse-<bu>` pipeline per BU.
  #
  # FAIL-CLOSED tenant isolation (mirrors resolveLangfuseRoute, task 10.2): a BU
  # that is empty, has no auth secret, or is ambiguous (appears in more than one
  # binding) is DROPPED — never added to the routing table/exporters — so it
  # falls out of the third-party leg rather than risk cross-BU delivery.
  # ==========================================================================

  # Normalized bindings (trimmed BU).
  lf_bindings_norm = [
    for b in var.langfuse_project_bindings : {
      bu              = trimspace(b.bu)
      auth_secret_arn = b.otlp_basic_auth_secret_arn
    }
  ]

  # BU occurrence counts, to fail closed on ambiguous duplicate-BU bindings.
  lf_bu_counts = {
    for bu in distinct([for b in local.lf_bindings_norm : b.bu]) :
    bu => length([for b in local.lf_bindings_norm : b.bu if b.bu == bu])
  }

  # Resolvable per-BU routes: non-empty BU + a supplied auth ref + shared
  # endpoint present + BU appears exactly once (unambiguous).
  #
  # NOTE on plan-stability: the auth ref is checked with a plan-known predicate,
  # not against the resolved ARN string. The binding's otlp_basic_auth_secret_arn
  # is frequently a to-be-created Secrets Manager ARN (known only after apply);
  # testing `!= ""` on that unknown value makes length(lf_routes) unknown at plan
  # time, which breaks `count`/`per_bu_active` downstream. Instead we treat a
  # binding as having an auth ref when the field is non-null (a supplied binding
  # always carries the ref; an empty/omitted one is filtered). This keeps route
  # CARDINALITY plan-known while the ARN VALUE stays free to resolve at apply.
  # Cardinality (how many routes) must depend ONLY on plan-known values, so the
  # `count`/`per_bu_active`/auth-secret-length decisions downstream are stable:
  #   - b.bu != ""                    : plan-known (from the input binding)
  #   - b.auth_secret_arn != null     : plan-known "was a ref supplied" (the ARN
  #                                     VALUE is often known-after-apply, so we
  #                                     must NOT test it with != "")
  #   - lf_bu_counts[b.bu] == 1       : plan-known (dedupe on the input bu)
  # We deliberately do NOT gate on var.default_langfuse_endpoint != "" here: that
  # is the Langfuse ALB DNS (known-after-apply) and would make length() unknown.
  # "Is Langfuse deployed" is already enforced upstream — the platform only
  # passes langfuse_project_bindings when deploy_langfuse is true — so a supplied
  # binding implies the endpoint exists. The endpoint value is still consumed in
  # the exporter render below (where a known-after-apply string is fine).
  # IMPORTANT: do NOT test b.auth_secret_arn here (neither != "" nor != null).
  # The ARN is a to-be-created Secrets Manager ARN, and Terraform treats even
  # `<unknown> != null` as UNKNOWN at plan time — which taints the filter's
  # cardinality and makes length(lf_routes)/per_bu_active/auth_secret_arns
  # unknown, breaking the `count` guards downstream. A supplied binding always
  # carries an auth ref (it's a required field on the input object), so route
  # EXISTENCE is decided purely from plan-known values: a non-empty, unambiguous
  # bu. The ARN VALUE is consumed later (exporter render + container secrets),
  # where known-after-apply is fine.
  lf_routes = [
    for b in local.lf_bindings_norm : b
    if b.bu != "" && local.lf_bu_counts[b.bu] == 1
  ]

  per_bu_active = length(local.lf_routes) > 0

  # Per-BU component suffix mirrors sanitizeComponentName(bu) in TS: lowercase,
  # non-[a-z0-9_-] runs → "-", trimmed of leading/trailing "-".
  lf_suffix = {
    for r in local.lf_routes :
    r.bu => trim(replace(lower(r.bu), "/[^a-z0-9_-]+/", "-"), "-")
  }

  # Per-BU auth env var name mirrors perBuAuthEnvVarName(bu) in TS.
  lf_env_name = {
    for r in local.lf_routes :
    r.bu => "EAP_OTLP_AUTH_LANGFUSE_${upper(replace(r.bu, "/[^A-Za-z0-9]+/", "_"))}"
  }

  # One otlphttp/langfuse-<bu> exporter per resolvable BU. Shared endpoint; the
  # per-project Basic-auth header value is injected via container `secrets`
  # (below) into the ${env:...} placeholder — the render stays secret-free.
  lf_per_bu_exporters = {
    for r in local.lf_routes :
    "otlphttp/langfuse-${local.lf_suffix[r.bu]}" => {
      endpoint = var.default_langfuse_endpoint
      headers = {
        Authorization = "Basic $${env:${local.lf_env_name[r.bu]}}"
      }
      # Task 7.6 isolation pattern: own queue + retry per BU. Non-blocking is the
      # default; the `blocking` key was removed from the collector's queue-batch
      # config and crashes config load if present, so it is omitted.
      sending_queue = {
        enabled    = true
        queue_size = var.sending_queue_size
      }
      retry_on_failure = {
        enabled          = true
        max_elapsed_time = var.retry_max_elapsed_time
      }
    }
  }

  # Per-BU FILTER processor — fail-closed tenant isolation WITHOUT a `routing`
  # connector. The ADOT collector distribution does not bundle the contrib
  # `routingconnector` (config load fails: `'connectors' unknown type:
  # "routing"`), but it DOES include the OTTL `filter` processor. So instead of a
  # shared receiver fanning out through a routing connector, each BU gets its own
  # pipeline reading the SAME otlp receiver with a filter that DROPS every span
  # whose `deployment.environment` resource attribute is not this BU. Net effect
  # is identical isolation: a span reaches EXACTLY its owning BU's Langfuse
  # exporter and no other. `error_mode: ignore` keeps a malformed span from
  # killing the pipeline (it is simply not dropped by that condition).
  #
  # traces.span.drop semantics: filter drops spans matching the OTTL condition,
  # so we drop where env != this BU (keep only this BU).
  lf_per_bu_filters = {
    for r in local.lf_routes :
    "filter/langfuse-${local.lf_suffix[r.bu]}" => {
      error_mode = "ignore"
      traces = {
        span = ["resource.attributes[\"deployment.environment\"] != \"${r.bu}\""]
      }
    }
  }

  # One traces/langfuse-<bu> pipeline per BU: shared otlp receiver → batch →
  # this BU's drop-everything-else filter → this BU's exporter. No connector.
  lf_per_bu_pipelines = {
    for r in local.lf_routes :
    "traces/langfuse-${local.lf_suffix[r.bu]}" => {
      receivers  = ["otlp"]
      processors = ["batch", "filter/langfuse-${local.lf_suffix[r.bu]}"]
      exporters  = ["otlphttp/langfuse-${local.lf_suffix[r.bu]}"]
    }
  }

  # Per-BU auth secret injection (task 10.4): each BU's Basic-auth secret VALUE
  # is injected into the collector container as its EAP_OTLP_AUTH_LANGFUSE_<BU>
  # env var via ECS `secrets` valueFrom.
  lf_container_secrets = [
    for r in local.lf_routes : {
      name      = local.lf_env_name[r.bu]
      valueFrom = r.auth_secret_arn
    }
  ]

  lf_auth_secret_arns = [for r in local.lf_routes : r.auth_secret_arn]

  # ==========================================================================
  # Combined container secrets + least-privilege secrets-read grant.
  #
  # Per-BU routing active => inject/grant ONLY the per-BU Langfuse auth secrets.
  # Otherwise => the default third-party exporter auth secrets. In BOTH cases the
  # collector's ENTIRE AWS permission surface is secretsmanager:GetSecretValue on
  # exactly these ARNs — still NO xray:PutTraceSegments, NO logs:* write, and NO
  # cloudwatch:PutMetricData / EMF.
  # ==========================================================================
  container_secrets = local.per_bu_active ? local.lf_container_secrets : local.default_container_secrets

  # Do NOT wrap the per-BU branch in distinct(): its elements are to-be-created
  # secret ARNs (known-after-apply), and distinct() over unknown values yields a
  # list of UNKNOWN LENGTH (dedup needs equality it can't resolve at plan) —
  # which breaks `count = length(auth_secret_arns) > 0` below. The per-BU list is
  # already dedup-by-construction (lf_routes fails closed on duplicate BUs via
  # lf_bu_counts == 1), so one ARN per surviving route. The default branch is
  # pure plan-known inputs, so distinct() there is safe and keeps length known.
  auth_secret_arns = local.per_bu_active ? local.lf_auth_secret_arns : distinct(local.default_auth_secret_arns)

  # ==========================================================================
  # Rendered collector config. Built with merge() so the `connectors` key is
  # present ONLY in the per-BU routing branch (avoids a type-inconsistent
  # conditional and keeps the default render byte-identical to before).
  # ==========================================================================
  # Rendered third-party exporter set: the per-BU Langfuse exporters when
  # per_bu_active, else the default resolved set. Built via merged for/if
  # fragments (not a conditional) because the two branches are object maps with
  # different keys, which a `? :` cannot unify. Both are third-party otlphttp
  # exporters only — never AWS-native.
  rendered_exporters = merge(
    { for k, v in local.lf_per_bu_exporters : k => v if local.per_bu_active },
    { for k, v in local.collector_exporters : k => v if !local.per_bu_active },
  )

  # traces/thirdparty exporter targets — used ONLY in the non-per-BU (default)
  # branch. Per-BU delivery uses one dedicated filtered pipeline per BU instead
  # (see lf_per_bu_pipelines), so there is no single fan-out pipeline then.
  thirdparty_exporters = keys(local.collector_exporters)

  # Whether the DEFAULT (non-per-BU) branch has any exporter to send to. When
  # false (no Langfuse default AND no external backend — the "collector up, leg
  # dormant" case), the traces/thirdparty pipeline is OMITTED entirely: an OTel
  # pipeline with zero exporters is invalid and would crash-loop the collector.
  # With no pipeline the collector simply accepts on the OTLP receiver and drops
  # — a valid dormant state. Requirements: R12.* (third-party only), dormancy.
  has_default_thirdparty = length(local.collector_exporters) > 0

  # Processors: always `batch`; plus one per-BU `filter/langfuse-<bu>` when
  # per-BU delivery is active (drops every span not owned by that BU).
  rendered_processors = merge(
    { batch = {} },
    { for k, v in local.lf_per_bu_filters : k => v if local.per_bu_active },
  )

  collector_config = {
    receivers = {
      otlp = {
        protocols = {
          grpc = { endpoint = "0.0.0.0:${var.otlp_grpc_port}" }
          http = { endpoint = "0.0.0.0:${var.otlp_http_port}" }
        }
      }
    }
    processors = local.rendered_processors
    exporters  = local.rendered_exporters
    service = {
      pipelines = merge(
        # Per-BU delivery: one filtered pipeline per BU
        # (otlp → batch → filter/langfuse-<bu> → otlphttp/langfuse-<bu>). Each
        # pipeline reads the shared otlp receiver and drops non-owning spans, so
        # a span reaches EXACTLY its BU's exporter — same isolation the routing
        # connector gave, but with the ADOT-bundled `filter` processor.
        { for k, v in local.lf_per_bu_pipelines : k => v if local.per_bu_active },
        # DEFAULT (no per-BU bindings): single otlp → batch → resolved exporters
        # pipeline. Omitted when there are no third-party exporters (dormant).
        (!local.per_bu_active && local.has_default_thirdparty) ? {
          "traces/thirdparty" = {
            receivers  = ["otlp"]
            processors = ["batch"]
            exporters  = local.thirdparty_exporters
          }
        } : {},
      )
    }
  }

  # Delivered to the ADOT collector container inline via AOT_CONFIG_CONTENT.
  collector_config_yaml = yamlencode(local.collector_config)
}

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# ECS cluster (created only when an existing cluster ARN is not supplied)
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  count = local.create_cluster ? 1 : 0

  name = "eap-${var.domain}-${var.name}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# CloudWatch log group for the collector container
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "collector" {
  name              = local.log_group_name
  retention_in_days = var.log_group_retention_days

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Security group — the collector's OTLP receiver ports, in-VPC only
# ---------------------------------------------------------------------------
resource "aws_security_group" "collector" {
  name        = "eap-${var.domain}-${var.name}-otel"
  description = "OTel collector OTLP receiver (in-VPC only)"
  vpc_id      = var.vpc_id

  ingress {
    description = "OTLP/gRPC from within the VPC"
    from_port   = var.otlp_grpc_port
    to_port     = var.otlp_grpc_port
    protocol    = "tcp"
    self        = false
    # NOTE: scoped to the VPC; agents export to the collector from private subnets.
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  ingress {
    description = "OTLP/HTTP from within the VPC"
    from_port   = var.otlp_http_port
    to_port     = var.otlp_http_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    description = "Collector egress (third-party OTLP export only; no AWS-native export)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.module_tags
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# ---------------------------------------------------------------------------
# IAM — execution role (image pull + logs) and task role (export identity).
#
# THIRD-PARTY LEG ONLY: the task role will hold ONLY Secrets Manager read for
# the per-BU third-party auth secrets (wired in task 7.8). It MUST NEVER be
# granted any AWS-native telemetry write permission — no xray:PutTraceSegments,
# no logs:* write, no cloudwatch:PutMetricData / EMF. That collector-is-
# third-party-only constraint is enforced in task 7.8. This scaffold creates
# the role with a trust policy only (no inline/attached telemetry policies).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  count = local.create_execution_role ? 1 : 0

  name               = "eap-${var.domain}-${var.name}-otel-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  count = local.create_execution_role ? 1 : 0

  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  count = local.create_task_role ? 1 : 0

  name               = "eap-${var.domain}-${var.name}-otel-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.module_tags
}

# ---------------------------------------------------------------------------
# Task-role permissions (task 7.8) — THIRD-PARTY AUTH SECRETS READ ONLY.
#
# The collector task role is granted EXACTLY `secretsmanager:GetSecretValue`,
# and ONLY for the per-BU / third-party auth secrets referenced by
# var.third_party_backends[*].auth_secret_arn (plus default_langfuse_auth_secret_arn
# when set). It is deliberately granted NO AWS-native telemetry write:
#   - NO xray:PutTraceSegments
#   - NO logs:* write (the collector's own container logging is handled by the
#     execution role's AmazonECSTaskExecutionRolePolicy against its own log group)
#   - NO cloudwatch:PutMetricData / EMF
# This makes "the collector is third-party leg only" an IAM-enforced property
# (R16.5) in addition to the config-render structural guarantee (R12.2).
#
# When there are no auth secrets to read (e.g. default Langfuse with per-BU
# project keys not yet provisioned — task 10.1), no secrets policy is attached
# and the task role holds no permissions beyond its trust policy.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "task_secrets" {
  count = length(local.auth_secret_arns) > 0 ? 1 : 0

  statement {
    sid       = "ReadThirdPartyAuthSecretsOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.auth_secret_arns
  }
}

resource "aws_iam_role_policy" "task_secrets" {
  count = local.create_task_role && length(local.auth_secret_arns) > 0 ? 1 : 0

  name   = "eap-${var.domain}-${var.name}-otel-thirdparty-secrets"
  role   = aws_iam_role.task[0].id
  policy = data.aws_iam_policy_document.task_secrets[0].json
}

# ---------------------------------------------------------------------------
# Execution-role secrets read — required by ECS to resolve the container
# `secrets` valueFrom refs at task launch (the ECS agent reads them with the
# EXECUTION role, then hands the values to the container as env vars). This is a
# secrets READ only — still NO telemetry write of any kind — and mirrors the
# convention used by the Langfuse_Stack module (per-service `read-secrets`
# policies on the *_execution roles). Scoped to exactly the same third-party
# auth ARNs as the task-role grant above.
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "execution_secrets" {
  count = local.create_execution_role && length(local.auth_secret_arns) > 0 ? 1 : 0

  name   = "eap-${var.domain}-${var.name}-otel-exec-secrets"
  role   = aws_iam_role.execution[0].id
  policy = data.aws_iam_policy_document.task_secrets[0].json
}

# ---------------------------------------------------------------------------
# ECS task definition — collector container.
# The container's collector config/command is a STUB (see local.collector_config_stub);
# task 6 mounts the rendered fan-out config and finalizes the command.
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "collector" {
  family                   = "eap-${var.domain}-${var.name}-otel"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "otel-collector"
      image     = var.collector_image
      essential = true

      # Rendered THIRD-PARTY-ONLY collector config (tasks 7.3 + 7.6). The ADOT
      # collector reads its full config inline from AOT_CONFIG_CONTENT, so no
      # config file needs to be mounted. This config has an OTLP receiver +
      # third-party pipeline(s) resolved from var.third_party_backends (Langfuse
      # by default), each exporter with its own non-blocking sending_queue +
      # retry_on_failure. It contains ZERO AWS-native exporters/pipelines.
      #
      # NOTE: this NEVER sets OTEL_EXPORTER_OTLP_ENDPOINT — that would divert
      # AgentCore's own AWS-native export away from CloudWatch/X-Ray.
      environment = [
        {
          name  = "AOT_CONFIG_CONTENT"
          value = local.collector_config_yaml
        }
      ]

      # Task 7.8 — inject the per-BU / third-party auth secret VALUES as the
      # EAP_OTLP_AUTH_<NAME> env vars the rendered config's `${env:...}`
      # Authorization headers reference. Each maps to its backend's Secrets
      # Manager ARN via valueFrom (no plaintext in the task definition). Empty
      # when no third-party backend declares an auth secret.
      secrets = local.container_secrets

      portMappings = [
        { containerPort = var.otlp_grpc_port, protocol = "tcp" },
        { containerPort = var.otlp_http_port, protocol = "tcp" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.collector.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "otel"
        }
      }
    }
  ])

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Cloud Map service discovery — in-VPC OTLP receiver endpoint
# ---------------------------------------------------------------------------
resource "aws_service_discovery_private_dns_namespace" "this" {
  count = var.enable_service_discovery ? 1 : 0

  name        = var.service_discovery_namespace
  description = "EAP OTel collector service discovery (${var.domain})"
  vpc         = var.vpc_id

  tags = local.module_tags
}

resource "aws_service_discovery_service" "collector" {
  count = var.enable_service_discovery ? 1 : 0

  name = var.name

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this[0].id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.module_tags
}

# ---------------------------------------------------------------------------
# Internal NLB — alternative OTLP receiver endpoint (optional)
# ---------------------------------------------------------------------------
resource "aws_lb" "collector" {
  enable_deletion_protection = var.alb_deletion_protection
  count                      = var.enable_internal_nlb ? 1 : 0

  name               = "eap-${var.domain}-${var.name}-otel"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  tags = local.module_tags
}

resource "aws_lb_target_group" "collector_grpc" {
  count = var.enable_internal_nlb ? 1 : 0

  name        = "eap-${var.domain}-${var.name}-grpc"
  port        = var.otlp_grpc_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  tags = local.module_tags
}

resource "aws_lb_listener" "collector_grpc" {
  count = var.enable_internal_nlb ? 1 : 0

  load_balancer_arn = aws_lb.collector[0].arn
  port              = var.otlp_grpc_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.collector_grpc[0].arn
  }
}

# ---------------------------------------------------------------------------
# ECS Fargate service — runs the collector in private subnets
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "collector" {
  name            = var.name
  cluster         = local.cluster_arn
  task_definition = aws_ecs_task_definition.collector.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.collector.id]
    assign_public_ip = false
  }

  dynamic "service_registries" {
    for_each = var.enable_service_discovery ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.collector[0].arn
    }
  }

  dynamic "load_balancer" {
    for_each = var.enable_internal_nlb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.collector_grpc[0].arn
      container_name   = "otel-collector"
      container_port   = var.otlp_grpc_port
    }
  }

  tags = local.module_tags
}
