# ADR-030: Private, Pluggable Observability — Always-On Collector, Optional Langfuse, External OTLP Backend

**Status:** Accepted
**Date:** 2026-09-02

**Supersedes:** ADR-025 (Agent Observability — AWS-Native + Pluggable OTLP)

## Context

ADR-025 established that "OpenTelemetry is an emission standard, not a
destination" and that third-party backends are pluggable. Its follow-on
(the `agentcore-observability` spec) then made a self-hosted **Langfuse** stack
the default third-party backend — but fronted it with a **public** CloudFront +
HTTPS ALB (requiring an ACM certificate) and gated the whole third-party leg
off-by-default behind that cert.

Two problems for the target deployment:

1. **Enterprise = no public access.** This platform is deployed for an
   enterprise that does not permit public endpoints. A public CloudFront/HTTPS
   edge for Langfuse is not acceptable, and the ACM-cert prerequisite made the
   default awkward.
2. **Langfuse is just one OTLP backend.** Langfuse, Fiddler, and Datadog are the
   same category — an OTLP destination. Treating Langfuse as a specially-hosted
   first-class stack, while other backends are "alternates," is inconsistent.
   The right model mirrors the IdP decision (ADR-028): the platform provides a
   default, and the deployer can point at their own instead.

## Decision

Observability is **private and pluggable**. The always-on AWS-native leg
(CloudWatch GenAI Observability + X-Ray) is unchanged. The third-party leg is
reworked as follows:

1. **The OTel Collector is ALWAYS deployed** (in the resolved VPC). Agents ship
   a copy of their spans to the in-VPC collector, which fans out to the
   configured backend(s). The collector publishes its OTLP endpoint to a fixed
   SSM parameter the base image reads at boot (unchanged mechanism).

2. **Langfuse is an OPTIONAL, PRIVATE default backend** (`deploy_langfuse`,
   default `true`). Its edge is simplified to a **private internal ALB over
   HTTP** — **no CloudFront, no HTTPS listener, no ACM certificate, no
   ALB-level Cognito authenticate action, no CSP/frame-ancestors policy**.
   Access is gated by **network isolation** (VPN/corp network) plus Langfuse's
   own application login. Reachable only from within the VPC.

3. **An external OTLP backend** (Datadog/Fiddler/Langfuse Cloud/…) is supplied
   via `otel_backend_endpoint` + `otel_backend_auth_secret_arn` +
   `otel_backend_mode` (`add` | `replace`, default `add`). `add` fans out
   alongside Langfuse; `replace` sends to the external backend instead. The auth
   secret is granted to the collector task role as `secretsmanager:GetSecretValue`
   only. Backend resolution:

   | `deploy_langfuse` | `otel_backend_endpoint` | Collector exports to |
   |---|---|---|
   | true (default) | empty (default) | Langfuse (private, self-hosted) |
   | true | set | Langfuse + external (`add`) / external only (`replace`) |
   | false | set | external only |
   | false | empty | nothing (collector up, third-party leg dormant) |

4. **VPC is import-or-create.** `vpc_id` empty (default) => the platform creates
   a VPC with **full egress** (Internet Gateway + NAT gateway + per-AZ private
   route tables) so in-VPC Fargate tasks can pull images from ECR and reach AWS
   APIs. When `vpc_id` is set, the deployer also supplies `private_subnet_ids`
   and `public_subnet_ids` **explicitly** (not inferred) — governed enterprise
   VPCs have isolated/egress subnet tiers that cannot be safely auto-classified,
   and the supplied private subnets MUST have egress (NAT or VPC endpoints).

## Consequences

- **No public exposure.** No CloudFront, no public ALB, no ACM cert anywhere in
  the default observability path — consistent with the enterprise posture.
- **Consistent pluggable model.** Langfuse/Fiddler/Datadog are all "an OTLP
  endpoint"; the platform provides Langfuse by default and the deployer swaps in
  their own by config — mirroring the IdP model (ADR-028).
- **Standing cost.** Because the collector (and, by default, Langfuse) are
  always on, the default deploy carries standing infrastructure: a VPC + NAT
  gateway + the collector Fargate task, and (with `deploy_langfuse=true`) the
  Langfuse datastores (Aurora Serverless v2 + ClickHouse-on-Fargate + Redis).
  This is a deliberate "batteries-included observability" choice and a reversal
  of the prior ~$1–2/mo idle posture. Operators control it via `deploy_langfuse`
  and by importing a VPC. Documented in the runbook FinOps section.
- **ALB-level SSO removed for Langfuse.** The private model drops the ALB
  `authenticate-cognito` gate; access control becomes network isolation +
  Langfuse app auth. Acceptable for a VPN/corp-network-only deployment.
- **Console embed is an interim gap.** The console is still public (CloudFront)
  while Langfuse is private, so the embedded-Langfuse iframe only loads for
  on-network (VPN/corp) users; the AWS-native CloudWatch panels + deep-links
  always work. **Making the console private is tracked as future work.**

## Alternatives Considered

- **Keep the public CloudFront/HTTPS Langfuse edge.** Rejected: violates the
  enterprise no-public-access requirement and forces an ACM/domain prerequisite.
- **Agents ship directly to the backend (no collector).** Rejected: the collector
  is kept always-on so there is one consistent egress path and centralized
  credential/fan-out; agents stay backend-agnostic.
- **Infer imported-VPC subnets from a single `vpc_id`.** Rejected for the BYO-VPC
  case: governed enterprise VPCs mix isolated and egress subnet tiers that
  route-table heuristics cannot safely classify; explicit subnet IDs avoid
  opaque image-pull failures.

---
