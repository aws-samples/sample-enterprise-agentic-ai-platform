# ADR-031: Agent Workloads Run In-VPC by Default

**Status:** Accepted
**Date:** 2026-09-02

## Context

EAP targets enterprise deployment where the operating assumption is **no
public access** — agent workloads must run inside the enterprise network
boundary so their egress is governed, inspectable, and reachable only from the
corporate network/VPN.

Before this decision, only the third-party observability leg (the OTel collector
and optional Langfuse) ran inside the resolved VPC (ADR-030). The AgentCore
**agent runtimes themselves ran on AgentCore-managed PUBLIC endpoints**: the
`runtime` module defaulted to `network_mode = "PUBLIC"`, and none of the three
runtime call sites (the platform-owned Studio/ADE agent, and the standalone +
multi-agent runtimes deployed by the app-team pipeline) passed any network
configuration. This is exactly the posture the AWS Config managed rule
`BEDROCKAGENTCORE_RUNTIME_PRIVATE_NETWORK_REQUIRED` flags as non-compliant.

Relevant AWS constraints (per the AgentCore VPC and PrivateLink docs):

- VPC connectivity is supported for **Runtime, Code Interpreter, and Browser
  Tool** only. AgentCore attaches ENIs in the specified private subnets via the
  service-linked role `AWSServiceRoleForBedrockAgentCoreNetwork`, and these
  workloads only ever **initiate outbound** connections.
- **Gateway, Memory, and Identity are managed regional services** — they take no
  `network_configuration` and cannot be "placed" in a VPC. Their traffic is kept
  private instead via **AWS PrivateLink interface endpoints**
  (`com.amazonaws.<region>.bedrock-agentcore`,
  `…bedrock-agentcore-control`, `…bedrock-agentcore.gateway`).
- A VPC-mode agent with no public internet still needs a path to pull its image
  and log: ECR (`ecr.api`, `ecr.dkr`), an **S3 gateway endpoint** (ECR image
  layers; free), and CloudWatch `logs`.
- Subnets must sit in **AgentCore-supported Availability Zones** (by AZ ID) or
  resource creation fails. AZ-ID support cannot be reliably validated at plan
  time.

The platform already resolves a VPC via **import-or-create** (ADR-030): a
deployer-supplied `vpc_id` + subnets, or a platform-created VPC with full egress
(IGW + NAT + private route tables).

## Decision

**We will run all AgentCore agent workloads inside the resolved VPC by default,
gated by a new `agent_network_mode` flag (default `"VPC"`), with an explicit
PUBLIC fallback.**

1. **`agent_network_mode` variable** — `"VPC"` (default) or `"PUBLIC"`. VPC mode
   takes effect only when a VPC is actually resolvable:
   `agent_vpc_enabled = agent_network_mode == "VPC" && vpc_id != ""`. When VPC is
   requested but no VPC resolves, or when `"PUBLIC"` is set explicitly, agents
   fall back to AgentCore-managed PUBLIC endpoints (the pre-ADR-031 behavior).

2. **All three runtime call sites join the VPC** — the platform-owned Studio/ADE
   runtime (via the `studio` module) and both pipeline-deployed runtimes
   (standalone `runtime` and multi-agent `app_runtime` in the deploy-template)
   receive `network_mode` + `vpc_config` (private subnets + the agent security
   group). For pipeline-deployed agents the posture is threaded from the
   platform root through the pipeline module into the deploy CodeBuild stage as
   `TF_VAR_agent_network_mode` / `TF_VAR_agent_subnet_ids` /
   `TF_VAR_agent_security_group_ids` (lists JSON-encoded), since the
   deploy-template runs its own `terraform apply` with its own state.

3. **Dedicated agent security group** — the platform creates an **egress-only**
   security group (HTTPS to AWS APIs + all-traffic within the VPC CIDR; **no
   inbound**, because runtimes only initiate outbound) in the resolved VPC. A
   deployer may override it with `agent_security_group_ids`.

4. **PrivateLink + supporting VPC endpoints (gated on VPC mode)** — interface
   endpoints for AgentCore data plane, control plane, and gateway, plus
   `ecr.api`, `ecr.dkr`, and `logs`; and an **S3 gateway endpoint** for ECR
   layers. The S3 gateway endpoint is created only for a **platform-created**
   VPC (whose private route tables the platform knows); for an **imported** VPC
   the deployer owns their own S3 endpoint/routing. PUBLIC deployments create
   none of these and incur no endpoint cost.

5. **The PUBLIC fallback is surfaced, never silent** — an `agent_network_posture`
   output plus a `check` block that fires when VPC was requested but could not be
   honored (no VPC resolved), telling the operator to supply a VPC or set
   `agent_network_mode = "PUBLIC"` explicitly.

Browser and Code Interpreter modules are VPC-capable but are **not instantiated
anywhere** in the platform today; no call sites exist to wire. When they are
introduced, they follow the same `agent_network_mode` posture.

## Consequences

- **Enterprise-default posture.** Agents run in the enterprise VPC out of the
  box, aligning with `BEDROCKAGENTCORE_RUNTIME_PRIVATE_NETWORK_REQUIRED`. Egress
  stays within the network boundary; managed-service traffic (Gateway/Memory/
  Identity) stays private via PrivateLink.
- **Escape hatch preserved.** `agent_network_mode = "PUBLIC"` (or simply having
  no resolvable VPC) reverts to the prior public behavior, so green-field/demo
  deploys still work without a VPC.
- **Standing cost in VPC mode.** Interface endpoints bill hourly per-AZ per-
  service (six here) plus data processing; the S3 gateway endpoint is free. This
  is only incurred in VPC mode. Least-privilege endpoint policies are a
  hardening follow-up (defaults grant full access; OAuth callers require
  `Principal: *`).
- **AZ-ID caveat.** For an imported VPC, the deployer must supply private subnets
  in AgentCore-supported AZs, and the platform-created VPC's static AZ defaults
  must likewise land on supported AZs. This cannot be validated at plan time and
  is documented as a deploy prerequisite (DEPLOY-RUNBOOK).
- **Imported-VPC endpoint gap.** The platform does not create the S3 gateway
  endpoint for imported VPCs; the deployer is responsible for ECR/S3/logs
  reachability in their governed network. Documented in the runbook.
- **No change to the AWS-native observability leg** (CloudWatch/X-Ray) or to
  ADR-030's third-party leg; this decision is orthogonal and additive.

## Alternatives Considered

- **Force VPC unconditionally (no flag).** Rejected: a deploy with no resolvable
  VPC would wedge, and green-field/demo use would be impossible. The flag with a
  visible fallback keeps the enterprise default while remaining operable.
- **Opt-in VPC (default PUBLIC).** Rejected: contradicts the enterprise
  no-public-access stance; the secure posture should be the default, not a
  setting a deployer must remember to turn on.
- **Place Gateway/Memory/Identity "in the VPC" directly.** Not possible — these
  are managed regional services with no network configuration. PrivateLink
  interface endpoints are the sanctioned mechanism and are used instead.
- **Always create the S3 gateway endpoint (including imported VPCs).** Rejected:
  associating it requires the VPC's private route table IDs, which the platform
  does not own for an imported VPC. Guessing them risks clobbering deployer
  routing; the deployer owns their own endpoints instead.
