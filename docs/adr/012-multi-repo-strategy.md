# ADR-012: Multi-Repo Strategy

**Status:** Accepted
**Date:** 2026-03-13

**Context:** Need to decide on repository structure for the Terraform track. Options considered:

| Option | Pros | Cons |
|--------|------|------|
| **Monorepo** | Single source of truth, atomic cross-cutting changes | Blast radius — one bad merge affects everything. Permission boundaries complex. Module versioning tied to platform ops. |
| **Two repos** (platform + per-team) | Simple split | Module library versioning coupled to platform ops. Shared Services has no clear home. |
| **Multi-repo** | Independent versioning for modules. Clear ownership per persona. Each repo has own pipeline. | More repos to manage. Cross-repo dependency management. |

**Decision:** Multi-repo strategy:

| Repository | Owner | Contents |
|------------|-------|----------|
| `eap-modules` | Platform_Admin | Terraform module library — one module per AgentCore primitive + domain, pipeline. Published to private Terraform Registry. Versioned via Git tags / semver. |
| `eap-platform` | Platform_Admin | AWS Config Rules, SCPs, IAM permission boundaries, shared workspace configs, identity module configs, observability defaults, domain module configs. |
| `eap-shared-services` | Shared_Services_Team | Gateway module HCL, MCP server source code, connector configs (Snowflake, S3, document management). |
| `team-{name}-agents` (per team) | App_Team | Agent source code, Dockerfile, `infra/` directory with HCL consuming EAP modules. |

**Rationale:**
- **Module library as separate repo** — modules are consumed by all teams. Independent versioning via semver tags lets consumers pin to stable versions (`source = "app.terraform.io/eap/runtime/aws" version = "~> 1.0"`). Decouples module releases from platform operational changes.
- **Platform ops separate from modules** — Config Rules, SCPs, and workspace configs change on a different cadence than module interfaces. Avoids accidental module version bumps when updating a Config Rule.
- **Shared Services gets its own repo** — MCP server source code and gateway HCL co-located. Full lifecycle ownership (code + infra) for data connectors. Can extract individual connectors to their own repos later if they grow complex.
- **Per-team agent repos** — each App_Team owns their agent code and infra HCL. Clear blast radius — a bad push only affects that team's agents.
- **Domain_Admin and Business_User have no repo** — they operate via the Admin Console UI.

**Consequences:**
- Module consumers must pin versions explicitly — no implicit "latest" from a monorepo HEAD
- Cross-repo CI: module changes require downstream consumers to update version pins (automate via Dependabot or Renovate)
- Each repo has its own CodePipeline with appropriate stages
- Platform_Admin manages two repos (`eap-modules` + `eap-platform`)
