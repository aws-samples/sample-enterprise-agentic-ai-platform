# UC0 — AWS Architect Agent

GenAI AWS Solutions Architect agent for the Enterprise Agentic AI Platform.
Designs comprehensive, Well-Architected AWS solutions through collaborative
conversation — architecture diagrams, cost analysis, and Well-Architected
Framework assessments.

Based on [sample-genai-aws-solutions-architect-agent](https://github.com/aws-samples/sample-genai-aws-solutions-architect-agent) (MIT).

## Platform Integration

| File | Purpose |
|---|---|
| `agent.yaml` | Platform manifest — model, memory, gateway refs, evaluations |
| `agent-card.yaml` | A2A agent card — capabilities, skills, version |
| `Dockerfile` | Builds on `eap-base-strands` base image |
| `main.py` | Agent entry point — Strands Agent with AgentCore Memory |
| `prompts.py` | System instructions (unchanged from upstream) |
| `file_writer.py` | Native `write_file` tool for deterministic file output |

## How It Works

- **MCP tools** (aws-knowledge) are provided by the AgentCore Gateway, declared in `agent.yaml` under `gateway_refs`. Diagram generation uses the public `awslabs.aws-diagram-mcp-server`.
- **Memory** is backed by AgentCore long-term memory (90-day retention).
- **Scaling** is handled by AgentCore — no rate limiter needed.
- **Observability** comes from OTel in the base image — no custom log capture.

## Local Testing

```bash
# A2A agent-card probe
cat tests/agent-card-request.json | curl -X POST -H "Content-Type: application/json" -d @- http://localhost:8080/a2a

# Architecture design request
cat tests/invoke-request.json | curl -X POST -H "Content-Type: application/json" -d @- http://localhost:8080/a2a
```

## Validating this agent

Once deployed, exercise this agent from the unified **console** (Examples surface → Standalone card). The per-pattern local demo UIs have been retired in favor of the console.
