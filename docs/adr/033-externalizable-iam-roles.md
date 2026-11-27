# ADR-033: Externalizable (Bring-Your-Own) IAM Roles for Restricted Deployers

**Status:** Accepted
**Date:** 2026-09-02

## Context

In many enterprises, **humans / deployers may not create IAM roles** — a central
IAM/security team must pre-create every role, with its own naming, permission
boundary, and policy. The platform's root `terraform apply` (Step 2), run by a
human deployer, previously **created ~17 IAM roles inline** (the gateway role,
the Studio/ADE runtime role, the studio-read / invoke-proxy / commit-validation
Lambda roles, the Cognito authenticated console role, the read-only
observability role, and the CodeBuild + CodePipeline service roles for each of
the five pipeline modules). A deployer without `iam:CreateRole` cannot run that
apply.

Important nuance (confirmed with the platform owner): **pipelines ARE allowed to
create roles** — only humans/deployers are not. So the roles a *vended pipeline*
creates at deploy time (per-agent runtime roles, the Step-Functions role, the
invoke-bridge Lambda role) are out of scope. The constraint applies only to
roles created by the **human-run root apply**.

An earlier, related decision (**IAM least-privilege hardening**) was
deliberately parked while the architecture is still evolving. Externalization is
explicitly a **structural** change — it does not tighten any policy.

## Decision

**We will make every root-apply IAM role "externalizable" via a bring-your-own
role ARN, using the same seam pattern as OIDC (ADR-028) and VPC (ADR-030).**

1. **Per-role `*_role_arn` variable (default empty).**
   - Empty (default) → the platform creates the role **and its policies**
     exactly as before — zero behavior change.
   - Supplied → the platform creates **nothing** for that role (no
     `aws_iam_role`, no inline `aws_iam_role_policy`, no
     `aws_iam_role_policy_attachment`) and wires the supplied ARN into the
     consuming resource (Lambda `role`, `module.gateway.role_arn`, CodeBuild
     `service_role`, CodePipeline `role_arn`, the Cognito identity-pool
     attachment, etc.). This is "Option A": if a deployer cannot create roles,
     they almost certainly cannot attach policies either, so the platform
     performs **no** IAM writes for an externalized role.

   Mechanically: `local.create_X = var.X_role_arn == ""`, a `count` on the role
   and every resource that references it, and a resolved
   `local.X_role_arn = create_X ? aws_iam_role.X[0].arn : var.X_role_arn`.
   Existing gates compound with the new one (e.g. the observability role is
   created only when `enable_observability_role && no external ARN`; the console
   role only when the identity pool is created && no external ARN).

2. **Ship the exact role/policy JSON for enterprises to pre-create the roles.**
   Under `docs/iam/` the platform publishes, per role, the **trust policy** and
   **permission policy** as copy-pasteable JSON with placeholders
   (`<ACCOUNT_ID>`, `<REGION>`, `<DOMAIN>`, `<ARTIFACTS_BUCKET_ARN>`, …). These
   are a **verbatim mirror** of what the platform creates today — not hardened —
   so the pre-created role can perform at least what the platform expects. A
   README maps each `*_role_arn` variable → role → JSON files with
   `aws iam create-role` / `put-role-policy` examples. The gateway role has no
   permission policy (the AgentCore service manages it). The pipeline
   service-role JSONs are marked **evolving** (they carry the CI/CD permissions,
   which change as the architecture evolves).

3. **Scope.** 17 root-apply roles. Explicitly out of scope: pipeline-*created*
   roles (pipelines may create roles) and the optional Langfuse / OTel-collector
   ECS execution/task roles (opt-in, rarely used in enterprise) — externalizing
   those is a clean follow-up if an enterprise opts into self-hosted
   observability.

## Consequences

- **Restricted deployers can run the platform apply** without `iam:CreateRole`
  — they supply the pre-created ARNs; the apply creates no IAM.
- **Zero behavior change by default.** Every `*_role_arn` defaults to empty, so
  an unrestricted deployer's apply is byte-for-byte what it was.
- **The enterprise owns the pre-created role's policy.** Because Option A creates
  no policy for an externalized role, the enterprise must author the role's
  permissions — the `docs/iam/` JSON is exactly that content, so there is no
  guessing. If the platform later needs a new permission on a role, the
  enterprise must update their pre-created role (the JSON is the reference; the
  ADR/runbook flags pipeline-role JSON as evolving).
- **`PassRole` coordination.** Whoever runs the apply still needs
  `iam:PassRole` on the pre-created ARNs it hands to services (runtime role →
  AgentCore, SFN/pipeline roles → their services). Documented in the runbook.
- **Standalone roles externalize cleanly; pipeline roles do not (pre-apply).**
  The 5 **standalone** roles (gateway, studio-runtime, studio-read,
  commit-validation, observability) reference only values knowable *before* the
  apply (account/region/partition/env/domain + deterministic repo/pipeline/table
  names), so an enterprise can pre-create them up front. The 10 **pipeline**
  service roles' (hardened) policies reference resources the platform *creates*
  (`COGNITO_USER_POOL_ID`, artifact-bucket ARNs), which are not knowable until
  the apply runs — so pre-creating them fully-scoped requires a **two-pass**
  apply (create identity/buckets, read the values, then create the roles and
  re-apply). Consequently the supported default posture — used by the
  `enterprise` preset's externalized-roles override (formerly the `poc`/`pilot`
  presets; see ADR-036) — is **externalize the 5 standalone roles, leave the 10
  pipeline roles as the empty default (platform-created).** Because each
  `*_role_arn` is independent, this mixed mode needs no code change; the empty
  default is exactly the platform-created path. Fully externalizing the pipeline
  roles (two-pass) is deferred and tracked with the "evolving pipeline-role
  JSON" note.
- **Two-tier trust shapes documented.** The console role (web-identity federated
  to the Cognito identity pool) and the observability role (AWS-principal trust)
  need the deployer to fill in the identity-pool ID / trusted service-role ARN
  in the trust policy; noted per-role.
- **No hardening.** Policies are unchanged; the parked least-privilege work is
  unaffected and still tracked separately.
- **Verification limit.** Verified via `terraform validate` + `terraform
  console` (empty → role created; supplied → the resolved local is the external
  ARN and the create-gate is false). No live apply (no bootstrapped account), so
  the supplied-ARN path and `PassRole` interplay are config-verified, not
  apply-verified.

## Alternatives Considered

- **Option B — BYO role, but the platform still attaches the policies.**
  Rejected: attaching a policy is itself an `iam:PutRolePolicy` write a
  restricted deployer likely cannot perform; it would not actually satisfy the
  "humans can't create/modify roles" constraint.
- **Externalize only the static roles, keep pipeline service roles internal.**
  Rejected as the default: the pipeline CodeBuild/CodePipeline roles are created
  by the *human* root apply too, so they must be externalizable for a restricted
  deployer. (Their JSON is marked evolving to set expectations.)
- **Do nothing / document manual role creation.** Rejected: without the
  `count`-gated seam the apply still tries to create the roles and fails for a
  restricted deployer.
- **Generate the JSON from Terraform (outputs/local_file).** Rejected: the
  enterprise must create the roles *before* the apply, so apply-time generation
  is circular; static reference files under `docs/iam/` are what an IAM team
  consumes. A pointer keeps them maintained alongside the TF.
