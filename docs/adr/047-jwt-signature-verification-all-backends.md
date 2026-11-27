# ADR-047: Verify JWT Signatures in Every Console Backend

**Status:** Accepted
**Date:** 2026-11-24

## Context

ADR-040 and ADR-041 moved the console backends off API Gateway, whose managed
Cognito authorizer verified token signatures, onto ALB→Fargate services that
check the JWT themselves. `ade-invoke-backend` and `studio-read-backend` ported
the old invoke-proxy check: they decode the token and compare `exp` and `iss`,
but never verify the signature. ADR-041 recorded this as a follow-up.

A token with the right `iss` and a future `exp` but no valid signature passed.
Anyone who could reach the backend could forge one: in the demo preset through
the public console CloudFront, in the enterprise preset from inside the VPC.
`ade-invoke-backend` invokes AgentCore runtimes and `studio-read-backend`
proxies Gateway tool calls and reads deployment data, so a forged token gave
the same access as a signed-in user. ADR-046 already verifies signatures in the
Examples backend.

## Decision

We will verify the signature, expiry and issuer of every bearer token in
`ade-invoke-backend` and `studio-read-backend` with `aws-jwt-verify`, against
the identity provider's JWKS:

- **Platform Cognito** (`COGNITO_USER_POOL_ID`): `CognitoJwtVerifier`, id or
  access tokens, any app client of the pool. Restricting the client would break
  an enterprise BYO UI that registers its own client.
- **External OIDC IdP** (`OIDC_ISSUER`, ADR-028): `JwtRsaVerifier`. The JWKS
  URI is `OIDC_JWKS_URI` when set, otherwise the `jwks_uri` from the issuer's
  `/.well-known/openid-configuration`. `OIDC_AUDIENCE` is checked when set.

The Examples backend (ADR-046) uses the same discovery lookup instead of
assuming `<issuer>/.well-known/jwks.json`, and keeps its console-client
restriction.

Each backend keeps its own copy of `src/auth.ts` (each ships as a
self-contained image). The services still refuse to start with no issuer
configured.

## Consequences

- Forged, expired or wrongly signed tokens get 401 on every console backend.
- The backends fetch the IdP's JWKS over HTTPS (cached by `aws-jwt-verify`).
  The platform VPC already routes private subnets through a NAT gateway.
- `platform/eap-platform/observability/src/lib/auth.ts` still holds a
  structural `validateJwt`, but nothing outside its unit test calls it.
- No Terraform change: both backends already receive `COGNITO_USER_POOL_ID`
  and `OIDC_ISSUER`.

## Alternatives Considered

- **Leave the structural check and accept the risk for a sample.** A reviewer
  would see a forged-token bypass next to ADR-046's verified check.
- **Restrict ADE and studio-read to the console app client.** Matches ADR-046
  but breaks an enterprise BYO UI that uses its own Cognito client.
- **ALB OIDC authentication action.** Needs an HTTPS listener and moves auth to
  the load balancer; larger change than a library swap.
