# ADR-014: Domain-Level IdP Groups for Agent Identity

**Status:** Accepted
**Date:** 2026-03-16

**Context:** When an agent is deployed to AgentCore Runtime, it needs an identity in the organization's identity provider (IdP) so that data entitlements, tool permissions, and cross-domain policies can be enforced. The question is: who is responsible for ensuring the agent's identity exists in the IdP before deployment?

Options considered:

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **App_Team prework** | App_Team manually registers agent identity in IdP before deploying | Clear ownership | Friction, error-prone, breaks "fire and forget" model. App_Team shouldn't touch IdP. |
| **Pipeline pre-check** | CodePipeline validates IdP identity exists before plan | Catches missing identity early | Still requires App_Team to do prework. Adds pipeline complexity. |
| **Plan-time validation** | Runtime module checks IdP for agent identity during `terraform plan` | Declarative, fails fast | Still requires App_Team to register identity first. |
| **Platform auto-provision (Domain groups)** | Platform creates IdP groups at Domain level. Agents auto-mapped to Domain group at deploy time. | Zero App_Team friction. Identity is a true horizontal. IdP-agnostic. | Platform must support IdP group lifecycle APIs. |

**Decision:** The platform provisions IdP groups at the Domain level. When a Domain is created via the domain module, the identity module creates a corresponding group in the configured identity provider (e.g., `eap-domain-{name}` in the enterprise IdP or Cognito). When an agent is deployed to AgentCore Runtime within that Domain, the runtime module automatically registers the agent as a member of the Domain's IdP group via AgentCore Identity. The App_Team performs zero IdP prework.

**Identity flow:**

```
Platform_Admin creates Domain
    → Domain module provisions IAM boundaries, workspace, ECR repo
    → Identity module creates IdP group: eap-domain-{name}
    → Group configured in AgentCore Identity with Domain-scoped claims

App_Team deploys agent into Domain
    → Runtime module deploys to AgentCore Runtime
    → Identity module creates a user identity for the agent in the IdP
      (external IdP: user, Cognito: user)
    → Identity module adds agent user to Domain's IdP group
    → Identity module passes credentials to AgentCore Identity
    → Agent inherits group claims → data entitlements, tool permissions, policies resolve from group

App_Team destroys agent
    → Runtime module removes agent user from Domain's IdP group
    → Identity module deactivates/deletes the agent's user identity in the IdP
```

**IdP-agnostic design:** The identity module uses a provider-agnostic interface for identity and group lifecycle operations (create agent user, create group, add user to group, remove user from group, deactivate/delete agent user). The interface is implemented per IdP:
- **External enterprise IdP**: the provider's user-management API (or SCIM) for agent user creation, and its group-management API for group membership
- **Amazon Cognito**: User Pool API (`AdminCreateUser`, `CreateGroup`, `AdminAddUserToGroup`)
- **Any OIDC-compliant IdP** with user creation and group-to-user mapping support

**Rationale:**
- Identity is a horizontal concern (ADR-008) — App_Teams should never touch it
- Aligns with ADR-006 — platform operates, app teams declare. Agent identity is an operational concern, not an app concern
- Domain-level grouping matches the existing isolation model (IAM boundaries, Cedar policies, workspace scoping)
- Group membership is the natural unit for entitlement resolution — data entitlements, tool permissions, and cross-domain policies all resolve from group claims
- Zero friction for App_Teams — deploy and identity is handled. True "fire and forget"

**Consequences:**
- Domain module must create IdP group as part of Domain provisioning (R17 updated)
- Runtime module must register/deregister agents in Domain IdP group at deploy/destroy time (R15 updated)
- Identity module must support a provider-agnostic group lifecycle interface
- Platform_Admin configures which IdP to use and the API credentials for group management (stored in Secrets Manager or similar)
- AWS Config Rule can enforce that every deployed agent has IdP group membership
