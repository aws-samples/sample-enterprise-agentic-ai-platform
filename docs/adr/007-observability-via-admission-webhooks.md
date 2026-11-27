# ADR-007: Observability via Mutating Admission Webhooks

**Status:** Accepted  
**Date:** 2026-03-12

**Context:** Observability needs to be injected into every agent deployment without requiring app teams to configure it. This is a cross-cutting concern owned by the platform team.

**Decision:** EAP uses Kubernetes mutating admission webhooks to automatically inject the OpenTelemetry (OTel) no-code auto-instrumentation agent into agent pods at admission time.

**How it works:**
1. Platform_Admin deploys the OTel Operator (or EAP's built-in webhook) and configures the `Instrumentation` CR with the desired exporters, sampling, and resource attributes
2. When an app team applies a `Runtime` CRD and the controller creates the agent pod, the mutating webhook intercepts the pod creation
3. The webhook injects the OTel auto-instrumentation agent (init container + environment variables) into the pod spec
4. The agent runs with full tracing, metrics, and logging — zero configuration from the app team
5. Telemetry flows to AgentCore Observability (CloudWatch) and any additional OTel-compatible backends

**Rationale:**
- Same pattern as Istio sidecar injection and OTel Operator auto-instrumentation — proven K8s pattern
- App teams get observability for free — no code changes, no manifest additions
- Platform_Admin controls what gets instrumented, sampling rates, and export destinations
- Domain-scoped configuration possible via namespace-level `Instrumentation` CRs
- Works with AgentCore Observability's existing OpenTelemetry integration

**Consequences:**
- Requires OTel Operator or custom mutating webhook deployed as part of EAP Helm chart
- Platform_Admin manages `Instrumentation` CRs per namespace/domain
- App teams can override or opt-out via pod annotations if needed
- All agent telemetry is automatically correlated with platform-level traces
