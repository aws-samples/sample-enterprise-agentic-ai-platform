# ADR-009: Two-Track Strategy — Terraform (MVP) and K8s (Future)

**Status:** Accepted (applies to both tracks)
**Date:** 2026-03-13

**Context:** Evaluated Kubernetes CRDs, CDK/CloudFormation, and Terraform as platform implementation approaches.

**Decision:** Pursue both tracks, starting with Terraform (simpler, AWS-native, lower operational overhead):
- **Terraform track (MVP):** Terraform modules + AWS Config Rules/SCPs + CodePipeline. Start here.
- **K8s track (future):** CRDs + controller-runtime. Revisit when targeting K8s-native teams.

**Key Insight:** AgentCore is fully managed — no need for K8s reconciliation loops to manage AWS resources. Terraform delivers the same governance model with less operational overhead.

**Consequences:** K8s spec is parked, not abandoned. Core principles carry forward (ADR-006, ADR-008, ADR-011).
