# ADR-017: Identity Architecture for the Enterprise Agentic AI Platform (EAP)

**Status**: Confirmed (IdP-provisioning refined by ADR-028)
**Date**: 2026-03-22
**Updated**: 2026-09-02
**Decision Makers**: Platform Team

> **Note (ADR-028):** This ADR establishes the three-layer identity model and
> the intent that the platform is IdP-agnostic via a single OIDC discovery URL.
> **ADR-028** makes that intent concrete: the OIDC provider is a deployer-supplied
> input (`oidc_discovery_url`); when empty the platform provisions the Cognito
> pool described below, and when set the platform skips Cognito and consumes the
> external IdP. The identity model here is unchanged — only *how the OIDC URL is
> supplied* is refined.

---

## Context

EAP needs an identity model that covers three distinct concerns:

1. **User → Agent**: Human users authenticate and invoke agents securely
2. **Agent → External Services**: Agents access data sources (Snowflake, Google, Salesforce) on behalf of users
3. **Agent → Agent**: Agents authenticate to each other for A2A communication

These are complementary flows, not competing models. Each uses Cognito as the IdP but via different OAuth grants.

## Confirmed Architecture: Three-Layer Identity Model

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: User → Agent (Cognito — Authorization Code Grant)     │
│                                                                 │
│  Human User → Cognito Managed Login → Human Access Token (JWT)  │
│  Human Access Token → Agent Runtime (JWT Authorizer validates)  │
│                                                                 │
│  Status: ACTIVE (re-enable JWT authorizer on runtime)           │
└─────────────────────────────────────────────────────────────────┘
                              │
                    human access token
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 2: Agent → External Services (AgentCore Identity — 3LO)  │
│                                                                 │
│  Agent calls GetWorkloadAccessTokenForJWT(human_access_token)   │
│  → AI Agent Access Token (bound to agent + human identity)      │
│                                                                 │
│  Agent calls GetResourceOauth2Token(agent_access_token)         │
│  → External service token from Token Vault                      │
│  → Token scoped to (agent identity + human identity + resource) │
│                                                                 │
│  Status: AVAILABLE (wire credential providers per service)      │
└─────────────────────────────────────────────────────────────────┘
                              │
                    resource token
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  External Services (Snowflake, Google, Salesforce, etc.)        │
│                                                                 │
│  Receives token scoped to the human user's identity.            │
│  Can enforce fine-grained access (table-level, calendar-level). │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Layer 3: Agent → Agent (AgentCore Gateway — A2A Routing)       │
│                                                                 │
│  A2A communication routed via AgentCore Gateway, not Cognito.   │
│  Gateway handles discovery, routing, and policy enforcement.    │
│  Cognito is restricted to user authentication only (Layer 1).   │
│                                                                 │
│  Status: PLANNED (replaces the Cognito M2M approach)           │
│  Previous Cognito M2M code removed from deploy-template.        │
└─────────────────────────────────────────────────────────────────┘
```

## Why These Are Complementary

| Concern | OAuth Flow | Cognito Role | AgentCore Role |
|---------|-----------|-------------|------------------------|
| User → Agent | Authorization Code (3LO) | Issues human JWT | Validates via JWT authorizer |
| Agent → External Service | Authorization Code (3LO) | Issues human JWT (passed through) | Identity manages credential providers + token vault |
| Agent → Agent | N/A | Not involved | Gateway handles routing + policy |
| Agent → Non-OIDC Service | Client Credentials (2LO) | Not involved | Identity manages credential providers + token vault |

Layer 1+2 handle the user-delegated path (human identity propagates).
Layer 3 handles the autonomous agent path (agent identity, no human in the loop).
Both use the same Cognito User Pool as the IdP.

## Layer 1+2: User-Delegated Flow (AWS-Documented Pattern)

Based on the [AWS Security Blog: Securing AI agents with AgentCore Identity](https://aws.amazon.com/blogs/security/securing-ai-agents-with-amazon-bedrock-agentcore-identity/):

### Sub-flow 1: User Authentication (Cognito)

1. User navigates to the web application
2. Redirected to Cognito Managed Login (username/password, passkey, federated IdP)
3. After successful auth, authorization code → `/oauth2/token` → Cognito tokens
4. Client receives ID, access, and refresh tokens — the **human access token**

### Sub-flow 2: AI Agent Interaction (AgentCore Identity)

5. User sends prompt to agent via web app, along with the human access token
6. Prompt + human access token reach the agent runtime
7. Agent calls `GetWorkloadAccessTokenForJWT(human_access_token)` on AgentCore Identity
   - AgentCore Identity verifies the human access token signature and expiration
8. AgentCore Identity returns an **AI agent access token** bound to the human user's identity
   - Identity derived from ISS + SUB claims in the human access token
9. Agent calls `GetResourceOauth2Token(agent_access_token)` for the external service
   - First time: triggers OAuth 2.0 authorization code grant (3LO) for user consent
   - Subsequent times: returns cached token from token vault
10. Authorization URL generated by AgentCore Identity for the external service
11. User redirected to external service (e.g., Snowflake, Google) for consent
12. After consent, authorization code returned to AgentCore Identity
13. AgentCore Identity exchanges code for access token
14. Token stored in vault, scoped to (agent identity + human identity + resource)

### Sub-flow 3: Agent Acting on Behalf of User

15. Agent calls `GetResourceOauth2Token` again — token returned from vault (no consent needed)
16. Agent calls external service API with the resource token
17. External service sees the human user's identity, not a generic agent client

### Three Tokens in Play

| Token | Issued By | Represents | Used For |
|-------|-----------|-----------|----------|
| Human Access Token | Cognito | Human user identity | Authenticating to agent runtime |
| AI Agent Access Token | AgentCore Identity | Agent + human identity (bound) | Requesting resource tokens |
| Resource Token (e.g., Snowflake) | External service | Human user's access to that service | Calling external APIs |

## Layer 3: Agent-to-Agent Communication (Gateway-Routed)

### Decision (2026-03-30)

A2A communication will be controlled via AgentCore Gateway, not Cognito client_credentials. Cognito is restricted to user authentication only (Layer 1).

### Rationale

1. **Cognito M2M is not usable from the runtime sidecar** — the sidecar does not compute the `SECRET_HASH` that Cognito client_credentials requires. Rather than depend on a change there, we route A2A through Gateway.
2. **Gateway provides more** — routing, discovery, policy enforcement, observability, and rate limiting. Cognito M2M only provides authentication.
3. **Simpler identity model** — Cognito handles users, Gateway handles agents. No per-agent Cognito app clients to manage.
4. **Consistent with data layer** — external tool access already goes through Gateway. A2A through Gateway means one control plane for all agent communication.

### How It Works

```
Agent A wants to call Agent B:

