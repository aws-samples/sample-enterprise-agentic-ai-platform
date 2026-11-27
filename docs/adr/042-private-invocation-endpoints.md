# ADR-042: Force Private Invocation of AgentCore Runtimes (and Lambdas) — Endpoint Policies + `aws:sourceVpce` Deny

**Status:** Proposed
**Date:** 2026-09-25

## Context

ADR-031 placed the AgentCore **agent runtimes** in the VPC and added the
AgentCore PrivateLink interface endpoints; ADR-032 placed the platform
**Lambdas** in the VPC and completed the endpoint set. Both improved the
network posture — but both **explicitly deferred** locking down *who can invoke*
and *whether the public path is closed*:

- ADR-031: "Least-privilege endpoint policies are a hardening follow-up
  (defaults grant full access…)."
- ADR-032: "Endpoint policies remain default (full access) — least-privilege
  scoping is a hardening follow-up," and it framed the win as *network placement*
  ("stays on the private path"), not *forced* privacy.

The precise current state (verified 2026-09-25):

1. **VPC mode ≠ private invocation.** `network_configuration = VPC` on the
   AgentCore runtime governs the agent's **ENIs and egress** (reach private
   resources without internet). It does **not** change the invocation surface.
   The `InvokeAgentRuntime` **data-plane API remains a public AWS endpoint**: any
   principal with `bedrock-agentcore:InvokeAgentRuntime` (SigV4) — or a valid
   OAuth token if a JWT authorizer is set — can call it from anywhere. Privacy
   today is *only* an artifact of the caller being in-VPC with
   `private_dns_enabled = true` resolving the regional hostname to the endpoint
   ENI. Nothing **forces** that path.

2. **The interface endpoints are default-allow.** `aws_vpc_endpoint.agent`
   (`agent-network.tf`) sets no `policy` argument, so the `bedrock-agentcore`
   data-plane endpoint (and all 11 others) carry the default full-access endpoint
   policy — not scoped to our runtimes or our principals.

3. **The runtime has no resource-based / principal policy.** The runtime module
   (`modules/runtime/main.tf`) exposes only an optional inbound **JWT authorizer**
   (`authorizer_configuration`). There is no policy attached to the runtime
   restricting which SigV4 principals may invoke it. Access control is entirely
   **caller-side** IAM, and those grants are broad: the ADE and examples task
   roles grant `InvokeAgentRuntime` on `runtime/*` (all runtimes), and the
   `invoke_bridge` Lambda role grants it on `*`.

4. **Lambda invocation is not publicly exposed today** (but has no forced-private
   guard either). The two live Lambdas — `commit_validation` (invoked by
   CodeCommit) and `invoke_bridge` (invoked by Step Functions) — are
   **AWS-service-invoked**, not user-invocable. There are **no Lambda Function
   URLs** anywhere, and the old public `triggers/` HTTP API was deleted (ADR-032
   update). There is **no `com.amazonaws.<region>.lambda` interface endpoint** —
   correctly, since nothing invokes a Lambda across the network from in-VPC. So
   the Lambda gap is not an open public door; it is the absence of a
   `aws:sourceVpce`/`aws:SourceArn` guard and a standing "no Function URL" rule.

The same principle holds for both services: **"in VPC" = private egress;
"private invocation" is a separate, deliberate control** that must be added.

## Decision

**We will force private invocation of the AgentCore runtimes as a deliberate,
gated hardening layer — not rely on network placement — using three controls,
and apply the analogous guard to Lambdas.** All new controls are gated on the
existing `agent_vpc_enabled` posture and are additive (PUBLIC/demo behavior
unchanged unless the deployer opts in).

1. **Scope the interface-endpoint policies (defense-in-depth).** Attach a
   `policy` to the `bedrock-agentcore` data-plane endpoint allowing only
   `bedrock-agentcore:InvokeAgentRuntime` on **our** runtime ARNs, by **our**
   task-role/Lambda-role principals. Where a runtime uses OAuth (JWT authorizer)
   rather than SigV4, `Principal` must be `*` (per AWS PrivateLink guidance) and
   the scoping falls to the resource/action. Apply least-privilege policies to
   the other endpoints (ECR/logs/codepipeline/…) in the same pass.

