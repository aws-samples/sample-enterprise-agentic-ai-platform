# ADR-015: Horizontal Injection via Base Images + Build/Deploy Validation

**Status:** Accepted
**Date:** 2026-03-16

**Context:** R20 requires agent communication protocol compliance on all AgentCore Runtime deployments (see ADR-016 for the decision to treat all protocols as a single extensible horizontal). The protocol horizontal is not just a Terraform configuration flag — the agent container itself must implement the protocol contracts. For example, the A2A protocol contract requires:

- JSON-RPC 2.0 over HTTP transport
- Listen on port 9000 (`0.0.0.0:9000`) — different from HTTP (8080) and MCP (8000)
- Serve Agent Card at `GET /.well-known/agent-card.json`
- Accept JSON-RPC messages at `POST /`
- Respond to health checks at `GET /ping`
- ARM64 container platform (required by AgentCore Runtime)
- Support OAuth 2.0 Bearer tokens and SigV4 authentication
- Return standard JSON-RPC error codes (-32501 through -32055)

Setting `protocols = ["mcp", "a2a"]` in the runtime module HCL tells AgentCore Runtime to route A2A traffic to the container, but if the container doesn't implement the protocol contract, A2A calls will fail at runtime.

The same injection problem applies to other horizontals at the container level:
- **Observability:** OTel auto-instrumentation must be present in the container for traces/metrics to flow. The Terraform observability module configures the backend, but the container needs the instrumentation agent and exporter.
- **Identity:** Outbound calls from the agent (to AWS services, third-party APIs) need credential management. The Terraform identity module provisions the agent's IdP user, but the container needs a credential helper SDK for OAuth token refresh and SigV4 signing.
- **Logging:** Structured JSON logging with trace ID correlation must be configured in the container for observability to work end-to-end.
- **Security:** Non-root user, minimal packages, CA certs — container-level security hardening.

The question is: how does the platform ensure App_Team containers include all horizontal dependencies without making App_Teams infrastructure experts?

Options considered:

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **Documentation only** | Provide docs, let App_Teams implement A2A + OTel + credentials themselves | Simple for platform team | High friction for App_Teams. Protocol and instrumentation errors discovered at runtime. Breaks "fire and forget" model. |
| **Runtime-only validation** | Check A2A endpoints after deploy | Catches non-compliance | Too late — agent is already deployed and broken. Bad UX. Doesn't cover OTel/credentials. |
| **Build-time validation only** | Validate container in CodePipeline before deploy | Catches early | Doesn't help App_Teams build compliant containers. Still requires protocol + instrumentation knowledge. |
| **Base images with all horizontals + build/deploy validation** | Platform provides base images per framework embedding all container-level horizontals (A2A, OTel, credentials, logging, security). Build stage validates. Deploy stage verifies. | Zero friction for base image users. All horizontals injected consistently. Early catch for custom containers. Defense in depth. | Platform must maintain base images per framework. More components to test per image. |

**Decision:** Three-layer approach to A2A compliance:

**Layer 1: Base container images with all container-level horizontals (path of least resistance)**
- Platform_Admin publishes base images to ECR — one per supported framework (Strands, LangGraph, CrewAI)
- Base images embed all container-level horizontal dependencies:
  - **A2A Protocol:** Full A2A protocol contract — port 9000, JSON-RPC handler, agent card endpoint, `/ping` health check, error codes
  - **OTel Auto-Instrumentation:** Language-specific auto-instrumentation agent, pre-configured OTLP exporter, trace context propagation (W3C TraceContext), resource attributes from env vars
  - **Identity Credential Helper:** AgentCore Identity SDK / credential provider for outbound calls — OAuth token refresh, SigV4 signing
  - **Structured Logging:** JSON logger to stdout with trace ID correlation, consistent field schema
  - **Security Baseline:** Non-root user, minimal OS packages, CA certs bundle
  - **Env Var Contract:** Reads `AGENTCORE_RUNTIME_URL`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `EAP_DOMAIN`, `EAP_AGENT_NAME` — all injected by runtime module at deploy time
- App_Teams `FROM eap-base-{framework}:latest` and add their agent logic (tools, prompts, business code, `agent-card.yaml`)
- The base image handles all horizontal plumbing — App_Teams never write JSON-RPC handlers, OTel instrumentation, credential management, or logging setup
- Starter templates provided in `eap-modules` repo as reference implementations for teams that need custom containers

**Layer 2: Build-time validation in CodePipeline**
- The container build stage (CodeBuild) validates A2A readiness before pushing to ECR:
  1. Verify Dockerfile targets ARM64 platform (`--platform linux/arm64`)
  2. Start the built container locally in CodeBuild
  3. Smoke test: `GET /ping` returns HTTP 200
  4. Smoke test: `GET /.well-known/agent-card.json` returns valid Agent Card JSON
  5. Smoke test: `POST /` with a minimal JSON-RPC request returns a valid JSON-RPC response