1. Agent A calls Gateway with A2A request
2. Gateway validates the request (policy, routing rules)
3. Gateway routes to Agent B's runtime endpoint
4. Agent B processes and responds via Gateway
```

### What Changes

- Per-agent Cognito app clients: **removed** (no longer needed)
- Per-agent Cognito users: **removed**
- `allowed_callers` in agent.yaml: **replaced** by Gateway routing policy
- JWT authorizer on runtime: **retained** for user→agent auth (Layer 1) only
- A2A doesn't depend on Cognito M2M

### Cognito Scope (Restricted)

Cognito is now exclusively for:
- User authentication (authorization code grant, managed login)
- JWT issuance for user→agent calls
- OIDC discovery endpoint for Gateway CUSTOM_JWT validation

Cognito is NOT used for:
- Agent-to-agent authentication (moved to Gateway)
- Per-agent identity (moved to AgentCore Workload Identity)

## Identity Propagation

The 3LO flow solves identity propagation for user-delegated access. The token vault binds tokens to (agent + user + resource), so external services see the human user's identity.

The M2M flow (Layer 3) propagates agent identity for autonomous operations. When Agent A calls Agent B, B sees A's Cognito client ID — not a human user, but a named agent identity.

Together they cover both cases:
- **User in the loop**: human identity propagates via 3LO
- **No user in the loop**: agent identity propagates via M2M JWT

## Cognito's Role

Cognito serves as the **user-facing IdP** — restricted to user authentication only:

- **User-facing**: Managed login, authorization code grant, federated IdP support (SAML, OIDC, social)
- **JWT authorizer source**: Runtime validates user tokens against Cognito's OIDC discovery endpoint
- **Gateway auth**: CUSTOM_JWT on Gateway validates user tokens via Cognito's OIDC discovery URL

Cognito does NOT handle agent-to-agent authentication. A2A communication is routed via AgentCore Gateway.

The Cognito User Pool is provisioned in `eap-platform/identity/` — but only
when the platform provisions its own IdP. Per ADR-028, when a deployer supplies
`oidc_discovery_url` (external IdP), the Cognito pool is not created and its ID is
not applicable.

## AgentCore Identity's Role

AgentCore Identity is the **platform-level credential manager**:

- Workload Identity Directory: each agent gets a stable identity (auto-created by runtime)
- Credential Providers: configured per external service (Snowflake, Google, Salesforce, etc.)
- Token Vault: stores tokens per (agent, user, resource) with KMS encryption
- SDK Integration: `@requires_access_token` decorator in agent code
- Supports both 2LO (machine-to-machine, no user) and 3LO (user-delegated access)

AgentCore Identity is NOT involved in A2A auth — that's Cognito-only.

Terraform location: `eap-terraform-modules/modules/identity/`

## IAM's Role

Standard AWS IAM for AWS service access:

- One shared role per domain (`team-bu-1-runtime-role`)
- Grants: ECR pull, Bedrock InvokeModel, CloudWatch Logs
- Could be per-agent if finer granularity needed

## Auth Flow Summary

| Flow | Layer | OAuth Flow | Mechanism | Status |
|------|-------|-----------|-----------|--------|
| User → Agent | 1 | Authorization Code | Cognito JWT + JWT authorizer | Ready |
| Agent → Snowflake (user-delegated) | 2 | Authorization Code (3LO) | AgentCore Identity + token vault | Available |
| Agent → Google (user-delegated) | 2 | Authorization Code (3LO) | AgentCore Identity + token vault | Available |
| Agent → GitHub (machine) | 2 | Client Credentials (2LO) | AgentCore Identity + token vault | Available |
| Agent → API-key services | 2 | N/A | AgentCore Identity API key provider | Available |
| Agent → Agent (A2A) | 3 | N/A | AgentCore Gateway (A2A routing + policy) | Planned |
| Agent → AWS services | N/A | N/A | IAM role + STS AssumeRole | Active |

## K8s Analogy

| Concept | K8s | EAP |
|---------|-----|-----------|
| User authentication | OIDC + kube-apiserver | Cognito + JWT authorizer (Layer 1) |
| Agent identity | ServiceAccount | AgentCore Workload Identity + Cognito User |
| External service auth (user-delegated) | OIDC federation | AgentCore Identity 3LO (Layer 2) |
| External service auth (machine) | Secrets + sidecar | AgentCore Identity 2LO (Layer 2) |
| A2A auth | mTLS / NetworkPolicy | Cognito M2M JWT (Layer 3, not enabled) |
| AWS service auth | IRSA | IAM role on runtime |
| Policy enforcement | OPA / Kyverno | Cedar policies via AgentCore Policy |

## References

- [AWS Security Blog: Securing AI agents with AgentCore Identity](https://aws.amazon.com/blogs/security/securing-ai-agents-with-amazon-bedrock-agentcore-identity/)
- [AgentCore Identity docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/identity.html)
- [Inbound JWT Authorizer](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/inbound-jwt-authorizer.html)
- [Supported authentication patterns](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/common-use-cases.html)
- `platform/eap-platform/identity/` — Cognito User Pool
- `platform/eap-terraform-modules/modules/identity/` — AgentCore Identity module
- `platform/eap-terraform-modules/modules/runtime/main.tf` — JWT authorizer config
- `platform/eap-terraform-modules/modules/pipeline/deploy-template/main.tf` — Per-agent Cognito resources (commented)

---

## Decision: Gateway Authorization via CUSTOM_JWT (IdP-Agnostic)

**Date**: 2026-03-25
**Status**: Confirmed

### Context

AgentCore Gateway supports two authorization modes: `AWS_IAM` and `CUSTOM_JWT`. We need to decide which to use for the platform's data services gateway (MCP server access).

### Decision

Use `CUSTOM_JWT` authorization on AgentCore Gateway. JWT tokens are validated against an OIDC discovery URL. The IdP is configurable — Cognito is the MVP default, but the architecture is designed to swap to any OIDC-compliant enterprise identity provider by changing a single variable (`oidc_discovery_url`).

### Rationale

1. **IdP-agnostic**: CUSTOM_JWT validates tokens via standard OIDC discovery. Any IdP that publishes a `.well-known/openid-configuration` endpoint works. No AWS-specific coupling.
2. **Enterprise-ready**: most enterprises use an external OIDC identity provider. Cognito is our MVP IdP, but the gateway must not be locked to it.
3. **Single swap point**: To change IdP, update `oidc_discovery_url` in `eap-data-services/variables.tf`. No code changes, no module changes, no agent changes.
4. **User identity propagation**: JWT tokens carry user identity claims. Gateway can enforce data entitlements based on who the user is, not just which agent is calling.

### Configuration

```hcl
# Cognito (MVP)
oidc_discovery_url = "https://cognito-idp.us-east-1.amazonaws.com/{pool_id}/.well-known/openid-configuration"

