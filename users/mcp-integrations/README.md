# Enterprise Integrations

Owned by: Data Team (Shared Services)

YAML configuration for enterprise tool and data integrations.
The platform's gateway-deploy template reads these and provisions
the AgentCore Gateway automatically via CI/CD.

## Adding sources

Drop a YAML file in the appropriate folder:

- `sources/mcp/` — Remote MCP servers with hosted HTTP endpoints
- `sources/rest-api/` — REST APIs (Gateway wraps as MCP natively)
- `sources/lambda/` — Lambda functions (compute-heavy tools)

Then `git push` — the pipeline handles the rest.
