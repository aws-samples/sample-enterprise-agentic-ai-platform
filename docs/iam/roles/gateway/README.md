# gateway role

**Terraform variable:** `gateway_role_arn`
**Trust:** `bedrock-agentcore.amazonaws.com`
**Permission policy:** **none** — the AgentCore Gateway service manages this
role's permissions internally; the platform attaches no inline policy. Create
the role with the trust policy only (`trust-policy.json`); no `put-role-policy`
step is needed.
