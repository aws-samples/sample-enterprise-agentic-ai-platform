# ADR-018: Platform Vending Model — Multi-BU, Config-Driven

**Status**: Confirmed
**Date**: 2026-03-26

---

## Context

The platform needs to be vended per business unit (BU), with each BU getting its own AWS account instance. Within each BU, app teams and data teams drive deployments via YAML configuration — no Terraform knowledge required.

## Decision

### Six Personas

| Persona | Role | What they write | Repo | Scope |
|---------|------|-----------------|------|-------|
| Platform Engineering | Builds the platform product — modules, deploy-templates, base images | Terraform (HCL) | `eap-terraform-modules` | Global — one codebase, versioned, consumed by all BUs |
| Platform Operator | Configures and operates platform instances per BU | Terraform (HCL) — consumes modules | `eap-platform-{bu}` | Per BU account |
| BU Admin | Configures domains, policies, model access for their BU | `bu-config.yaml` | `eap-platform-{bu}` | Per BU account |
| Developer (App Team) | Builds and deploys agents | `agent.yaml`, `agent-card.yaml`, Dockerfile, Python | `team-{name}` | Per team within a BU |
| Data Team (Shared Services) | Registers gateway sources | `sources/*.yaml` — MCP servers, REST APIs, Lambda refs | `enterprise-integrations-{bu}` | Per BU (shared across teams) |
| AI Governance | Monitors agent behavior, quality, and compliance | Observability dashboards, evaluation configs, Cedar policies | Read-only across all BUs | Cross-BU — OTel, AgentCore Observability, Evaluations, Policy |

### Repository Structure

```
eap-terraform-modules/          ← Platform Admin (THE PRODUCT)
  modules/                             ← Reusable TF modules (1:1 per AgentCore primitive)
  deploy-templates/
    agent-deploy/                      ← yamldecode(agent.yaml) → provisions agents
    gateway-deploy/                    ← yamldecode(targets/*.yaml) → provisions gateway
  base-images/                         ← Protocol layers, OTel, creds
  pipelines/                           ← Pipeline buildspecs

eap-platform-{bu}/             ← BU Admin (one per BU account)
  bu-config.yaml                       ← BU-specific: account, region, IdP, domains
  (platform TF that reads bu-config)

team-{name}/                           ← Developer (YAML + code only, zero TF)
  standalone-agent-pattern/
    agent-name/                        ← agent.yaml, agent-card.yaml, Dockerfile, main.py
  supervisor-pattern/
    app-name/                          ← application.yaml + agent subfolders
  sequential-workflow-pattern/
    app-name/                          ← application.yaml + agent subfolders

data-services-{bu}/                    ← Data Team (YAML only, zero TF)
  targets/
    mcp/                               ← Remote MCP servers
    rest-api/                          ← REST APIs (Gateway wraps natively)
    lambda/                            ← Lambda-backed tools
```

### Key Principles

1. **Platform Admin writes Terraform, everyone else writes YAML** — deploy-templates bridge the gap
2. **One product, many instances** — `eap-terraform-modules` is versioned and published; each BU gets an instance
3. **Config-driven deployments** — pipelines read YAML via `yamldecode()`, provision resources automatically
4. **Clear blast radius** — each repo has one owner, one purpose, one deployment scope
5. **IdP-agnostic** — BU Admin sets `oidc_discovery_url` in config; swap identity providers by changing one URL

### Vending a New BU

1. Platform Admin creates `eap-platform-{bu}/` with BU config
2. `terraform apply` provisions identity, ECR, pipelines, base images in BU's account
3. Hand off `team-{name}/` and `data-services-{bu}/` repos to BU teams
4. Teams write YAML, push, pipeline handles the rest

## Consequences

- Platform Admin maintains one codebase that serves all BUs
- BU Admin has account-level control without Terraform expertise
- App and Data teams never touch infrastructure — YAML in, infrastructure out
- Adding a new BU is a config operation, not a code change

---

## Decision: Business Unit → Architecture → Application Hierarchy

**Date**: 2026-03-30
**Updated**: 2026-03-30
**Status**: Confirmed

### Hierarchy

Standalone agents (single agent = single app):
```
team-{name}/
  standalone-agent-pattern/
    {agent-name}/                       ← app = agent (agent.yaml is sufficient)
      agent.yaml
      agent-card.yaml
      Dockerfile
      main.py
```

Multi-agent applications (supervisor, workflow, router, parallel):
```
team-{name}/
  {architecture}-pattern/
    {app-name}/                         ← app folder (gets Cognito app client)
      application.yaml                  ← defines multi-agent topology
      {agent-a}/
        agent.yaml
        Dockerfile
        main.py
      {agent-b}/
        agent.yaml
        Dockerfile
        main.py
```

| Level | What it is | Identity | Example |
|-------|-----------|----------|---------|
| Business Unit | Team boundary, one CodeCommit repo | IAM role (shared) | `team-bu-1` |
| Agent Architecture | Composition template — defines how agents are structured | None (just a folder) | `standalone-agent-pattern`, `supervisor-pattern` |
| Application | Deployable unit — what users interact with | Cognito app client (one per app) | `aws-architect-agent`, `code-review-app` |
| Agent | Individual agent within a multi-agent app | AgentCore Workload Identity | `supervisor`, `specialist` |

