# ADR-005: Controller Framework — controller-runtime for MVP, No ACK or Crossplane Dependency

**Status:** Accepted  
**Date:** 2026-03-12

**Context:** Evaluated three options for implementing CRD controllers:
1. **Pure controller-runtime** — custom Go controllers with AWS SDK for Go v2
2. **AWS Controllers for Kubernetes (ACK)** — auto-generated 1:1 CRD controllers from AWS API models. No ACK controller for AgentCore exists today.
3. **Crossplane** — Composition engine for declarative blueprints. Adds XRDs, Compositions, Providers — significant learning curve.

**Decision:** Use **pure controller-runtime** for MVP. No ACK or Crossplane dependency.

**Rationale:**
- No ACK AgentCore controller exists yet — we'd have to build one from scratch anyway
- ACK's auto-generated controllers are a good fit for 1:1 mapping, but EAP needs platform-level logic (webhook injection, domain isolation, memory claim binding) that ACK doesn't provide
- Crossplane's value is composition/blueprints — which we explicitly don't want (ADR-006)
- controller-runtime gives full control over reconciliation logic, webhook registration, and status reporting
- If AWS ships an ACK AgentCore controller post-MVP, we can evaluate adopting it for the low-level reconciliation and layering EAP's platform logic on top

**Consequences:**
- All controller logic is custom Go code using controller-runtime + AWS SDK for Go v2
- No external framework dependencies beyond controller-runtime
- Webhook registration (mutating, validating) handled natively by controller-runtime
