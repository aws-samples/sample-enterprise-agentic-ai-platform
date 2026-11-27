# ADR-003: Tech Stack

**Status:** Accepted  
**Date:** 2026-03-12

**Context:** Need to choose languages and frameworks for the K8s operators and the Admin Console UI.

**Decision:**
- **K8s Operators:** Go (Golang) via controller-runtime — one controller per AgentCore primitive CRD (Runtime, Gateway, Memory, Identity, Policy, Observability, Evaluations, CodeInterpreter, Browser) plus platform CRDs (Domain, MemoryClaim, Pipeline)
- **AgentCore Integration:** AWS SDK for Go v2 — controllers call AgentCore APIs to reconcile desired state
- **Admin Console UI:** React (TypeScript) — visual agent builder, pipeline composer, domain-scoped dashboards, policy editor
- **CLI:** Go — `eap` CLI for interacting with the platform (wraps kubectl + custom commands)
- **Installation:** Helm chart

**Rationale:**
- Go + controller-runtime is the standard for K8s operators (used by Kubernetes itself, ArgoCD, Istio, Crossplane)
- AWS SDK for Go v2 is the official SDK for AgentCore API integration
- React/TypeScript is the standard for complex interactive UIs
- Single language (Go) for all backend components simplifies the build pipeline

**Consequences:** No Python in the stack. The entire backend is Go. Teams familiar with the K8s operator ecosystem will feel at home.
