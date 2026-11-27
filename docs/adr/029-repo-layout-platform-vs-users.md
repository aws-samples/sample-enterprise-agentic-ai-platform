# ADR-029: Repository Layout — `platform/` vs `users/`, and User-Repo Naming

**Status:** Accepted
**Date:** 2026-09-02

**Relates to:** ADR-012 (Multi-repo strategy), ADR-018 (Platform Vending Model)

## Context

The working monorepo colocated every repo under a single `terraform/` parent:

```
terraform/
  eap-terraform-modules/  eap-platform/  console/  demo-ui/
  eap-governance/  eap-mcp-integrations/
  eap-knowledge-bases-team-bu-1/  team-bu-1/
```

Two problems:

1. **`terraform/` is a misnomer.** Several children contain no Terraform at all —
   `team-bu-1/` (agent code + YAML), `console/` and `demo-ui/` (React apps), and
   the governance/mcp/KB repos (Cedar policy + YAML). Grouping them under
   `terraform/` mislabels them.
2. **Inconsistent naming.** Three platform-*user* repos carried the platform
   brand prefix (`eap-governance`, `eap-mcp-integrations`,
   `eap-knowledge-bases-*`) while the fourth user repo (`team-bu-1`) did
   not — even though all four are repos that platform *users* (different
   personas) push content to, not platform-owned product.

The platform's own model distinguishes **the platform product/blueprint**
(Platform Engineering/Operator, writes Terraform) from **platform-user repos**
(governance / data / GenAI-data / app-dev personas, write YAML/policy/code, no
Terraform). The layout should make that ownership boundary obvious.

## Decision

Group repos at the workspace root by **ownership**, and reserve the `eap-`
prefix for the platform product only.

```
platform/                              # platform product + blueprint (writes Terraform)
  eap-terraform-modules/         # reusable modules — the product/interface
  eap-platform/                  # the composed blueprint (deployed per BU)
  console/                             # platform console SPA
  demo-ui/                             # demo/validation UIs
  DEPLOY-RUNBOOK.md
users/                                 # platform-user / tenant repos (NO Terraform)
  governance/                          # AI Governance          (was eap-governance)
  mcp-integrations/                    # Data Engineer          (was eap-mcp-integrations)
  knowledge-bases-team-bu-1/           # GenAI Data Engineer    (was eap-knowledge-bases-team-bu-1)
  team-bu-1/                           # App Developer (tenant) — unchanged
docs/
```

- The `terraform/` parent is removed; everything moves up one level into
  `platform/` or `users/`.
- **Naming rule:** `eap-` prefix = the platform PRODUCT
  (`eap-terraform-modules`, `eap-platform`). Platform-user repos are
  **unprefixed**, named by role/tenant (`governance`, `mcp-integrations`,
  `team-{name}`). The three user repos drop their `eap-` prefix to match
  `team-bu-1`.
- `eap-terraform-modules/` and `eap-platform/` remain **siblings**
  inside `platform/`, preserving the module `source = "../eap-terraform-modules/…"`
  references with no edits.
- The `team-bu-1` **domain/BU identifier** (Cognito groups, IAM boundaries,
  lifecycle table, pipeline domain keys) is unchanged — only the repo *folder*
  grouping moved; its name is untouched.

## Consequences

- The ownership boundary is visible in the top-level layout, and the
  `eap-` prefix now means exactly one thing (the product).
- These folders map to independent CodeCommit repos; the three renamed user
  repos get the new (unprefixed) names on the fresh-account deploy. Since nothing
  is deployed yet, there is no repo-rename migration.
- All path/reference updates (source-repo config, pipeline `repository_name`,
  `terraform_remote_state`, `codecommit::` remotes, `.gitignore`, runbook `cd`
  paths, README layout, steering `code-layout.md`) are updated to the new
  locations/names in the same change.
- `console/` and `demo-ui/` are placed under `platform/` as platform-owned apps
  (not vended user repos). `console/deploy.sh`'s `../eap-platform` path
  stays valid since both remain siblings under `platform/`.

## Alternatives Considered

- **Flatten to the repo root (no parent).** Rejected: mixes repo-folders with
  `docs/` and loses the ownership grouping.
- **Rename `terraform/` → `repos/`, keep flat.** Simpler, but doesn't express the
  platform-vs-user ownership split the model cares about.
- **Strict `infra/` vs `app/` split.** Rejected: the governance/mcp/KB repos are
  config/policy repos owned by non-developer personas — neither "infra" nor
  "app" — so a two-way infra/app split misrepresents them. Ownership
  (`platform` vs `users`) is the axis that actually holds.

---
