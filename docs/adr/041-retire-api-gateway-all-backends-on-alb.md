# ADR-041: Retire API Gateway — All Console Backends on ALB/Fargate

**Status:** Accepted
**Date:** 2026-09-18

## Context

ADR-040 introduced an always-on ECS/Fargate backend (`ade-invoke-backend`) that
streams the Agent Deployment Engineer (ADE) chat over SSE, with in-service
Cognito/OIDC JWT validation and the Requirement-11 runtime allow-list. It
deliberately **deferred** retiring the older `invoke-proxy` Lambda + REST API
Gateway path (ADR-040, decision point 4): the buffered `/api/invoke` REST path
was kept for the per-agent deployed-agent chat (`AgentDetailView`) and any
non-ADE callers.

With the read routes already moved to the `studio-read-backend` ECS/ALB service
(HTTP API Gateway + shared JWT authorizer removed), the invoke-proxy REST API is
now the **only** remaining API Gateway in the platform, and the invoke-proxy
Lambda the only remaining Lambda on the console invoke path. The console today
has three backend transports:

- `/ade-api/*`      → ALB → Fargate (streaming, JWT + allow-list) — ADR-040
- `/examples-api/*` → ALB → Fargate (streaming, no caller auth)   — ADR-037
- `/api/invoke`     → **REST API Gateway → invoke-proxy Lambda** (buffered)

The historical reason for the REST path was API Gateway's raisable integration
timeout (above the 29s default) for long, tool-heavy turns. That rationale **no
longer holds**: the ALB/Fargate path streams with a 10s heartbeat and an
`idle_timeout` well above any single frame, so there is no 29s ceiling to work
around. The buffered REST path is therefore strictly worse than the streaming
ALB path for the same chat — and it is the last thing keeping API Gateway in the
platform.

Verification confirmed the ADE backend is a drop-in target for the deployed-agent
chat: its `resolveTarget` matches the Lambda's semantics (default runtime when no
ARN; 400 malformed; 403 not-in-allow-list; member → provided/discovered
qualifier); its `runtimeAllowList` reads the SAME lifecycle table + `runtime_arn`
field, so any `primary_runtime_arn` surfaced by `GET /api/my-deployed-agents` is
an allow-list member by construction; its task-role IAM already permits
`bedrock-agentcore:InvokeAgentRuntime` on `runtime/*` (not just the Studio
runtime) and `dynamodb:Scan` on the lifecycle table; and the frontend
`agentStream` client already sends a body carrying both `message`/`prompt` and
`agentArn`/`runtimeArn`, which the backend reads.

## Decision

We will **remove API Gateway from the platform entirely**. Every console backend
runs on ALB/Fargate.

Specifically:

1. **Route the deployed-agent chat through `/ade-api/invoke`.** The
   `AgentDetailView` per-agent chat (via `fromDeployedAgent`) now defaults its
   `invokeEndpoint` to `/ade-api/invoke` (authMode `cognito`), passing the
   agent's `primary_runtime_arn` as the invocation target. It gains
   token-by-token streaming and is validated + allow-listed in-service, exactly
   as the ADE design chat is.

2. **Delete the `invoke-proxy` module** — the REST API Gateway, its Cognito
   authorizer, the `/api/invoke` resource/method/integration/deployment/stage,
   the invoke-proxy Lambda, its IAM role/policies and Lambda permissions, the
   `rest_api_*` outputs, and the module source. Remove `module "invoke_proxy"`
   from the root and the `invoke_proxy_role_arn` variable.

3. **Remove the CloudFront `invoke-rest-api` origin and the `/api/invoke`
   behavior** from the console distribution, along with the
   `invoke_rest_api_domain` / `invoke_rest_api_stage` inputs. `/api/*` continues
   to route to the studio-read ALB (read routes); there is no longer any
   `/api/invoke` behavior.

This supersedes decision point 4 of ADR-040 ("retain the invoke-proxy Lambda +
REST API for now"). The rest of ADR-040 (the streaming ADE backend itself)
stands.

## Consequences

**Positive**
- **No API Gateway anywhere** in the platform — one fewer service, one fewer
  auth surface, and a uniform "CloudFront → ALB → Fargate, JWT-in-service"
  shape for every console backend.
- The deployed-agent chat now **streams** token-by-token (it was buffered), and
  is no longer bounded by the 29s integration timeout.
- Removes the last Lambda + its IAM role on the console invoke path, and the
  duplicated auth/allow-list logic shrinks to the two Fargate backends.

**Negative / cost**
- **No new standing cost.** The ADE backend is already always-on (ADR-040); the
  deployed-agent chat simply reuses it. No additional Fargate task or ALB is
  introduced. Removing the Lambda + REST API slightly *reduces* footprint.
- The deployed-agent chat now depends on the always-on ADE backend being
  healthy; there is no separate buffered fallback. This is the same dependency
  the ADE design chat already has.

**Neutral / follow-on**
- The `docs/iam/roles/invoke-proxy/` role reference documentation is now stale
  (the role no longer exists) and should be pruned from the IAM docs index.
- The ADE backend's default target (its own Studio runtime, used when no
  `runtimeArn` is supplied) is unchanged; only the deployed-agent path, which
  always supplies a `runtimeArn`, is added.
- JWT validation is still structural/exp/iss only (no RS256 signature
  verification) in the Fargate backends — a pre-existing shared hardening
  follow-up, unchanged by this ADR.

## Alternatives Considered

- **Keep `/api/invoke` on API Gateway for the per-agent chat.** The status quo
  after ADR-040. Rejected: its only justification (raisable timeout) is moot on
  the streaming ALB path, it keeps the per-agent chat buffered, and it retains
  API Gateway + a Lambda solely for a path the ADE backend already serves
  better.

- **Stand up a separate ECS/Fargate backend for the deployed-agent chat**
  (distinct from ADE). Rejected as needless: the ADE backend already enforces the
  same auth + Requirement-11 allow-list, already has `runtime/*` invoke IAM, and
  already accepts a caller-supplied `runtimeArn`. A second service would add
  standing cost and duplicate logic for no benefit.

- **Lambda response streaming (Function URL, `RESPONSE_STREAM`).** Would let the
  Lambda stream and keep scale-to-zero, but Function URLs support only
  `AuthType=NONE`/`AWS_IAM` (no managed JWT gate), and it duplicates a streaming
  backend we already run. Rejected — it reintroduces hand-rolled auth to keep a
  transport the ALB path makes redundant.

---
<!--
Authoring rules (see docs/adr/README.md):
- Copy this file to docs/adr/NNN-slug.md using the next free number from README.md.
- Never reuse or renumber an existing ADR. Superseding decisions get a NEW number
  and flip the old one's Status to "Superseded by ADR-NNN".
- Update the index table + "Next available number" in docs/adr/README.md.
-->
