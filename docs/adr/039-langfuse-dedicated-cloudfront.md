# ADR-039: Langfuse via Its Own Dedicated Hardened CloudFront (not a console subpath)

**Status:** Accepted
**Date:** 2026-09-14

## Context

ADR-038 exposed the Langfuse UI publicly by adding the Langfuse ALB as a
`/langfuse/*` origin on the **demo console's** CloudFront distribution, so the
console could embed it same-origin. In practice this did not work, confirmed
against a live deploy:

- Langfuse is a **Next.js app that serves at root (`/`)**. It does not run under
  a `/langfuse` subpath: it 308-redirects `/langfuse/` → `/langfuse`, and links
  all its assets/routes at `/`.
- CloudFront's `/langfuse/*` behavior does **not** match the bare `/langfuse`
  path the console iframe requests, so that request fell through to the
  **default S3 origin (the console SPA)** — the console rendered *itself* inside
  the Langfuse iframe (infinite self-nesting).
- Even a trailing-slash `/langfuse/` returned `308 → /langfuse`, bouncing back
  to the S3-served SPA.

Making the subpath work would require a CloudFront Function to strip the
`/langfuse` prefix before the origin **and** configuring Langfuse's Next.js
`basePath`/`NEXTAUTH_URL` to live under `/langfuse` — brittle, version-dependent
on the self-hosted Langfuse image, and fighting the tool's root-origin
assumption.

## Decision

We will front Langfuse with its **own dedicated, hardened CloudFront
distribution** — a single origin at the Langfuse ALB **root** — and have the
console embed that distribution's **absolute URL**. Langfuse serves normally at
`/`; there is no subpath and no prefix rewriting.

- The distribution is created in the `examples-console` module (which already
  owns the WAF WebACL and the shared origin secret, and the Langfuse ALB is
  already CloudFront-facing from ADR-038's lockdown). One origin = the Langfuse
  ALB (`http-only`, web port); a single default cache behavior (no caching,
  all-viewer-except-host); the **same WAF** attached; the **same secret origin
  header** injected (the ALB listener rule still requires it, and its security
  group still admits only the CloudFront origin-facing prefix list).
- The console's `ObservabilityWorkspace` does **not iframe** Langfuse — it
  renders an **"Open GenAI Observability ↗" launch card** that opens
  `https://<langfuse-cloudfront>` (absolute, BU-scoped) in a **new tab**.
  Langfuse ships anti-clickjacking headers (`X-Frame-Options` /
  `frame-ancestors`) and uses first-party auth cookies, so a cross-origin iframe
  was refused by the browser ("refused to connect") and in-frame login was
  unreliable. Opening in a new tab keeps Langfuse's security headers intact and
  gives first-party auth. This mirrors the existing "View in CloudWatch"
  deep-link pattern in the same workspace.
- The `/langfuse/*` origin + behavior are **removed** from the demo console
  distribution.
- Created only in the demo path (`deploy_console` + `deploy_langfuse`); the
  Langfuse ALB stays fully private otherwise (ADR-030 unchanged).

## Consequences

- **Langfuse actually renders** in the console iframe — it is served at its own
  root, so its redirects and asset links resolve correctly. The self-nesting is
  eliminated.
- **Same hardened posture** as ADR-037/038: WAF at the edge, ALB reachable only
  via CloudFront (prefix list + secret header), TLS 1.2+. Nothing about the
  lockdown is weakened; only the *delivery* changes from a console subpath to a
  dedicated distribution.
- **Two public CloudFront domains in the demo** (the console and Langfuse)
  instead of one. That is the accepted trade for a working embed; it is also how
  a full app like Langfuse is normally productionized behind an edge.
- **The embed is cross-origin** (console domain vs. Langfuse domain), so the
  iframe relies on Langfuse's own app login rather than a same-origin session.
  The console distribution already emits no `X-Frame-Options`/frame-denying CSP,
  so framing is permitted; if Langfuse later sets a restrictive
  `frame-ancestors`, its `console_domain` input names the console origin.
- **Supersedes ADR-038.** The private-by-default posture and the
  `enable_cloudfront_origin` opt-in on the Langfuse module (which makes the ALB
  CloudFront-facing + secret-header-locked) are retained from ADR-038; only the
  *edge topology* (dedicated distribution vs. console subpath) changes.

## Alternatives Considered

- **Keep the console `/langfuse` subpath (ADR-038) and make it work** — add a
  CloudFront Function to strip the prefix + set Langfuse `basePath`/
  `NEXTAUTH_URL`. Rejected: brittle, depends on the self-hosted Langfuse image's
  subpath support, and multiple interacting moving parts (prefix rewrite, auth
  cookies, absolute asset URLs, CSP). Confirmed non-trivial against a live
  deploy.
- **Drop in-console Langfuse embedding entirely** and rely on the AWS-native
  CloudWatch/X-Ray surfaces. Rejected: the embedded Langfuse trace explorer is
  the intended primary in-console trace surface for the demo.

---
