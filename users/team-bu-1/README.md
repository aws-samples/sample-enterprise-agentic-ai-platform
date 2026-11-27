# Team BU-1 — EAP A2A Demo

Reference App_Team repo demonstrating multi-agent A2A (Agent-to-Agent) deployment on the
EAP platform using Amazon Bedrock AgentCore.

## Monorepo vs Production Layout

This directory lives inside the EAP monorepo workspace for development convenience.
In production, each App_Team gets its own Git repo (e.g., `team-bu-1` on CodeCommit) containing
only what the team owns:

```
team-bu-1 repo (production)         team-bu-1/ (this monorepo)
─────────────────────────────       ──────────────────────────────
uc1-a2a-workflow/                   uc1-a2a-workflow/
uc2-a2a-supervisor/                 uc2-a2a-supervisor/
uc3-full-agent/                     uc3-full-agent/
uc4-stateless-agent/                uc4-stateless-agent/
uc5-standalone-agent/               uc5-standalone-agent/
uc6-runtime-only/                   uc6-runtime-only/
requirements.txt                    requirements.txt
                                    infra/        ← demo scaffolding (see below)
                                    pipeline/     ← demo scaffolding (see below)
```

- `infra/` — Hand-written Terraform used before `eap-generate` existed. With
  `yaml_manifest_enabled = true` (the default), the pipeline ignores this folder and
  generates HCL from `agent.yaml` instead. Kept here as a legacy/escape-hatch reference.
- `pipeline/` — CodePipeline definition. In production, Platform_Admin provisions this
  from `eap-platform/` and points it at the team's repo. It lives here so the
  demo runbook can stand up the full stack from a single workspace.