# External IdP (future)
oidc_discovery_url = "https://{idp-domain}/.well-known/openid-configuration"
```

### Consequences

- Agents must acquire a JWT token before calling Gateway tools (via AgentCore Identity 3LO flow or direct IdP token exchange)
- Gateway validates tokens on every request — no anonymous tool access
- IdP swap requires zero changes to agents, gateway module, or deploy-template — only the discovery URL variable

---

## Future Feature: User-Level Data Entitlements via 3LO

**Date**: 2026-03-25
**Status**: Planned (Critical)
**Priority**: High

### Problem

Agents access data sources (Snowflake, SharePoint, CRM) on behalf of users. Without user-level auth, the data source sees the agent's identity — all users get the same data. This violates data entitlement policies (row-level security, document access controls).

### Solution: Three-Legged OAuth (3LO) via AgentCore Identity Token Vault

Gateway targets configured with `credential_type: oauth` and `grant_type: authorization_code` use the Token Vault to acquire per-user tokens. The data source sees the user's identity and enforces entitlements natively.

### Why 3LO over Header Propagation

| | Header Propagation | 3LO (Token Vault) |
|---|---|---|
| Identity proof | Header value (spoofable) | Cryptographic token (verified by resource) |
| Scope control | None — just "I'm Alice" | Scoped — read vs write, specific datasets |
| User consent | Implicit (no consent flow) | Explicit — user authorizes agent access |
| Works with external services | Only if they trust headers | Yes — standard OAuth, works with Snowflake/Salesforce/etc. |
| Token lifecycle | Manual | Automatic refresh via Token Vault |

### What Needs to Be Built

1. **Consent UI** — Web page that redirects users to the resource's OAuth login, captures the authorization code, and stores it in Token Vault
2. **Token Vault registration** — Register each resource (Snowflake, SharePoint, CRM) as an OAuth provider in AgentCore Identity
3. **Resource OAuth configuration** — Configure each data source as an OAuth resource server that accepts tokens from AgentCore Identity
4. **Gateway target YAML** — Uncomment examples in `targets/rest-api/_future-3lo-entitlements.yaml`

### AgentCore Primitives Required

All primitives exist today:
- AgentCore Identity (Token Vault, `GetWorkloadAccessTokenForJWT`)
- AgentCore Gateway (OAuth outbound auth, `authorization_code` grant)
- CUSTOM_JWT inbound auth (validates user JWT)

The gap is integration work, not missing primitives.

### References

- `users/mcp-integrations/rest-api/_future-3lo-entitlements.yaml` — Example YAML configs
- `017-identity-architecture.md` — Gateway CUSTOM_JWT decision
- [AWS Blog: Securing AI agents with AgentCore Identity](https://aws.amazon.com/blogs/security/securing-ai-agents-with-amazon-bedrock-agentcore-identity/)


---

## Decision: Convention-Based OAuth Callback URLs

**Date**: 2026-03-30
**Status**: Confirmed

### Context

AgentCore Gateway uses CUSTOM_JWT authorization with `allowed_scopes` to enforce capability-based access control. Cognito requires OAuth flows (implicit or authorization code) to issue tokens with custom scopes — the `USER_PASSWORD_AUTH` flow only returns the default `aws.cognito.signin.user.admin` scope. OAuth flows require registered callback URLs on each Cognito app client.

This creates a coupling: the agent deployment pipeline must know the UI's callback URL at deploy time.

### Decision

Use convention-based callback URLs derived from the agent name and domain:

```
https://{agent-name}.{domain}.platform.example.com/auth/callback
```

Examples:
- `https://aws-architect-agent.team-bu-1.platform.example.com/auth/callback`
- `https://support-agent.team-bu-1.platform.example.com/auth/callback`
- `https://code-review-app.team-bu-1.platform.example.com/auth/callback`

