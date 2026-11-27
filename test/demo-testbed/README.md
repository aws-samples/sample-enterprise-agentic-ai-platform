# Demo Test Bed

A committed, repeatable harness that stands up the EAP platform in **DEMO
mode** and exercises it end to end — public console, in-VPC agents, self-hosted
observability — proving the "show it works" posture.

> This is **test scaffolding**, not platform code. It only feeds the platform's
> existing inputs (the committed `configs/demo.tfvars` preset). Nothing here
> ships to a customer.

> **⚠️ Cannot coexist with the ENTERPRISE bed in the same account.** There is exactly
> **one** platform Terraform state per account (backend key
> `platform/terraform.tfstate`) and the platform's ECR / CodeCommit / pipeline /
> runtime names are account-global. This DEMO bed and `test/enterprise-testbed/` are two
> *postures* of that single deployment, not two independent stacks — deploying
> one on top of the other **converts** it and collides on shared names. Run them
> **sequentially** (deploy demo → `./99-teardown.sh` → deploy enterprise), or use a
> **separate AWS account** per mode. Script 02 refuses to deploy if it detects a
> enterprise deployment already present.

## Demo vs Enterprise (why this bed is smaller)

| Aspect | Demo | Enterprise |
|---|---|---|
| Public console | **deployed** (`deploy_console = true`) | not deployed |
| Agent network | in-VPC (private subnets) — VPC default, same as enterprise | in-VPC (private subnets) |
| VPC | platform-created, hosts **agents + the observability leg** | **imported** enterprise VPC |
| IAM roles | all **platform-created** | 5 standalone roles **externalized (hardened)** |
| Identity | Cognito reference IdP | Cognito reference IdP |
| Observability | self-hosted Langfuse (internal ALB) + AWS-native | same |
| Transaction Search | on | off |

Because the platform creates its own VPC and all IAM roles in demo, this bed has
**no `enterprise-vpc` fixture, no `iam-roles` fixture, and no jumphost setup** —
it just applies the committed `configs/demo.tfvars`.

In demo, the console also ships the **Examples** surface (ADR-037) and embeds
**Langfuse** as "GenAI Observability" (ADR-038): a single hardened CloudFront
distribution fronts the S3 SPA, an ALB→Fargate signer backend (`/examples-api/*`),
and the Langfuse ALB (`/langfuse/*`), each locked to CloudFront (prefix list +
secret header) with a WAF attached. So — unlike the earlier private model —
Langfuse's UI is reachable publicly through the edge (no VPN); it stays private
in every non-demo posture.

## Prerequisites

- AWS creds for the target account (`aws sts get-caller-identity` works), region `us-east-1`.
- terraform ≥ 1.5, aws cli v2, jq.
- **Node + npm** — demo deploys the public console, whose SPA is built
  (`npm run build`) and s3-synced at apply time by the console module.
- **Docker (daemon running)** — the demo apply builds + pushes the examples
  backend image (`platform/examples-backend`, ADR-037) to ECR at apply time.
  This is separate from `studio_build_image` (which stays false).
- `git-remote-codecommit` for the CI/CD seed (script 04): `pip install git-remote-codecommit`.
- The base + ADE images present in ECR (script 02 deploys Docker-free with
  `studio_build_image=false`). On a **clean account** these don't exist yet —
  **`scripts/00-seed-images.sh`** seeds them (idempotent), and `run-all.sh` runs
  it automatically before 02. See `platform/DEPLOY-RUNBOOK.md` Step 1.

## Run it

**Automated (recommended):**
```bash
cd test/demo-testbed
./run-all.sh            # one confirmation, then runs 01..06 unattended
# ./run-all.sh --yes    # no prompt
```

**Step by step:**
```bash
cd test/demo-testbed
scripts/01-check-prereqs.sh
scripts/00-seed-images.sh         # clean-account bootstrap: seed base+ADE images (idempotent)
scripts/02-deploy-platform.sh     # applies configs/demo.tfvars (prints the console URL)
scripts/03-validate.sh            # asserts console present, agents in-VPC, Langfuse on
scripts/04-seed-repos.sh          # seed users/team-bu-1 -> CodeCommit -> triggers deploy pipeline
scripts/05-monitor-pipeline.sh    # watch team-bu-1-deploy-pipeline to a terminal state
scripts/06-invoke-agent.sh        # headless smoke test of the deployed agents (all patterns)
scripts/07-validate-console.sh    # console edge + ALB origin-lockdown smoke test (ADR-037/038)
```