2. **Close the public path with an `aws:sourceVpce` deny (the actual lock).**
   Because the AgentCore runtime does not accept an `aws:sourceVpce`-conditioned
   resource policy the way S3 does, enforce this on the **calling principals**:
   add an explicit `Deny` on `bedrock-agentcore:InvokeAgentRuntime` unless
   `aws:sourceVpce` equals our data-plane endpoint id (or `aws:SourceVpc` equals
   our VPC), on the ADE, examples, and `invoke_bridge` roles — and, for
   account-wide enforcement, as an **SCP**. Include a documented **break-glass**
   exception so operators are never fully locked out. Narrow the caller-side
   `InvokeAgentRuntime` grants from `runtime/*` / `*` to the specific runtime
   ARNs each caller legitimately needs.

3. **Tighten inbound auth on the runtime where applicable.** For runtimes that
   should be OAuth-gated, set the JWT `authorizer_configuration` (audience/
   clients/scopes) so inbound callers present a verifiable token; keep SigV4-only
   for service-to-service runtimes (the two are mutually exclusive per runtime).

4. **Lambda parity.** Add `aws:SourceArn`/`aws:sourceVpce` conditions to the
   Lambda resource policies (`commit_validation`'s CodeCommit permission is
   already `source_arn`-scoped; extend the pattern), and add a standing guard
   that **no Lambda ever gets a Function URL** (lint/policy check), since a
   `FunctionUrl` with `AuthType: NONE` is a public door VPC attachment cannot
   close. Only add the `com.amazonaws.<region>.lambda` interface endpoint if a
   future in-VPC client needs to invoke a Lambda over the network (not the case
   today).

## Consequences

- **Truly non-public invocation (item 2 is the crux).** With the `aws:sourceVpce`
  deny in place, `InvokeAgentRuntime` succeeds only from inside our VPC via the
  PrivateLink endpoint; a leaked credential used from the public internet is
  denied. Items 1, 3, 4 are defense-in-depth around it.
- **Least-privilege blast radius.** Scoping caller grants and endpoint policies
  to specific runtime ARNs means a compromised task role can invoke only its own
  runtimes, not every runtime in the account.
- **Real operational risk — lockout.** A hard `sourceVpce` deny can lock out
  legitimate management/console/CI access if scoped too broadly. It MUST be
  limited to the data-plane `InvokeAgentRuntime` action, carry a break-glass
  exception, and be rolled out in an audit-first (deny-logging) manner. This is
  why it is a deliberate ADR, not a silent default.
- **Demo/PUBLIC unchanged.** All controls are gated on `agent_vpc_enabled`; the
  public demo keeps public-endpoint-with-IAM (acceptable: IAM already gates it).
- **Not free to operate.** Endpoint policies and SCPs add review/change-control
  surface; per-runtime ARN scoping adds wiring the platform must generate as
  runtimes come and go.
- **Ordering constraint.** The `aws:sourceVpce` deny references the data-plane
  endpoint id, so it must be applied after the endpoint exists (already created
  by ADR-031/032).

## Alternatives Considered

- **Rely on network placement alone (status quo).** Rejected: the public API
  stays open; a stolen SigV4 credential works from anywhere. Placement is
  necessary but not sufficient.
- **Endpoint policy only, no `sourceVpce` deny.** Rejected as the *complete*
  answer: an endpoint policy constrains traffic *through the endpoint* but does
  not disable the parallel public path. Good as defense-in-depth (item 1), not as
  the lock.
- **Runtime resource-based policy with `aws:sourceVpce`.** Not currently
  available on `aws_bedrockagentcore_agent_runtime` the way S3 bucket policies
  support it; hence enforcement on the calling principals + SCP.
- **OAuth/JWT authorizer as the sole control.** Rejected as sole control:
  authenticates the caller but still over a public endpoint, and is mutually
  exclusive with SigV4 per runtime; used as a complementary layer (item 3).
- **Add the Lambda interface endpoint now.** Rejected as premature: nothing
  invokes a Lambda across the network from in-VPC today, and there are no
  Function URLs — adding it would be standing cost for no caller.

---
<!-- Supersedes nothing. Extends the deferred hardening noted in ADR-031 and ADR-032. -->
