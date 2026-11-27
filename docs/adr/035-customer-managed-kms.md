# ADR-035: Optional Customer-Managed KMS Key for Data at Rest

**Status:** Accepted
**Date:** 2026-09-02

## Context

Every data store the platform creates is already encrypted at rest, but with
**AWS-provided default keys** rather than a **customer-managed key (CMK)**. Some
enterprises mandate CMK on data at rest so key policy, rotation, and revocation
sit under their control.

Two encryption models are involved and they are not the same:

- **S3** (state bucket) — SSE with `sse_algorithm = "aws:kms"` and no
  `kms_master_key_id` uses the **AWS-managed** `aws/s3` key. Supplying a
  `kms_master_key_id` switches it to a CMK.
- **DynamoDB** (lifecycle table) — encryption is always on with **three** tiers:
  AWS **owned** (default; no key in your account), AWS **managed**
  (`aws/dynamodb`), and **customer-managed** (CMK). Critically, in Terraform's
  `aws_dynamodb_table` a `server_side_encryption { enabled = true }` block with
  **no** `kms_key_arn` is still the **AWS-owned** key — there is no
  "AWS-managed" middle tier reachable without supplying a CMK. So for DynamoDB
  the choice here is binary: **service-managed (AWS-owned)** or **CMK**.

Before this ADR, `var.kms_key_arn` existed only inside the Langfuse and Gateway
modules (each defaulting to null → AWS-managed). It was **not** a root-level
knob, and two resources ignored it entirely:

1. the **Terraform state S3 bucket** (created by `bootstrap.sh`, and mirrored by
   the `state-backend/` module) — AWS-managed `aws/s3`, no CMK path; and
2. the **lifecycle DynamoDB table** — no `server_side_encryption` block at all,
   i.e. the AWS-owned key, no CMK path.

This was the last open item in the enterprise gap review (#15).

## Decision

We will add a single platform-wide root variable **`kms_key_arn`** (default
`null`) and thread it to every CMK-capable resource:

- **`null` (default)** — each resource keeps its AWS-provided default: the
  AWS-managed `aws/s3` key for the state bucket, DynamoDB **service-managed
  (AWS-owned)** encryption for the lifecycle table, and the AWS-managed keys for
  the Langfuse datastores/secrets. No behavior change from before.
- **Set to a CMK ARN** — threaded to: the lifecycle DynamoDB table, the Langfuse
  stack, the Gateway, and — via `bootstrap.sh`'s `TF_STATE_KMS_KEY_ARN` env var
  and the `state-backend/` module's `kms_key_arn` — the Terraform state bucket.

Implementation details:

- **DynamoDB** uses a `dynamic "server_side_encryption"` block that is **present
  only when a CMK is supplied**. With no CMK the block is omitted → service-
  managed (AWS-owned) encryption, a true no-op versus today. This avoids
  implying an "AWS-managed key" tier DynamoDB does not offer here.
- **S3 state bucket** sets `kms_master_key_id = var.kms_key_arn` inside the
  existing `aws:kms` rule — null → AWS-managed `aws/s3`, set → CMK.
- **`bootstrap.sh`** reads `TF_STATE_KMS_KEY_ARN`; when set it passes
  `KMSMasterKeyID` to `put-bucket-encryption`, otherwise it keeps the
  AWS-managed default.

The presets wire this per posture (two presets since ADR-036): `demo` leaves it
unset (AWS defaults); `enterprise` leaves it unset by default and documents the
CMK opt-in via the `kms_key_arn` override block (the former `pilot` stage set a
CMK across the platform).

## Consequences

- **CMK is a one-variable, opt-in change.** Default null reproduces today's
  encryption exactly, so existing deploys are unaffected.
- **The state bucket has a caveat: S3/DynamoDB SSE is not retroactive.** For an
  existing deployment, setting a CMK re-encrypts only new object versions; the
  key must be chosen at **bootstrap/first-create** time to cover state from the
  start. This is documented in the runbook.
- **DynamoDB terminology is now precise.** Without a CMK the lifecycle table is
  explicitly service-managed (AWS-owned), not "AWS-managed" — the code and docs
  say so, so no one assumes a middle tier that isn't there.
- **Key policy is the deployer's responsibility.** The supplied CMK's policy
  must allow the relevant AWS service principals (S3, DynamoDB, RDS,
  ElastiCache, Secrets Manager) and the deploy/runtime roles to use it;
  otherwise applies or agent operations fail with KMS AccessDenied.
- **Closes gap #15.** No platform resource now silently pins an AWS-provided
  key with no CMK path.

## Alternatives Considered

- **Default to a CMK / force CMK.** Rejected — the platform must not create or
  assume a key; CMK is a customer-owned input. Forcing it would break the
  zero-config demo and the "integrate by reference" principle.
- **Per-resource key variables** (separate keys for state, DynamoDB, Langfuse).
  Rejected for the MVP — one platform-wide key matches how enterprises usually
  scope a workload CMK and keeps the presets simple. Per-resource keys can be
  added later without breaking the single-key default.
- **Set DynamoDB `server_side_encryption { enabled = true }` with a null key as
  the default.** Rejected — it is still the AWS-owned key (a no-op) yet reads as
  if it were an upgrade; omitting the block entirely when there is no CMK is
  clearer and identical in effect.
