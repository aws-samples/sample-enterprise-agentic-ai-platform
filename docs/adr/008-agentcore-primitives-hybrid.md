# ADR-008: AgentCore Primitives Are Hybrid (App + Infra)

**Status:** Accepted (applies to both tracks)
**Date:** 2026-03-13

**Context:** Need to understand the ownership boundary for each AgentCore primitive to determine which Terraform modules are managed by platform teams vs app teams.

**Analysis:**

| AgentCore Primitive | Nature | App Team Responsibility | Platform Team Responsibility |
|---|---|---|---|
| **Runtime** | Hybrid | Framework, container, code, protocol | Where it runs, scaling, isolation |
| **Memory** | Hybrid | Memory type (short/long/episodic), what to remember | Retention, quotas, domain isolation |
| **Gateway** | Hybrid | Which tools their agent uses | Which data sources are available (Shared Services) |
| **Identity** | Mostly infra | Inherits identity automatically | IdP config, OIDC federation, data entitlements |
| **Policy** | Pure infra/governance | Subject to policies | Defines and enforces rules |
| **Observability** | Pure infra | Benefits without config | Configures dashboards, enforces via Config Rules |
| **Evaluations** | Hybrid | Defines quality criteria | Provides evaluation infrastructure |
| **Code Interpreter** | Hybrid | Decides if agent needs code exec | Controls sandbox security |
| **Browser** | Hybrid | Decides if agent needs web access | Controls session limits |

**Decision:** Three categories:
1. **Pure infra / cross-cutting** (app team shouldn't touch): Identity, Policy, Observability
2. **Infra-provisioned, app-consumed**: Gateway (Shared Services provisions, app team references)
3. **App-declared, platform-governed**: Runtime, Memory, Evaluations, Code Interpreter, Browser

**Consequences:** This classification informs which modules live in which repo and who applies them.
