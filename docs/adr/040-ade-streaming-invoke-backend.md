# ADR-040: Streaming ADE Invoke via an Always-On ECS/Fargate Backend

**Status:** Accepted
**Date:** 2026-09-18

## Context

The Agent Deployment Engineer (ADE, a.k.a. Studio) is the platform-owned agent
that backs the Console **Build workspace** chat. Users design and deploy agents
by conversing with it, so its chat is the most latency- and UX-sensitive surface
in the platform.

Today the ADE chat does **not** stream token-by-token. The response appears all
at once when the turn finishes. The cause is the invoke transport, not the
agent:

- The Console (`a2aClient.invokeAgent`) calls `/api/invoke` → CloudFront →
  **API Gateway REST API** → the **invoke-proxy Lambda** → AgentCore.
- The Lambda calls A2A `message/send` (buffered) and accumulates the whole turn
  before returning one Server-Sent-Events (SSE) body.
- **API Gateway (REST and HTTP) cannot stream a Lambda proxy response** — it
  buffers. REST was chosen deliberately because its integration timeout can be
  raised above the 29s default (Service Quota) for long, tool-heavy turns; the
  cost of that choice is that the response is buffered (documented in
  `invoke-proxy/src/index.ts` and `invoke-proxy/main.tf`).

The ADE runtime itself **can** stream: the Strands base image sets
`enable_a2a_compliant_streaming=True`, and A2A `message/stream` yields
incremental `artifact-update` deltas. This was verified live against the
deployed `aws_architect_agent` runtime (58+ progressive frames vs. one buffered
blob for `message/send`).

The one streaming invoke path that exists today — the **Examples surface**
(`/examples-api/invoke` → CloudFront → ALB → Fargate signer, ADR-037) — is:

1. **Demo-only.** It is part of `module.examples_console`, gated on
   `deploy_console` (ADR-034). The `enterprise` preset sets
   `deploy_console = false`, so it (and all public ingress) is not deployed.
2. **Not safe for the ADE as-is.** It has **no Cognito JWT authorizer** (its
   security is CloudFront origin-secret header + WAF + prefix-list SG) and it
   enforces **no Requirement-11 runtime allow-list** — it signs and forwards any
   `runtimeArn` sent. The invoke-proxy Lambda, by contrast, enforces both a
   Cognito authorizer and the `isValidRuntimeArn` + discovered-runtime allow-list
   (Requirement 11).

So there is a gap: the ADE chat should stream in **both** presets, but the only
streaming transport is demo-only and lacks the ADE's security guarantees, while
the ADE's current transport enforces those guarantees but cannot stream.

## Decision

We will introduce a dedicated, **always-on ECS/Fargate ADE invoke backend** that
streams the ADE turn end-to-end via SSE, deployed in **both** presets, and we
will move the Console Build-workspace ADE chat onto it.

Specifically:

1. **New module `ade-invoke-backend`** (own module, not gated on
   `deploy_console`): an ECS/Fargate service running an SSE-streaming signer
   (the same streaming pattern proven in `examples-backend` — A2A
   `message/stream`, `artifact-update` deltas, 10s heartbeat), fronted by an
   **internal ALB** in the resolved VPC.
   - **Demo:** the existing demo CloudFront distribution fronts the internal ALB
     (adding an `/ade-api/*` behavior), reusing the ADR-037 origin-secret +
     WAF + prefix-list hardening.
   - **Enterprise:** the ALB is **internal only** (VPC/VPN/corp-network
     reachable); the customer's BYO UI calls it directly. No public edge is
     created, preserving the enterprise "zero public ingress" posture.

2. **Security parity with the Lambda path is mandatory.** The backend MUST
   enforce, in its own code:
   - **Cognito JWT validation** (or the resolved external OIDC, ADR-028) on every
     request — the caller's `Authorization: Bearer` token is validated before any
     invoke. This replaces the API Gateway Cognito authorizer that the Lambda
     path relied on.
   - The **Requirement-11 runtime allow-list** — port `isValidRuntimeArn` +
     `listDiscoveredRuntimeQualifiers` (the shared `runtimeAllowList` module) so a
     caller cannot invoke an arbitrary runtime. The ADE default (Studio runtime
     ARN) is resolved server-side, exactly as `resolveTarget` does today.