### application.yaml

For multi-agent architectures, `application.yaml` defines the topology:

```yaml
# supervisor-pattern/code-review-app/application.yaml
name: code-review-app
architecture: supervisor
description: Code review system — supervisor delegates to specialist reviewers

agents:
  - name: supervisor
    role: orchestrator
    calls: [specialist]
  - name: specialist
    role: worker
    called_by: [supervisor]
```

For standalone agents, `agent.yaml` is sufficient — no `application.yaml` needed.

### Cognito App Client Scope

Each application gets its own Cognito app client (user authentication only):
- Standalone agent: one app client per agent folder
- Multi-agent app: one app client per `application.yaml` (shared by all agents in the app)
- Gateway can scope tool access per app via `allowed_clients`
- Audit trails attribute actions to the specific application

Cognito is restricted to user authentication. A2A communication is routed via AgentCore Gateway.

### Agent Architectures

Agent architectures are composition templates that define how agents are structured and which AgentCore primitives they use. Based on [Anthropic's Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) taxonomy, mapped to platform primitives:

| Architecture | Anthropic Name | AgentCore Primitives | Description | Folder |
|---------|---------------|---------------------|-------------|--------|
| Standalone Agent | Agents | runtime + memory + gateway_refs + evaluations | Single agent with tools, memory, and quality monitoring. The default starting point. | `standalone-agent-pattern/` |
| Sequential Workflow | Prompt Chaining | runtime × N (sequential) | Task decomposed into fixed sequential steps, each LLM processes previous output. Programmatic gates between steps. | `sequential-workflow-pattern/` |
| Router | Routing | runtime (classifier) + runtime × N (specialists) | Classifies input and directs to specialized handler. Separation of concerns. | `router-pattern/` |
| Parallel | Parallelization | runtime × N (concurrent) | Subtasks run simultaneously, outputs aggregated. Sectioning (split task) or voting (same task, multiple attempts). | `parallel-pattern/` |
| Supervisor | Orchestrator-Workers | runtime (supervisor) + runtime × N (workers) | Supervisor agent dynamically breaks down tasks, delegates to workers, synthesizes results. Flexible — subtasks not predefined. | `supervisor-pattern/` |
| Swarm | Swarm | runtime × N (peers, A2A mesh) | Peer agents collaborate iteratively via A2A handoffs. No central orchestrator — agents decide who to call next. Flow is emergent, driven by each agent's LLM. | `swarm-pattern/` |

Content rephrased from [Anthropic's Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) for compliance with licensing restrictions.

### Architecture Selection Guide

Start simple, add complexity only when it improves outcomes:

1. **Start here**: Standalone Agent — single agent with tools, memory, and evals. Covers most use cases.
2. **Need sequential steps?**: Sequential Workflow — when task decomposes cleanly into fixed subtasks.
3. **Need classification?**: Router — when distinct input categories need different handling.
4. **Need speed?**: Parallel — when subtasks are independent and can run concurrently.
5. **Need flexibility?**: Supervisor — when subtasks can't be predicted upfront and need dynamic delegation.
6. **Need collaboration?**: Swarm — when agents need to brainstorm, critique, and refine iteratively. No central control.

### Example: Current Deployment

```
team-bu-1/
  standalone-agent-pattern/
    aws-architect-agent/                ← app: AWS solutions architecture
    support-agent/                      ← app: Customer support
    query-agent/                        ← app: Stateless query agent
    reasoning-agent/                    ← app: Memory-only reasoning
    echo-agent/                         ← app: Runtime-only echo

  supervisor-pattern/
    code-review-app/                    ← app: Code review (multi-agent)
      application.yaml
      supervisor/
      specialist/

  sequential-workflow-pattern/
    data-pipeline-app/                  ← app: Data processing (multi-agent)
      application.yaml
      extractor/
      enricher/
      summarizer/

  swarm-pattern/
    research-swarm/                     ← app: Collaborative research (multi-agent)
      application.yaml
      researcher/
      analyst/
      writer/
```

### References

- [Anthropic: Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)
- `docs/templates/composition/` — YAML templates for each pattern
- `017-identity-architecture.md` — Cognito restricted to user auth, A2A via Gateway


---

## Future Decision: Pattern Ownership — Platform Team vs BU Admin

**Status**: Pending
**Date**: 2026-04-13

### Context

Currently, architecture patterns (standalone, supervisor, sequential-workflow, swarm, etc.) are defined as folder conventions in the platform. The deploy-template discovers and processes them. The question is: who should own which patterns are available to a BU?

### Options Under Consideration

1. **Platform Team owns patterns** — patterns are global, all BUs get all patterns. Simple but no governance.

2. **BU Admin owns pattern policy** — BU Admin configures which patterns are allowed, default orchestration modes, guardrails (max agents, required evaluations) via `bu-config.yaml`. Platform Team owns the Terraform modules and deploy-templates. BU Admin owns the policy layer.

Example `bu-config.yaml`:
```yaml
allowed_patterns: [standalone-agent, supervisor, sequential-workflow]
pattern_defaults:
  supervisor:
    orchestration: step-functions
    max_agents: 10
  swarm:
    enabled: false
required:
  evaluations: [correctness, safety]
```

### Decision

Pending. Will evaluate when multi-BU deployment begins. For MVP, Platform Team owns everything.
