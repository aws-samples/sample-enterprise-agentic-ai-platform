# Enterprise Agentic AI Platform (EAP) — Studio Knowledge Base

## Pattern Decision Matrix

| Use Case | Pattern | Orchestration | application.yaml? |
|----------|---------|---------------|-------------------|
| Single task, no delegation | standalone | none | No (agent.yaml only) |
| Subtask delegation to specialists | supervisor | step-functions | Yes |
| Linear processing chain | sequential-workflow | step-functions | Yes |
| Input classification → route to handler | router | step-functions | Yes |
| Iterative peer collaboration | swarm | a2a | Yes |
| Fan-out to parallel workers | supervisor (parallel) | step-functions | Yes |

## YAML Schema — agent.yaml (Required Fields)

```yaml
name: string          # kebab-case, unique within domain
framework: string     # strands | langgraph | crewai | claude-sdk | custom
model_id: string      # e.g., us.anthropic.claude-sonnet-5
protocols: [string]   # [a2a] | [mcp] | [a2a, mcp]
```

Optional fields: role (standalone|orchestrator|worker|peer|classifier|handler),
memory (type: short-term|long-term, retention: 30d|90d|365d),
gateway_refs (mcp_servers: [target-names]),
evaluations (evaluators: [correctness,helpfulness,safety], thresholds),
calls ([agent-names]).

## YAML Schema — application.yaml (Required Fields)

```yaml
name: string          # kebab-case application name
architecture: string  # supervisor | sequential-workflow | parallel | router | swarm
description: string   # human-readable
orchestration: string # step-functions | a2a | none
```


## YAML Schema — agent-card.yaml (Required Fields)

```yaml
name: string          # must match agent.yaml name
version: string       # semver e.g., 1.0.0
description: string   # human-readable
skills:
  - id: string
    name: string
    description: string
```

## Canonical Templates

### Standalone Agent (agent.yaml only, no application.yaml)

```yaml
name: my-support-agent
framework: strands
model_id: us.anthropic.claude-sonnet-5
protocols: [a2a]
role: standalone
memory:
  type: long-term
  retention: 90d
gateway_refs:
  - mcp_servers: [snowflake-warehouse, sharepoint-docs]
evaluations:
  evaluators: [correctness, helpfulness, safety]
  thresholds:
    safety: 0.95
```

### Supervisor Pattern (application.yaml + agent.yaml per agent)

```yaml
# application.yaml
name: code-review-app
architecture: supervisor
description: Code review — supervisor delegates to specialist reviewers
orchestration: step-functions
agents:
  - name: supervisor
    role: orchestrator
    calls: [quality-reviewer, security-reviewer]
  - name: quality-reviewer
    role: worker
    called_by: [supervisor]
  - name: security-reviewer
    role: worker
    called_by: [supervisor]
```

### Sequential Workflow Pattern

```yaml
# application.yaml
name: data-pipeline-app
architecture: sequential-workflow
description: Extract → Enrich → Summarize pipeline
orchestration: step-functions
steps:
  - name: extractor
    description: Extracts raw data from sources
  - name: enricher
    description: Enriches extracted data
    depends_on: [extractor]
  - name: summarizer
    description: Summarizes enriched data
    depends_on: [enricher]
```

### Swarm Pattern (A2A Mesh)

```yaml
# application.yaml
name: research-swarm
architecture: swarm
description: Collaborative research — peers brainstorm via A2A
orchestration: a2a
agents:
  - name: researcher
    role: peer
    can_call: [analyst, writer]
  - name: analyst
    role: peer
    can_call: [researcher, writer]
  - name: writer
    role: peer
    can_call: [researcher, analyst]
```

## Dockerfile Template

```dockerfile
ARG BASE_IMAGE_URI
FROM ${BASE_IMAGE_URI}
COPY main.py /app/agent/main.py
COPY agent-card.yaml /app/agent-card.yaml
ENV AGENT_MODULE=agent.main
```

Base image includes: Strands SDK, OTel, A2A/MCP protocol handlers, health checks, structured logging.

## Deploy Pipeline Contract

- Agents live in CodeCommit repos (one per domain/persona)
- Pipeline auto-discovers agent.yaml and application.yaml via fileset()
- Standalone: agent.yaml without sibling application.yaml
- Multi-agent: directory with application.yaml + agent subfolders
- Build stage: docker build per agent → push to ECR
- Deploy stage: Terraform provisions runtimes, memory, evaluations, orchestration
- Runtime naming: {domain}_{agent_name} (max 39 chars, underscores)

## Platform Provisions from YAML

| YAML Field | What Gets Created |
|------------|-------------------|
| agent.yaml name + framework | AgentCore Runtime |
| agent.yaml model_id | IAM policy for Bedrock model |
| agent.yaml memory | AgentCore Memory resource |
| agent.yaml evaluations | Evaluations config (SSM + CloudWatch) |
| agent.yaml calls | Peer runtime name env vars |
| agent.yaml gateway_refs | Gateway ID env var (future) |
| application.yaml orchestration: step-functions | Step Functions state machine |
| application.yaml orchestration: a2a | Peer env vars for A2A mesh |
| application.yaml agents | One runtime per agent |

## Available Models

- us.anthropic.claude-sonnet-5 (default, recommended)
- us.anthropic.claude-haiku-3-20250307-v1:0 (faster, cheaper)

## Key Platform Principles

