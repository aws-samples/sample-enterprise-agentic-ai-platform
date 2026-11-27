# ADR-028: Deployer-Supplied OIDC Identity Provider

**Status:** Accepted
**Date:** 2026-09-02

**Refines:** ADR-017 (Identity Architecture)

## Context

ADR-017 established EAP's three-layer identity model and stated the intent
that the platform is **IdP-agnostic** — swappable between Cognito and any external
OIDC provider by changing a single OIDC discovery URL. In practice that intent was only
partially realized:

- The `identity/` module **unconditionally created** an Amazon Cognito user pool;
  there was no way to point the platform at an external IdP.
- Only the gateway and runtime/pipeline layers consumed an `oidc_discovery_url`
  *variable*. There was no root-level input, so "swap the IdP" would have meant
  editing modules, not changing one value.
- Several places hardcoded a specific pool's discovery URL / pool ID
  (`us-east-1_VuSizpIwi`) and a hardcoded `us-east-1` issuer region, plus a stale
  CloudFront domain in the Cognito app client's OAuth callback list.

The platform's operating model treats external core components (identity,
observability) as integrations wired **by reference**, not hosted by the
platform. Identity should follow that model: the deployer brings an OIDC
provider and the platform consumes it.

## Decision

The OIDC identity provider is a **deployer-supplied input**, propagated
platform-wide:

1. **Root inputs** (`eap-platform/variables.tf`):
   - `oidc_discovery_url` (default `""`) — the external IdP's OIDC discovery URL.
   - `oidc_issuer`, `oidc_audience` (default `""`) — optional JWT-validation overrides.
   - `console_url` (default `""`) — the public console URL used to build the
     OAuth callback (`<console_url>/auth/callback`); empty ⇒ derive from the
     platform-created CloudFront domain.

2. **Conditional Cognito.** `module.identity` is created **only when
   `oidc_discovery_url == ""`** (`count = var.oidc_discovery_url == "" ? 1 : 0`).
   - Empty ⇒ the platform provisions the Cognito pool exactly as before
     (default, zero-config path).
   - Set ⇒ Cognito is skipped and the external IdP is used.

3. **Single source of truth.** A `local.oidc_discovery_url = coalesce(
   var.oidc_discovery_url, try(module.identity[0].oidc_discovery_url, ""))`
   (and companion audience/scope locals) feeds **every** consumer: the AgentCore
   Gateway CUSTOM_JWT authorizer, the integration pipelines, the invoke-proxy
   JWT authorizer/issuer, studio-read, and the console build.

4. **Callback propagation.** The OAuth callback URL is derived from `console_url`
   (or the CloudFront domain) and standardized on the `/auth/callback` path. When
   Cognito is created, its app-client `callback_urls`/`logout_urls` are driven
   from that value (no hardcoded domains). When an external IdP is used, the
   platform does not manage the IdP's client; instead the runbook instructs the
   deployer to register `<console_url>/auth/callback` in their IdP, and the
   resolved value is still injected into the console build.

5. **No stale literals.** All `us-east-1_VuSizpIwi` occurrences and the hardcoded
   `us-east-1` issuer region are removed from Terraform and application code;
   pool ID / issuer are always derived from injected config.

## Consequences

- The platform is genuinely IdP-agnostic: a deployer integrates any OIDC provider
  by setting `oidc_discovery_url` (+ optional issuer/audience) and `console_url`,
  with no module edits.
- The default experience is unchanged: leave `oidc_discovery_url` empty and the
  platform provisions Cognito and creates users per the runbook (Step 2.5).
- **Cognito-dependent surfaces under an external IdP.** A few resources assume a
  Cognito pool: the console **Cognito Identity Pool** (browser AWS-credential
  exchange), the per-domain **Cognito user group** (`module.domains`), and the
  **Langfuse SSO** wiring. These are handled by gating them on the
  Cognito-created condition (they are skipped when an external IdP is supplied);
  providing external equivalents (e.g. an OIDC-federated identity pool) is
  tracked as follow-up work. This is the known edge of the external-IdP path and
  is documented rather than silently broken.
- `identity/` outputs are now referenced as `module.identity[0].*`; all consumers
  route through the `local.oidc_*` values.

## Alternatives Considered

- **Keep Cognito always-created, add an override variable only.** Lower risk, but
  not truly IdP-agnostic — Cognito resources would still be provisioned and
  billed even when an external IdP is used, and the "one variable swap" intent of
  ADR-017 would remain unrealized.
- **Support only Cognito.** Rejected — contradicts ADR-017 and the
  integrate-external-components-by-reference operating model.

---
