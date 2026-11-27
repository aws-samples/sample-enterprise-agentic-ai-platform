# console-authenticated role (Cognito browser identity-pool role)

**Terraform variable:** `console_authenticated_role_arn`
**Trust:** web identity — `cognito-identity.amazonaws.com` via
`sts:AssumeRoleWithWebIdentity`.

**Chicken-and-egg note:** the trust policy's `aud` condition binds to the
Cognito **identity pool ID**, which the platform creates at apply time. To
pre-create this role you must either (a) create the identity pool first and pass
its ID into `<IDENTITY_POOL_ID>`, or (b) create the role with a broader trust and
tighten the `aud` after the pool exists. Only relevant on the platform-Cognito
path (`create_cognito_identity_pool = true`); under an external OIDC IdP this
role is not used.
