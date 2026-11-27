# Pipeline service roles (evolving)

The `*-pipeline-codebuild` and `*-pipeline-codepipeline` role directories hold
the CodeBuild and CodePipeline **service roles** for each vended pipeline
(agent, integration/gateway, governance, kb, qa).

> **These policies are EVOLVING.** They carry the platform's CI/CD permissions
> (which provision AgentCore runtimes, IAM roles, Step Functions, Lambdas, KBs,
> evaluators, etc.) and will change as the architecture evolves. They also use
> broad action wildcards (`bedrock-agentcore:*`, `logs:*`, `states:*`,
> `bedrock:*`, `bedrock-agent:*`) and `Resource: "*"` — a faithful mirror of the
> current grants, **not** hardened. Re-check them on platform upgrade.

**Placeholders specific to pipeline roles:** `<NAME>` (pipeline name suffix),
`<REPOSITORY_NAME>` (the pipeline's CodeCommit repo), `<ARTIFACTS_BUCKET_ARN>`
(that pipeline's artifact bucket), `<DOMAIN_UNDERSCORED>` (the domain with `-`
replaced by `_`, e.g. `team_bu_1`), plus the common ones in the top-level
[README](../README.md).

The `codebuild:StartBuild` resource is shown scoped to the project name pattern
for readability; the platform grants it against the explicit project ARNs it
creates. Either form works.

## Hardened variant (recommended)

Each pipeline role also ships `permissions-policy-hardened.json`. Versus the
mirror it:

- **Closes the privilege-escalation edge** — `iam:CreateRole` /
  `iam:PutRolePolicy` / `iam:PassRole` scoped from `Resource: "*"` to
  `role/<DOMAIN>-*` (agent/kb/qa/governance) or `role/eap-*`
  (integration). This is the single most important hardening on these roles.
- Resource-scopes `ecr` image actions → `repository/eap-*`, `lambda` →
  `function:<DOMAIN>-*` / `function:eap-*`, `secretsmanager` →
  `secret:eap-*`, `logs` write → the role's own log-group ARN, `s3:*` →
  the artifact-bucket ARN with an explicit action list, `states:*` →
  `stateMachine:<DOMAIN>_*` (agent pipeline).
- **Keeps** the `bedrock-agentcore:*` / `bedrock:*` / `bedrock-agent:*` action
  wildcards (evolving CI/CD surface — see the note above) and the genuinely
  unscopable `ecr:GetAuthorizationToken` / `logs:DescribeLogGroups` /
  `ssm:DescribeParameters` on `*`.

Use the hardened variant; fall back to `permissions-policy.json` for any
statement that proves too tight after a platform upgrade.
