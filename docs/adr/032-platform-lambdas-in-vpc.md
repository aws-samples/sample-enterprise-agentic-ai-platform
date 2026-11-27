# ADR-032: Platform Lambdas Run In-VPC; Complete the VPC Endpoint Set

**Status:** Accepted
**Date:** 2026-09-02

## Context

ADR-031 put the AgentCore **agent runtimes** inside the enterprise VPC by
default. It did not touch the platform's **Lambda tier** or size the VPC endpoint
set for a fully sealed (no-public-egress) install. Two gaps remained for a
no-public-access posture:

1. **Lambdas ran outside the VPC.** Every platform Lambda lacked a `vpc_config`:
   `invoke_proxy` and `invoke_bridge` (which call AgentCore
   `InvokeAgentRuntime`), `studio_read` (CodePipeline/CodeCommit/DynamoDB/
   AgentCore reads), `commit_validation` (CodeCommit), and the orphaned
   `qa_trigger`/`prod_trigger`. Critically, a Lambda **outside** the VPC does not
   use the AgentCore PrivateLink endpoint ADR-031 created — it reaches the
   **public** AgentCore API. So the *invocation path* leaked even though the
   runtimes were private.

2. **The VPC endpoint set was sized for the agent runtimes only.** ADR-031
   created interface endpoints for AgentCore data/control/gateway + ECR
   (api/dkr) + Logs, and an S3 gateway endpoint. It did **not** include the
   services the Lambdas call (CodePipeline, CodeCommit, CloudWatch metrics, SSM,
   DynamoDB) nor `execute-api` (a prerequisite for a future PRIVATE REST API
   front door). In a no-egress VPC, in-VPC Lambdas would fail to reach those.

Relevant constraints:

- A Lambda's `vpc_config` block uses `subnet_ids` / `security_group_ids` (distinct
  attribute names from the AgentCore runtime's `subnets` / `security_groups`).
- A Lambda in a VPC requires ENI-management permissions
  (`ec2:CreateNetworkInterface` / `DescribeNetworkInterfaces` /
  `DeleteNetworkInterface`, and Assign/Unassign private IPs).
- CodeCommit exposes **two** distinct endpoint services: `codecommit` (API — the
  SDK `GetFolder`/`GetFile` the Lambdas call) and `git-codecommit` (Git
  operations — `git pull` used by pipeline/image builds). They are not
  interchangeable.
- Gateway endpoints (S3, DynamoDB) associate to **route tables**, which the
  platform only knows for a VPC it created; for an imported VPC that list is
  empty.

## Decision

**We will run the platform's Lambdas inside the resolved VPC whenever the
platform is in VPC mode, and complete the VPC endpoint set so a no-public-egress
install works — reusing the ADR-031 `agent_vpc_enabled` gate.**

1. **Reuse the ADR-031 posture gate.** All Lambda VPC placement and the new
   endpoints are gated on `local.agent_vpc_enabled`. A `local.lambda_vpc_config`
   (`{subnet_ids, security_group_ids}`) is `null` in PUBLIC mode, so PUBLIC
   deployments are byte-for-byte unchanged.

2. **Dedicated Lambda security group.** A separate egress-only SG
   (`eap-lambdas-*`: 443 + intra-VPC egress, no inbound) is created in VPC
   mode — kept distinct from the agent SG so the tiers evolve independently.

3. **Place the live root-apply Lambdas in-VPC**, wired from root locals:
   `invoke_proxy`, `studio_read`, `commit_validation`. Each gets a dynamic
   `vpc_config` block and the ENI-management IAM permissions (managed
   `AWSLambdaVPCAccessExecutionRole` where a basic-exec policy already exists,
   else an inline `ec2:*NetworkInterface*` statement — added only in VPC mode).

4. **Place `invoke_bridge` in-VPC via the ADR-031 pipeline TF_VAR seam.** It is
   created inside the vended pipeline's Deploy CodeBuild (not the root apply), so
   it reuses the subnet/SG values already threaded to the deploy-template; a
   deploy-template `local.lambda_vpc_config` drives its `vpc_config` and the ENI
   permission statement.