The deploy-template generates this URL automatically from `agent.name` and `var.domain`. No manual configuration needed.

### How It Works

1. Deploy-template creates Cognito app client with convention callback URL + localhost for dev:
   ```hcl
   callback_urls = [
     "https://${each.key}.${var.domain}.platform.example.com/auth/callback",
     "http://localhost:5175/auth/callback"
   ]
   ```

2. Agent UIs use `window.location.origin + "/auth/callback"` as the redirect URI — works in both dev (localhost) and production (convention URL) without code changes.

3. After Cognito login, the browser redirects to `/auth/callback#access_token=...`. The UI extracts the token from the URL fragment and uses it for gateway/agent API calls.

### Production Requirements

For the convention URLs to work in production:
- DNS: Wildcard record `*.{domain}.platform.example.com` pointing to the UI hosting (CloudFront, ALB, etc.)
- TLS: Wildcard certificate for `*.{domain}.platform.example.com`
- UI Deployment: Each agent UI must be deployed at its convention URL. The platform can automate this via CloudFront + S3 with origin path routing.

### Cognito Limitation: USER_PASSWORD_AUTH Does Not Support Custom Scopes

Cognito's `USER_PASSWORD_AUTH` (initiate-auth CLI) is a proprietary flow that bypasses OAuth2 — tokens only include `aws.cognito.signin.user.admin` scope. Custom scopes like `gateway/tools.invoke` require OAuth implicit or authorization code flow via the Cognito hosted UI.

This is Cognito-specific. Other OIDC providers' Resource Owner Password flow (`grant_type=password`) supports custom scopes natively.

For programmatic testing without a browser, use the Cognito hosted UI implicit flow URL directly and extract the token from the redirect.

### References

- `platform/eap-terraform-modules/modules/pipeline/deploy-template/main.tf` — App client with convention callback URLs
- `platform/demo-ui/aws-architect-ui/src/App.tsx` — React OAuth callback handler
- `platform/eap-platform/identity/main.tf` — Resource servers (gateway, agent)