App teams never touch pipeline or infra Terraform. They write agent code, declare
`agent.yaml`, and push.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  team-bu-1 repo (what App_Team owns)                            │
│                                                                 │
│  uc1-a2a-workflow/                        — UC1: Pipeline Agent   │
│    ├── extractor/                        — Step 1: extract       │
│    ├── enricher/                         — Step 2: enrich        │
│    └── summarizer/                       — Step 3: summarize     │
│  uc2-a2a-supervisor/                     — UC2: Supervisor       │
│    ├── supervisor/                       — A2A caller agent     │
│    └── specialist/                       — A2A callee agent     │
│  uc3-full-agent/                         — UC3: Full Agent       │
│    └── support-agent/                    — Tools + memory + eval │
│  uc4-stateless-agent/                    — UC4: Stateless Agent  │
│    └── query-agent/                      — Tools, no memory      │
│  uc5-standalone-agent/                   — UC5: Standalone Agent │
│    └── reasoning-agent/                  — Memory, no tools      │
│  uc6-runtime-only/                       — UC6: Runtime Only     │
│    └── echo-agent/                       — Runtime only          │
│  requirements.txt            — Shared Python dependencies       │
└─────────────────────────────────────────────────────────────────┘
```

## Composition Patterns

Each use case demonstrates a different EAP composition pattern:

| UC | Pattern | Modules | Agents |
|----|---------|---------|--------|
| `uc1-a2a-workflow` | Pipeline Agent | runtime + pipeline | extractor → enricher → summarizer (Step Functions) |
| `uc2-a2a-supervisor` | Supervisor | runtime + memory + evaluations (×2) | supervisor → specialist |
| `uc3-full-agent` | Full Agent | runtime + memory + gateway_refs + evaluations | support-agent |
| `uc4-stateless-agent` | Stateless Agent | runtime + gateway_refs | query-agent |
| `uc5-standalone-agent` | Standalone Agent | runtime + memory | reasoning-agent |
| `uc6-runtime-only` | Runtime Only | runtime | echo-agent |

All patterns automatically get identity, observability, and governance — the horizontals are always present.

## Quick Start

### Prerequisites

- AWS account with EAP platform deployed (see [DEPLOY-RUNBOOK.md](../DEPLOY-RUNBOOK.md))
- Terraform >= 1.5
- Docker (for local testing only — pipeline handles builds)
- AWS CLI configured with appropriate credentials

### Deploy via GitOps with YAML Manifest (Recommended)

App teams should never write Terraform. Define your agents in `agent.yaml` and
let the pipeline generate the infrastructure.

1. **Edit `agent.yaml`** — declare your agents, protocols, A2A relationships:
   ```yaml
   domain: demo
   framework: strands
   model_id: anthropic.claude-sonnet-5

   agents:
     orchestrator:
       protocols: [a2a]
       role: orchestrator
       calls: [specialist]
     specialist:
       protocols: [a2a]
       role: specialist
       allowed_callers: [orchestrator]
   ```

2. **Implement each agent** in `uc1-a2a-workflow/{name}/` (or `uc2-a2a-supervisor/{name}/`):
   - `main.py` — your agent logic (Strands SDK + Claude Sonnet 5)
   - `agent.yaml` — individual agent config
   - `agent-card.yaml` — A2A discovery metadata
   - `Dockerfile` — container build from EAP base image

3. **Push to trigger pipeline:**
   ```bash
   git add -A && git commit -m "Deploy agents"
   git push origin main
   ```

4. **Pipeline runs automatically:**
   - Source → Base Image → Build → **Generate** → Plan → Approve → Apply → Verify
   - The Generate stage runs `eap-generate` against `agent.yaml`
   - Produces `generated-infra/` with correct Terraform HCL
   - Plan/Apply use the generated HCL

5. **Monitor pipeline** in the AWS CodePipeline console.

### Generate HCL Locally (Optional)

You can preview the generated Terraform before pushing:

```bash
pip install eap-generate
eap-generate generate --input agent.yaml --output generated-infra/
eap-generate format --input agent.yaml --check
```

### Deploy with Hand-Written Terraform (Legacy)

> `infra/` is demo scaffolding. With `yaml_manifest_enabled = true` (default), the
> pipeline generates HCL from `agent.yaml` and ignores this folder entirely.

If you prefer writing Terraform directly, set `yaml_manifest_enabled = false`
in the pipeline variables and use `infra/` or `infra/a2a-demo/` directly.

```bash
cd infra/a2a-demo
terraform init
terraform plan -var="cognito_user_pool_id=..." -var="ecr_repo_url=..."
terraform apply
```

## agent.yaml (future — eap-generate)

> `eap-generate` is a planned CLI (Task 23) that will read a root-level
> `agent.yaml` topology manifest and produce Terraform HCL automatically. Until
> then, each agent has its own `agent.yaml` inside its folder describing its
> individual config (model, protocols, role, allowed callers).

Key fields:
- `domain` — your EAP domain name
- `framework` — agent framework (strands, langgraph, crewai, custom)
- `model_id` — Bedrock foundation model
- `agents` — map of agent name to configuration
  - `protocols` — communication protocols (a2a, mcp, agui, http)
  - `calls` — agents this agent calls via A2A
  - `allowed_callers` — agents allowed to call this agent (default-deny)
  - `memory` — optional memory configuration
  - `evaluations` — optional evaluation configuration
  - `code_interpreter` / `browser` — optional tool access

Each agent also has its own `uc2-a2a-supervisor/{name}/agent.yaml` with the individual
agent config, and `uc2-a2a-supervisor/{name}/agent-card.yaml` for A2A discovery.

## Agent Code

### Supervisor (`uc2-a2a-supervisor/supervisor/main.py`)

Uses Strands SDK `Agent` with Claude Sonnet 5. Discovers specialist via agent
card, sends A2A request with OAuth2 Bearer token from Cognito client credentials.

### Specialist (`uc2-a2a-supervisor/specialist/main.py`)

Uses Strands SDK `Agent` with Claude Sonnet 5 to process incoming A2A requests
with real LLM reasoning. Only accepts calls from the supervisor (default-deny
via Cognito JWT authorizer).

## Pipeline

> In production, Platform_Admin provisions one pipeline per domain. The pipeline
> auto-discovers all `uc*/` directories and builds/deploys every agent automatically.
> The `pipeline/` folder here is legacy demo scaffolding (no longer used).

One pipeline per domain auto-discovers all use case directories (`uc*/`).
Any push to the repo triggers a build of all agents across all UCs.

```bash
# Single pipeline for the entire domain
terraform apply -var='pipelines={"team-bu-1"={"domain"="team-bu-1","repository_name"="team-bu-1"}}'
```

The CI/CD pipeline runs:

1. **Source** — CodeCommit trigger on push
2. **Base Image** — Build shared Strands base image
3. **Build** — Docker build (ARM64) + ECR push per agent
4. **Generate** — Run `eap-generate` against `agent.yaml` (conditional)
5. **Plan** — `terraform plan` with platform variables
6. **Approve** — Manual approval gate
7. **Apply** — `terraform apply`
8. **Verify** — Health check against deployed endpoints

The Generate stage is enabled by default (`yaml_manifest_enabled = true`).
Set to `false` to skip generation and use hand-written Terraform.

## Files

### App_Team owned (ships in production repo)

| File | Purpose |
|------|---------|
| `uc1-a2a-workflow/` | UC1: Pipeline Agent — externally orchestrated workflow (Step Functions) |
| `uc2-a2a-supervisor/` | UC2: Supervisor pattern — supervisor delegates to specialist via A2A |
| `uc3-full-agent/` | UC3: Full Agent — runtime + memory + gateway_refs + evaluations |
| `uc4-stateless-agent/` | UC4: Stateless Agent — runtime + gateway_refs (no memory) |
| `uc5-standalone-agent/` | UC5: Standalone Agent — runtime + memory (no tools) |
| `uc6-runtime-only/` | UC6: Runtime Only — runtime only (simplest possible) |
| `requirements.txt` | Shared Python dependencies |

### Demo scaffolding (monorepo only — Platform_Admin owns in production)

| File | Purpose |
|------|---------|
| `pipeline/main.tf` | CI/CD pipeline definition (provisioned by Platform_Admin in prod) |
| `infra/a2a-demo/main.tf` | Hand-written agent Terraform (legacy, replaced by `eap-generate`) |
| `infra/main.tf` | Single-agent Terraform (legacy) |
| `generated-infra/` | Auto-generated HCL output (do not edit) |
