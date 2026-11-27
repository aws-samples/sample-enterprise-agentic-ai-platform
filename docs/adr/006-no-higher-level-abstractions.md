# ADR-006: No Higher-Level Abstractions — Platform Operates, App Teams Declare

**Status:** Accepted (applies to both tracks)
**Date:** 2026-03-12

**Context:** The original design had a composite `Agent` resource where the platform orchestrated Runtime + Memory + Identity + Gateway + Policy + Observability behind a single declaration. This made the platform team the architect of agent resource composition. Platform teams are infrastructure operators — they are not subject matter experts in agent development and should not be defining how agents are assembled.

**Decision:** EAP does NOT create higher-level abstractions over AgentCore primitives. The platform's value is:

1. **Operating the platform** — managing the module library, Terraform Cloud workspaces, and governance policies
2. **Enforcing cross-cutting concerns transparently:**
   - **Identity**: Platform_Admin configures OIDC connectors; identity flows into all agents automatically
   - **Observability**: Module defaults + AWS Config Rules ensure every deployment has observability
   - **Policy/Entitlements**: Platform_Admin defines Cedar policies; enforced at runtime by AgentCore Policy
   - **Domain isolation**: Platform_Admin creates Domains; cross-domain access blocked by default
   - **Gateway/MCP servers**: Shared_Services_Team registers data connectors as MCP servers
   - **Data entitlements**: Enforced via AgentCore Identity
3. **Provisioning shared resources** — identity providers, gateway endpoints, ECR repositories, domain configs

App teams are the SMEs. They declare exactly what their agent needs using Terraform modules. The platform doesn't hide or compose those primitives.

**Consequences:**
- No composite "agent" module — each module maps 1:1 to an AgentCore primitive
- App teams must understand which AgentCore primitives they need (acceptable — they're the SMEs)
- Platform value is in operations, governance, and cross-cutting injection — not in abstraction