## What the smoke test covers (script 06)

One entrypoint per architecture pattern (ADR-020), each through its **real**
invoke path — identical to the enterprise bed, since demo differs only in posture:

- **Standalone** (`aws-architect-agent`) and **swarm** entry peer
  (`research-swarm` → researcher): invoked directly on their AgentCore runtime
  with the A2A `message/send` envelope, targeting the version-pinned
  `<name>_endpoint`. PASS = HTTP 200 + result `state: completed`.
- **Step-Functions apps** (`data-pipeline-app`,
  `rrf-search-app`): the **state machine is the entrypoint** (ADR-020). The
  script `start-execution`s each with `{"query": ...}` and polls to a terminal
  state. PASS = `SUCCEEDED`; still-`RUNNING` after the budget is a soft pass
  (tune with `SFN_POLL_ITERS` / `SFN_POLL_SLEEP`).

Agents run in-VPC in demo (the `agent_network_mode` default `"VPC"`, same as
enterprise), so agent egress stays in the platform VPC and traces flow to the
in-VPC OTel collector → Langfuse.

## Console edge + hardening (script 07)

`07-validate-console.sh` is a read-only HTTP smoke test of the console edge
(ADR-037/038) — no browser, no Cognito login. It asserts:

- the CloudFront root serves the SPA (200);
- `/examples-api/*` reaches the Fargate backend **through** CloudFront (not 403);
- `/langfuse/*` reaches Langfuse **through** CloudFront (not 403);
- hitting the examples **ALB directly** returns 403 — proving the origin
  lockdown (CloudFront prefix list + secret header) blocks non-CloudFront traffic.

It's wired into `run-all.sh` after 06 and is **non-fatal** there (a still-warming
Langfuse can trip a transient check). Deep UI behavior (agent invoke, graph
rendering) is out of scope — that's the browser + script 06.

### Examples surface: seed → activate

The **Examples** tab is always visible, but its cards resolve from the lifecycle
table, so they are 3-state:

1. **Not deployed** — after `02`, before `team-bu-1` is seeded.
2. **Deploying** — while `team-bu-1-deploy-pipeline` runs (after `04`).
3. **Ready** — once the pipeline writes lifecycle records; Launch enabled.

Cards auto-flip (no reload) as `05` progresses. So the Examples tab only becomes
functional after `04`/`05` complete — expected, not a failure.

## Teardown (manual only)

```bash
cd test/demo-testbed
./99-teardown.sh                  # pre-destroy cleanup (98) -> destroy platform (prompts)
# ./99-teardown.sh --with-bootstrap  # also deletes the TF state bucket + lock table
```
`99-teardown.sh` is **never** run by `run-all.sh`. It runs `scripts/98-predestroy.sh`
first to remove what plain `terraform destroy` cannot:

- **Pipeline-deployed agent runtimes** (created by the deploy pipeline's own,
  separate Terraform state). Deleted endpoint-first, sparing the platform ADE
  runtime (removed by the platform destroy). They are VPC-attached, so they must
  be deleted endpoint-first before the platform VPC destroy, and they bill if left.
- **Non-empty ECR repos** (the three platform repos, created without
  `force_delete`) — emptied via `batch-delete-image`; the repos themselves are
  left for Terraform. (The examples-backend ECR repo is `force_delete=true`, so
  `terraform destroy` removes it directly — no pre-destroy emptying needed.)
- **Versioned state bucket** (only under `--with-bootstrap`).

You can also run it standalone: `scripts/98-predestroy.sh --yes`.

## Cost note

Demo runs a NAT gateway (platform VPC), Fargate/datastores (Langfuse), the
always-on examples backend (ECS Fargate + ALB, ADR-037), CloudFront + S3 (console),
a WAF WebACL, and AgentCore runtimes. Tear down when done. See the FinOps section
of `platform/DEPLOY-RUNBOOK.md`.
