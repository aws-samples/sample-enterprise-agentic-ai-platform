# ADR-038: Expose Langfuse UI Publicly Through the Hardened Demo Console Edge

**Status:** Superseded by ADR-039
**Date:** 2026-09-14

> **Superseded by [ADR-039](039-langfuse-dedicated-cloudfront.md).** The
> `/langfuse` subpath on the console distribution did not work in practice —
> Langfuse serves at root and does not run under a subpath, so the iframe
> requests fell through to the S3 console SPA (the console nested itself).
> ADR-039 fronts Langfuse with its own dedicated hardened CloudFront (root
> origin). The private-by-default posture and the Langfuse module's
> `enable_cloudfront_origin` opt-in (ALB CloudFront-facing + prefix-list +
> secret-header lockdown) introduced here are RETAINED by ADR-039; only the edge
> topology changes.

## Context

ADR-030 deploys Langfuse **private**: an internal ALB (`internal = true`), HTTP,
reachable only from within the VPC (its security group admits the VPC CIDR on
the web port). The console's ObservabilityWorkspace iframe-embeds Langfuse via
`VITE_LANGFUSE_EMBED_ORIGIN` set to the internal ALB DNS. Because the console is
public (CloudFront) while Langfuse is private, that embed **only renders for
on-network viewers** (VPN / corp network); a public visitor's browser cannot
reach the internal ALB.

ADR-037 introduces a hardened, exec-facing demo console: a single CloudFront
distribution (WAF, TLS) whose origins are the S3 SPA assets and an
internet-facing-but-locked-down ALB (CloudFront origin-facing prefix list + a
secret origin header) fronting the examples Fargate backend.

The requirement now is that an **executive hitting the public console URL** can
see the Langfuse "GenAI Observability" UI — without a VPN. That is impossible
while Langfuse's ALB is internal.

## Decision

We will make Langfuse reachable through the **same hardened demo console
CloudFront distribution**, as an additional locked-down origin, gated behind a
new opt-in flag. Langfuse stays private by default (ADR-030 unchanged).

### 1. Optional CloudFront-facing mode on the Langfuse module

Add `enable_cloudfront_origin` (default `false`) to the Langfuse module. When
`true`:

- The Langfuse ALB becomes `internal = false` (internet-facing, in the public
  subnets it already uses).
- Its security group ingress is **restricted to the CloudFront origin-facing
  managed prefix list** (`com.amazonaws.global.cloudfront.origin-facing`), and
  its listener requires a **secret origin header** injected by CloudFront —
  identical lockdown to the examples ALB (ADR-037). The existing VPC-CIDR
  ingress is retained so the OTel Collector's in-VPC OTLP path is unaffected.

When `false` (the default, and every non-demo deployment): the ALB stays
`internal = true` exactly as ADR-030 specifies. No posture change.

### 2. Langfuse as a third origin on the demo console CloudFront

The demo console distribution (ADR-037) gains a third origin: the Langfuse ALB,
served under path pattern `/langfuse/*` (no-cache, all-viewer-except-host,
secret header attached). Langfuse's public base URL / `NEXTAUTH_URL` and its
`frame-ancestors` CSP (the module already has a `console_domain` input) are set
so it can be served under that subpath and framed by the console origin.

### 3. Console integration

The ObservabilityWorkspace is relabeled **"GenAI Observability / Langfuse"** and
embeds `https://<console-domain>/langfuse/` (same-origin) instead of the
internal ALB DNS, so it renders for any public viewer through the edge.

### 4. Scope boundary

This is wired into the **demo preset only**, alongside the ADR-037 examples
surface. The `enterprise` preset keeps `deploy_console=false` and Langfuse
private (or absent). Enterprises that self-host observability are unaffected.

## Consequences

- **Public exec demo works.** Langfuse renders through the hardened edge without
  a VPN — the point of the demo surface.
- **Consistent hardening.** Langfuse reuses the exact ADR-037 lockdown (prefix
  list + secret header + WAF at the edge + TLS), rather than a bespoke exposure.
- **Private-by-default preserved.** The default and all non-demo deployments keep
  Langfuse internal; only the explicit `enable_cloudfront_origin` opt-in (set in
  the demo path) exposes it, so ADR-030's private posture is intact everywhere
  else.
- **Posture change is real and now auditable.** Langfuse handling sensitive trace
  data behind a *public* (if hardened) edge is a deliberate widening of exposure;
  it is acceptable for a demo environment with non-sensitive sample traffic, and
  MUST NOT be enabled where Langfuse holds real customer telemetry. This
  constraint is recorded here.
- **Follow-on wiring risk.** Serving Langfuse under a `/langfuse` subpath can
  require setting its public base URL and CSP correctly; asset/redirect paths may
  need adjustment. Tracked as part of the demo-console implementation.

## Alternatives Considered

- **Relabel-only, keep the private embed (Option A).** Zero infra change, but the
  embed stays blank for public viewers — fails the "exec without VPN" goal.
- **Separate public CloudFront distribution for Langfuse (Option C).** Cleaner
  routing/CSP isolation, but a second public front door diverges from the single
  hardened console URL and duplicates edge/WAF setup.
- **Make the Langfuse ALB unconditionally internet-facing.** Rejected: would
  weaken ADR-030's private posture for every deployment; the change must be an
  explicit demo-only opt-in.

---