- App teams write YAML, platform owns all Terraform
- Every agent gets its own AgentCore Runtime (container + endpoint)
- MCP = enterprise integration (databases, APIs via Gateway)
- A2A = agent-to-agent collaboration (peer agents via direct invocation)
- Scale-to-zero, consumption-based pricing
- All agents share a common identity model (Cognito + AgentCore Identity)

## Tool Discovery Contract (MANDATORY)

The AgentCore Gateway is the SOLE source of truth for MCP tools on the platform.
Studio must call the `mcp_catalog_browser` tool to discover available MCPs — never
hardcode, guess, or hallucinate tool or server names.

Rules:

1. Before recommending or naming any MCP tool during a conversation, call
   `mcp_catalog_browser` first to refresh the known catalog.
2. Every `gateway_refs.mcp_servers` entry in generated `agent.yaml` MUST be a
   server name returned by `mcp_catalog_browser`. The `yaml_validator` tool
   cross-checks this at validation time and rejects unknown servers.
3. The catalog is **user-scoped** — it reflects only the MCPs the designing user
   is entitled to invoke (see `docs/adr/023-studio-mcp-catalog-scoping.md`). If the user
   asks for a tool that isn't in their scope, inform them and offer alternatives
   from the returned catalog.
4. If `mcp_catalog_browser` returns an empty list or an error, Studio must tell
   the user the platform tool catalog is unavailable and MUST NOT recommend
   specific MCP tools until it recovers.

This contract prevents hallucinated tool names from reaching deployed runtimes
and guarantees every MCP reference Studio produces will work at runtime.

## Platform Architecture & Philosophy (for explaining how EAP works)

Use this section when a user asks how the platform works, its philosophy, base
images, pipelines, or governance — explain in plain language, grounded in these facts.

### Core philosophy — "declare intent, the platform does the rest"

- **YAML in, infrastructure out.** App teams describe *what they want* in simple
  manifests (`agent.yaml`, `application.yaml`, `kb.yaml`, Cedar policies). They
  never write Terraform or touch infrastructure. Pipelines read the YAML via
  `yamldecode()`/`fileset()` and provision everything automatically.
- **No higher-level abstractions.** Terraform modules map 1:1 to AgentCore
  primitives (runtime, gateway, memory, evaluations). Nothing is hidden behind a
  bespoke layer — the platform is the composition, not a wrapper.
- **One product, many instances.** The platform is built once and vended per
  Business Unit into separate AWS accounts. Each BU owns its agents, data, IAM,
  and blast radius, operating independently within central guardrails.
- **Cross-cutting concerns are injected transparently.** Identity, observability,
  governance, and A2A/MCP protocol handling are added by the platform — users
  never write that code.
- **Everything flows through a git repo wired to a CI/CD pipeline** — never by
  touching infrastructure directly.

### Base image (horizontal injection)

Every agent is built `FROM` a platform base image. The base image auto-injects,
so app teams don't write any of it:
- The agent framework runtime (Strands SDK; LangGraph/CrewAI/custom also supported)
- **OpenTelemetry** instrumentation (distributed tracing) — zero code from the user
- **A2A and MCP** protocol handlers (agent-to-agent + tool integration)
- `agent-card.yaml` metadata, health checks, and structured logging
This is how observability and protocols are "free" for every deployed agent.

### CI/CD pipeline (how a deploy actually happens)

A push to the app team's CodeCommit repo triggers the deploy pipeline:
**Source → Build (ARM64 docker build per agent → push to ECR) → Deploy
(Terraform provisions AgentCore runtimes, memory, evaluations, orchestration) →
Verify (A2A smoke test) → Evaluate → Gate.** The pipeline auto-discovers every
`agent.yaml`/`application.yaml`, so adding an agent is just adding YAML + a push.
Gateway targets and knowledge bases have their own analogous pipelines.

### Agent School (lifecycle)

Deployed agents move through a lifecycle state machine — enrolled → training →
validated → graduated — with an evaluate/gate stage, semantic-versioned,
version-tagged ECR images, and QA/prod promotion triggers. Graduation policy and
red-team/eval thresholds gate promotion.

### Three layers of state (what is authoritative for what)

- **Desired state** = Git/CodeCommit (the YAML/HCL you declare — what *should* exist).
- **Provisioning ledger** = Terraform state (S3 backend + DynamoDB lock — what
  Terraform *has* provisioned).
- **Operational state** = the DynamoDB **Agent School lifecycle table** — what is
  *actually deployed and running* (runtime ARNs, entrypoints, topology, stage).
  The console, invoke-proxy allow-list, and dashboards all read this table.

### Security & networking posture

- Agents run **inside the enterprise VPC by default** — AgentCore runtime ENIs in
  private subnets; managed AgentCore APIs (Gateway, Memory, Identity) reached
  privately.
- **IdP-agnostic** identity via CUSTOM_JWT + an OIDC discovery URL — swap
  identity providers by changing one URL. Least-privilege IAM per agent; Cedar
  policy enforcement; per-user AgentCore session isolation; safety guardrails.
- Consumption-based, scale-to-zero pricing (pay for active CPU, not idle waits).

### Extensibility

The platform grows **horizontally** — onboarding a new capability means adding a
repo + a Terraform module (1:1 to a primitive) + a CI/CD pipeline, never coupling
teams or growing a monolith. Each extension is independently owned and governed by
the same guardrails.
