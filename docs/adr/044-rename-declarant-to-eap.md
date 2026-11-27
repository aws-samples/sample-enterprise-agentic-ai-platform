# ADR-044: Rename Platform Declarant → Enterprise Agentic AI Platform (EAP)
**Status:** Accepted
**Date:** 2026-11-12
**Supersedes:** ADR-027 (Rename Platform Tortellini → Declarant)

## Context
ADR-027 renamed the platform to **Declarant**. The platform is now being
prepared for open-source release, and the name was reviewed against AWS
open-source naming guidance, which groups names as *descriptive*, *suggestive*,
or *abstract*:

- **Descriptive** names say what the project does. They carry the lowest
  trademark risk and are approved fastest.
- **Declarant** is suggestive at best. It is also an existing English legal
  term (a person who makes a formal declaration), which hurts search and
  first-glance comprehension. Most readers do not connect it to AI agents.

A descriptive name is the better fit for an adoption-first open-source project.

As with the previous rename, the name is hardcoded as a literal across the repo
(~1,340 references in ~280 files, plus directory paths, AWS resource-name
literals, the Terraform state backend, and the runtime env-var prefix
`DECLARANT_*`).

The only deployed environment was the demo test bed. It was torn down under the
old name before the rename, so there is no Terraform state to migrate.

## Decision
We will rename the platform to **Enterprise Agentic AI Platform**, short form
**EAP**, with the tagline **"Powered by Amazon Bedrock AgentCore"**.

- **Display name** (README, docs, console UI, specs): "Enterprise Agentic AI
  Platform (EAP)" on first mention, "EAP" after. "Amazon Bedrock AgentCore"
  stays in the tagline and attribution, not in the name itself.
- **Declarative model is unchanged.** The name no longer carries the
  "one who declares" wordplay, so the declarative message moves into the copy:
  "an open-source, declarative agentic AI platform", "Declare your agents — the
  platform handles the rest", and "YAML in, infrastructure out". The console
  brand mark is an "E" whose three arms are the YAML `---` marker.
- **Code & infrastructure token: `eap`.** Case mapping:
  `declarant → eap`, `Declarant → EAP`, `DECLARANT → EAP`. This covers
  resource-name literals (`declarant-*` → `eap-*`), the env-var prefix
  (`DECLARANT_*` → `EAP_*`), the `x-declarant-origin` header, SSM paths
  (`/declarant/...` → `/eap/...`), and the Python package
  (`declarant_generate` → `eap_generate`).
- **Directory & file paths:** `platform/declarant-platform` →
  `platform/eap-platform`, `platform/declarant-terraform-modules` →
  `platform/eap-terraform-modules`, `.kiro/specs/declarant-*` →
  `.kiro/specs/eap-*`, plus diagram, vision and console asset file names.
- **Terraform state backend:** `eap-platform-state-<ACCOUNT_ID>` /
  `eap-platform-locks`.
- **Repository slug:** `enterprise-agentic-ai-platform`.

ADR-027 is marked `Superseded by ADR-044`. Unlike ADR-027, this rename does
**not** rewrite earlier decisions in place: ADR-001 and ADR-027 keep the
Declarant wording they were accepted with, so the naming lineage
(ADR-001 → ADR-027 → ADR-044) stays auditable.

## Consequences
- Human-facing and machine-facing references read **EAP**, except the
  historical ADR-001 and ADR-027 text.
- Any stack deployed under the old name must be destroyed with the old code
  before deploying the new code. Resource names and the state backend both
  change, so a plain `terraform apply` would start from empty state and
  collide with resources whose names do not contain the platform name.
- `eap` is a short, common token. Names that must be globally unique and are
  not account-scoped (S3 buckets, the Cognito hosted-UI domain) are more
  likely to collide than `declarant-*` was. They are verified at first deploy.
- Binary assets (the vision deck and PDFs, `docs/vision/EAP.png`, and the
  architecture diagram PNG) are renamed but their contents still show the old
  name until they are re-exported.
- The rename is again a literal replacement, so a future rename would be equally
  invasive. The ADR-027 follow-up to parameterize the name prefix still applies.

## Alternatives Considered
- **Keep Declarant.** Lowest effort, but keeps the trademark, search and
  comprehension issues above.
- **Enterprise Agent Platform** (`enterprise-agent-platform`). Shorter, with an
  exact EAP acronym. Not chosen: "agentic AI" matches current industry search
  terms and the existing subtitle and repository name.
- **Put AgentCore in the name** (for example `agentcore-platform`). Leans on an
  AWS service mark. Keeping it in the tagline is the safer pattern.
- **Brand-only rename** (docs and UI text only). Leaves `declarant` in
  directory names, quick-start commands, packages and deployed AWS resource
  names. For an open-source audience that reads the code and runs the commands,
  that inconsistency is the more visible half.
