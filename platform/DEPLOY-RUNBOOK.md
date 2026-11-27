# EAP Platform Deploy Runbook

Deploy the full EAP platform. All infrastructure is provisioned via Terraform — no ad-hoc AWS CLI resource creation. App teams write `agent.yaml`, the platform does the rest.

Account: `<AWS_ACCOUNT_ID>` (customer's chosen deployment account) · Region: `us-east-1` · Environment: `dev`

## Enterprise Architecture Approval — Services That Need to Be Approved for Deploying This Pattern

> **For EA / cloud-service approval.** Exact AWS resources the platform's Terraform creates on a default deploy (names shown for `dev`; other envs use the matching suffix). All via Terraform in `us-east-1` — no click-ops.

### AWS services and the named resources created

| AWS Service | Named resources created (dev) | Purpose |
|---|---|---|
| **Amazon ECR** (4 repositories) | 1. `eap-agents`<br>2. `eap-agents-base-strands`<br>3. `eap-terraform`<br>4. `eap-ade-dev-backend` (ADE streaming backend image — ADR-040) | Agent images, Strands base image, Terraform build image, ADE invoke-backend image (scan-on-push + lifecycle policies) |
| **AWS CodeCommit** (5 repositories) | 1. `team-bu-1`<br>2. `mcp-integrations`<br>3. `governance`<br>4. `nocode-user`<br>5. `knowledge-bases-team-bu-1` | Git source for: agents, MCP/gateway integrations, governance policies, Studio/no-code agents, knowledge bases |
| **AWS CodePipeline (V2)** (5 pipelines) | 1. `team-bu-1-deploy-pipeline`<br>2. `nocode-user-deploy-pipeline`<br>3. `mcp-integrations-deploy-pipeline`<br>4. `governance-deploy`<br>5. `kb-team-bu-1-deploy` | CI/CD per repo: Source → Build → Deploy → Verify (`<repo>-deploy-pipeline` convention). The `nocode-user` pipeline (ADE-generated agents) adds an **Approve** stage after Build: approve the commit in the CodePipeline console before it deploys (ADR-048). |
| **AWS CodeBuild** | 1. 5 projects per agent pipeline: `build`, `evaluate`, `gate`, `deploy`, `verify`<br>2. KB pipeline: `validate`, `plan`, `apply`<br>3. governance + integration: `deploy` | ARM64 Docker builds, `terraform apply`, validation, evaluation, health checks |
| **Amazon S3** (7 buckets) | 1. `eap-console-dev-<ACCOUNT_ID>` (console site)<br>2. `eap-cloudfront-logs-dev-<ACCOUNT_ID>` (CloudFront access logs)<br>3. `team-bu-1-a2a-demo-pipeline-artifacts-<ACCOUNT_ID>`<br>4. `nocode-user-nocode-user-deploy-pipeline-artifacts-<ACCOUNT_ID>`<br>5. `shared-services-mcp-integrations-deploy-artifacts-<ACCOUNT_ID>`<br>6. `governance-deploy-artifacts-<ACCOUNT_ID>`<br>7. `kb-team-bu-1-deploy-artifacts-<ACCOUNT_ID>` | Console static hosting, CloudFront access logs, and per-pipeline CI/CD artifacts. Every name ends in the account ID so it cannot be pre-registered by another account. |
| **Amazon DynamoDB** (1 table) | 1. `agent-school-lifecycle-team-bu-1-dev` | Deployed-agent lifecycle state (single source of truth) |
| **Amazon Cognito** | 1. User Pool `eap-agents-dev`<br>2. Domain `eap-platform-bu-1-dev`<br>3. App client `eap-console-dev`<br>4. Resource servers `gateway` + `agent`<br>5. User group `team-bu-1`<br>6. Identity Pool `eap-console-dev` | User→agent / user→gateway identity, OAuth2 / JWT authorization |
| **Amazon Bedrock** | 1. IAM policy `eap-bedrock-model-access-dev` (Claude Sonnet 5 inference profile) | Foundation-model invocation access |
| **Amazon Bedrock AgentCore** (13 core services — approve the family) | ✅ deployed: 1. **Runtime** `team_bu_1_agent_deployment_engineer` + endpoint<br>2. **Gateway** `eap-shared`<br>3. **Memory**<br>4. **Identity** (CUSTOM_JWT+OIDC)<br>5. **Observability** (CloudWatch GenAI + X-Ray)<br>6. **Policy (Cedar)**<br>7. **Evaluations** (SSM/CW workaround)<br>⛔ not deployed: 8. **Browser** · 9. **Code Interpreter** · 10. **Managed Harness** · 11. **MCP Server** (dev tool) · 12. **Payments** (Preview) · 13. **Registry** (Preview) | Agent execution, gateway, Cedar authz, memory, identity, observability, eval. Items 1–7 created on default deploy; 8–13 listed so EA can pre-approve the full family (not deployed today). |
| **Amazon CloudFront** | 1. 1 distribution<br>2. Origin Access Control `eap-console-oac-dev` | HTTPS delivery of the console SPA (private S3 origin). Demo also adds locked-down ALB origins/behaviors: `/examples-api/*` (ADR-037) and `/ade-api/*` → the ADE streaming backend ALB (ADR-040), each gated by a secret origin header + WAF |
| **Amazon API Gateway** | 1. HTTP API (`invoke-proxy` + studio-read routes)<br>2. REST API (buffered `/api/invoke`) | Browser → AgentCore invocation, read-only console backend. Note: the **ADE Build-workspace chat streams via the ECS/Fargate `/ade-api` backend (ADR-040)**, not this buffered REST path; `/api/invoke` remains for per-agent chat |
| **AWS Lambda** (3 functions) | 1. `invoke-proxy-dev`<br>2. `studio-read-dev`<br>3. `eap-commit-validation` | Console API backend + Conventional Commits enforcement |
| **Amazon ECS / Fargate + ALB** (ADE invoke backend — ADR-040; **both presets**) | 1. ECS cluster `eap-ade-dev`<br>2. Service/task `eap-ade-dev-backend`<br>3. ALB `eap-ade-dev-alb` (demo: internet-facing, locked to CloudFront; enterprise: **internal**)<br>4. ECR `eap-ade-dev-backend`<br>5. Log group `/eap/ade-invoke-backend/dev`<br>6. Two security groups: `eap-ade-dev-alb` (ingress: CloudFront prefix-list in demo / VPC-CIDR in enterprise) + `eap-ade-dev-backend` (ingress from ALB only)<br>7. Origin secret (`random_password`) for the demo CloudFront→ALB secret header | **Always-on** streaming ADE console chat (A2A message/stream over SSE) — the interactive Build-workspace chat that renders token-by-token. Enforces Cognito/OIDC JWT + the Requirement-11 runtime allow-list in-service. Egress-only tasks (ECR pull / AgentCore / DynamoDB reads); in enterprise this rides the in-VPC PrivateLink/NAT path (ADR-031/032). **This is the one always-on compute component and adds standing cost — see FinOps.** |
| **AWS IAM** | Roles:<br>1. `eap-gateway-role-dev`<br>2. `eap-console-auth-dev`<br>3. `studio-runtime-role-dev`<br>4. `invoke-proxy-lambda-dev`<br>5. studio-read + commit-validation Lambda roles<br>6. per-pipeline + CodeBuild roles<br>7. ADE backend `eap-ade-dev-task` (InvokeAgentRuntime + lifecycle Scan) + `eap-ade-dev-exec` (ECS execution) — ADR-040<br>Plus per-domain boundary policy `eap-domain-boundary-team-bu-1-dev` | Least-privilege execution + per-BU isolation |
| **AWS SSM Parameter Store** | 1. `/eap/dev/team-bu-1/agent-school/lifecycle-table` | Service discovery (lifecycle table name) |
| **AWS CloudFormation** | 1. Stack `...transaction-search...` (enables X-Ray/CloudWatch Transaction Search) | One-time enablement of Transaction Search for AgentCore traces |
| **Amazon CloudWatch + AWS X-Ray** | 1. Lambda/CodeBuild log groups<br>2. GenAI Observability<br>3. X-Ray Transaction Search<br>4. Lambda error alarm | AWS-native agent observability — on by default |

> **Notes:** `dev` values shown (`staging`/`prod` differ only by suffix). Encryption at rest defaults to AWS-provided keys (state bucket SSE-KMS `aws/s3`; lifecycle DynamoDB service-managed/AWS-owned); an optional customer-managed key (CMK) can be supplied via `kms_key_arn` / `TF_STATE_KMS_KEY_ARN` — ADR-035. State backend (`eap-platform-state-<ACCOUNT_ID>` S3, versioned + SSE-KMS, + `eap-platform-locks` DDB) is an external one-time bootstrap. ADE role `studio-runtime-role-dev` has `codecommit:CreateCommit` scoped to `nocode-user`.

> **CI/CD is a deployer customization.** The platform ships an **AWS-native
> reference CI/CD** — CodeCommit (source), CodePipeline (orchestration), and
> CodeBuild (build/deploy stages) — so it stands up end-to-end out of the box. A
> deployer who standardized on another CI/CD system (other Git hosting + their
> own build runners) substitutes that toolchain at this layer; the platform's
> agent contract is unchanged (teams still declare `agent.yaml`, and the same
> platform-owned Terraform runs — invoked from the other CI/CD system instead of
> CodeBuild). Swapping CI/CD is therefore a **deployer-side integration, not a
> platform gap or blocker**. (EA note: if CodeBuild/CodePipeline/CodeCommit are
> not acceptable in your environment, replace them with equivalents; no change
> to the agent runtime, gateway, or networking layers.)

## FinOps — Estimated Deployment Cost

> **For FinOps approval.** Standing (idle) monthly cost of the deployed platform — **before any traffic, builds, or model calls**. Idle prices from the AWS Price List API (us-east-1, on-demand, 2026-07-23). **Run cost is workload-driven — see the estimation template further down** (a calculator you fill in with your own assumptions + current Bedrock rates, not a hardcoded total).

### Headline: ≈ $30–45 / month idle (ADE streaming backend), or ≈ $1–2 / month without it

The **one always-on compute component is the ADE streaming invoke backend** (ECS/Fargate task + ALB, ADR-040), present in **both** presets. It adds roughly **$30–45/month** of standing cost per instance so the ADE Build-workspace chat streams token-by-token. **Everything else is idle-storage-only** (≈ $1–2/month, mostly ECR images) — no other always-on compute. If a deployment does not need the streaming ADE chat, dropping the always-on backend (see the note below) returns idle cost to ≈ $1–2/month.

### Standing (idle) monthly cost by service

| Service | Standing driver | AWS unit price (us-east-1) | Est. qty at deploy | Est. $/mo |
|---|---|---|---|---|
| **Amazon ECR** | Container image storage (4 repos: agent, base, terraform, ADE backend) | $0.10 / GB-month | ~8–12 GB of images/layers | **$0.80–1.20** |
| **Amazon S3** | Console SPA + 5 pipeline-artifact buckets | $0.023 / GB-month (first 50 TB) | < 1 GB total | **< $0.05** |
| **Amazon DynamoDB** | `agent-school-lifecycle` table (on-demand) + PITR | $0.25 / GB-month (first 25 GB free) | << 25 GB (free tier) | **$0.00** |
| **AWS CodeCommit** | 5 repos | $1 / active-user-month beyond first 5 users | ≤ 5 users | **$0.00** |
| **AWS KMS** | Encryption | AWS-provided keys by default (no platform-created key); optional customer-managed key (CMK) via `kms_key_arn` — ADR-035 | 0 keys (default) | **$0.00** (CMK: ~$1/key/mo if you supply one) |
| **AWS Fargate** (ADE invoke backend — ADR-040) | 1 always-on task (0.5 vCPU / 1 GB), both presets | ~$0.04048/vCPU-hr + ~$0.004445/GB-hr | 1 task × 730 hr | **≈ $18–20** |
| **Elastic Load Balancing** (ADE backend ALB — ADR-040) | 1 ALB always-on (+ minimal LCU) | ~$0.0225/ALB-hr + LCU | 1 ALB × 730 hr | **≈ $16–18** |
| **Everything else** (CloudFront, API Gateway, Lambda, CodeBuild, CodePipeline V2, Cognito, SSM Parameter Store, CloudFormation, Bedrock AgentCore Gateway/Policy/Memory/Runtime) | All consumption-priced — $0 when idle | per-request / per-minute / per-token | 0 at idle | **$0.00** |
| | | | **Total standing cost** | **≈ $30–45 / month** (≈ $1–2 without the ADE backend) |

### Run cost — estimation template (fill in your own numbers)

> Run cost is **overwhelmingly Bedrock model tokens** and is entirely driven by
> your workload, so this is a **calculator, not a quote**. Plug your assumptions
> into the variables below rather than trusting a pre-baked total — every hard
> dollar figure here would go stale as AWS reprices and as your usage differs.
> **Current model rates:** see the [Amazon Bedrock pricing page](https://aws.amazon.com/bedrock/pricing/)
> (per-1M input/output tokens for your chosen model) — do not hardcode them.

**Cost model (per period):**

```
run_cost ≈  invocations
            × LLM_calls_per_invocation
            × ( input_tokens  × price_in_per_1M  / 1e6
              + output_tokens × price_out_per_1M / 1e6 )      # Bedrock tokens — dominant term
          + invocations × agentcore_per_invocation            # Memory/Runtime/Evals/Policy/Gateway (consumption)
          + invocations × lambda_cloudwatch_per_invocation     # invoke-proxy/studio-read + observability (tiny)
          + platform_infra_per_month × months                 # time-based BU overhead (ECR/S3/Cognito/CI)
```

**Your assumptions (fill in):**

| Variable | Meaning | Your value |
|---|---|---|
| `invocations` | Total agent invocations over the period | _______ |
| `LLM_calls_per_invocation` | LLM round-trips per invocation (agent loop count) | _______ |
| `input_tokens` / `output_tokens` | Avg tokens in/out per LLM call | _______ / _______ |
| `price_in_per_1M` / `price_out_per_1M` | Model rates — from the Bedrock pricing page (dated) | _______ / _______ |
| `agentcore_per_invocation` | Consumption cost per invocation (I/O wait is free) | _______ |
| `platform_infra_per_month` | Time-based per-BU overhead (ECR/S3/Cognito/CI) | _______ |
| `months` | Billing period length | _______ |

**Durable takeaways (workload-independent):**

- **Tokens dominate** (typically the large majority of run cost). The biggest
  levers are prompt/context size, agent **loop count** (LLM calls per
  invocation), **model choice**, and **prompt caching**.
- **AgentCore + Lambda/CloudWatch overhead is a small fraction** of the token
  cost — consumption-priced, I/O wait is free.
- **Run cost scales ~linearly** with invocations (the token term is per-call);
  `platform_infra_per_month` is the only time-based, invocation-independent term.
- **Excluded:** data egress, third-party SaaS, build-minutes, CloudWatch/X-Ray
  ingestion, API/CloudFront transfer. These are list rates — reconcile against
  your org EDP.

### Notes for FinOps reviewers

- **One always-on component (ADR-040):** the ADE streaming invoke backend (Fargate task + ALB, ~$30–45/mo, both presets). Everything else idle = storage only and bills per-use. Drop the backend to return to ≈ $1–2/mo idle (see the drop-the-ADE-backend note below).
- **AgentCore runtime has no idle compute / no ENIs:** Runtime is `PUBLIC` (consumption-billed, $0 when not invoked); `VPC` mode adds ENIs (+ any NAT/PrivateLink cost). This is separate from the always-on ADE backend above.
- **Dropping the ADE streaming backend:** if the interactive ADE chat can tolerate the buffered (non-streaming) `/api/invoke` path — or isn't used — set `backend_desired_count = 0` on `module.ade_invoke_backend` to scale the Fargate task to zero (the ALB standing cost remains until the module is removed). Removing the module entirely returns idle cost to ≈ $1–2/mo, at the cost of no streaming ADE chat.
- **First deploy:** one-time CodeBuild/Docker build ≈ $0, non-recurring.
- **Free tier:** DynamoDB (<25 GB) + Cognito (<50k MAU) = $0 at baseline.
- **Out of scope (run):** Bedrock tokens, build-minutes, CloudWatch/X-Ray ingestion, API/CloudFront transfer.
- **Discounts:** public list rates — net against org EDP.

## Prerequisites

Grouped by **where** each item is needed. The "deployment host" is whatever machine runs `terraform apply` — your laptop, a bastion/jump box, or a CI runner. The "AWS account" items are one-time account/region enablement. Validation in Step 8 is done through the deployed console, so it needs only a browser with network access to the console's CloudFront URL — no extra host.

### A. Deployment host (laptop / bastion / CI runner — runs `terraform apply`)

- **AWS CLI v2**, authenticated — `aws sts get-caller-identity` returns the **customer's target account** (`<AWS_ACCOUNT_ID>`) in `us-east-1`
- **Terraform >= 1.5** (`terraform version`)
- **AWS provider >= 6.37.0** (pinned in the config; required for `aws_bedrockagentcore_*` resources)
- **Git CLI** + **git-remote-codecommit** (`pip install git-remote-codecommit`) — to push agent repos to CodeCommit
- **Docker (or Lima/Colima)** — **only** for the one-time base/agent image build (Step 1 / `studio_build_image=true`). Skip if you deploy with `-var 'studio_build_image=false'` and the images already exist in ECR
- **Node.js 18+** — the console SPA build runs automatically during `terraform apply`; if the deploy host builds the console, Node must be present
- Credentials refresh helper for this environment (e.g. `aws sso login` or your organization's credential tool) since AgentCore work spans hours and STS tokens expire

### B. AWS account / region (one-time enablement)

- Account with **Bedrock AgentCore access** in **us-east-1**
- **Bedrock model access** enabled for `us.anthropic.claude-sonnet-5` (the cross-region inference profile — the bare foundation-model id is not valid for on-demand Converse/ConverseStream)
- Terraform **state backend** bootstrapped (`./bootstrap.sh` → S3 bucket `eap-platform-state-<ACCOUNT_ID>` (account-scoped for global uniqueness), versioned + SSE-KMS + public-access-blocked, and DynamoDB lock table `eap-platform-locks`) — external, one-time. `bootstrap.sh` prints the exact `terraform init -backend-config="bucket=…"` command.
- **Identity provider (OIDC)** decided — either let the platform provision Cognito (default) or bring your own IdP. See **"Identity provider (OIDC) — choose one"** below.
- **Agent base image source** decided. The strands base image (Step 1a) is built **locally at deploy time**, so you control its upstream. It defaults to the official `python:3.12-slim` image on Amazon ECR Public (`public.ecr.aws/docker/library/python:3.12-slim`, `ARG BASE_IMAGE`). For a **locked-down / no-egress account**, rebuild it on your **organization-approved (golden) base** by passing `--build-arg BASE_IMAGE=<your-registry>/<approved-python-3.12>` — no Dockerfile edit, no public image pulled at build time. Every agent image inherits from this base, so approving it covers the whole fleet. See Step 1a.
- **Encryption at rest (CMK)** decided (ADR-035). Everything is encrypted at rest by default with AWS-provided keys (AWS-managed `aws/s3` for the state bucket, DynamoDB **service-managed / AWS-owned** for the lifecycle table, AWS-managed keys for the Langfuse datastores). To use a **customer-managed key (CMK)**, set `-var 'kms_key_arn=<arn>'` on the apply — it is threaded to the lifecycle DynamoDB table, the Langfuse stack, and the Gateway. **The state bucket is separate:** it is created by `bootstrap.sh`, so export `TF_STATE_KMS_KEY_ARN=<arn>` **before** running it. **S3/DynamoDB SSE is not retroactive** — the CMK must be chosen at bucket/table **first-create** time to cover data from the start; setting it later re-encrypts only new writes. The key policy must allow the relevant AWS service principals + the deploy/runtime roles to use the key. (`pilot` preset sets this; `demo`/`poc` leave it default.)
- **IAM role creation** decided (ADR-033). By default the platform apply **creates** its ~17 root-apply IAM roles. If your organization does **not** allow humans/deployers to create IAM roles, have your IAM team **pre-create** them and supply the ARNs via the `*_role_arn` variables (`gateway_role_arn`, `studio_runtime_role_arn`, `studio_read_role_arn`, `invoke_proxy_role_arn`, `commit_validation_role_arn`, `console_authenticated_role_arn`, `observability_role_arn`, and the per-pipeline `*_codebuild_role_arn` / `*_codepipeline_role_arn`). When an ARN is supplied the platform creates **no** IAM for that role. The exact trust + permission policy JSON to pre-create each role (verbatim, with placeholders) is in [`docs/iam/`](../docs/iam/README.md). Note: the deploy principal still needs **`iam:PassRole`** on the pre-created ARNs it hands to services (e.g. the runtime role → AgentCore, the pipeline roles → CodeBuild/CodePipeline). Pipelines themselves are still allowed to create the per-agent roles they vend.
- **X-Ray Transaction Search** decided (OPTIONAL, account+region-wide). This is what makes the AWS-native agent traces (emitted automatically by AgentCore) **searchable** on the CloudWatch GenAI Observability page. Two things to know before enabling it:
  - It is a **singleton, account+region-wide** setting (`AWS::XRay::TransactionSearchConfig`). Enabling it affects X-Ray/CloudWatch for the **whole account/region**, not just EAP — in a shared account, coordinate with whoever owns account-level observability.
  - **Cost:** span **ingestion is billed regardless**; only the first **1%** of indexing is free. `transaction_search_indexing_percentage` (default `5`) controls how many spans are indexed as queryable summaries.
  - **Default is on** (`enable_transaction_search = true`). To skip it — e.g. observability is centrally managed, or you don't want the platform flipping the account-wide switch — deploy with `-var 'enable_transaction_search=false'`. Agents still emit traces; they just aren't searchable via GenAI Observability until Transaction Search is enabled (by you or centrally). This is purely AWS-native and has **no** effect on the private OTel/Langfuse leg.
- **Demo console / public ingress** decided (ADR-034). By default the platform deploys the bundled demo console — an S3 + CloudFront SPA plus the `invoke-proxy` API Gateways and `studio-read` routes that back it. **This stack is the platform's entire public ingress** (JWT-gated, but internet-reachable). For a **no-public-access** install, deploy with `-var 'deploy_console=false'`: it removes CloudFront, the S3 SPA bucket, both API Gateways, both Lambdas, and their IAM in one switch, leaving zero public ingress. Host your own UI internally (BYO UI) reaching agents over the in-VPC path (ADR-031/032). If a BYO UI on a different origin must call a still-deployed `invoke-proxy`, set `-var 'console_cors_origins=["https://your-ui.internal"]'` (default `[]` = no CORS, correct for the same-origin demo). Leave the default (`true`) for the out-of-the-box demo.
- IAM permissions for the deploy principal to create the services listed in the EA-approval section (ECR, CodeCommit/Pipeline/Build, S3, DynamoDB, Cognito, IAM, Bedrock AgentCore; **API Gateway, Lambda, and CloudFront only when `deploy_console=true`** — the default; and — only when `enable_transaction_search=true` — CloudFormation + X-Ray Transaction Search config)

### Identity provider (OIDC) — choose one

The platform integrates its identity provider **by reference** (ADR-028). A single
variable, `oidc_discovery_url`, decides whether the platform provisions Cognito for
you or consumes an external IdP. Every consumer (AgentCore Gateway authorizer,
integration pipelines, invoke-proxy, studio-read, console) uses the resolved value.

**Option A — Platform-managed Cognito (default, zero-config).**
Leave `oidc_discovery_url` empty. The platform provisions the Cognito user pool,
app client, resource servers, per-domain groups, and the console Identity Pool. You
then create users manually (Step 2.5). Nothing extra to configure.

**Option B — Bring your own IdP (any OIDC provider).**
Set these variables (e.g. in a `*.tfvars` or `-var` flags):

```hcl
oidc_discovery_url = "https://<your-idp>/.well-known/openid-configuration"
oidc_issuer        = "https://<your-idp>/"          # optional; if issuer != discovery host
oidc_audience      = "<your-api-audience-or-scope>"  # optional; defaults to Cognito gateway scope
console_url        = "https://<your-console-domain>" # used to build the OAuth callback
```

When `oidc_discovery_url` is set, the platform **does not create Cognito** and skips
the Cognito-dependent surfaces (console Identity Pool for browser AWS-credential
exchange, per-domain Cognito user groups, Langfuse SSO). Gateway and agent-runtime
JWT validation use your IdP directly. You are responsible, in your IdP, for:

1. Registering an application/client for the console.
2. Adding the **callback URL** `https://<console_url>/auth/callback` (and, for local
   dev, `http://localhost:5173/auth/callback`) to that client's allowed redirect URIs.
3. Issuing tokens whose `aud`/scope match `oidc_audience`.

> **Callback URL propagation.** The platform builds the console's redirect URI from
> `console_url` (falling back to the created CloudFront domain when empty) and
> standardizes on the `/auth/callback` path. If you use the CloudFront default domain,
> run the platform apply once, read `terraform output -raw console_url` (or the
> CloudFront domain), then register that `…/auth/callback` in your IdP.

### C. Console validation (browser — for Step 8)

- A browser + network access to the console's CloudFront URL (`terraform output console_url`) and the Cognito hosted UI
- A console user (Step 2.5) — the `console-admin` example account (see `platform/console/LOGIN.md`)

## Repository Layout

All deployments flow through these repos — no ad-hoc AWS CLI resource creation:

Repos are grouped by ownership under `platform/` (the product — the only place
Terraform is written) and `users/` (tenant repos — YAML/policy/code, zero
Terraform). See [ADR-029](../docs/adr/029-repo-layout-platform-vs-users.md).

```
platform/                                   # Platform product + blueprint (Platform Eng / Operator)
  eap-platform/            # ALL platform Terraform (root module)
    ecr/                            # ECR repos (agent, base, terraform, ADE backend) — child module
    identity/                       # Cognito User Pool + resource server + console client
    domains/                        # Per-domain Cognito group + IAM permission boundary
    bedrock-model-access/           # IAM for Bedrock model invocation
    source-repos/                   # CodeCommit repos for app teams
    pipelines/                      # Per-domain CodePipeline (agent + integration)
    studio/                         # Agent Deployment Engineer runtime (platform-owned agent)
    studio-read/                    # Read-only Console Build workspace routes
    invoke-proxy/                   # API Gateway + Lambda for browser→AgentCore invoke (buffered)
    ade-invoke-backend/             # ECS/Fargate + ALB streaming ADE invoke backend (ADR-040)
    examples-console/               # Demo Examples surface backend infra (ADR-037)
    console/                        # S3 + CloudFront unified console (Build/Govern/Run/Evolve)
    lifecycle-store/                # DynamoDB — deployed-agent state (source of truth)
  eap-terraform-modules/   # Reusable module library
    modules/runtime/                # AgentCore runtime + endpoint
    modules/pipeline/               # CodePipeline: Source → Build → Deploy → Verify
    modules/gateway/                # AgentCore Gateway (MCP) + policy engine
    modules/governance-pipeline/    # Cedar policy deploy pipeline
    modules/qa-pipeline/            # QA evaluation pipeline
    modules/kb-pipeline/            # Knowledge Base pipeline
    modules/observability/          # OTel collector + Langfuse (ADR-030)
    base-images/strands/            # ARM64 base image with A2A, OTel, credentials
  console/                       # Unified console SPA (React/TS) — built + synced to S3
  ade-invoke-backend/            # ADE streaming backend service (Express SSE signer — ADR-040)
  examples-backend/              # Generic Examples surface signer service (ADR-037)

users/                                      # Platform-user / tenant repos — ZERO Terraform
  governance/                    # Governance_Team — Cedar policies, red-team prompts
  mcp-integrations/              # Shared_Services — MCP/Gateway YAML sources
  knowledge-bases-team-bu-1/     # GenAI_Data_Eng — Bedrock KB configs (kb.yaml, data-sources.yaml)
    <kb-name>/                      # one folder per KB — feeds the kb-team-bu-1-deploy pipeline
  team-bu-1/                     # App_Team — agent code + agent.yaml
    standalone/                     # Standalone agent pattern
    orchestration/supervisor/       # Supervisor / fan-out pattern
    choreography/swarm/             # Swarm pattern
```

## Terraform state — single root, single remote backend

There is **one** Terraform root module (`eap-platform`) with **one** S3 backend (`backend.tf` → bucket `eap-platform-state-<ACCOUNT_ID>` supplied at init via `-backend-config` since S3 names are globally unique, key `platform/terraform.tfstate`, DynamoDB lock table `eap-platform-locks`). Everything — `ecr`, `identity`, `domains`, `source-repos`, `pipelines`, `studio`, `console`, `gateway`, `lifecycle-store`, etc. — is a **child module** of that root (`source = "./..."`), so all resources live in that single remote state. Child modules do not (and must not) declare their own backend. **No local state, no per-directory state.**

Terraform writes state per-run (not continuously): every `apply`/`destroy` — and state-mutating subcommands (`state mv/rm`, `import`, `taint`) — acquires a lock in `eap-platform-locks`, PUTs the whole `terraform.tfstate` object to S3 (SSE-KMS, `serial` incremented), then releases the lock. Read-only commands (`plan`, `output`, `show`, `state list`) never write. In this platform that means a new state version is written on each deploy (the CodePipeline/CodeBuild `terraform apply` stages), not on any schedule.

> **State history / recovery.** `bootstrap.sh` provisions the state bucket with **S3 versioning enabled** (plus SSE-KMS and full public-access block), so every write retains the prior object version. To recover a bad state write (using your account-scoped bucket `eap-platform-state-<ACCOUNT_ID>`): `aws s3api list-object-versions --bucket eap-platform-state-<ACCOUNT_ID> --prefix platform/terraform.tfstate` to find the last-good `VersionId`, then `aws s3api get-object --bucket eap-platform-state-<ACCOUNT_ID> --key platform/terraform.tfstate --version-id <ID> restored.tfstate` and `terraform state push restored.tfstate`. Consider a bucket lifecycle rule to expire noncurrent versions after N days so history doesn't grow unbounded.

> Migrating an older deployment that used split/local state (separate `ecr/`, `source-repos/`, `pipelines/` applies)? Do it once: from `eap-platform` run `terraform init -backend-config="bucket=eap-platform-state-<ACCOUNT_ID>"` (adopts the S3 backend), `terraform plan` to confirm the child-module resources are already tracked (import any that aren't), then delete the stale local `terraform.tfstate*` files under `ecr/`, `source-repos/`, and `pipelines/`. They are gitignored and not the source of truth.

## Deploy Steps — the test bed is the canonical, executable path

> **The source of truth for the exact deploy mechanics is the test bed**, not the
> prose below. Run it end-to-end:
>
> ```bash
> cd test/demo-testbed && ./run-all.sh          # DEMO (public console + Examples + Langfuse)
> cd test/enterprise-testbed && ./run-all.sh    # ENTERPRISE (no public console, agents in-VPC)
> # add --yes for unattended; tear down with ./99-teardown.sh in the same dir
> ```
>
> The test bed's numbered scripts are the authoritative commands (they carry the
> current flags, image tags, and ordering); `run-all.sh` runs them in order and
> stops on first failure. **Steps 0–8 below are the annotated/manual equivalent**
> — read them to understand *what* each script does and *why*, but treat the
> scripts as the up-to-date "how." The two test beds cannot coexist in one account
> (one shared Terraform state); run sequentially or use separate accounts.

**Which test-bed script maps to which step:**

| Test-bed script (`test/demo-testbed/scripts/`) | Runbook step | Does |
|---|---|---|
| `01-check-prereqs.sh` | Prerequisites | Verifies aws/terraform/node/docker/jq + creds |
| `00-seed-images.sh` | Step 0 + Step 1 | Bootstraps state + ECR repos, seeds base + ADE images (idempotent) |
| `02-deploy-platform.sh` | Step 2 | `terraform apply -var-file=configs/demo.tfvars -var studio_build_image=false` (+ examples-backend + ADE-backend build) |
| `03-validate.sh` | Step 7 | Asserts console present, agents in-VPC, Langfuse on |
| `04-seed-repos.sh` | Steps 3–4 | Seeds `users/team-bu-1` → CodeCommit → triggers the deploy pipeline |
| `05-monitor-pipeline.sh` | Step 5 | Watches `team-bu-1-deploy-pipeline` to a terminal state |
| `06-invoke-agent.sh` | Step 8 | Headless smoke test of the deployed agents (all patterns) |
| `07-validate-console.sh` | Step 6 | Console edge + ALB origin-lockdown smoke test (ADR-037/038) |
| `98-predestroy.sh` / `99-teardown.sh` | Teardown | Removes pipeline-created runtimes + empties ECR, then `terraform destroy` |

> Seeding Cognito users (Step 2.5) is still manual — Terraform does not create
> user identities (see that step). Everything else in Steps 0–8 is what the
> scripts above automate.

## Step 0 — Bootstrap ECR Repositories

ECR repos must exist before the base/agent images can be pushed (Step 1), so front-load just that module from the **root** state — no separate state:

```bash
cd platform/eap-platform

# The state bucket is account-scoped (S3 names are globally unique). Bootstrap
# it first (creates eap-platform-state-<ACCOUNT_ID> + the lock table) and
# pass the name to init. bootstrap.sh prints this exact command.
# CMK (ADR-035, optional): export TF_STATE_KMS_KEY_ARN=<arn> BEFORE this to
# encrypt the state bucket with a customer-managed key (must be set at create
# time — S3 SSE is not retroactive). Omit for the AWS-managed aws/s3 key.
./bootstrap.sh
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init -backend-config="bucket=eap-platform-state-${ACCOUNT_ID}"

terraform apply -target=module.ecr

# Capture URLs from the root outputs
ECR_REPO_URL=$(terraform output -raw ecr_repository_url)
BASE_IMAGE_ECR_URL=$(terraform output -raw ecr_base_image_repository_url)

echo "Agent ECR:      $ECR_REPO_URL"
echo "Base Image ECR: $BASE_IMAGE_ECR_URL"
```

## Step 1 — Seed Container Images (clean-account bootstrap)

AgentCore Runtime can only pull images from ECR, and Terraform creates the ECR
*repos* (Step 0) but not the *images*. On a brand-new account both repos start
empty, so seed two images once — in this order (the ADE image builds `FROM` the
base image). This seeds the ADE **runtime** image so the platform apply can run
with `studio_build_image=false`. (The apply still builds a couple of other
images itself — the demo console/examples-backend and the ADR-040 ADE
streaming-backend — so Docker is also needed at apply time; see Step 2.)

**1a. Base image** — the strands runtime base:

```bash
cd platform/eap-terraform-modules/base-images/strands
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $BASE_IMAGE_ECR_URL
# Default upstream is python:3.12-slim on Amazon ECR Public. For a locked-down / no-egress
# account, point --build-arg BASE_IMAGE at your org-approved (golden) base:
#   docker build --platform linux/arm64 \
#     --build-arg BASE_IMAGE=<your-registry>/<approved-python-3.12> \
#     -t $BASE_IMAGE_ECR_URL:latest .
docker build --platform linux/arm64 -t $BASE_IMAGE_ECR_URL:latest .
docker push $BASE_IMAGE_ECR_URL:latest
```

> **Base image source (customer customization — not a platform gap).** This base
> image is **built locally at deploy time**, so the customer controls what it is
> built from. The Dockerfile's upstream is parameterized —
> `ARG BASE_IMAGE=public.ecr.aws/docker/library/python:3.12-slim` (Amazon ECR Public) by default. In a
> locked-down / no-egress account, pass
> `--build-arg BASE_IMAGE=<your-approved-image>` (e.g. from your internal
> registry) to rebuild on your **organization-approved (golden) base** — no
> Dockerfile edit needed. Every agent image inherits from this base (agent
> Dockerfiles use `FROM ${BASE_IMAGE_URI}`), so approving the base covers the
> whole fleet. No public image is pulled at runtime — only at this one
> build step, which you own.

**1b. Agent Deployment Engineer (ADE) image** — the platform-owned agent, built
on top of the base image. Pass the tag `module.studio` looks up:

```bash
cd platform/eap-platform/studio
AWS_REGION=us-east-1 ./build-and-push.sh agent-builder-studio-latest
```

`build-and-push.sh` logs in to ECR, pulls the base image, builds `studio/app/`
on top of it, and pushes to the agent repo. With both images seeded, the Step 2
apply runs Docker-free (`studio_build_image=false`).

## Step 2 — Deploy Platform

A single `terraform apply` provisions the whole platform. Most inputs have
sensible defaults (domains, source repos, pipelines, model id).

### Choose a deployment preset

The platform ships **two** preset `.tfvars` files under
[`configs/`](eap-platform/configs/) — `demo` (show it works) and
`enterprise` (hardened, no public ingress). This supersedes the former three
presets: "POC" and "Pilot" are now **maturity stages of the `enterprise`
preset**, reached by uncommenting its OVERRIDE blocks (ADR-036). Pick a preset,
pass it with `-var-file`. All variables have defaults, so Terraform never
prompts interactively — a bare `apply` (no `-var-file`) is the `demo` posture.

| Preset | Public console (`deploy_console`) | Agent traffic (`agent_network_mode`) | VPC (`vpc_id`) | Observability (`deploy_langfuse` / `otel_backend_endpoint`) | Identity (`oidc_discovery_url`) | IAM roles (`*_role_arn`) | KMS (`kms_key_arn`) | Public endpoints |
|---|---|---|---|---|---|---|---|---|
| **`demo`** | `true` — demo console on public CloudFront | `"VPC"` (default; not overridden) — agents run in the platform-created VPC's private subnets | `""` — platform creates a VPC that hosts **both agents and the observability leg** | `true` / `""` — self-hosted Langfuse (private, in that VPC) | `""` — Cognito (reference IdP) | `""` — AWS-managed | Console + Cognito hosted UI |
| **`enterprise`** (base) | `false` — no public console (BYO UI internal) | `"VPC"` — agents run in the VPC's private subnets | `""` — platform **creates** the VPC and runs agents in it (or *import* your own via override) | `false` / `""` — AWS-native CloudWatch/X-Ray only (Langfuse off; override to turn on or ship to your OTLP backend) | `""` — Cognito (reference IdP, as-is pending EA approval) | `""` — platform-created (or BYO via override) | `""` — AWS-managed (or CMK via override) | Cognito hosted UI only |

`""`/`[]` = leave default · *import*/*set* = deployer supplies the value (via an OVERRIDE block in `enterprise.tfvars`) · the last column is an outcome, not a flag · `enable_transaction_search=false` in `enterprise` (`true` in `demo`); the AWS-native CloudWatch/X-Ray leg is always on regardless.

- **`demo`** — show it works. In-VPC agents (VPC default, same as enterprise), public console, Cognito, private Langfuse. No deployer inputs required; a bare `apply` yields this.
- **`enterprise`** — prove/run it inside the enterprise network. Agents in-VPC, no public console, AWS-native observability. **Self-contained by default** (platform creates the VPC + IAM roles + uses Cognito), so it is runnable in your own account with no bring-your-own inputs — this is the former "POC" stage, using the reference components **as-is pending Enterprise Architecture approval**.

> **Maturity ladder within `enterprise` (the former "pilot" stage).** Advance from the reference stage by uncommenting the OVERRIDE blocks in `enterprise.tfvars`: import your VPC (`vpc_id` + subnets), swap in your external OIDC IdP (`oidc_discovery_url` → removes Cognito), ship telemetry to your own OTLP backend (`otel_backend_endpoint`, keep Langfuse off), use a customer-managed KMS key (`kms_key_arn`), and externalize the 5 standalone IAM roles (pre-created from [`docs/iam/`](../docs/iam/README.md)). Filling all of these in yields **zero public ingress** with fully enterprise-approved components.

### Apply

Because the ADE **runtime** image was seeded in Step 1, pass
`studio_build_image=false` so the apply does not rebuild it. Note this is not a
fully Docker-free apply in **demo**: the console SPA is built (`npm run build`)
and the **examples-backend** (ADR-037) and **ADE streaming-backend** (ADR-040)
container images are built + pushed during `apply`, so Node/npm and a running
Docker daemon must be present on the deploy host. In **enterprise**
(`deploy_console=false`) the console/examples stack is skipped; the ADE backend
still builds (it is in both presets).

```bash
cd platform/eap-platform
# Already initialized in Step 0? A bare `terraform init` reuses the cached
# backend config. From a clean checkout, pass the account-scoped bucket:
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init -backend-config="bucket=eap-platform-state-${ACCOUNT_ID}"

# Pick a preset (demo | enterprise) — two presets since ADR-036. `enterprise`
# is the hardened base (console off, agents in-VPC, Langfuse off); advance it
# toward the former "pilot" posture by uncommenting its OVERRIDE blocks
# (bring-your-own VPC / external OIDC / external OTLP / CMK / roles).
terraform apply -var-file=configs/enterprise.tfvars -var 'studio_build_image=false'
# Or, for the default public demo, no -var-file is needed:
# terraform apply -var 'studio_build_image=false'
```

This brings up, in one pass:

- **Identity** — Cognito User Pool, resource server, console app client
- **Domains** — per-domain Cognito group + IAM permission boundary
- **Bedrock model access** — IAM for `us.anthropic.claude-sonnet-5`
- **Source repos** — CodeCommit repos (`team-bu-1`, `mcp-integrations`, `governance`) + fail-open Conventional Commits validation
- **Pipelines** — per-domain agent + integration CodePipelines
- **Gateway** — shared AgentCore Gateway (MCP) + policy engine
- **Governance / QA / KB pipelines** — Cedar, evaluation, and Knowledge Base pipelines
- **Agent Deployment Engineer (`module.studio`)** — platform-owned agent, runtime provisioned from the ADE image seeded in Step 1b
- **Invoke proxy + studio-read** — API Gateway + Lambda backing the console Build chat
- **Console** — S3 + CloudFront unified console (see Step 6)
- **Lifecycle store** — DynamoDB, single source of truth for deployed-agent state

Capture key outputs:

```bash
COGNITO_POOL_ID=$(terraform output -raw cognito_user_pool_id)
PIPELINE_NAME=$(terraform output -json pipeline_names | jq -r '.["a2a-demo"]')

echo "Cognito Pool ID: $COGNITO_POOL_ID"
echo "Pipeline:        $PIPELINE_NAME"
```

### Agent network posture (VPC by default — ADR-031)

By default (`agent_network_mode = "VPC"`) every AgentCore agent runtime — the
platform-owned ADE agent and every pipeline-deployed app-team agent — runs
**inside the resolved VPC** (private-subnet ENIs), and the managed AgentCore APIs
(Gateway, Memory, Identity) are reached over **PrivateLink**. The platform's
**Lambdas** also run in-VPC in this mode (ADR-032) — `invoke_proxy` /
`invoke_bridge` (agent invocation), `studio_read`, and `commit_validation` — each
in a dedicated egress-only Lambda security group. The platform provisions the
interface endpoints (AgentCore data/control/gateway, ECR api+dkr, CloudWatch
Logs + `monitoring`, CodePipeline, CodeCommit API + Git, SSM, `execute-api`) and
the S3 + DynamoDB **gateway** endpoints, so the whole agent + Lambda path stays
inside the enterprise boundary — no public egress required.

VPC mode takes effect only when a VPC is resolvable (imported `vpc_id`, or the
platform-created VPC). If VPC is requested but none resolves, the apply prints a
`check` warning and falls back to public endpoints; confirm the actual posture:

```bash
terraform output agent_network_posture   # "VPC" or "PUBLIC"
terraform output agent_network_vpc_id     # the VPC agents run in (empty if PUBLIC)
```

**VPC-mode prerequisites (read before deploying VPC mode):**

- **AgentCore-supported AZs.** The private subnets you run agents in **must** sit
  in AgentCore-supported Availability Zones (by AZ **ID**) for the region, or
  AgentCore resource creation fails. This cannot be validated at plan time.
  Check with:
  `aws ec2 describe-subnets --subnet-ids <id> --query 'Subnets[0].AvailabilityZoneId'`
  and cross-reference the AgentCore VPC docs' supported-AZ table. The
  platform-created VPC's default AZs (`us-east-1a`/`us-east-1b`) may need
  overriding to land on supported AZ IDs in your account.
- **Egress for image pulls.** VPC-mode agents pull their container image from ECR
  and need a path out — the platform-created VPC provides NAT egress. An imported
  VPC's private subnets **must** have egress via NAT and/or the ECR/S3/logs VPC
  endpoints.
- **Imported-VPC gateway-endpoint gap.** The **interface** endpoints (AgentCore,
  ECR, Logs, CodePipeline, CodeCommit, SSM, monitoring, execute-api) attach to
  subnets and are created for **both** created and imported VPCs. The **gateway**
  endpoints (**S3** for ECR image layers, **DynamoDB** for the Lambda
  lifecycle-table reads) associate to route tables, which the platform only owns
  for a VPC it created — so for an **imported** VPC it does **not** create them.
  You are responsible for S3 + DynamoDB reachability (a gateway endpoint — free,
  or NAT) in your VPC. For a platform-**created** VPC these are provisioned for
  you.
- **Both presets run agents in-VPC.** `agent_network_mode` defaults to `"VPC"`
  and **neither `demo` nor `enterprise` overrides it** — agents always attach
  ENIs to the resolved VPC's private subnets. This is required for agents to
  reach in-VPC platform services (notably the OTel collector, whose Cloud Map
  private DNS only resolves in-VPC; a public agent cannot resolve it and stalls
  on failed telemetry export). Supply your own agent-ENI security groups with
  `-var 'agent_security_group_ids=["sg-…"]'` if you don't want the platform's.
- **PUBLIC agent mode is deprecated.** `-var 'agent_network_mode=PUBLIC'` still
  exists as the pre-ADR-031 escape hatch, but it is **not recommended** (public
  agents can't reach in-VPC services) and is slated for removal so VPC is the
  only posture — see ADR-031.

> **FinOps note.** VPC mode adds hourly per-AZ charges for the interface
> endpoints (12 services: AgentCore data/control/gateway, ECR api+dkr, Logs,
> monitoring, CodePipeline, CodeCommit API + Git, SSM, execute-api) plus data
> processing; the S3 and DynamoDB gateway endpoints are free. PUBLIC mode creates
> none of these. See the FinOps section.

### Step 2.5 — Create Cognito users (manual — not auto-created)

> **Option A (platform-managed Cognito) only.** Skip this step if you supplied an
> external `oidc_discovery_url` (Option B) — no Cognito pool is created; manage users
> in your own IdP instead.

**Cognito users are NOT created by Terraform.** The user pool is provisioned with `allow_admin_create_user_only = true` (self-signup disabled), and the stack creates only the **pool, app clients, resource servers, and the `team-bu-1` user group** — no user identities. You must seed at least:

- a **console admin** (to log into the unified console — Steps 6 and 8).

The `console-admin` account referenced in `platform/console/LOGIN.md` is an example that was created this way — it is not recreated by an apply.

```bash
cd platform/eap-platform
POOL_ID=$(terraform output -raw cognito_user_pool_id)

# 1. Console admin
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username console-admin \
  --message-action SUPPRESS \
  --region us-east-1

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username console-admin \
  --password '<STRONG_PASSWORD>' \
  --permanent \
  --region us-east-1

# 2. (Optional) a domain-scoped user — only if you need one carrying the team-bu-1 group claim
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" --username testuser --message-action SUPPRESS --region us-east-1
aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" --username testuser --password '<STRONG_PASSWORD>' --permanent --region us-east-1
aws cognito-idp admin-add-user-to-group \
  --user-pool-id "$POOL_ID" --username testuser --group-name team-bu-1 --region us-east-1
```

> `--message-action SUPPRESS` + `admin-set-user-password --permanent` sets a ready-to-use password with no email/verification step (the pool has no SES email configured). Store these credentials in your secrets manager — do not commit real passwords. Group membership (`team-bu-1`) is only needed for users who must carry the domain claim; a console-only admin may not need it.

## Step 3 — Verify Git Remote (team-bu-1 → CodeCommit)

Confirm the app team repo is mapped to the CodeCommit repo created in Step 2.

```bash
cd users/team-bu-1
git remote -v
# Expected:
# origin  codecommit::us-east-1://team-bu-1 (fetch)
# origin  codecommit::us-east-1://team-bu-1 (push)

# If no remote exists:
git init
git remote add origin codecommit::us-east-1://team-bu-1
# If it points elsewhere:
# git remote set-url origin codecommit::us-east-1://team-bu-1
```

Requires `git-remote-codecommit` (`pip install git-remote-codecommit`).

## Step 4 — Push Agent Code (team-bu-1)

Push the app team repo to CodeCommit. This triggers the pipeline.

```bash
cd users/team-bu-1
git add .
git commit -m "feat: deploy agents"
git push -u origin main
```

Use `--force` on fresh deploys where the CodeCommit repo is empty and the local
branch has history from a previous deploy.

The pipeline executes: Source → Build (ARM64 Docker + ECR push) → Deploy
(`yamldecode` of each `agent.yaml` → `terraform apply` via the runtime module) →
Verify.

## Step 4.5 — Seed the Knowledge Base repo (kb-team-bu-1-deploy)

> ## ⛔ DO NOT EXECUTE — descoped for now (known issue)
>
> **Skip this entire step.** The `kb-deploy` deploy-template (`eap-terraform-modules/deploy-templates/kb-deploy/main.tf`)
> has Terraform config that the pinned AWS provider does not support, so the
> `kb-team-bu-1-deploy` pipeline **fails at the Plan stage** even if the repo is seeded:
> - `aws_bedrockagent_data_source` — unsupported `dynamic "url"` block (line ~229) and
>   missing required argument in `source_configuration` (line ~262)
> - `aws_bedrockagentcore_gateway_target` — unsupported `smithy_model_endpoint` argument (line ~303)
> - `aws_bedrockagentcore_policy_engine_policy` — **invalid resource type** (does not exist in the provider) (line ~311)
>
> Knowledge Base provisioning is **out of scope** until the template is reconciled
> with the AWS provider schema (tracked as a separate follow-up — do NOT attempt as
> part of this runbook run). The rest of the platform (agents, console)
> does not depend on the KB, so the deploy test proceeds without it. Leave the
> `knowledge-bases-team-bu-1` repo unseeded; its pipeline will simply
> sit idle (Source fails on the empty repo, which is expected and harmless).

Terraform creates the `knowledge-bases-team-bu-1` CodeCommit repo but
**not its content or `main` branch**. Until it is seeded, the `kb-team-bu-1-deploy`
pipeline's Source stage fails (no branch to pull). Seed a baseline KB — the
in-repo working copy lives at `users/knowledge-bases-team-bu-1/`.

Each subdirectory with a `kb.yaml` is provisioned as one Bedrock Knowledge Base
(the Validate stage schema-checks `kb.yaml` + `data-sources.yaml`; Plan/Apply run
the `kb-deploy` template). Minimal layout:

```
knowledge-bases-team-bu-1/
  team-bu-1-docs/
    kb.yaml            # name, description, embedding_model, chunking_strategy.type, sync_schedule
    data-sources.yaml  # non-empty data_sources[] (e.g. an s3 source with create_bucket: true)
```

Push it to `main` (creates the branch and triggers the pipeline):

```bash
cd users/knowledge-bases-team-bu-1
git init -b main                                   # if not already a repo
git remote add origin codecommit::us-east-1://knowledge-bases-team-bu-1
git add .
git commit -m "feat: seed baseline team-bu-1 knowledge base"
git push -u origin main
```

> The `kb-*` CodeBuild stages run on the `eap-terraform` image, which ships
> Terraform only — the buildspecs `pip install awscli` at runtime because they use
> `aws s3 cp` (fetch scripts/template) and `aws bedrock-agent` (trigger sync). If
> you fork the image, either bake in the AWS CLI or keep that install line.

Pipeline stages: `Source → Validate → Plan → Apply`.

## Step 5 — Monitor Pipeline

```bash
aws codepipeline get-pipeline-state \
  --name $PIPELINE_NAME \
  --region us-east-1 | jq '.stageStates[] | {stage: .stageName, status: .latestExecution.status}'
```

Build stage logs:

```bash
aws codebuild batch-get-builds \
  --ids $(aws codepipeline get-pipeline-state --name $PIPELINE_NAME --region us-east-1 | \
    jq -r '.stageStates[] | select(.stageName=="Build") | .actionStates[0].latestExecution.externalExecutionId') \
  --region us-east-1 | jq '.builds[0].logs.deepLink'
```

## Step 6 — Console Access

The bundled demo console (S3 + CloudFront) comes up as part of the platform
apply **when `deploy_console = true`** (the default). Its navigation is grouped
into the four platform pillars — **Build · Govern · Run · Evolve**. The
`null_resource.console_deploy` step rebuilds the SPA, syncs to S3, and
invalidates CloudFront on every apply.

> **Enterprise / no-public-access installs (ADR-034):** set
> `deploy_console = false`. The bundled console, its `invoke-proxy` API Gateways,
> and the `studio-read` routes are a single stack that exists **only** to serve
> this public CloudFront UI — they are the platform's entire public ingress.
> Setting the flag to `false` removes all of them (CloudFront, the S3 SPA bucket,
> both API Gateways, both Lambdas, and their IAM), leaving **zero public
> ingress**. Host your own UI internally (BYO UI) and reach agents over the
> in-VPC path (ADR-031/032). If a BYO UI on a different origin must call a
> still-deployed `invoke-proxy` cross-origin, set `console_cors_origins` to that
> origin (default `[]` = no CORS, correct for the same-origin demo). Leave
> `deploy_console = true` for the out-of-the-box demo. The rest of Step 6 applies
> only when the console is deployed.

```bash
# Console URL
cd platform/eap-platform
terraform output -raw console_url 2>/dev/null || \
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Origins.Items[].Id, 's3-console')].DomainName" \
    --output text
```

Login credentials and the Cognito flow are documented in
`platform/console/LOGIN.md`. **You must have created a console user first (Step 2.5)** — Terraform does not seed users. After a deploy, hard-refresh the browser
(Cmd+Shift+R) once the CloudFront invalidation completes (~1–2 min).

### Redeploy just the console

The console deploy re-runs on every apply (timestamp trigger). To redeploy only
the console (rebuild SPA + S3 sync + CloudFront invalidation) without touching
the rest of the platform:

```bash
cd platform/eap-platform
# module.console is count-gated by deploy_console (ADR-034), so target the [0] instance.
terraform apply -target='module.console[0]' -var 'studio_build_image=false'
```

## Step 7 — Verify Deployment

```bash
# List deployed agent runtimes (app agents + the Agent Deployment Engineer)
aws bedrock-agentcore list-agent-runtimes --region us-east-1

# Check a runtime's status
aws bedrock-agentcore get-agent-runtime \
  --agent-runtime-id <runtime-id> \
  --region us-east-1 | jq '{name: .agentRuntimeName, status: .status}'
```

## Step 8 — Validate Running Agents with the Console

Beyond the CLI checks in Step 7, the bundled **console** (`deploy_console = true`, the default) exercises deployed agents end-to-end (browser → Cognito auth → invoke-proxy/ADE streaming backend/AgentCore → agent → LLM). Use it to smoke-test each orchestration pattern after a deploy — it replaces the per-pattern local dev UIs the repo previously shipped.

### What the console validates by pattern

The console's **Examples** surface (demo preset) renders one card per agent pattern, each resolving its target live from the lifecycle table (see "Demo Console: Examples surface" below). Launching a card confirms that pattern end-to-end:

| Pattern | Backs the agent | Confirms |
|---|---|---|
| Standalone | `team-bu-1/standalone/aws-architect-agent` | Runtime reachable, auth works, model responds (streaming) |
| Standalone (ADE) | Agent Deployment Engineer (`module.studio`) | The ADE Build workspace / streaming `/ade-api` path |
| Supervisor (Step Functions) | `orchestration/supervisor/rrf-search-app` | Orchestration + multi-agent fan-out (RRF fusion) |
| Sequential (Step Functions) | sequential-workflow app | Linear hand-off between stages |
| Swarm (A2A choreography) | `choreography/swarm/research-swarm` | Default-deny A2A auth + peer routing |

### Authentication

The console authenticates through **Cognito** — the same identity the platform provisions. **A console user must exist first (Step 2.5)** — it is not auto-created. The `console-admin` example account (see `platform/console/LOGIN.md`) is created this way. Scopes requested include `openid gateway/tools.invoke`.

### Quick validation flow

1. Confirm the runtime is `READY` (Step 7: `get-agent-runtime`).
2. Open the console CloudFront URL (`terraform output console_url`) and log in via Cognito.
3. On the **Examples** surface, launch the card matching the pattern you deployed (cards auto-flip Not deployed → Deploying → Ready as the `team-bu-1` pipeline completes).
4. Send a prompt; confirm a streamed response and (optionally) watch traces on the CloudWatch **GenAI Observability** page.

## Observability (private + pluggable — ADR-030)

Two independent legs. The **AWS-native leg** (always on) needs no VPC; the
**third-party leg** (private, in-VPC) is where the OTel collector + optional
Langfuse live.

### AWS-native leg (always on)

CloudWatch GenAI Observability + X-Ray, populated by AgentCore
auto-instrumentation. Works out of the box:

- `enable_transaction_search = true` (default) turns on CloudWatch/X-Ray
  Transaction Search (account + region singleton) so spans/traces are searchable
  on the CloudWatch GenAI Observability page.
- `transaction_search_indexing_percentage = 5` (default) controls how many spans
  are indexed as queryable trace summaries (ingestion is billed on all spans
  regardless; the first 1% is indexed free).

No VPC required for this leg.

### Third-party leg (private, in-VPC)

The **OTel collector is always deployed** in-VPC and fans a copy of agent spans
out to a backend. Fully private — no public endpoints, no CloudFront, no ACM.
Choose the backend by config:

| Variable | Default | Effect |
|---|---|---|
| `deploy_langfuse` | `true` | Deploy self-hosted **Langfuse** (private internal HTTP ALB) as the default backend. |
| `otel_backend_endpoint` | `""` | External OTLP backend (Datadog/Fiddler/…). When set, combined with Langfuse per `otel_backend_mode`. |
| `otel_backend_auth_secret_arn` | `""` | Secrets Manager ARN of the external backend's auth header/token. |
| `otel_backend_mode` | `add` | `add` = fan out to Langfuse **and** external; `replace` = external instead of Langfuse. |

Resolution: `deploy_langfuse=true` + no external ⇒ Langfuse only · `+ external` ⇒
both (`add`) or external only (`replace`) · `deploy_langfuse=false` + external ⇒
external only · `deploy_langfuse=false` + none ⇒ collector up, leg dormant.

**Langfuse access is network-scoped:** the internal ALB (HTTP) is reachable only
from within the VPC (VPN/corp network) plus Langfuse's own app login — there is
no ALB-level SSO in the private model. The console's embedded-Langfuse view
therefore only loads for on-network users (interim gap). AWS-native CloudWatch panels always
work.

### VPC — import or create

The third-party leg runs in-VPC:

- **Create (default):** leave `vpc_id = ""` and the platform creates a VPC with
  full egress (Internet Gateway + NAT gateway + private route tables).
- **Import:** set `vpc_id` **and** `private_subnet_ids` **and**
  `public_subnet_ids` explicitly (not inferred). The supplied **private subnets
  MUST have egress** to ECR + AWS APIs (via NAT or VPC endpoints) or the
  collector/Langfuse Fargate tasks will fail to pull images.

> **FinOps note:** because the collector (and, by default, Langfuse) are always
> on, the default deploy carries standing infrastructure — a VPC + NAT gateway +
> the collector Fargate task, and (with `deploy_langfuse=true`) the Langfuse
> datastores (Aurora Serverless v2 + ClickHouse-on-Fargate + Redis). This is a
> deliberate batteries-included choice and higher than the storage-only idle
> baseline. Set `deploy_langfuse=false` and/or use an external backend to reduce
> it; import a VPC to avoid a second NAT.

## Teardown

Single root, single destroy — ECR is a child module, so it tears down with everything else:

```bash
cd platform/eap-platform
# ALBs have deletion protection on by default; turn it off on the ALBs first.
terraform apply -var alb_deletion_protection=false \
  $(terraform state list | grep -E '\.aws_lb\.[a-z_]+(\[[0-9]+\])?$' | sed 's/^/-target=/')
terraform destroy -var alb_deletion_protection=false
```

> `terraform destroy` is destructive and removes live resources. Empty the
> console S3 bucket first if the destroy fails on a non-empty bucket. The
> Terraform state backend (`eap-platform-state-<ACCOUNT_ID>` S3 bucket + lock table)
> is an external bootstrap resource and is not destroyed by this command.

> **⚠️ `terraform destroy` does NOT remove pipeline-deployed agent runtimes —
> and that is by design.** The root state (`platform/terraform.tfstate`) only
> manages resources declared in the root module — including the **ADE / Agent
> Deployment Engineer** runtime (`module.studio.module.runtime`), which *is*
> destroyed. But the **app-team AgentCore runtimes** (e.g. `team-bu-1`'s agents,
> `nocode-user`'s deployed apps) are created by each deploy pipeline's
> CodeBuild against a **separate**, pipeline-owned Terraform state —
> `s3://<domain>-<name>-pipeline-artifacts-<ACCOUNT_ID>/_tfstate/deploy.tfstate` (e.g.
> `team-bu-1-a2a-demo-pipeline-artifacts-<ACCOUNT_ID>`).
>
> This separation is intentional: the **platform operator is deliberately NOT
> granted account-wide `bedrock-agentcore:Delete*` ("god mode")**. Each BU's
> agents are owned — and torn down — by that BU's own pipeline role, preserving
> least-privilege and per-BU blast radius. The operator tears down the platform;
> teams tear down their own agents.
>
> **Correct teardown order (federated, no god privileges):**
>
> 1. **Each app team destroys its own agents first** — via that team's deploy
>    pipeline / its scoped role, running `terraform destroy` against the
>    pipeline's own state (`bucket=<domain>-<name>-pipeline-artifacts-<ACCOUNT_ID>`,
>    `key=_tfstate/deploy.tfstate`). This uses the pipeline's existing
>    per-BU permissions — no broad grant to the operator.
> 2. **Then the platform operator runs the root `terraform destroy`** (below),
>    which removes the ADE/studio runtime and all shared platform resources.
>
> Do **not** invert this order: a root destroy first deletes each pipeline **and
> its artifacts bucket** (which holds that `deploy.tfstate`), which would strand
> the app runtimes with no state left to destroy them cleanly — and recovering
> from that is exactly the scenario least-privilege is meant to avoid. If runtimes
> are ever orphaned, clean them up with a principal scoped to that BU (the
> pipeline role), not a blanket account admin.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `terraform validate` fails on `aws_bedrockagentcore_*` | Ensure AWS provider >= 6.37.0 |
| `ExpiredToken` on `terraform init`/`plan`/`apply` | Re-authenticate with your SSO or credential helper (e.g. `aws sso login`) |
| Pipeline Source stage fails | Verify CodeCommit repo exists (`terraform output source_repository_clone_urls`) |
| Build stage fails | Check base image exists: `aws ecr describe-images --repository-name eap-agents-base-strands` |
| Deploy stage fails on yamldecode | Verify `agent.yaml` files exist in the agent directories |
| AgentCore Runtime stuck in CREATING | Check IAM role trust policy includes `bedrock-agentcore.amazonaws.com` |
| ADE runtime not updating after image rebuild | Rebuild+push, then `terraform apply -target=module.studio` (digest change rolls the runtime) |
| Console shows stale UI after deploy | Wait for CloudFront invalidation, then hard-refresh (Cmd+Shift+R) |
| Console apply wants Docker but image is in ECR | Pass `-var 'studio_build_image=false'` for a Docker-free apply |
| Console "Sign in" → **"An error was encountered with the requested page"** | Cognito callback/CORS points at a stale CloudFront domain (see note below) — sync the app client + invoke-proxy CORS to the live distribution domain and re-apply |
| JWT authorizer rejects valid token | Verify `discovery_url` matches Cognito pool region and ID |
| 401 on A2A call | Check `allowed_clients` includes the caller's Cognito client ID |
| `ValidationException: model identifier is invalid` | Use the cross-region inference profile id `us.anthropic.claude-sonnet-5`, not the bare model id |

### Known issue — Cognito callback / CORS pinned to a stale CloudFront domain

The console CloudFront distribution gets a **new random `dXXXX.cloudfront.net` domain on every clean (re)deploy**, but the Cognito app-client `callback_urls`/`logout_urls` (`identity/main.tf`) are still built from `console_url` and can lag the live distribution. After a fresh deploy the hosted UI may reject the sign-in redirect ("An error was encountered with the requested page") because the callback allow-list names the previous deploy's domain.

> **CORS is no longer part of this issue (ADR-034).** The invoke-proxy HTTP API no longer hardcodes a CloudFront origin — CORS is driven by `console_cors_origins` (default `[]`). The demo console is served **same-origin** via CloudFront, so it needs no CORS at all and cannot go stale. Only set `console_cors_origins` for a cross-origin BYO UI.

> The SPA itself is fine: it derives `VITE_REDIRECT_URI` from the live distribution at build time. Only the Cognito callback allow-list can go stale.

**Unblock (sync both allow-lists to the live domain, then re-apply):**

```bash
cd platform/eap-platform

# 1. Discover the current console CloudFront domain
CONSOLE_DOMAIN=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Origins.Items[].Id, 's3-console')].DomainName" \
  --output text)
echo "Console domain: $CONSOLE_DOMAIN"

# 2. Point console_url at the live domain (drives the Cognito callback/logout URLs):
#    - set -var "console_url=https://$CONSOLE_DOMAIN" on the apply below, or
#    - edit identity/main.tf's aws_cognito_user_pool_client.console callback_urls + logout_urls.
#    (CORS no longer needs editing — see the ADR-034 note above.)

# 3. Re-apply just the identity module (Docker-free)
terraform apply -target=module.identity \
  -var "console_url=https://$CONSOLE_DOMAIN" \
  -var 'studio_build_image=false'
```

Then hard-refresh the console (Cmd+Shift+R) after the CloudFront invalidation settles and sign in again.

> **Durable fix (TODO — not yet implemented):** stop hardcoding the Cognito callback domain. Options, in order of preference: **(A)** put a stable custom domain (Route 53 + ACM) on the distribution and reference it everywhere; **(B)** post-apply sync via a `null_resource` in the console module (`aws cognito-idp update-user-pool-client`) plus `lifecycle { ignore_changes }` on the identity client; **(C)** a two-pass `console_domain` variable (first apply creates the distribution, capture `console_url`, set the var, re-apply). A/B give a single-apply clean deploy; C is pure-Terraform but requires two passes. (The invoke-proxy CORS half of this is already fixed via `console_cors_origins` — ADR-034.)

### Known issue — Strands version unpinned in the base image (A2AServer + session_manager crash)

The base image (`eap-terraform-modules/base-images/strands/requirements-base.txt`) originally
pinned Strands loosely (`strands-agents[a2a]>=0.1.0`). Any base-image rebuild pulled the **latest**
Strands, and newer Strands (1.4x+) changed the `A2AServer` contract to **reject a single `agent` that
carries a `session_manager`** — it now requires the `agent_factory` pattern. Because the Studio/ADE
agent attaches an AgentCore Memory `session_manager`, the container **crash-loops on startup**:

```
strands/multiagent/a2a/executor.py:151
ValueError: A single 'agent' with a session_manager is not supported ...
Use 'agent_factory' to build a per-context agent with its own session_manager.
```

Symptom at the client: invoke returns `AgentCore 424 / -32055 "Runtime client error"` (or the console
UI "takes too long", since invoke-proxy aborts at `INVOKE_TIMEOUT_MS`).

**Current mitigation (applied):** the framework deps are pinned to the repo-initiation-era stack
(2026-03-20), which predates the breaking change and still supports `A2AServer(agent=, session_manager=)`:

```
strands-agents[a2a]==1.32.0
strands-agents-tools==0.2.23
bedrock-agentcore[strands-agents]==1.4.7   # ships memory/integrations/strands; requires strands>=1.1.0
```

> **Durable fix (TODO — not yet implemented):** migrate `base-images/strands/entrypoint.py`
> `create_app()` to the **`agent_factory` pattern** so the A2AServer builds a per-context agent with its
> own `session_manager`, then unpin (or widen) the Strands versions. This keeps memory AND stays
> forward-compatible with current/future Strands. Until then, do **not** bump the three pins above
> without doing the `agent_factory` migration in the same change (bump them together, and re-test the
> ADE boot: `Uvicorn running on http://0.0.0.0:9000` with no `ValueError` in the runtime `-DEFAULT` log
> group).

## Demo Console: Examples surface + GenAI Observability (ADR-037, ADR-038)

The demo preset's console (`deploy_console = true`) includes an **Examples**
surface — an exec-facing gallery of the platform's agent patterns — and embeds
the **Langfuse** UI as "GenAI Observability". Both are served through one
hardened CloudFront distribution.

### What gets deployed (demo preset only)

- **`examples-console` module** — a generic **ECS Fargate** signer backend
  (`platform/examples-backend`, built + pushed to ECR at apply) behind an
  **ALB**, plus a **WAF** WebACL. The ALB is internet-facing but reachable
  **only through CloudFront** (CloudFront origin-facing prefix list + a secret
  origin header). It exposes `/examples-api/*`:
  `invoke` (SigV4 AgentCore A2A), `sfn/start`, `sfn/status`, `sfn/history`,
  `logs`. Every route requires the signed-in user's Cognito JWT (signature
  verified) and only accepts runtimes / state machines recorded in the
  lifecycle table (ADR-046).
- **Console CloudFront (C2)** — the existing console distribution gains two
  locked-down origins: the examples ALB (`/examples-api/*`) and the Langfuse
  ALB (`/langfuse/*`), and the WAF is attached. S3 still serves the SPA assets.
- **Langfuse public-via-edge (ADR-038)** — in the demo path the Langfuse ALB
  is made CloudFront-facing (`enable_cloudfront_origin = true`), so its UI is
  embedded same-origin at `/langfuse/` and renders for public viewers without a
  VPN. Outside the demo path Langfuse stays fully private (ADR-030 unchanged).

### The Examples gallery reflects what is actually deployed (Behavior A)

The gallery is always visible, but each card resolves its target from the
**lifecycle table** (`pattern`, `runtime_arn`, and — for Step Functions apps —
`state_machine_arn`, added by the deploy stage). So the cards are **3-state**:

1. **Not deployed** — platform applied, but `team-bu-1` not yet seeded.
2. **Deploying** — the `team-bu-1-deploy-pipeline` is running (polled live).
3. **Ready** — a lifecycle record exists; Launch is enabled.

Cards auto-flip (no reload) as the pipeline completes. So the demo flow is:

```
terraform apply -var-file=configs/demo.tfvars   # console + empty repo + idle pipeline
scripts/04-seed-repos.sh                         # push users/team-bu-1 → triggers the pipeline
#   → pipeline builds + deploys the example agents, writes lifecycle records
#   → Examples cards flip Not deployed → Deploying → Ready
```

Until `team-bu-1` is seeded and its pipeline finishes, the example endpoints do
not exist and the cards stay "Not deployed" — this is expected.

### Local development (no CloudFront needed)

- `platform/console` — `npm run dev` (Vite). `/examples-api/*` is proxied to a
  local backend (`VITE_API_PROXY`, default `http://localhost:8080`).
- `platform/examples-backend` — `./run.sh` (uses ambient AWS creds to sign).
  It needs `LIFECYCLE_TABLE` plus `COGNITO_USER_POOL_ID` and
  `COGNITO_APP_CLIENT_ID` (ADR-046), and the console must be signed in with
  Cognito (`VITE_COGNITO_*` set). The console's dev auth bypass sends no token,
  so Examples calls return 401 without a real login.
- The gallery renders immediately; Launch works once a seeded deployment exists.

### Security posture note (ADR-038)

Exposing Langfuse through the public (if hardened) edge is a deliberate,
demo-only widening of ADR-030's private posture. **Do not** enable
`enable_cloudfront_origin` where Langfuse holds real customer telemetry.