3. The agent is invoked with the **Fargate task role**, never the caller's
   identity — matching the current "invoke with the proxy's own role" rule.

4. **The `invoke-proxy` Lambda + REST API are retained** for now (per-agent chat
   via `AgentDetailView` and any non-ADE callers). Consolidating or retiring them
   is deferred follow-on work, not part of this decision.

## Consequences

**Positive**
- ADE chat streams token-by-token in **both** demo and enterprise — the primary
  UX goal.
- **No cold starts** for the ADE chat (always-on task); the Console's cold-start
  fallback messaging can be simplified.
- Long, tool-heavy ADE turns are no longer bounded by the API Gateway 29s
  integration timeout; each SSE frame + 10s heartbeat keeps the connection alive
  (ALB `idle_timeout`, CloudFront per-packet `origin_read_timeout`).
- Enterprise gets a first-class, in-VPC, no-public-ingress streaming invoke path
  it does not have today.

**Negative / cost**
- **Standing cost increases.** An always-on Fargate task + ALB is roughly
  ~$25–40/month per instance (task + ALB + data path), 24/7, **per BU/account**.
  This directly changes the FinOps headline in the runbook ("≈ $1–2/month idle,
  storage only, no always-on compute"). The runbook FinOps section and any
  "scales to zero when idle" claim MUST be updated to reflect an always-on ADE
  backend. This is the main tradeoff and warrants FinOps/EA awareness.
- **Two invoke transports coexist** until the Lambda path is retired
  (`/api/invoke` REST for per-agent chat, `/ade-api/*` ECS for ADE), which is
  more surface area to maintain in the interim.

**Neutral / follow-on**
- Auth + allow-list logic is now **duplicated** (Lambda and Fargate). Keep the
  `runtimeAllowList` module shared to avoid drift; consider extracting the JWT
  validation into a shared module too.
- Enterprise ingress is a **different** networking shape from the demo examples
  backend (internal ALB vs. CloudFront-fronted ALB) — the module must support
  both, gated by preset.
- The demo `/ade-api/*` route reuses ADR-037's hardening; the origin secret is
  already generated by `examples_console` in demo, but in enterprise (no
  examples_console) the ADE backend owns its own (internal-only) ingress and
  needs no origin secret.
- Frontend change: the Build-workspace ADE chat repoints from
  `a2aClient.invokeAgent('/api/invoke')` to the streaming ADE endpoint and must
  resolve/pass the Studio runtime ARN (or let the backend default it).

## Alternatives Considered

- **Lambda response streaming (Function URL, `InvokeMode=RESPONSE_STREAM`).**
  Keeps the pay-per-invoke / scale-to-zero cost model and avoids always-on
  compute. Rejected as the primary path because (a) it requires a substantial
  handler rewrite (`awslambda.streamifyResponse`), and (b) Function URLs support
  only `AuthType=NONE` or `AWS_IAM` — there is no Cognito authorizer, so the
  managed auth gate would have to be replaced by hand-rolled JWT validation or
  browser SigV4 (the console previously removed exactly that browser-IAM path).
  It remains a viable future option if the standing cost of an always-on backend
  proves unjustified; this ADR can be superseded if we switch.

- **Reuse the demo `examples-backend` for ADE.** Fastest to stand up (streaming
  already works), but it is demo-only (`deploy_console`), has no Cognito
  authorizer, and enforces no Requirement-11 allow-list. Routing the ADE — a
  privileged, deploy-capable agent — through an unauthenticated,
  unrestricted-target backend is an unacceptable security regression, and it
  would not exist in enterprise at all. Rejected.

- **Do nothing (keep buffered ADE chat).** Zero cost, but the ADE — the most
  interactive surface — never streams, and the UX gap persists in both presets.
  Rejected because streaming ADE is the goal that motivated this ADR.

---
<!--
Authoring rules (see docs/adr/README.md):
- Copy this file to docs/adr/NNN-slug.md using the next free number from README.md.
- Never reuse or renumber an existing ADR. Superseding decisions get a NEW number
  and flip the old one's Status to "Superseded by ADR-NNN".
- Update the index table + "Next available number" in docs/adr/README.md.
-->
