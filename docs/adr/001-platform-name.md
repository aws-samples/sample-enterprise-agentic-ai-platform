# ADR-001: Platform Name

**Status:** Superseded by ADR-027
**Date:** 2026-03-12

**Context:** The platform is built on top of Amazon Bedrock AgentCore primitives. The name must be distinct from AgentCore to avoid confusion.

**Decision:** The platform is named **Declarant** — a *declarant* is one who declares. The name reflects the platform's core model: teams **declare** what they need (agents, tools, memory, policies) in YAML manifests, and the platform provisions and operates the underlying AgentCore primitives. It is a declarative Enterprise Agentic AI Platform — YAML in, infrastructure out.

**Consequences:** All platform-layer concepts use the Declarant prefix. Terraform modules mirror AgentCore primitive names directly (runtime, gateway, memory, identity, policy, observability, evaluations, code-interpreter, browser). Platform-specific modules use Declarant naming (domain, pipeline).
