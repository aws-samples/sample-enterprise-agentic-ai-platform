# ADR-046: Examples Backend Requires a Verified Caller JWT and a Lifecycle Allow-List

**Status:** Accepted
**Date:** 2026-11-24

## Context

ADR-037 put the demo console's Examples surface behind a hardened edge:
CloudFront with WAF, an ALB that accepts only the CloudFront origin-facing
prefix list plus a secret origin header, and a Fargate backend
(`platform/examples-backend`) that signs AgentCore and Step Functions calls with
its own task role.

The backend did not authenticate the caller. Anyone with the public CloudFront
URL could call `/examples-api/invoke`, `/sfn/start`, `/sfn/status`,
`/sfn/history` and `/logs` without signing in, and could pass any runtime or
state machine ARN in the account. That allowed unauthenticated agent
invocations (Bedrock cost to the deployer), workflow starts, and reads of agent
logs. The security scan rated it Critical.

The repo is published as an AWS sample in which the demo preset
(`deploy_console = true`) is the default, so this exposure would ship to every
default deployment. The console already signs users in with Cognito and holds
their JWT; only this backend ignored it.

## Decision

We will require, on every `/examples-api/*` route:

1. **A verified bearer JWT.** `src/auth.ts` uses `aws-jwt-verify` to check the
   token signature against the identity provider's JWKS, plus expiry, issuer
   and client id/audience. Issuer resolution follows ADR-028: the platform
   Cognito pool and console app client (`COGNITO_USER_POOL_ID`,
   `COGNITO_APP_CLIENT_ID`), or an external issuer (`OIDC_ISSUER`, optional
   `OIDC_AUDIENCE`, `OIDC_JWKS_URI`). With neither configured the service
   refuses to start.
2. **A target allow-list.** `src/allowList.ts` scans the lifecycle DynamoDB
   table (ADR-026) and only permits `runtime_arn` and `state_machine_arn` values
   recorded there; executions must belong to an allowed state machine. The
   `runtimePrefix` used for log lookups must be a plain identifier. A
   non-deployed target returns 403; an unreadable table returns 503.

The console sends the user's token on all Examples calls
(`services/examplesApi.ts`, and `authMode: 'cognito'` for Examples chat).
Terraform passes the auth settings and lifecycle table to the module and grants
the task role `dynamodb:Scan` on that table only. `/healthz` stays open for the
ALB health check.

This amends ADR-037 by adding caller auth. The rest of ADR-037 stands.

## Consequences

- An unauthenticated request, a forged or expired token, or a token for another
  app client gets 401. Signed-in users can only target resources the platform
  deployed.
- The backend now fetches the IdP's JWKS (cached by `aws-jwt-verify`), which
  needs outbound HTTPS. The platform VPC already routes private subnets through
  a NAT gateway.
- The task role gains read access to the lifecycle table.
- `ade-invoke-backend` and `studio-read-backend` still use a structural JWT
  check that does not verify the signature. Moving them to `aws-jwt-verify` is
  follow-up work.
- Remaining sample-level gaps (HTTP between CloudFront and the ALB, mutable ECR
  tags, root containers, broad IAM resources) are recorded in the threat model,
  not addressed here.

## Alternatives Considered

- **Make demo mode opt-in or remove it.** Removes the exposure but leaves the
  sample without a UI, and with opt-in the unauthenticated code still ships and
  is still flagged by the scanner.
- **Copy the ADE backend's structural JWT check.** Smaller change, but a token
  with the right `iss` and no valid signature would pass.
- **CloudFront or ALB authentication (Lambda@Edge, ALB OIDC action).** Moves
  auth out of the service but adds edge components, and ALB OIDC actions need an
  HTTPS listener the demo ALB does not have.
