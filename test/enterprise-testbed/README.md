# Enterprise Test Bed

A committed, repeatable harness that stands up an **enterprise-shaped
environment** and deploys the EAP platform into it in **enterprise mode**, to
prove the no-public-ingress / in-VPC / externalized-IAM posture end to end.

> This is **test scaffolding**, not platform code. The customer brings their own
> VPC + IdP + roles; this fixture *stands in* for that so we can exercise the
> imported-VPC + externalized-IAM path in our own account. Nothing here ships to
> a customer. The platform itself is unchanged — the test bed only feeds its
> existing inputs (`vpc_id`, `*_role_arn`, `deploy_console=false`, …).

> **⚠️ Cannot coexist with the DEMO bed in the same account.** There is exactly
> **one** platform Terraform state per account (backend key
> `platform/terraform.tfstate`) and the platform's ECR / CodeCommit / pipeline /
> runtime names are account-global. This enterprise bed and `test/demo-testbed/` are two
> *postures* of that single deployment, not two independent stacks — deploying
> one on top of the other **converts** it and collides on shared names. Run them
> **sequentially** (deploy enterprise → `./99-teardown.sh` → deploy demo), or use a
> **separate AWS account** per mode. Script 05 refuses to deploy if it detects a
> demo deployment already present.

## What it builds

