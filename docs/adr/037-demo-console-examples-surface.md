# ADR-037: Demo Console Examples Surface — Hardened CloudFront → ALB → Fargate

**Status:** Accepted
**Date:** 2026-09-14

## Context

The demo console (`platform/console/`, a Vite/React SPA delivered as static
assets from S3 behind CloudFront per ADR-034) presents deployed agents as a
directory of chat cards. It only does **basic request/response chat** against a
single agent.

Separately, the repo ships six rich, per-pattern demo experiences under
`platform/demo-ui/` — a swarm handoff graph, a Reciprocal-Rank-Fusion search
panel, a Step Functions pipeline timeline, and an architect chat. Each is an
**independent Vite app with its own Express `server.ts`** that SigV4-signs
AgentCore `InvokeAgentRuntime` calls or drives Step Functions
`StartExecution`/`DescribeExecution`/`GetExecutionHistory`, plus CloudWatch log
reads. They run locally only (`run.sh`, ports 5173–5179) and **hardcode target
ARNs** for a specific dev account. There is no deploy path for any of them.

The goal is an **executive-facing marketing surface inside the console** that
shows this richness — preset prompts, live pattern visualizations — for the
agents that are actually deployed, without standing up six separate frontends
or six backends.

Two hard facts shape the design (see the deployment model in
ADR-020, ADR-026, ADR-029):

1. **Example endpoints are not created by the platform apply.** A `demo`
   deployment (`configs/demo.tfvars`) provisions the base platform plus an
   *empty* `team-bu-1` CodeCommit repo and an *idle* `team-bu-1-deploy-pipeline`.
   The AgentCore runtimes and Step Functions state machines only come into
   existence after the `team-bu-1` source tree is pushed (the seed step), which
   triggers the pipeline whose Deploy stage records each deployed agent
   (`runtime_arn`, `pattern`, `app_topology`, `is_entrypoint`) into the shared
   lifecycle DynamoDB table. So the console cannot hardcode endpoints; it must
   **discover** them at runtime, and must degrade gracefully before seeding.

2. **A browser cannot SigV4-sign.** A purely static site has no server to sign
   AgentCore requests or call Step Functions. The six `server.ts` backends exist
   for exactly this reason. They all perform the same small set of operations.

Constraints from the platform owner: **no Lambda** (avoid function sprawl), a
**security-hardened** public surface, and the console must remain
**independently evolvable** from the backend.

## Decision

We will add an **Examples surface** to the demo console, backed by a single
**ECS Fargate** service, delivered through a hardened CloudFront distribution.

### 1. Delivery topology (C2)

One hardened CloudFront distribution with **two origins**:

- **S3 origin** — the static console SPA assets (unchanged from ADR-034; the
  existing `console_deploy` build-and-sync path is reused).
- **ALB → ECS Fargate origin** — path pattern `/api/*`, no-cache behavior,
  forwarded to a single Fargate service.

We will **not** use Lambda and will **not** expose the ALB publicly.

### 2. Origin hardening

- **WAF WebACL** on the CloudFront distribution (AWS managed rule sets: common,
  known-bad-inputs, rate-based).
- The ALB security group ingress is restricted to the **CloudFront-managed
  prefix list** (`com.amazonaws.global.cloudfront.origin-facing`).
- CloudFront injects a **secret origin header** that an ALB listener rule
  requires; requests lacking it get `403`. Prefix list + secret header together
  prevent reaching the ALB except through this distribution.
- TLS 1.2+ via a CloudFront security policy; ACM certificate at the edge.

### 3. Generic backend — one Fargate container, five routes

The six `server.ts` backends collapse into **one example-agnostic** service.
It holds the task-role credentials and exposes exactly:

- `POST /api/invoke` — SigV4 `InvokeAgentRuntime` (service `bedrock-agentcore`,
  path `/runtimes/{encodedRuntimeArn}/invocations`, optional `?qualifier=`).
  Body carries the A2A JSON-RPC 2.0 envelope
  `{jsonrpc:"2.0", method:"message/send", id, params:{message:{role:"user",
  parts:[{kind:"text", text}], messageId}}}`. Returns
  `{response, a2aRequest, rawResponse, duration, sessionId}` (the swarm A2A
  inspector needs `a2aRequest`/`rawResponse`). `sessionId`, when supplied, is
  sent as the `x-amzn-bedrock-agentcore-runtime-session-id` header.
- `POST /api/sfn/start` — `StartExecution`, input `{"query": text}`.
- `GET /api/sfn/status` — `DescribeExecution` → `{status, startDate, stopDate,
  output}`.
- `GET /api/sfn/history` — `GetExecutionHistory` (`includeExecutionData`) →
  `{events[], a2aPayloads[]}` reconstructed from `TaskScheduled`/`TaskSucceeded`.
  Required for the SFN step timeline and A2A inspector.
- `GET /api/logs` — CloudWatch (`DescribeLogGroups`/`DescribeLogStreams`/
  `GetLogEvents`) → `[{agent, timestamp, message, level, traceId?, spanId?}]`.

The backend knows nothing about any specific example: the frontend passes the
resolved `runtimeArn`/`stateMachineArn`/log prefix, the backend signs and
forwards. Adding or restyling examples requires **no backend change**.

### 4. Dynamic, pattern-driven Examples gallery (Behavior A)

