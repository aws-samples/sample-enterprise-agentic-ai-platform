# Architecture Decision Records (ADR)

This is the single index for all platform Architecture Decision Records.

An ADR captures one significant architectural decision — its context, the
decision, and its consequences. ADRs are **append-only and immutable**: once a
number is assigned it is never reused or renumbered. A decision that changes is
recorded as a *new* ADR that marks the older one `Superseded`.

## Conventions

- **Location:** all ADRs (001 onward) live in `docs/adr/` as `NNN-slug.md`
  (zero-padded 3-digit number + kebab-case slug), e.g. `025-observability.md`.
- **Numbering:** sequential and monotonic. The next ADR is **049**. Never
  renumber an existing ADR.
- **Status:** `Proposed` → `Accepted` → (`Superseded by ADR-NNN` | `Deprecated`).
- **Authoring:** copy `template.md`, assign the next free number, fill it in.

## ADR Index

| # | Decision | Date | File |
|---|----------|------|------|
| 001 | Platform named **Declarant** | 2026-03-12 | [001-platform-name.md](001-platform-name.md) · superseded by 027 |
| 002 | Kubernetes-native architecture | 2026-03-12 | [002-kubernetes-native-architecture.md](002-kubernetes-native-architecture.md) · parked (K8s track) |
| 003 | Go + React stack | 2026-03-12 | [003-tech-stack.md](003-tech-stack.md) · parked (K8s track) |
| 004 | 1:1 CRD-to-AgentCore mapping | 2026-03-12 | [004-crd-to-agentcore-mapping.md](004-crd-to-agentcore-mapping.md) · parked (K8s track) |
| 005 | controller-runtime for MVP | 2026-03-12 | [005-controller-runtime-for-mvp.md](005-controller-runtime-for-mvp.md) · parked (K8s track) |
| 006 | No higher-level abstractions | 2026-03-12 | [006-no-higher-level-abstractions.md](006-no-higher-level-abstractions.md) |
| 007 | Observability via mutating admission webhooks | 2026-03-12 | [007-observability-via-admission-webhooks.md](007-observability-via-admission-webhooks.md) · parked (K8s track) |
| 008 | AgentCore primitives are hybrid (app + infra) | 2026-03-12 | [008-agentcore-primitives-hybrid.md](008-agentcore-primitives-hybrid.md) |
| 009 | Two-track strategy (Terraform + K8s) | 2026-03-12 | [009-two-track-strategy.md](009-two-track-strategy.md) |
| 010 | Terraform for the MVP track | 2026-03-12 | [010-terraform-for-mvp-track.md](010-terraform-for-mvp-track.md) |
| 011 | PV/PVC pattern not needed (managed Memory) | 2026-03-12 | [011-no-pv-pvc-for-memory.md](011-no-pv-pvc-for-memory.md) |
| 012 | Multi-repo strategy | 2026-03-12 | [012-multi-repo-strategy.md](012-multi-repo-strategy.md) |
| 013 | Amazon ECR for agent images | 2026-03-12 | [013-ecr-for-agent-images.md](013-ecr-for-agent-images.md) |
| 014 | Domain-level IdP groups for agent identity | 2026-03-12 | [014-domain-level-idp-groups.md](014-domain-level-idp-groups.md) |
| 015 | Horizontal injection via base images | 2026-03-12 | [015-horizontal-injection-base-images.md](015-horizontal-injection-base-images.md) |
| 016 | Agent communication protocols as an extensible horizontal | 2026-03-12 | [016-agent-communication-protocols.md](016-agent-communication-protocols.md) |
| 017 | Identity Architecture | 2026-03-23 | [017-identity-architecture.md](017-identity-architecture.md) |
| 018 | Platform Vending Model — Multi-BU, Config-Driven | 2026-03-27 | [018-platform-vending-model.md](018-platform-vending-model.md) |
| 019 | Authorization Model — Scopes, Cedar, AgentCore Policy | 2026-04-14 | [019-authorization-scopes-policy.md](019-authorization-scopes-policy.md) |
| 020 | Multi-Agent Orchestration — Step Functions + A2A Mesh | 2026-04-14 | [020-multi-agent-orchestration.md](020-multi-agent-orchestration.md) |
| 021 | Generic Agent Chat UI vs Per-Agent UI Generation | 2026-04-27 | [021-studio-generic-chat-ui.md](021-studio-generic-chat-ui.md) |
| 022 | LLM Safety and Guardrails — OWASP Top 10 for LLMs | 2026-04-30 | [022-llm-safety-guardrails.md](022-llm-safety-guardrails.md) |
| 023 | Studio MCP Catalog Scoping | 2026-05-04 | [023-studio-mcp-catalog-scoping.md](023-studio-mcp-catalog-scoping.md) |
| 024 | Agent Evaluation Separation of Concerns | 2026-06-03 | [024-evaluation-separation-of-concerns.md](024-evaluation-separation-of-concerns.md) |
| 025 | Agent Observability — AWS-Native + Pluggable OTLP | 2026-07-23 | [025-observability.md](025-observability.md) · superseded by 030 |
| 026 | Platform State Architecture — Three Layers of State | 2026-07-23 | [026-platform-state-architecture.md](026-platform-state-architecture.md) |
| 027 | Rename Platform Tortellini → Declarant | 2026-09-02 | [027-rename-tortellini-to-declarant.md](027-rename-tortellini-to-declarant.md) · superseded by 044 |
| 028 | Deployer-Supplied OIDC Identity Provider | 2026-09-02 | [028-deployer-supplied-oidc.md](028-deployer-supplied-oidc.md) |
| 029 | Repository Layout — `platform/` vs `users/` | 2026-09-02 | [029-repo-layout-platform-vs-users.md](029-repo-layout-platform-vs-users.md) |
| 030 | Private, Pluggable Observability — Always-On Collector, Optional Langfuse, External OTLP | 2026-09-02 | [030-observability-private-pluggable.md](030-observability-private-pluggable.md) |
| 031 | Agent Workloads Run In-VPC by Default | 2026-09-02 | [031-agent-workloads-in-vpc.md](031-agent-workloads-in-vpc.md) |
| 032 | Platform Lambdas Run In-VPC; Complete the VPC Endpoint Set | 2026-09-02 | [032-platform-lambdas-in-vpc.md](032-platform-lambdas-in-vpc.md) |
| 033 | Externalizable (Bring-Your-Own) IAM Roles for Restricted Deployers | 2026-09-02 | [033-externalizable-iam-roles.md](033-externalizable-iam-roles.md) |
| 034 | Demo Console Is Optional (`deploy_console`) | 2026-09-02 | [034-optional-demo-console.md](034-optional-demo-console.md) |
| 035 | Optional Customer-Managed KMS Key for Data at Rest | 2026-09-02 | [035-customer-managed-kms.md](035-customer-managed-kms.md) |
| 036 | Two Deployment Presets — `demo` and `enterprise` (collapses poc/pilot) | 2026-09-14 | [036-two-preset-model.md](036-two-preset-model.md) |
| 037 | Demo Console Examples Surface — Hardened CloudFront → ALB → Fargate | 2026-09-14 | [037-demo-console-examples-surface.md](037-demo-console-examples-surface.md) |
| 038 | Expose Langfuse UI Publicly Through the Hardened Demo Console Edge | 2026-09-14 | [038-langfuse-public-via-console-edge.md](038-langfuse-public-via-console-edge.md) · superseded by 039 |
| 039 | Langfuse via Its Own Dedicated Hardened CloudFront (not a console subpath) | 2026-09-14 | [039-langfuse-dedicated-cloudfront.md](039-langfuse-dedicated-cloudfront.md) |
| 040 | Streaming ADE Invoke via an Always-On ECS/Fargate Backend | 2026-09-18 | [040-ade-streaming-invoke-backend.md](040-ade-streaming-invoke-backend.md) |
| 041 | Retire API Gateway — All Console Backends on ALB/Fargate | 2026-09-18 | [041-retire-api-gateway-all-backends-on-alb.md](041-retire-api-gateway-all-backends-on-alb.md) |
| 042 | Force Private Invocation of AgentCore Runtimes (and Lambdas) — Endpoint Policies + `aws:sourceVpce` Deny | 2026-09-25 | [042-private-invocation-endpoints.md](042-private-invocation-endpoints.md) |
| 043 | Enterprise Agent SDK as the Single Horizontal-Injection Implementation — Base Image Dogfoods It, CI Enforces Usage, Floci Local Testing | 2026-09-30 | [043-enterprise-agent-sdk-and-local-testing.md](043-enterprise-agent-sdk-and-local-testing.md) |
| 044 | Rename Platform Declarant → Enterprise Agentic AI Platform (EAP) | 2026-11-12 | [044-rename-declarant-to-eap.md](044-rename-declarant-to-eap.md) |
| 045 | Teardown Destroys Each App Through Its Own State Before the Platform | 2026-11-13 | [045-teardown-destroys-app-state-first.md](045-teardown-destroys-app-state-first.md) |
| 046 | Examples Backend Requires a Verified Caller JWT and a Lifecycle Allow-List | 2026-11-24 | [046-examples-backend-caller-auth.md](046-examples-backend-caller-auth.md) · amends 037 |
| 047 | Verify JWT Signatures in Every Console Backend | 2026-11-24 | [047-jwt-signature-verification-all-backends.md](047-jwt-signature-verification-all-backends.md) |
| 048 | Manual Approval Before Deploying ADE-Generated Agents | 2026-11-24 | [048-manual-approval-for-generated-agents.md](048-manual-approval-for-generated-agents.md) |

_Next available number: **049**._
