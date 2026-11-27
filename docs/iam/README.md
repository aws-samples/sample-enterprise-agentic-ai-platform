# Externalizable IAM Roles — Enterprise Reference Pack

For enterprises where **humans / deployers may not create IAM roles**, the
platform's root-apply roles can be **pre-created by your IAM team** and supplied
to Terraform as ARNs. When you supply a role ARN, the platform creates **no**
IAM for that role — no `aws_iam_role`, no inline policy, no attachment — and
wires your ARN into the consuming resource instead. Leave the variable empty
(the default) and the platform creates the role exactly as before.

See [ADR-033](../adr/033-externalizable-iam-roles.md) for the decision and
[`platform/DEPLOY-RUNBOOK.md`](../../platform/DEPLOY-RUNBOOK.md) for the deploy
prerequisite.

> **Scope.** This pack covers the roles created by the human-run
> `terraform apply` of `platform/eap-platform` (Step 2). Roles that a
> **vended pipeline** creates at deploy time (per-agent runtime roles, the
> Step-Functions role, the invoke-bridge Lambda role) are **not** externalized —
> pipelines are permitted to create roles. The optional self-hosted
> observability stack (Langfuse + OTel collector, `deploy_langfuse`) creates its
> own ECS execution/task roles; those are **not** covered here (opt-in, rarely
> used in enterprise).

## How the JSON here is generated

Each role directory contains a **verbatim mirror** of the trust policy
(`trust-policy.json`) and permission policy (`permissions-policy.json`) the
platform would otherwise create. Runtime values are shown as **placeholders**
you substitute:

| Placeholder | Meaning |
|---|---|
| `<ACCOUNT_ID>` | Your AWS account ID |
| `<REGION>` | Deploy region (e.g. `us-east-1`) |
| `<PARTITION>` | AWS partition (`aws`, or `aws-us-gov` / `aws-cn`) |
| `<ENVIRONMENT>` | `dev` / `staging` / `prod` |
| `<DOMAIN>` | Business-unit / domain (e.g. `team-bu-1`) |
| `<NAME>` | Pipeline / resource name suffix |
| `<ARTIFACTS_BUCKET_ARN>` | The pipeline's artifact bucket ARN |
| `<PLATFORM_STATE_BUCKET>` | Account-scoped state bucket (`eap-platform-state-<ACCOUNT_ID>`) |
| `<LIFECYCLE_TABLE>` | Agent School lifecycle DynamoDB table name |
| `<REPOSITORY_NAME>` | The pipeline's CodeCommit repo name |
| `<DEPLOY_REPO>` / `<DEPLOY_PIPELINE>` | Studio deploy repo / pipeline (default `nocode-user*`) |
| `<COGNITO_USER_POOL_ID>` / `<IDENTITY_POOL_ID>` | Cognito pool / identity-pool IDs |
| `<OBSERVABILITY_TRUSTED_ROLE_ARN>` | ARN(s) of the console services allowed to assume the observability role |

## Two policy variants per role

Each role directory ships **two** permission-policy files:

- **`permissions-policy.json`** — the **verbatim mirror** of what the platform
  grants today. This is the **guaranteed-to-work baseline**: create the role with
  this and the apply/pipeline behaves exactly as an internally-created role. It
  is *not* hardened — some statements use action wildcards (`bedrock:*`,
  `logs:*`, `states:*`, `bedrock-agentcore:*`) and `Resource: "*"` because that
  is what the platform grants.
- **`permissions-policy-hardened.json`** — a **least-privilege target**. It
  differs from the mirror **only by tightening, never by adding**:
  resource-scopes wildcards where the ARN is knowable (ECR → `repository/*`,
  IAM role-management → `role/<DOMAIN>-*`, Lambda → `function:<DOMAIN>-*`,
  Secrets/DynamoDB/CodeCommit → specific ARNs), and narrows a few action
  wildcards to explicit action lists. **Prefer the hardened variant.** If a
  scoped statement turns out too tight for your deployment (e.g. a new platform
  version needs an action the hardened list omits), fall back to the mirror for
  that statement.

**What the hardened variant deliberately does NOT tighten** (and why): genuinely
unscopable actions stay `Resource: "*"` — `ecr:GetAuthorizationToken`,
`*:List*`/`Describe*` control-plane reads, `xray:Put*`,
`cloudwatch:PutMetricData` (already namespace-conditioned), and Lambda ENI
actions. Broad **action** wildcards on the pipeline roles
(`bedrock-agentcore:*`, `states:*`, `bedrock:*`, `bedrock-agent:*`, `logs:*`)
are **kept** even in the hardened variant, because the platform's CI/CD action
set is **evolving** and enumerating it risks breaking a live pipeline on the
next upgrade — the hardened variant scopes their *resources* (and, critically,
the `iam:CreateRole`/`PutRolePolicy`/`PassRole` escalation edge) but leaves the
action wildcard with this note. Re-review the pipeline roles on platform
upgrade.

