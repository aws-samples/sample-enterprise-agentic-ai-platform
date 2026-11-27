# ADR-016: Agent Communication Protocols as an Extensible Horizontal

**Status:** Accepted
**Date:** 2026-03-16

**Context:** AgentCore Runtime supports four communication protocols, each with its own container contract:

| Protocol | Port | Transport | Primary Endpoint | Health | Discovery |
|----------|------|-----------|-----------------|--------|-----------|
| **A2A** | 9000 | JSON-RPC 2.0 over HTTP | `POST /` | `GET /ping` | `GET /.well-known/agent-card.json` |
| **AGUI** | 8080 | SSE / WebSocket | `POST /invocations`, `WS /ws` | `GET /ping` | — |
| **MCP** | 8000 | Streamable HTTP (JSON-RPC) | `POST /mcp` | — | — |
| **HTTP** | 8080 | REST + SSE / WebSocket | `POST /invocations`, `WS /ws` | `GET /ping` | — |

All protocols require ARM64 containers and `0.0.0.0` host binding. AGUI and HTTP share port 8080 — AgentCore Runtime distinguishes them via the `--protocol` flag at deploy time.

The original design (ADR-015) treated A2A as the primary protocol horizontal, with other protocols mentioned but not systematically addressed. As the platform matures, protocol compliance needs to be a single extensible horizontal that covers all AgentCore communication protocols — not just A2A.

Options considered:

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **Per-protocol horizontals** | Separate horizontal for each protocol (A2A horizontal, AGUI horizontal, MCP horizontal, HTTP horizontal) | Clear separation | Duplicated injection logic, governance rules, and validation pipelines. Doesn't scale when AgentCore adds new protocols. |
| **A2A-only horizontal + ad-hoc others** | Keep A2A as the formal horizontal, handle other protocols informally | Minimal change from current design | Inconsistent compliance guarantees. AGUI/MCP/HTTP containers may not be validated. |
| **Single extensible protocol horizontal** | All protocols treated as one horizontal with modular protocol layers activated by config | Scales to new protocols. Single injection point. Consistent validation. | Slightly more complex base image architecture (modular activation). |
| **No protocol horizontal** | Leave protocol compliance entirely to App_Teams | Zero platform overhead | Breaks "fire and forget" model. Protocol errors discovered at runtime. |

**Decision:** All AgentCore communication protocols (A2A, AGUI, MCP, HTTP) are treated as a single extensible horizontal called "Agent Communication Protocols." The platform guarantees protocol compliance based on what protocols the App_Team selects via the runtime module's `protocols` variable.

**How it works:**

1. **Terraform layer:** The runtime module's `protocols` variable (default: `["mcp", "a2a"]`) determines which protocols are active. Valid values: `mcp`, `a2a`, `agui`, `http`. The module injects `EAP_PROTOCOLS` env var into the container at deploy time.

2. **Container layer:** Base images include modular protocol layers for all four protocols. At startup, the base image reads `EAP_PROTOCOLS` and activates only the declared protocol listeners. Unused protocol layers remain dormant — no ports opened, no handlers registered.

3. **Build-time validation:** CodePipeline validates only the protocols declared in the runtime module config. If `protocols = ["mcp", "a2a"]`, only MCP and A2A endpoints are smoke-tested. AGUI and HTTP are not validated because they're not active.

4. **Deploy-time verification:** Post-deploy Lambda verifies only the active protocol endpoints on the live agent.

5. **Extensibility:** When AgentCore adds a new protocol, the platform adds a new protocol layer to the base images and a new valid value to the `protocols` variable. No App_Team changes required — teams that don't select the new protocol are unaffected.

**Protocol references:**
- [A2A protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-a2a-protocol-contract.html)
- [AGUI protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-agui-protocol-contract.html)
- [MCP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-mcp-protocol-contract.html)
- [HTTP protocol contract](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-http-protocol-contract.html)

**Rationale:**
- Aligns with ADR-006 — platform operates, app teams declare. Protocol compliance is an operational concern. App_Teams select which protocols they need; the platform guarantees compliance.
- Aligns with ADR-015 — base images are the container-level injection point for horizontals. Protocol layers are just another set of components in the base image, alongside OTel, credential helper, and logging.
- Single horizontal scales better than per-protocol horizontals. When AgentCore adds protocol #5, the platform adds one protocol layer — not an entire new horizontal with its own governance rules, validation pipeline, and Config Rules.
- Modular activation via `EAP_PROTOCOLS` means unused protocols have zero overhead — no ports opened, no handlers running, no attack surface.

**Consequences:**
- R20 updated: renamed from "A2A Protocol Enabled by Default" to "Agent Communication Protocol Compliance" — ACs expanded to cover all protocols, not just A2A
- ADR-015 updated: base images now explicitly cover all four protocol layers, not just A2A
- Runtime module `protocols` variable updated: valid values now include `http` alongside `mcp`, `a2a`, `agui`
- Config Rule `eap-runtime-a2a-enabled` updated to `eap-runtime-protocol-compliance` — validates that declared protocols are compliant, not just that A2A is present
- Build-time and deploy-time validation is protocol-aware — tests only the protocols declared in the runtime config
- CP-11 correctness property expanded from A2A-only to all protocols
- Glossary updated with protocol contract entries for AGUI, MCP, HTTP alongside existing A2A entry
