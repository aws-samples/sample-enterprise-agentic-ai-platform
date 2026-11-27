# ADR-004: 1:1 CRD-to-AgentCore API Mapping — No Higher-Level Abstractions

**Status:** Accepted (supersedes previous ADR-004)  
**Date:** 2026-03-12

**Context:** The original design had a composite `Agent` CRD that orchestrated multiple AgentCore services (Runtime + Memory + Identity + Gateway + Policy + Observability) in a single reconciliation loop. This meant the platform was defining higher-level abstractions over AgentCore primitives — effectively making platform teams the architects of agent resource composition. Platform teams are not agent development SMEs; they should operate infrastructure and enforce cross-cutting concerns, not define how agents are assembled.

**Decision:** CRDs map 1:1 to AgentCore primitives. Each CRD has the same name as its AgentCore counterpart. No composite abstractions.

| CRD | Controller | AgentCore API | Owner |
|-----|-----------|---------------|-------|
| `Runtime` | RuntimeReconciler | AgentCore Runtime | App_Team |
| `Gateway` | GatewayReconciler | AgentCore Gateway | Shared_Services_Team |
| `Memory` | MemoryReconciler | AgentCore Memory | Platform_Admin (provision) / App_Team (claim) |
| `Identity` | IdentityReconciler | AgentCore Identity | Platform_Admin |
| `Policy` | PolicyReconciler | AgentCore Policy | Platform_Admin / Domain_Admin |
| `Observability` | ObservabilityReconciler | AgentCore Observability | Platform_Admin |
| `Evaluations` | EvaluationsReconciler | AgentCore Evaluations | App_Team / Domain_Admin |
| `CodeInterpreter` | CodeInterpreterReconciler | AgentCore Code Interpreter | App_Team |
| `Browser` | BrowserReconciler | AgentCore Browser | App_Team |
| `Domain` | DomainReconciler | AgentCore Policy (isolation) | Platform_Admin |
| `MemoryClaim` | MemoryClaimReconciler | AgentCore Memory (bind) | App_Team |
| `Pipeline` | PipelineReconciler | AgentCore Runtime (dispatch) | App_Team |

App teams apply the CRDs they need — potentially all in a single YAML file — and each controller reconciles its CRD against the corresponding AgentCore API independently.

**Rationale:**
- App teams are the SMEs — they know what their agent needs (which memory type, which tools, which identity model)
- Platform teams operate, not abstract — they configure identity providers, inject observability, enforce policies, provision shared resources
- 1:1 mapping is transparent — no hidden orchestration, no magic. What you apply is what gets created in AgentCore
- Aligns with ACK (AWS Controllers for Kubernetes) model — if AWS ships an ACK AgentCore controller, EAP's CRDs could be replaced or augmented
- Single YAML file can still declare Runtime + Memory + Gateway + Identity together — K8s handles multi-resource documents natively

**Consequences:**
- No composite `Agent` CRD — the previous `AgentReconciler` that orchestrated 6 services is removed
- Each controller is truly single-responsibility: one CRD → one AgentCore API
- Cross-cutting concerns (observability, identity, policy) are injected by the platform via webhooks and default policies, not by composing them into the agent CRD
- App teams have full control over which AgentCore primitives their agent uses
