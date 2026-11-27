# ADR-034: Demo Console Is Optional (`deploy_console`)

**Status:** Accepted
**Date:** 2026-09-02

## Context

The platform ships a bundled demo console: an S3 + CloudFront single-page app
that lets a user chat with agents and drive the Build workspace. Three
Terraform modules make it work, and they form one stack:

- `module.console` — the S3 bucket + CloudFront distribution serving the SPA.
- `module.invoke_proxy` — the browser→AgentCore bridge. Creates a REST API
  (`POST /api/invoke`, buffered, timeout-bumpable) for interactive chat, plus
  an HTTP API that exists only to host the read routes below, both gated by a
  Cognito JWT authorizer, fronting a Lambda that calls
  `bedrock-agentcore:InvokeAgentRuntime` with its own execution role.
- `module.studio_read` — a read-only Lambda that attaches seven Build-workspace
  GET/POST routes (`/api/my-deployed-agents`, `/api/deployment-status`, etc.)
  onto the invoke-proxy HTTP API and its shared authorizer.

Two facts drove this decision:

1. **These three modules are a closed unit.** A dependency trace confirmed the
   only consumers of `module.invoke_proxy` outputs are `module.console` (for its
   CloudFront origins) and `module.studio_read` (which hangs its routes off the
   invoke-proxy HTTP API). Nothing else in the root — no output, no other
   module, no remote state — references any of the three. Remove the console and
   `studio_read` is orphaned and `invoke_proxy` is referenced only by that
   orphan. The invoke proxy was built to serve the CloudFront console and stream
   its output; it has no purpose independent of it.

2. **This stack is the platform's entire public ingress.** CloudFront is a
   public edge and the two API Gateways expose public `execute-api` endpoints
   (JWT-gated, but internet-reachable). An enterprise doing a no-public-access
   install hosts its own UI internally (BYO UI) and reaches agents over the
   in-VPC path (ADR-031/032) — it neither needs nor wants this demo stack.

Previously the console stack was created unconditionally. There was no way to
deploy the platform without also standing up public CloudFront + API Gateway
endpoints. A stale hardcoded CloudFront hostname
(`https://d1y0985nzqjge1.cloudfront.net`) was also baked into the invoke-proxy
HTTP API's CORS configuration.

## Decision

We will make the demo console **optional**, gated by a single root variable
`deploy_console` (bool, **default `true`**). It gates all three modules as a
unit via module-level `count`:

- `module.console`, `module.invoke_proxy`, and `module.studio_read` each get
  `count = var.deploy_console ? 1 : 0`. Because they are gated by the same flag,
  the cross-references between them (`module.invoke_proxy[0].*`) are always valid
  when evaluated.
- `deploy_console = true` (default) reproduces today's behavior exactly, so the
  out-of-the-box demo keeps working.
- `deploy_console = false` removes the **entire public ingress** in one switch:
  CloudFront, the S3 SPA bucket, both API Gateways, both Lambdas, and their IAM.

We will also remove the stale hardcoded CloudFront hostname from the
invoke-proxy CORS config and replace it with a deployer-supplied
`console_cors_origins` variable (list, default `[]`). When empty — the demo
default — the HTTP API is configured with **no** CORS block at all, which is
correct because the demo console is served same-origin through CloudFront. CORS
is only for a cross-origin BYO UI pointed at a still-deployed proxy.

## Consequences

- **No-public-access installs are now a supported one-line posture.** Setting
  `deploy_console = false` leaves the platform with zero public ingress; the
  enterprise's internal UI talks to agents over the in-VPC path.
- **The API-Gateway "public surface" gap collapses into this flag.** Because the
  API Gateways exist only to serve the console, they are not an independent gap
  to privatize separately — `deploy_console = false` removes them outright.
- **The demo is unaffected by default.** `true` is the default and the console
  matrix (`terraform console`) confirms 1/1/1 modules when true and 0/0/0 when
  false.
- **The stale CloudFront hostname is gone.** CORS is now empty-by-default and
  deployer-configurable, removing a baked-in literal that never matched a live
  distribution.
- **BYO UI cross-origin access requires opt-in.** A BYO UI that calls a
  still-deployed proxy from a different origin must set `console_cors_origins`;
  there is no implicit allowed origin anymore.

## Alternatives Considered

- **Host the demo UI privately in-platform (jumphost / internal ALB).**
  Rejected — over-engineering a throwaway demo UI that a BYO enterprise UI
  replaces anyway. The value is the flag to turn it off, not a second hosting
  mode.
- **Serve the SPA from S3 only, drop CloudFront.** Rejected — worse posture: an
  S3 website endpoint is public HTTP-only and forces CORS onto the API Gateways.
  A downgrade, not a simplification.
- **Default `deploy_console = false`.** Rejected — would break existing demo
  deploys on upgrade. We keep the lean-`true` default and document the
  enterprise override, consistent with how `enable_transaction_search` is
  handled.
- **Gate the modules independently (separate flags).** Rejected — they are a
  single dependency-closed stack; independent flags would allow incoherent
  combinations (e.g. a console with no invoke path).
