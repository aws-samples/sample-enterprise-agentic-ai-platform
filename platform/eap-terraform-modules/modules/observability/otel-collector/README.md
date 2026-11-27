# OTel_Collector Module — THIRD-PARTY LEG ONLY

Central Gateway OpenTelemetry Collector (ADOT distribution) deployed as an ECS
Fargate service in **private subnets**, exposing an in-VPC OTLP receiver
endpoint via AWS Cloud Map service discovery and/or an internal Network Load
Balancer.

## Scope and the two-leg model

This collector sits **exclusively on the platform's third-party telemetry leg**.
The platform has two structurally independent telemetry legs that originate from
one agent process:

1. **AWS-native leg (always-on, AgentCore-managed) — NOT this module.**
   AgentCore-managed ADOT auto-instrumentation in the Strands base image exports
   telemetry **directly** to CloudWatch GenAI Observability and X-Ray Transaction
   Search. It is **never routed through any collector**. This module has nothing
   to do with that leg.
2. **Third-party leg (additive) — this module.** The base-image
   `Additional_Span_Exporter` sends a **copy** of the same spans to this
   collector over OTLP. The collector fans that copy out **only** to the
   configured third-party OTLP backend(s) — Langfuse by default.

### Hard constraint: no AWS-native receivers or exporters

This collector has **NO** AWS-native receivers or exporters and **NEVER**
exports to CloudWatch or X-Ray. Specifically, the rendered collector config
(implemented in Section 7) MUST contain:

- **Zero** `awsxray`, `awsemf`, or `awscloudwatchlogs` exporters.
- **No** `traces/aws`, `metrics/aws`, or `logs/aws` pipeline.

And the collector's IAM **task role** MUST hold **only** Secrets Manager read
(for per-BU third-party auth secrets). It MUST **never** be granted
`xray:PutTraceSegments`, any `logs:*` write, or `cloudwatch:PutMetricData` / EMF.
(The task-role permission set is wired and enforced in **task 7.8**.)

Because the AWS-native leg is a separate AgentCore-managed pipeline that does not
traverse this collector, no state of this collector — saturated queues, crash,
misconfiguration, or any `Backend_Configuration` value — can add, remove,
reroute, or disable AWS-native export. That independence is **structural**, not
template-conditional.

### Endpoint wiring — never override `OTEL_EXPORTER_OTLP_ENDPOINT`

The runtime module points the base-image `Additional_Span_Exporter` at this
collector via the `EAP_OTEL_COLLECTOR_ENDPOINT` environment variable.
This module and its consumers **never** set or override
`OTEL_EXPORTER_OTLP_ENDPOINT` — doing so would divert AgentCore's own export away
from CloudWatch/X-Ray. See the `otlp_grpc_endpoint` / `otlp_http_endpoint`
outputs.

## Status

This module stands up:

- the ECS Fargate service (private subnets) and its security group,
- the OTLP receiver endpoint (Cloud Map service discovery and/or internal NLB),
- the `third_party_backends` variable (the Backend_Configuration swap point),
- the rendered **third-party-only** collector config (task 7.3) with per-exporter
  non-blocking `sending_queue` + `retry_on_failure` (task 7.6),
- **least-privilege IAM (task 7.8)**: the task role is granted EXACTLY
  `secretsmanager:GetSecretValue` for the resolved third-party auth secret ARNs
  and nothing else (no telemetry write); the execution role keeps the standard
  `AmazonECSTaskExecutionRolePolicy` (image pull + its own log group) plus a
  scoped secrets read so ECS can resolve the container `secrets` valueFrom refs,
- **auth secret injection (task 7.8)**: each resolved backend's auth secret is
  injected into the collector container as the `EAP_OTLP_AUTH_<NAME>` env
  var the rendered config's `${env:...}` Authorization header references, via
  container `secrets` valueFrom (the render itself stays secret-free),
- **per-BU Langfuse routing (task 10.4)**: when `langfuse_project_bindings` is
  set, the render emits one `otlphttp/langfuse-<bu>` exporter per BU (pointed at
  the shared `default_langfuse_endpoint`, each with its own non-blocking
  `sending_queue` + `retry_on_failure`), a `routing` connector keyed on the
  `deployment.environment` (BU) resource attribute, a `traces/thirdparty`
  pipeline (otlp → batch → routing) and one `traces/langfuse-<bu>` pipeline per
  BU (routing → that BU's exporter); each BU's `otlp_basic_auth_secret_arn` is
  injected as its `EAP_OTLP_AUTH_LANGFUSE_<BU>` env var and is the ONLY
  addition to the secrets-read grant (still no CloudWatch/X-Ray/Logs write), and
- a CloudWatch log group for the collector container.

The following remain as clearly-marked **STUBS/seams** for later sections:

| Stub | Filled by |
|------|-----------|
| Per-BU `routing` connector + per-BU `otlphttp` exporters into the config render | task 10.4 ✅ done |
| Per-BU Langfuse project auth secrets (`default_langfuse_auth_secret_arn`) provisioning | task 10.1 |
| Base-image `Additional_Span_Exporter` → collector endpoint runtime wiring | Section 6 (runtime module) |

### Task-role permission surface (task 7.8, R16.5)

The collector task role's ENTIRE permission set is
`secretsmanager:GetSecretValue` on exactly the resolved third-party auth secret
ARNs (`third_party_backends[*].auth_secret_arn` + `default_langfuse_auth_secret_arn`
when set). It is granted **NO** `xray:PutTraceSegments`, **NO** `logs:*` write,
and **NO** `cloudwatch:PutMetricData` / EMF. This makes "the collector is
third-party leg only" an IAM-enforced property in addition to the config-render
structural guarantee. When no auth secret is configured, no secrets policy is
attached and the task role holds nothing beyond its trust policy.

## Backend_Configuration (`third_party_backends`)

```hcl
third_party_backends = [
  {
    name            = "langfuse"        # "langfuse" | "fiddler" | "datadog" | ...
    otlp_endpoint   = "https://..."     # third-party OTLP receiver URL
    auth_secret_arn = "arn:aws:secretsmanager:..."
    mode            = "add"             # "replace" | "add" (relative to default Langfuse)
    enabled         = true
  }
]
```

- Empty (default `[]`) → the collector exports to the default Langfuse backend
  only.
- `mode = "replace"` → render the alternate in place of Langfuse.
- `mode = "add"` → render Langfuse **and** the alternate.

Every resolved exporter is a third-party OTLP exporter; the render never
produces an AWS-native exporter (enforced in Section 7).

## Requirements

- R12.1 (scaffold — this task 1.4)
- R12.2, R12.3, R16.* (third-party-only render — Section 7)
