# ADR-019: Authorization Model — Scopes, Cedar Policies, and AgentCore Policy

**Status**: Planned
**Date**: 2026-03-30

---

## Context

The platform needs fine-grained authorization at two levels:
1. Platform-level: which applications can access which platform services (gateway, agent runtimes)
2. Domain-level: what business operations can a user perform through an agent (e.g., issue refunds, approve orders)

## Decision: Two-Tier Authorization

### Tier 1: Platform Scopes (Current)

Platform Engineering defines infrastructure scopes via Cognito resource servers:
- `gateway/tools.invoke` — invoke tools via AgentCore Gateway
- `gateway/tools.read` — list/discover tools via Gateway
- `agent/invoke` — invoke an agent runtime

These are enforced by the Gateway and Runtime JWT authorizers. Every application gets these automatically via the deploy-template.

**Who defines**: Platform Engineering
**Where**: `eap-platform/identity/main.tf` (Cognito resource servers)
**Who enforces**: Gateway (`allowed_scopes`), Runtime (JWT authorizer)
**Who consumes**: All applications (assigned automatically by deploy-template)

### Tier 2: Domain Scopes + Cedar Policies (Future)

BU Admins define domain-specific scopes and Cedar policies that control what business operations agents can perform on behalf of users.

**Who defines**: BU Admin / AI Governance
**Where**: Domain config (bu-config.yaml or policy YAML files)
**Who enforces**: AgentCore Policy Engine (attached to Gateway)
**Who consumes**: Specific applications that handle sensitive business operations

### How AgentCore Policy Works

Based on [AgentCore Policy documentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html):

1. A Policy Engine is created and attached to a Gateway
2. Cedar policies are stored in the Policy Engine
3. Every agent request through the Gateway is intercepted
4. The Policy Engine evaluates the request against Cedar policies
5. Access is allowed or denied before the tool is invoked

Cedar policies can reference:
- **Principal**: the user identity (from JWT claims)
- **Action**: the tool being called
- **Resource**: the data being accessed
- **Context**: request parameters, time, etc.

### Example: Order Management Domain

Domain scopes (defined by BU Admin):
```
Resource server: "orders"
Scopes: orders/refund, orders/read, orders/approve
```

Cedar policy (enforced by Policy Engine):
```cedar
// Only users with the orders/refund scope can process refunds up to $1000
permit(
  principal,
  action == Action::"process_refund",
  resource
) when {
  principal has scope && principal.scope.contains("orders/refund") &&
  context.amount <= 1000
};

// Deny all refunds over $5000 regardless of scope
forbid(
  principal,
  action == Action::"process_refund",
  resource
) when {
  context.amount > 5000
};
```

### Architecture Flow

```
User → Cognito (scopes in JWT) → Gateway → Policy Engine (Cedar evaluation) → Tool
                                                    ↓
                                              ALLOW / DENY
```

The scopes in the JWT tell the Policy Engine what the user is authorized to do. The Cedar policies define the business rules. Together they provide:
- Scopes = coarse-grained capability (can this user issue refunds at all?)
- Cedar = fine-grained rules (can this user refund THIS order for THIS amount?)

### What's Needed

1. **AgentCore Policy Engine** — create via API/CLI (not managed through the Terraform AWS provider)
2. **Cedar policies** — written by BU Admin or AI Governance, stored in Policy Engine
3. **Domain resource servers** — Cognito resource servers per domain with business scopes
4. **Gateway attachment** — Policy Engine attached to Gateway in ENFORCE mode
5. **IAM permissions** — Gateway role needs `bedrock-agentcore:AuthorizeAction`, `bedrock-agentcore:PartiallyAuthorizeActions`, `bedrock-agentcore:GetPolicyEngine`

### Provisioning

The Policy Engine and its Cedar policies are created via the AgentCore API/CLI rather than through Terraform AWS provider resources.

### Persona Responsibilities

| Concern | Persona | What they do |
|---------|---------|-------------|
| Platform scopes | Platform Engineering | Define `gateway/*`, `agent/*` scopes in Cognito |
| Domain scopes | BU Admin | Define business scopes (e.g., `orders/*`) in domain config |
| Cedar policies | BU Admin / AI Governance | Write business rules as Cedar policies |
| Policy Engine | Platform Operator | Create and attach Policy Engine to Gateway |
| Scope assignment | Deploy-template (automated) | Assigns scopes to app clients based on agent config |
| Enforcement | Gateway + Policy Engine | Validates scopes (JWT) + evaluates Cedar policies |

### Key Principle

Agents don't know about scopes or policies. Authorization is enforced at the gateway boundary, outside agent code. The agent trusts that if a request reached it, it's already authorized. This separation means:
- Security controls can't be bypassed by agent manipulation
- Policies can be updated without redeploying agents
- AI Governance can audit and modify policies independently

### References

- [AgentCore Policy docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html)
- [AgentCore Policy IAM permissions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy-permissions.html)
- [Cedar policy language](https://www.cedarpolicy.com/)
- [AgentCore Policy getting started](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy-getting-started.html)
- `017-identity-architecture.md` — Cognito scopes and gateway auth
- `platform/eap-platform/identity/main.tf` — Resource servers


---

## Pending Decision: AWSCC Provider for Resources Outside the AWS Provider

**Status**: Pending
**Date**: 2026-03-30

### Context

Several AgentCore resources are not covered by the standard Terraform AWS provider (v6.38.0):
- Policy Engine (`aws_bedrockagentcore_policy_engine`)
- Cedar Policies (`aws_bedrockagentcore_cedar_policy`)
- Evaluations (`aws_bedrockagentcore_evaluator`)
- Gateway OpenAPI/REST targets

The AWS Cloud Control (AWSCC) Terraform provider auto-generates resources from CloudFormation schemas via the Cloud Control API. Any resource with a CloudFormation schema is immediately available — no waiting for the AWS provider team.

### Options

1. **Use AWSCC now** — fill gaps immediately, accept future migration cost (state mv + HCL rewrite from PascalCase to snake_case) when native support lands
2. **Wait for native AWS provider** — no migration cost, but features unavailable in Terraform until then (use API/CLI as workaround)
3. **Hybrid** — use AWSCC only for resources with no native alternative, migrate as native support arrives

### Tradeoffs

| | AWSCC Now | Wait |
|---|---|---|
| Feature availability | Immediate | Months |
| Migration cost | One-time state mv per resource | None |
| HCL conventions | PascalCase (CloudFormation style) | snake_case (Terraform style) |
| Documentation | Auto-generated, less polished | Hand-written, better examples |
| Stability | Depends on CloudFormation schema quality | Battle-tested |

### Decision

Pending. Will evaluate when Policy Engine implementation begins.

### References

- [AWS Blog: AWSCC Provider](https://aws.amazon.com/blogs/devops/quickly-adopt-new-aws-features-with-the-terraform-aws-cloud-control-provider/)
- [AWSCC Provider Registry](https://registry.terraform.io/providers/hashicorp/awscc/latest)
