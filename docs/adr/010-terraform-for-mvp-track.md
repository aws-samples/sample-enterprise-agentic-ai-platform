# ADR-010: Terraform for MVP Track

**Status:** Accepted
**Date:** 2026-03-13

**Context:** With the two-track decision (ADR-009), need to define the Terraform-based platform architecture.

**Decision:** EAP Terraform track consists of:

1. **Terraform module library** (`eap-modules` repo) — one module per AgentCore primitive:
   - `modules/runtime`, `modules/memory`, `modules/gateway`, `modules/identity`, `modules/policy`, `modules/observability`, `modules/evaluations`, `modules/code-interpreter`, `modules/browser`
   - Platform-specific: `modules/domain`, `modules/pipeline`

2. **Cross-cutting governance** via AWS Config Rules + SCPs + IAM Access Analyzer (Fiddler.ai optional)

3. **Self-service** via Terraform Cloud workspaces (or Atlantis for PR-driven)

4. **GitOps** via CodePipeline (other CI/CD pipelines optional) — PR-driven plan/apply

**Tech Stack:** Terraform (HCL), AWS Config Rules/SCPs, CodePipeline, S3+DynamoDB or Terraform Cloud for state, React (TypeScript) Admin Console.

**Consequences:** No Go backend. Platform logic lives in Terraform modules and governance policies. Cross-cutting concerns enforced at plan time and via AWS-native services.
