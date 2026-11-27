# ADR-021: Generic Agent Chat UI vs Per-Agent UI Generation

**Status**: Accepted
**Date**: 2026-04-27
**Context**: Agent Builder Studio — how nocode-users interact with agents they create

---

## Decision

The Agent Builder Studio UI serves as both the agent design interface and a generic chat interface for talking to deployed agents. After deploying an agent, the Studio switches its chat target from the Studio agent to the newly deployed agent's A2A endpoint. No per-agent UI is generated.

## Context

When a nocode-user creates and deploys an agent via the Studio, they need a way to interact with it. Two options were considered:

### Option 1: Generic Agent Chat UI (Selected)

The Studio UI doubles as a universal chat interface. After deployment, the UI switches its A2A target from the Studio agent to the deployed agent. A "My Agents" panel lists all agents deployed by the user, each switchable as the active chat target.

- Single UI serves all agents
- No code generation for UI artifacts
- Immediate interaction after deploy (no additional setup)
- Agent switching is a backend concern (change the target ARN in the `/api/invoke` call)

### Option 2: Per-Agent UI Generation (Rejected for POC)

The `code_scaffolder` tool generates a tailored demo UI (App.tsx, server.ts, run.sh) for each deployed agent, similar to the existing demo UIs.

- More customizable per agent
- Requires hosting infrastructure for each generated UI
- Adds complexity to the code generation pipeline
- Nocode-users would need to run `npm start` locally — defeats the no-code purpose

## Rationale

Option 1 is the right fit for the nocode-user persona. These users don't run local dev servers. They need a hosted, browser-based experience where they can design an agent and immediately talk to it in the same interface. The Studio UI already has the chat infrastructure (message area, A2A invocation, SigV4 signing) — switching the target ARN is trivial.

Option 2 makes sense for developer-facing demo UIs where customization matters (pattern visualization, OTel logs, YAML viewers). But for nocode-users, a generic chat is sufficient.

## Consequences

- The Studio UI needs a "My Agents" panel and agent switching logic
- The backend `/api/invoke` endpoint needs to accept a dynamic target ARN (not hardcoded to the Studio agent)
- Per-agent UI customization (e.g., custom branding, specialized input forms) is deferred to v2.0
- The Studio agent's `pipeline_trigger` tool returns the deployed agent's endpoint ARN, which the UI stores in the "My Agents" list

## Future Enhancement

Per-agent UI generation could be added as a v2.0 feature for users who need customized interfaces. The generated UIs would be hosted on S3 + CloudFront (static site) rather than requiring local `npm start`.

## References

- `platform/demo-ui/standalone/aws-architect-ui-v2/src/App.tsx` — Reference chat UI pattern