> **Neither variant is a completeness guarantee for the evolving pipeline
> service roles** — treat their hardened files as a strong starting point your
> IAM team owns, not a frozen contract.

## Roles

| Terraform variable | Role | Trust | JSON |
|---|---|---|---|
| `gateway_role_arn` | AgentCore Gateway | `bedrock-agentcore.amazonaws.com` | [gateway/](roles/gateway/) — trust only; **no permission policy** (the gateway service manages its own) |
| `studio_runtime_role_arn` | Studio/ADE agent runtime | `bedrock-agentcore.amazonaws.com` | [studio-runtime/](roles/studio-runtime/) |
| `studio_read_role_arn` | studio-read Lambda | `lambda.amazonaws.com` | [studio-read/](roles/studio-read/) |
| `commit_validation_role_arn` | commit-validation Lambda | `lambda.amazonaws.com` | [commit-validation/](roles/commit-validation/) |
| `console_authenticated_role_arn` | Cognito authenticated console role | `cognito-identity.amazonaws.com` (web identity) | [console-authenticated/](roles/console-authenticated/) |
| `observability_role_arn` | Read-only console observability role | your console service role ARN(s) | [observability/](roles/observability/) |
| `agent_pipeline_codebuild_role_arn` | Agent pipeline CodeBuild | `codebuild.amazonaws.com` | [agent-pipeline-codebuild/](roles/agent-pipeline-codebuild/) *(evolving)* |
| `agent_pipeline_codepipeline_role_arn` | Agent pipeline CodePipeline | `codepipeline.amazonaws.com` | [agent-pipeline-codepipeline/](roles/agent-pipeline-codepipeline/) *(evolving)* |
| `integration_pipeline_codebuild_role_arn` | Integration (gateway) pipeline CodeBuild | `codebuild.amazonaws.com` | [integration-pipeline-codebuild/](roles/integration-pipeline-codebuild/) *(evolving)* |
| `integration_pipeline_codepipeline_role_arn` | Integration pipeline CodePipeline | `codepipeline.amazonaws.com` | [integration-pipeline-codepipeline/](roles/integration-pipeline-codepipeline/) *(evolving)* |
| `governance_pipeline_codebuild_role_arn` | Governance pipeline CodeBuild | `codebuild.amazonaws.com` | [governance-pipeline-codebuild/](roles/governance-pipeline-codebuild/) *(evolving)* |
| `governance_pipeline_codepipeline_role_arn` | Governance pipeline CodePipeline | `codepipeline.amazonaws.com` | [governance-pipeline-codepipeline/](roles/governance-pipeline-codepipeline/) *(evolving)* |
| `kb_pipeline_codebuild_role_arn` | KB pipeline CodeBuild | `codebuild.amazonaws.com` | [kb-pipeline-codebuild/](roles/kb-pipeline-codebuild/) *(evolving)* |
| `kb_pipeline_codepipeline_role_arn` | KB pipeline CodePipeline | `codepipeline.amazonaws.com` | [kb-pipeline-codepipeline/](roles/kb-pipeline-codepipeline/) *(evolving)* |
| `qa_pipeline_codebuild_role_arn` | QA pipeline CodeBuild | `codebuild.amazonaws.com` | [qa-pipeline-codebuild/](roles/qa-pipeline-codebuild/) *(evolving)* |
| `qa_pipeline_codepipeline_role_arn` | QA pipeline CodePipeline | `codepipeline.amazonaws.com` | [qa-pipeline-codepipeline/](roles/qa-pipeline-codepipeline/) *(evolving)* |

## Creating a role (example)

```bash
ROLE_DIR=docs/iam/roles/studio-read     # pick the role
# 1. substitute placeholders in the JSON (edit, or sed) for your account/region/etc.
# 2. create the role with its trust policy:
aws iam create-role \
  --role-name my-eap-studio-read \
  --assume-role-policy-document file://$ROLE_DIR/trust-policy.json
# 3. attach the permission policy (skip for gateway — it has none).
#    Prefer the hardened variant; use permissions-policy.json if you hit a
#    too-tight scope:
aws iam put-role-policy \
  --role-name my-eap-studio-read \
  --policy-name eap-studio-read \
  --policy-document file://$ROLE_DIR/permissions-policy-hardened.json
# 4. supply the ARN to Terraform:
#    -var 'studio_read_role_arn=arn:aws:iam::<ACCOUNT_ID>:role/my-eap-studio-read'
```

Roles with a **web-identity / federated** trust (console-authenticated) or an
**AWS-principal** trust (observability) require you to fill the trust policy's
condition/principal with your identity-pool ID or console service role ARN(s) —
see each role's `trust-policy.json` comments.
