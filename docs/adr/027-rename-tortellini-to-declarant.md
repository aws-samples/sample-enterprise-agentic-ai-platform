# ADR-027: Rename Platform Tortellini → Declarant

**Status:** Superseded by ADR-044
**Date:** 2026-09-02

**Supersedes:** ADR-001 (Platform Name)

## Context

ADR-001 named the platform **Tortellini** — a name chosen to be distinct from
the underlying Amazon Bedrock AgentCore primitives it wraps (the original
rationale used a "stuffed pasta wrapping its filling" metaphor). The platform is
now being productized and delivered under the name **Declarant**, which is also
the name of this repository (`declarant-agentic-ai-platform`) and the name shown
in the console UI ("Declarant — Declarative Enterprise Agentic AI Platform").

**Declarant** better reflects the platform's core model: a *declarant* is one who
declares, and teams **declare** what they need in YAML manifests while the
platform provisions the underlying primitives ("YAML in, infrastructure out").
Carrying two names — the old codename in the source and Declarant externally —
was a persistent source of confusion in docs, resource names, and customer-facing
surfaces.

The name was never parameterized: it is hardcoded as a literal across the repo
(~1,480 references in ~248 files, plus ~409 file/directory paths, AWS
resource-name literals, the Terraform state backend, and the runtime env-var
prefix `TORTELLINI_*`). A rename is therefore invasive by construction.

This change is being made while the platform is **not deployed to any AWS
account** — a fresh account will be stood up under the new name — so there is no
Terraform state to migrate and no destroy/recreate risk on live resources.

## Decision

We will rename the platform from **Tortellini** to **Declarant** everywhere,
as a single brute-force cutover:

- **Prose** (README, `docs/**`, `.kiro/specs/**`, `.kiro/steering/**`): all
  human-facing references `Tortellini → Declarant` (case-preserving).
- **Code & infrastructure**: resource-name literals (`tortellini-*` →
  `declarant-*`), the runtime/observability env-var prefix (`TORTELLINI_*` →
  `DECLARANT_*`), and Terraform module `source` paths.
- **Directory & file paths**: the seven top-level `tortellini-*` directories and
  the `.kiro/specs/tortellini-*` spec folders are renamed to `declarant-*`.
- **Terraform state backend**: the S3 bucket and DynamoDB lock table literals
  become `declarant-platform-state` / `declarant-platform-locks`. These cannot
  be Terraform variables (the `backend` block must be literal), so this is a
  one-time deliberate naming choice.

The case mapping is: `Tortellini → Declarant`, `tortellini → declarant`,
`TORTELLINI → DECLARANT`.

ADR-001 is marked `Superseded by ADR-027` (both in the `docs/adr/README.md`
index and in the body of both spec `adr.md` files where it appears). To keep the
codebase free of the retired name and the outdated pasta metaphor, ADR-001's
narrative in the two foundational spec files is updated in place to reflect the
Declarant name and its declarative rationale; the decision's *substance* (the
platform has a distinct name that wraps AgentCore primitives) is unchanged, and
this ADR-027 records the lineage of the rename.

## Consequences

- Every human-facing and machine-facing reference reads **Declarant**, removing
  the codename/brand split.
- Because the rename is a blind literal replacement, it does **not** de-brittle
  the platform: the new name `declarant` is now hardcoded in the same ~1,480
  places. A future rename would be equally invasive. A follow-up to parameterize
  the resource-name prefix and env-var prefix behind a single `platform_name`
  input is recorded as optional future work (it can only cover the code/infra
  layer — directory names, the state backend, and prose are inherently literal).
- The fresh AWS account must bootstrap the state backend under the new
  `declarant-platform-state` / `declarant-platform-locks` names before the first
  `terraform init`.
- The console `dist/` build artifact is regenerated from source (during
  `npm run build` / `terraform apply`); it is not hand-edited and may lag until
  the next build.

## Alternatives Considered

- **Cosmetic/brand-only rename** (docs + user-facing text; leave infra literals
  and env vars as `tortellini`). Rejected: leaves a confusing codename/brand
  split in the source and AWS resource names.
- **Parameterize the name behind a `platform_name` variable ("hybrid").**
  Rejected as the primary approach: Terraform cannot parameterize the backend
  block, directory names, or prose, so it would only cover the resource-name and
  env-var layer (~40% of references) while adding real refactor risk now. Kept as
  optional future work, decoupled from this rename.

---