- The gallery is **always visible** the moment the console is deployed
  (marketing content), independent of seeding.
- It **discovers** cards from the lifecycle table (the same DynamoDB read the
  existing `/apps` view uses via the Cognito Identity Pool), one card per
  deployed app. Renderer selection keys off the record's **`pattern`** field
  (`standalone`, `swarm`, `supervisor`, `sequential-workflow`) — not a hardcoded
  list. Any future `team-bu-1` app (e.g. a re-added `code-review`) appears
  automatically with its pattern's renderer.
- Rich renderers, one per pattern, ported from the demo-ui apps and rendering
  from the record's `app_topology` graph: swarm → handoff graph; standalone →
  rich chat; supervisor → RRF fusion + dispatch/parallel/aggregate viz;
  sequential-workflow → linear stage timeline + summary.
- A thin **presentation overlay** keyed by `app_name` supplies marketing polish
  that cannot be inferred (display title, description, curated preset prompts
  lifted from the demo-ui apps, optional bespoke renderer). Apps absent from the
  overlay still render, using a generated title, the pattern default renderer,
  and generic prompts — new apps degrade gracefully.
- **3-state, auto-flipping cards:** `Not deployed → Deploying → Ready`.
  Readiness comes from a lifecycle-table poll (TanStack Query `refetchInterval`,
  paused when unfocused); the `Deploying` state is driven by real CodePipeline
  execution status (`@aws-sdk/client-codepipeline`, already a console dep). No
  manual refresh; identical behavior local and remote.
- Invocation targets the **entrypoint** runtime (`is_entrypoint`) for
  AgentCore-direct patterns (standalone always; swarm → the orchestrator/peer
  entrypoint), matching "invoke the primary agent, not subagents."

### 5. Lifecycle-table schema addition — `state_machine_arn`

The deploy-template records `runtime_arn` but **not** the Step Functions
`state_machine_arn`, so SFN examples (supervisor, sequential-workflow) cannot be
resolved today. We will thread `module.orchestration[app].state_machine_arn`
into the `deployed_agent_records` for step-functions apps and extend the Deploy
stage's DynamoDB upsert to persist it. Non-SFN records omit it.

### 6. Scope boundary

The Examples surface, the Fargate backend, the ALB, and the WAF are wired into
the **`demo` preset only**. The `enterprise` preset (ADR-036) keeps
`deploy_console=false` and its bring-your-own-UI posture — none of this is
created there.

### 7. Local development

`vite.config.ts` gains a **dev-only** `server.proxy` forwarding `/api/*` to the
backend running locally; the backend is runnable standalone. The console is
reviewable with `npm run dev` (UI only; cards show `Not deployed` with no
deployment), and full request paths are exercised with the local backend and a
seeded deployment. `npm run build && npm run preview` gives a production-parity
check. CloudFront is never required to develop or review.

## Consequences

- **Kills the six-server sprawl.** One container, five routes, replaces six
  `server.ts` backends. No Lambda.
- **No hardcoded ARNs.** The gallery reflects what is actually deployed and
  survives redeploys in any account, because it resolves from the lifecycle
  table.
- **Honest deployment story.** The surface visibly tracks state: apply → seed
  `team-bu-1` → pipeline runs → cards flip to Ready. The seed step is a
  prerequisite for functional examples and is documented as such.
- **Independent evolution.** Console assets (S3) and backend (Fargate container)
  deploy on separate cadences; the two CloudFront origins keep them decoupled.
  Adding examples is frontend-only.
- **Hardened public front door.** WAF + CloudFront prefix list + secret header +
  TLS + Shield Standard. The ALB is never publicly reachable.
- **Always-on cost.** The Fargate service runs at least one task even when idle
  (no scale-to-zero). Accepted as the cost of avoiding Lambda for a demo
  surface; scoped to the `demo` preset only.
- **Follow-on:** the `state_machine_arn` addition changes the lifecycle record
  shape; the recorder stays non-fatal so a recording hiccup never fails a
  deploy. Standalone AWS-Architect's live MCP Gateway tool-discovery panel is
  **dropped** in the console renderer (it needs a Cognito-JWT MCP passthrough
  that does not fit the generic backend); the core architect chat is preserved.

## Alternatives Considered

- **A — Evolve the static console + extend the existing invoke-proxy Lambda for
  SFN/log routes.** Rejected: keeps and grows Lambda (explicitly unwanted), and
  a static-only site still cannot sign without a server.
- **B — ALB → Fargate with the ALB as the public front door (no CloudFront).**
  Rejected once hardening became a requirement: a public ALB gives no WAF at the
  edge, no origin hiding, and no Shield posture.
- **C1 — One Fargate container serving both assets and `/api/*`.** Viable, but
  couples asset and backend deploys into one image; C2's two origins keep them
  independently deployable and reuse the existing S3 console deploy path.
- **Lift-and-shift the six demo-ui apps as-is.** Rejected: six frontends, six
  backends, hardcoded ARNs — the opposite of the sprawl-reduction goal.
- **Static manifest of a fixed example list.** Rejected in favor of
  pattern-driven discovery + a thin overlay: less code, and future apps appear
  automatically instead of requiring a manifest edit.
- **Hardcoded ARNs (as the demo-ui apps do).** Rejected: breaks on every fresh
  deploy and every new account.

---
