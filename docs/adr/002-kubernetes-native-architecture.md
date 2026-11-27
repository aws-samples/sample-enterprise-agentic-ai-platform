# ADR-002: Kubernetes-Native Architecture

**Status:** Accepted  
**Date:** 2026-03-12

**Context:** EAP needs a runtime platform. Options considered: standalone Go binary, serverless (Lambda), or Kubernetes-native (CRDs + operators). The platform's core metaphor is Kubernetes-inspired (control plane, declarative resources, reconciliation loops, PV/PVC, Gateway API, OIDC connectors).

**Decision:** EAP runs exclusively on Kubernetes as a set of CRDs and controller-runtime operators.

- All CRDs mirror AgentCore primitives 1:1 (same names as AgentCore services):
  - `Runtime` — agent deployment to AgentCore Runtime (container image, framework, session config)
  - `Gateway` — MCP server registration, tool routing via AgentCore Gateway
  - `Memory` — memory store provisioning via AgentCore Memory (short-term, long-term, episodic)
  - `Identity` — OIDC federation, agent identity via AgentCore Identity
  - `Policy` — Cedar policy rules via AgentCore Policy
  - `Observability` — telemetry configuration via AgentCore Observability
  - `Evaluations` — quality monitoring via AgentCore Evaluations
  - `CodeInterpreter` — sandbox code execution via AgentCore Code Interpreter
  - `Browser` — serverless browser sessions via AgentCore Browser
- Platform-level CRDs (EAP-specific, not AgentCore mirrors):
  - `Domain` — logical boundary for federated administration
  - `MemoryClaim` — PVC-style request for memory (binds to a `Memory` resource)
  - `Pipeline` — directed graph of agent execution steps
- State managed by K8s API server (etcd)
- GitOps-native: CRDs are YAML manifests, deployable via ArgoCD/Flux
- Installable via Helm chart
- Local development via kind or minikube

**Rationale:**
- Maximizes adoption — teams already running K8s adopt EAP with zero new infrastructure
- Leverages the K8s ecosystem: RBAC, namespaces, Helm, ArgoCD/Flux, Prometheus, admission webhooks
- Reconciliation loops, watch/informer, and status reporting come free with controller-runtime
- No custom state store to operate — etcd is managed by the K8s cluster
- `kubectl get runtimes`, `kubectl get gateways`, `kubectl get memories` — native K8s UX with AgentCore-native naming

**Consequences:**
- Requires a Kubernetes cluster (EKS recommended) to run EAP
- Local development uses kind or minikube
- CRD schemas maintained alongside Go types via controller-gen