- If any check fails, pipeline blocks before Terraform plan — App_Team gets actionable error messages
- This catches custom containers that don't implement the contract

**Layer 3: Deploy-time verification (defense in depth)**
- CodePipeline post-deploy stage (Lambda) calls the deployed agent's endpoints via AgentCore Runtime
- Verifies `/ping` and `/.well-known/agent-card.json` respond correctly in the actual runtime environment
- If verification fails: Agent_Registry marks agent as unhealthy, Observability emits alert
- Agent card from `/.well-known/agent-card.json` is auto-registered into the Agent Registry with platform metadata

**Base image architecture:**

```
Platform_Admin publishes base images (eap-modules repo)
    → eap-base-strands:latest    (Strands + all container-level horizontals)
    → eap-base-langgraph:latest  (LangGraph + all container-level horizontals)
    → eap-base-crewai:latest     (CrewAI + all container-level horizontals)
    → Each image includes: A2A protocol, OTel auto-instrumentation, credential helper,
      structured logging, security baseline, env var contract
    → Published to central ECR repo, pullable by all App_Teams

App_Team builds agent (team-{name}-agents repo)
    → FROM eap-base-strands:latest
    → ADD agent code, tools, prompts, agent-card.yaml
    → Agent inherits ALL horizontal compliance from base image
    → CodePipeline build stage validates (Layer 2)
    → CodePipeline deploy stage verifies (Layer 3)
```

**Rationale:**
- Aligns with ADR-006 — platform operates, app teams declare. A2A protocol compliance, OTel instrumentation, credential management, and security hardening are all operational concerns, not app concerns. The platform should make compliance easy, not require App_Teams to become protocol/instrumentation experts.
- Base images are the "fire and forget" path — App_Teams get all horizontals for free if they use platform base images. Same pattern as identity (ADR-014) — the platform handles the horizontal transparently.
- The base image is the container-level equivalent of what the runtime module does at the Terraform level — both inject cross-cutting concerns at their respective layers.
- Build-time validation catches custom containers early — before they reach AgentCore Runtime. Actionable errors, not runtime failures.
- Deploy-time verification is defense in depth — catches edge cases where build validation passes but runtime behavior differs (e.g., environment-specific issues).
- Agent card auto-registration from `/.well-known/agent-card.json` closes the loop with R10 (Agent Registry) — agents are discoverable immediately after deploy.

**Consequences:**
- Platform_Admin must maintain base images per framework — new framework support requires a new base image
- Base images must be versioned and published to ECR alongside module library releases
- Base image tests must validate all horizontal components (A2A, OTel, credential helper, logging, security), not just A2A
- CodePipeline template for App_Teams must include A2A validation steps in the build stage
- App_Teams using custom containers (not base images) must implement the A2A protocol contract themselves — but build-time validation catches non-compliance early. Custom containers also need to handle OTel, credentials, and logging independently.
- R1 (CodePipeline) updated: build stage includes A2A smoke tests; post-deploy stage includes A2A verification
- R13 (ECR) updated: central ECR repo for platform base images in addition to per-team repos
- R15 (Identity) updated: container-level credential helper requirement (AC 14)
- R19 (Observability) updated: container-level OTel auto-instrumentation and structured logging requirements (AC 9-11)
- R20 updated: acceptance criteria split into Infrastructure (AC 1-8) and Application (AC 9-16)

**Future / TBD:**
- **Build-time container mutation:** Instead of requiring App_Teams to use base images or implement the A2A contract, the CodePipeline build stage could automatically wrap any App_Team container with a platform proxy layer at build time. The pipeline would generate a new multi-stage Dockerfile that `FROM`s the app image and layers in a platform-provided reverse proxy + all horizontal dependencies (A2A, OTel, credential helper, structured logging) as the entrypoint. The proxy listens on port 9000, handles JSON-RPC, serves the agent card, and forwards actual agent requests to the app container's HTTP endpoint internally. OTel auto-instrumentation wraps the entire process. App_Teams would provide agent metadata (name, description, skills) via a simple `agent-card.yaml` in their repo — the wrapper reads it and serves it at `/.well-known/agent-card.json`. This eliminates all horizontal code from App_Teams entirely, even for custom containers. Blocked on: validating that a single-process proxy-to-app pattern works within AgentCore Runtime's single-container model (process supervisor like s6-overlay or supervisord to run both proxy and app in one container). Note: mutation must inject ALL container-level horizontals (not just A2A) — OTel, credentials, logging, security baseline all need to be layered in. Revisit when base image adoption patterns are established and custom container friction is measurable.
- **Sidecar injection:** If AgentCore Runtime adds multi-container/sidecar support in the future, the platform could inject a horizontal sidecar at deploy time — similar to Envoy/Istio in K8s. The sidecar would handle A2A protocol, OTel collection, credential management, and health checks, leaving the app container completely untouched. This would be the cleanest separation. Blocked on AgentCore Runtime feature support.
