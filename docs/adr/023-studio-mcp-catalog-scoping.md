# ADR-023: Studio MCP Catalog Scoping

**Status**: Accepted
**Date**: 2026-04-30
**Deciders**: Platform Engineering, AI Governance

## Context

The Agent Builder Studio helps non-technical users design agents that reference MCP tools via
`agent.yaml → gateway_refs → mcp_servers`. Studio must discover what MCP tools exist without
hardcoding the catalog, and it must recommend only tools that will actually work when the
generated agent runs.

Two scoping models were considered:

1. **Global** — Studio uses its own IAM workload identity to query the Gateway and sees every
   MCP tool on the platform, regardless of who is designing.
2. **User-scoped** — Studio forwards the authenticated user's Cognito JWT to the Gateway and
   receives only tools the user is entitled to (Gateway Cedar policy filters by user group /
   OAuth scope).

## Decision

**Studio uses user-scoped discovery.**

The Studio runtime forwards the calling user's Cognito JWT to the AgentCore Gateway for every
`tools/list` query. The Gateway returns only MCP tools the user is authorized to invoke. If
Studio is ever invoked outside a user session (e.g., from a backend job), it falls back to its
own workload identity and gets the global catalog.

## Consequences

### Positive

- **Least privilege at design time.** Studio never recommends a tool the user's future agent
  cannot actually call. This catches entitlement gaps during design instead of at first
  invocation after deploy.
- **Aligned with platform identity model** (see 017-identity-architecture.md Layer 1).
  The same Cognito JWT that authenticates the user to Studio authenticates them to the Gateway.
- **No elevated privilege leak.** A user designing an agent cannot discover or reference MCP
  tools outside their entitlement scope.
- **Cedar policy remains authoritative.** Gateway stays the single source of truth for who
  can access what — Studio does no client-side filtering.

### Negative

- Studio must plumb the Cognito JWT from the UI through to its runtime environment and onward
  to the Gateway. Adds one header-forwarding step.
- If the user's Gateway entitlements change during a long design session, the catalog is stale
  until the next cache TTL expires.

### Neutral

- Catalog is cached per-container (10-minute TTL) keyed by user sub. New MCPs appear when the
  cache refreshes.

## Guardrail

Studio **MUST NOT** reference, recommend, or generate YAML entries for any MCP tool that is not
returned by the `mcp_catalog_browser` tool. The system prompt enforces this, and the
`yaml_validator` tool rejects any `gateway_refs.mcp_servers` entry whose server name is not
present in the cached catalog.

This guardrail is the only sanctioned path for Studio to reference MCP tools. It prevents
hallucinated tool names from reaching deployed runtimes.

## References

- `017-identity-architecture.md` — Layer 1 (user→agent auth)
- `018-platform-vending-model.md` — Gateway as platform-vended resource
- `users/team-bu-1/standalone/agent-builder-studio/tools/mcp_catalog_browser.py`
- `users/team-bu-1/standalone/agent-builder-studio/knowledge/platform-guide.md`