5. **Make the trigger module VPC-capable but do not force-wire it.**
   `qa_trigger`/`prod_trigger` gain a `vpc_config` variable + dynamic blocks + ENI
   permissions, but the module has **no root call site** (it is not deployed by
   the platform apply today), so nothing is instantiated — the capability is
   ready for when the module is wired in.

   > **Update (2026-09-02):** the `triggers/` module was subsequently **deleted**
   > during the console-off enterprise-hardening pass. It was never wired to a
   > root call site and carried a latent **public** HTTP API (`aws_apigatewayv2_api.triggers`),
   > so it was removed to eliminate a dead public-ingress footprint. If the QA/Prod
   > trigger interfaces are built later, they should be reintroduced as a
   > private API (`execute-api` VPC endpoint already provisioned by item 6).

6. **Complete the VPC endpoint set** (VPC mode, in `agent-network.tf`):
   - **New interface endpoints:** `codepipeline`, `codecommit` (API),
     `git-codecommit` (Git), `monitoring` (CloudWatch PutMetricData), `ssm` (base
     image reads the collector-endpoint param at boot), `execute-api`
     (prerequisite for a future PRIVATE REST API).
   - **New gateway endpoint:** `dynamodb` (Lambda lifecycle-table reads), joining
     the existing S3 gateway endpoint. Both gateway endpoints are created **only
     for a platform-created VPC** (known route tables); for an imported VPC the
     deployer owns their own.

## Consequences

- **Private end-to-end invocation.** With the invoking Lambdas in-VPC and the
  AgentCore/DynamoDB/etc. endpoints present, agent invocation now stays on the
  private path from front door to runtime — closing the leak ADR-031 left.
- **No-egress installs are viable** for the platform Lambdas: they reach every
  service they call via VPC endpoints, no NAT/internet required.
- **PUBLIC mode unchanged.** Everything is gated on `agent_vpc_enabled`; a PUBLIC
  (or no-VPC) deploy provisions no Lambda VPC config, no Lambda SG, and no
  endpoints — and incurs no endpoint cost.
- **Standing cost in VPC mode grows.** The interface-endpoint count rises from 6
  to 12 (hourly per-AZ per-service + data processing). The two gateway endpoints
  (S3, DynamoDB) are free. Only incurred in VPC mode. Endpoint policies remain
  default (full access) — least-privilege scoping is a hardening follow-up.
- **Imported-VPC gap (unchanged principle).** For an imported VPC the platform
  still does not create the S3/DynamoDB **gateway** endpoints (it does not own
  the route tables); the deployer must provide S3 + DynamoDB reachability. The
  interface endpoints (which attach to subnets, not route tables) *are* created
  for both created and imported VPCs.
- **ENI cold-start note.** Lambdas in a VPC attach ENIs; AWS's Hyperplane ENI
  model makes this largely a one-time concern, but it is a known trade-off vs.
  non-VPC Lambdas.
- **Cold ENI cleanup lag.** As with agent ENIs, VPC Lambda ENIs may persist
  briefly after teardown — expected AWS behavior.

## Alternatives Considered

- **Leave Lambdas out of the VPC and rely on IAM only.** Rejected: a
  no-public-access install must not have its agent-invocation path egress to the
  public AgentCore API. IAM authz does not make the network path private.
- **One shared SG for agents and Lambdas.** Rejected (mild): reusing the agent SG
  couples two tiers with different lifecycles and muddies its purpose. A
  dedicated Lambda SG is clearer for one extra cheap resource.
- **Force the trigger Lambdas into the VPC now.** Rejected: they have no root
  call site (not deployed today). Wiring a dead module in would be scope creep;
  making the module capable is enough.
- **Only the `codecommit` (API) endpoint, not `git-codecommit`.** Rejected: a
  sealed install also needs Git operations for pipeline/image builds. Including
  both is cheap correctness.
- **Create S3/DynamoDB gateway endpoints for imported VPCs too.** Rejected:
  associating them needs the deployer's private route table IDs, which the
  platform does not own; guessing risks clobbering their routing.