| Component | What |
|---|---|
| `enterprise-vpc/` | VPC (3 AZ, public + private), IGW, single NAT, **S3 + DynamoDB gateway endpoints** on the private route tables (the imported-VPC gap the platform can't fill). CIDR `10.30.0.0/16`. |
| `iam-roles/` | The **5 standalone** roles (gateway, studio-runtime, studio-read, commit-validation, observability) rendered from `docs/iam/roles/*/{trust-policy,permissions-policy-hardened}.json` with tokens substituted — i.e. the **hardened** least-privilege policies — plus a scoped `iam:PassRole` policy for the deploy principal. (The 10 **pipeline** roles are left platform-created; ADR-033.) |
| platform | `terraform apply` of `eap-platform` in enterprise mode against the above. |

## Posture exercised (enterprise mode)

- `deploy_console = false` → no public console / CloudFront / API gateways.
- `agent_network_mode = "VPC"` → agents + Lambdas in the imported private subnets.
- `deploy_langfuse = true` → self-hosted Langfuse (private internal ALB).
- Cognito reference IdP; `enable_transaction_search = false`.
- 5 standalone roles **externalized (hardened)**; 10 pipeline roles platform-created.

## Prerequisites

- AWS creds for the target account (`aws sts get-caller-identity` works), region `us-east-1`.
- terraform ≥ 1.5, aws cli v2, jq.
- The base + ADE images present in ECR (script 05 deploys Docker-free with
  `studio_build_image=false`). On a **clean account** these don't exist yet —
  **`scripts/00-seed-images.sh`** seeds them (idempotent, needs Docker), and
  `run-all.sh` runs it automatically before 05. See `platform/DEPLOY-RUNBOOK.md`
  Step 1.
- `iam:PassRole` on the externalized role ARNs — script 03 creates a scoped
  policy and prints the attach command.

## Run it

**Automated (recommended):**
```bash
cd test/enterprise-testbed
./run-all.sh            # one confirmation, then runs 01..06 unattended
# ./run-all.sh --yes    # no prompt
```

**Step by step:**
```bash
cd test/enterprise-testbed
scripts/01-check-prereqs.sh
scripts/02-create-vpc.sh
scripts/03-create-iam.sh          # then attach the printed PassRole policy to your principal
scripts/04-gen-tfvars.sh      # writes platform/eap-platform/configs/enterprise.testbed.tfvars
scripts/00-seed-images.sh         # clean-account bootstrap: seed base+ADE images (idempotent)
scripts/05-deploy-platform.sh
scripts/06-validate.sh
scripts/07-jumphost.sh            # optional — SSM jumphost to reach internal services
scripts/08-seed-repos.sh          # seed users/team-bu-1 -> CodeCommit -> triggers deploy pipeline
scripts/09-monitor-pipeline.sh    # watch team-bu-1-deploy-pipeline to a terminal state
scripts/10-invoke-agent.sh        # headless smoke test of the deployed agents (all patterns)
```

## End-to-end CI/CD path (scripts 08–10)

Scripts 08–10 exercise the real platform flow: push agent code -> CodeCommit ->
deploy pipeline -> AgentCore runtimes + Step Functions -> headless invocation.

- `08-seed-repos.sh [repo]` copies `users/<repo>` (default `team-bu-1`) into a
  **temp** dir, inits a fresh git repo there, and pushes to the platform-created
  CodeCommit repo using **git-remote-codecommit** (`codecommit::<region>://<repo>`),
  which SigV4-signs each request and is the reliable method for temporary /
  assumed-role credentials — the plain-HTTPS CodeCommit credential helper 403s
  with STS session creds. Install: `pip install git-remote-codecommit`. The
  tracked source under `users/` is **never** git-init'd in place. Pushing to
  `main` triggers `<repo>-deploy-pipeline`.
- `09-monitor-pipeline.sh [pipeline] [max-iters]` polls the pipeline stages
  (Source → Build → Deploy → Verify) until it succeeds or fails, and prints how
  to inspect a failed action.
- `10-invoke-agent.sh` is a headless smoke test that exercises every deployed
  team-bu-1 entrypoint through its **real** invoke path, one per architecture
  pattern (ADR-020):
  - **Standalone** (`aws-architect-agent`) and **swarm** entry peer
    (`research-swarm` → researcher): invoked directly on their AgentCore runtime
    with the A2A `message/send` envelope (the same payload the demo UIs send),
    targeting the version-pinned `<name>_endpoint`. PASS = HTTP 200 + result
    `state: completed`.
  - **Step-Functions apps** (`data-pipeline-app`,
    `rrf-search-app`): the **state machine is the entrypoint** (ADR-020 — SFN is
    the driver; the orchestrator/supervisor agent is a task inside it, not an
    invocable entry). The script `start-execution`s each with `{"query": ...}`
    and polls to a terminal state. PASS = `SUCCEEDED`; a still-`RUNNING` run
    after the poll budget is a soft pass (multi-agent runs are long — tune with
    `SFN_POLL_ITERS` / `SFN_POLL_SLEEP`).

  Each AgentCore invoke prints a `runtime-session-id` and each SFN run an
  `executionArn` so the resulting traces can be found in Langfuse. `10` is
  **manual** (not in `run-all`) — run it after 08/09 report the deploy succeeded.

After success, confirm the runtimes + state machines:
```bash
aws bedrock-agentcore-control list-agent-runtimes --region us-east-1 \
  --query 'agentRuntimes[].[agentRuntimeName,status]' --output text
aws stepfunctions list-state-machines --region us-east-1 \
  --query "stateMachines[?contains(name,'team_bu_1')].name" --output text
```

## Reaching the private Langfuse UI (SSM jumphost)

Langfuse is deployed **internal-only** (ADR-030): its ALB is `internal` (HTTP :3000),
reachable only from inside the VPC. Script `07-jumphost.sh` (fixture `jumphost/`)
launches a tiny SSM-managed EC2 in a public subnet — no open SSH, no keypair —
so you can port-forward to it from your laptop.

```bash
# 1. the internal Langfuse endpoint:
cd platform/eap-platform && terraform output -raw langfuse_base_url
#    -> http://internal-langfuse-alb-XXXX.us-east-1.elb.amazonaws.com:3000

# 2. port-forward through the jumphost (needs the Session Manager plugin:
#    session-manager-plugin --version || brew install --cask session-manager-plugin):
aws ssm start-session --region us-east-1 \
  --target <jumphost-instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<langfuse-alb-dns>"],"portNumber":["3000"],"localPortNumber":["3000"]}'

# 3. open http://localhost:3000  (first load = Langfuse setup screen; create the admin user)
```
Get `<jumphost-instance-id>` from `cd test/enterprise-testbed/jumphost && terraform output -raw instance_id`.

## After deploy — AgentCore-supported AZ check

Verify the private subnets landed on AgentCore-supported AZ **IDs** (can't be
validated at plan time):
```bash
aws ec2 describe-subnets --subnet-ids <private-subnet-id> \
  --query 'Subnets[0].AvailabilityZoneId'
```
Cross-reference the AgentCore VPC docs' supported-AZ table. If not supported,
adjust `availability_zones` in `enterprise-vpc/variables.tf` and re-run 02.

## Expect: hardened-policy iteration

The `iam-roles` fixture uses the **hardened** (least-privilege) policies. The
first run may surface an `AccessDenied` where a hardened policy scoped out
something the platform needs at runtime. That is a *feature* of this test — fix
the relevant `docs/iam/roles/<role>/permissions-policy-hardened.json`, re-run 03,
and re-apply. This is how we validate the hardened set.

## Teardown (manual only)

```bash
cd test/enterprise-testbed
./99-teardown.sh                  # pre-destroy cleanup (98) -> platform -> iam-roles -> vpc (prompts)
# ./99-teardown.sh --with-bootstrap  # also deletes the TF state bucket + lock table
```
`99-teardown.sh` is **never** run by `run-all.sh`.

**`99` runs `scripts/98-predestroy.sh` first** to remove the resources plain
`terraform destroy` cannot:

- **Pipeline-deployed agent runtimes.** If you ran script 08, the deploy pipeline
  created AgentCore **runtimes + endpoints** (and per-agent IAM roles) via its own
  `terraform apply` in a SEPARATE state — the platform `terraform destroy` does
  not manage them, and in VPC mode their `agentic_ai` ENIs would otherwise block
  the VPC destroy with `DependencyViolation`. Script 98 deletes them
  **endpoint-first** (a runtime with a live endpoint returns `ConflictException`),
  sparing the platform-owned ADE runtime (`team_bu_1_agent_deployment_engineer`),
  which the platform destroy removes since it is in platform state.
- **Non-empty ECR repos.** The platform ECR repos are created **without**
  `force_delete` (deliberate — no accidental image-nuke on destroy), so once the
  pipeline has pushed images `terraform destroy` fails with
  `RepositoryNotEmptyException`. Script 98 **empties** the repos (`batch-delete-image`);
  it never deletes the repos themselves (Terraform owns those).
- **Versioned state bucket** (only under `--with-bootstrap`): purges all object
  versions + delete-markers so 99 can then delete the bucket.

You can also run it standalone before a manual destroy:
```bash
scripts/98-predestroy.sh            # delete pipeline agents + empty ECR repos (prompts)
scripts/98-predestroy.sh --yes --with-bootstrap
```

## Cost note

VPC mode adds hourly interface-endpoint charges (created by the platform) + a
NAT gateway; Langfuse runs Fargate + datastores. Tear down when done. See the
FinOps section of `platform/DEPLOY-RUNBOOK.md`.
