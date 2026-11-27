# Langfuse_Stack Module — Optional Private Default Observability Backend

Self-hosted [Langfuse](https://langfuse.com) deployed as the platform's
**optional default** third-party OTLP backend (Requirement 11.7). This module
provisions the compute, datastores, and a **private, VPC-internal edge** that
run Langfuse on AWS, following the platform's Terraform conventions
(`eap_module` / `eap_domain` tags, VPC/subnets passed as variables,
`versions.tf`).

Deployment of this stack is gated at the platform root by `deploy_langfuse`
(default `true`). When `deploy_langfuse = false`, the always-on OTel collector
still runs and fans spans out to whatever external OTLP backend is configured
(Datadog / Fiddler / any OTLP) — Langfuse is not required. See
[ADR-030](../../../../../docs/adr/030-observability-private-pluggable.md).

> **Attribution.** This Langfuse deployment pattern (ECS Fargate web+worker +
> Aurora PostgreSQL + ClickHouse + Redis + ALB, and the dual AWS-native +
> embedded-Langfuse observability approach) is adapted from the AWS-samples
> **Agentic Value Accelerator (AVA)**
> (<https://github.com/aws-samples/sample-agentic-value-accelerator>), used
> under the Apache License 2.0. See the repo `NOTICE` / `ATTRIBUTION.md`.

## Two-leg model

Langfuse is a **third-party OTLP backend only**. It is not part of the always-on
AWS-native leg (AgentCore auto-instrumentation → CloudWatch/X-Ray). The
`observability/otel-collector` module fans the duplicated span stream into this
stack's per-BU Langfuse projects. Any degradation of this stack cannot affect
the AWS-native leg — that independence is structural.

## Edge posture — private, internal, HTTP (ADR-030)

This is an **enterprise, no-public-access** deployment. The Langfuse edge is a
**private internal ALB** reachable only from within the VPC (on-network users
via VPN / corp network), not the public internet:

- **Internal ALB, HTTP only.** A single ALB HTTP listener on the web port
  (`web_container_port`, default `3000`) forwards to the Langfuse web target
  group. There is **no** CloudFront distribution, **no** HTTPS/ACM listener,
  **no** HTTP→HTTPS redirect, and **no** ALB-level `authenticate-cognito`
  action.
- **Access control is network isolation + Langfuse's own login.** Because the
  ALB is private and only reachable on-network, TLS termination and an identity
  proxy at the edge are unnecessary for this posture. Langfuse's application
  login gates the UI; the OTel collector reaches the same listener in-VPC for
  OTLP span ingestion (`/api/public/otel`).
- **`langfuse_base_url` / `NEXTAUTH_URL`** resolve to
  `http://<internal-alb-dns>:<web_container_port>`. The console embed origin
  (when `deploy_langfuse`) is fed from this internal DNS name and therefore
  degrades off-VPN — making the **console itself private** is a separate piece of future work.
- **Demo (`enable_cloudfront_origin`).** The ALB stays internal. CloudFront
  reaches it through a CloudFront VPC origin over the AWS network, so the ALB
  has no public address. Ingress is limited to the CloudFront origin-facing
  prefix list plus the secret origin header.

> **HTTP inside the VPC only; use HTTPS for production.** The ALB is internal,
> in private subnets, and its security group admits only VPC traffic
> (enterprise) or CloudFront's origin-facing prefix list through a VPC origin
> (demo, where TLS terminates at CloudFront). Traffic between clients in the
> VPC and the ALB, including Langfuse logins and OTLP keys, is not encrypted.
> HTTPS needs a certificate for a domain you own, so the sample does not
> assume one. For production, add an HTTPS listener with an ACM certificate (an
> AWS Private CA certificate works for an internal ALB), redirect HTTP to
> HTTPS, and set `langfuse_base_url` / `NEXTAUTH_URL` to the `https://` URL.

> **Bridge variables.** A few public-edge inputs (`acm_certificate_arn`,
> `cloudfront_certificate_arn`, `dns_domain_name`, `cognito_user_pool_*`,
> `console_domain`, `restrict_alb_to_cloudfront_prefix_list`) remain in
> `variables.tf` as **deprecated / unused** in the private model, retained
> optional for a possible future public-exposure opt-in. They are not wired into
> the shipped private edge. Pruning them is a separate interface-cleanup pass.

## What this module provisions

| Concern | Resource(s) | Requirement |
|---------|-------------|-------------|
| Compute | ECS Fargate **web** + **worker** services and task definitions | 11.2 |
| Transactional store | **Aurora PostgreSQL Serverless v2** cluster + instance (private subnets) | 11.3 |
| Analytical store | **ClickHouse** on Fargate with an ECS-managed **EBS** data volume (private subnets) | 11.4 |
| Cache/queue | **ElastiCache Redis** replication group (private subnets, at-rest + in-transit encrypted, AUTH token) | 11.5 |
| Object storage | **S3** bucket for event/media blobs (SSE, public access blocked, versioned) | 11.1 |
| Edge | **Private internal ALB → web target group**, HTTP on the web port (no CloudFront, no HTTPS/ACM) | 11.6, 15.6 |
| Secrets | Secrets Manager for `DATABASE_URL`, `CLICKHOUSE_PASSWORD`, `REDIS_AUTH`, `SALT`, `ENCRYPTION_KEY`, `NEXTAUTH_SECRET` | 15.4 |

The Langfuse container environment is wired for `DATABASE_URL`, `CLICKHOUSE_*`,
`REDIS_*`, S3 event/media blob config, `NEXTAUTH_URL`, `SALT`, and
`ENCRYPTION_KEY` — all sensitive values injected as **Secrets Manager refs**,
never plaintext in the task definition.

## Per-BU Langfuse projects

Set `var.business_units` to provision one isolated `Langfuse_Project` per
Business_Unit (Requirement 14.1). For each entry the module:

- derives a **stable, distinct** projectId (`${name_prefix}-proj-<bu>`);
- generates a per-project **public key** (`pk-lf-…`) and **secret key**
  (`sk-lf-…`) via `random_password`;
- stores the public key, secret key, and the `base64(publicKey:secretKey)`
  Basic-auth header in **three KMS-encrypted Secrets Manager secrets** per BU
  (never plaintext), tagged with `eap_bu`;
- **seeds** the project into Langfuse — the first BU via Langfuse **headless
  init** (`LANGFUSE_INIT_*` on the web container, keys injected as secret refs),
  and any additional BUs via an **idempotent post-apply bootstrap**
  (`terraform_data` + `local-exec` calling the Langfuse Public API), gated on
  `var.enable_project_bootstrap` (default `false`) so `terraform validate`/`plan`
  never need live Langfuse credentials;
- emits a **`LangfuseProjectBinding`** per BU via the `langfuse_project_bindings`
  output (`bu → { bu, projectId, publicKeyRef, secretKeyRef, otlpBasicAuthRef }`,
  refs = Secrets Manager ARNs) that the `otel-collector` per-BU routing
  consumes alongside `langfuse_otlp_endpoint`.

No new provider is introduced — the optional bootstrap uses the built-in
`terraform_data` resource. A `terraform test` snapshot
(`tests/per_bu_project_isolation.tftest.hcl`, Terraform **1.6+**) asserts exactly
one project per BU with distinct project ids and distinct key refs.

```hcl
module "langfuse" {
  # …
  business_units = [
    { bu = "team-bu-1" },
    { bu = "team-bu-2", name = "Business Unit Two" },
  ]
  # enable_project_bootstrap = true  # seed non-primary projects via the Public API at apply
}
```

## Security posture

Network and least-privilege hardening (Requirements 15.1, 15.3, 15.4, 15.5,
15.6):

- **Private everything**: Aurora, ClickHouse, Redis, and the ALB all run only in
  private subnets; the S3 blob bucket blocks all public access, enforces a
  TLS-only bucket policy, and (when `private_route_table_ids` is supplied) is
  reached via an S3 **gateway VPC endpoint** so blob traffic never leaves the
  AWS backbone.
- **Per-datastore SGs**: each datastore admits ingress ONLY from the web/worker
  service security groups; the ALB is internal and admits ingress from within
  the VPC.
- **Per-service IAM**: web, worker, and clickhouse each have their own execution
  role reading ONLY the secrets they inject; web/worker task roles get only the
  blob-bucket access they need; KMS grants are attached only when
  `kms_key_arn` is set.
- **KMS at rest**: when `kms_key_arn` is provided, Aurora, ClickHouse EBS, Redis,
  every Secrets Manager secret, and S3 (`aws:kms`) use the customer-managed key;
  otherwise AWS-managed keys keep everything encrypted by default.
- **No public edge / no TLS at the ALB**: access is gated by network isolation
  (private ALB, VPN/corp reachable only) plus Langfuse's application login —
  see the edge posture section above.

## Usage

```hcl
module "langfuse" {
  source = "../../eap-terraform-modules/modules/observability/langfuse"

  name   = "langfuse"
  domain = "observability"

  # Networking — datastores and the internal ALB all live in private subnets.
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  public_subnet_ids  = var.public_subnet_ids # unused by the private edge; retained for signature stability

  # Security hardening:
  # kms_key_arn             = var.observability_kms_key_arn # CMK for at-rest encryption
  # private_route_table_ids = var.private_route_table_ids   # for the S3 gateway endpoint

  # Per-BU isolated projects:
  # business_units = [{ bu = "team-bu-1" }, { bu = "team-bu-2" }]

  tags = var.tags
}
```

## Notes

- **Aurora Serverless v2** uses `engine_mode = "provisioned"` with a
  `serverlessv2_scaling_configuration` (min/max ACUs), which is how Serverless v2
  is expressed in Terraform.
- **ClickHouse EBS** uses ECS-managed EBS volumes (`configure_at_launch = true`
  on the task-def volume + `volume_configuration.managed_ebs_volume` on the
  service), so the service runs a single node (single-attach EBS). An ECS
  infrastructure role (`AmazonECSInfrastructureRolePolicyForVolumes`) lets ECS
  manage the volume lifecycle.
- **Private HTTP edge**: a single internal ALB HTTP listener on
  `web_container_port` forwards to the web target group. No CloudFront, no
  HTTPS/ACM, no HTTP→HTTPS redirect (ADR-030).

## Requirements

- R11.1, R11.2, R11.3, R11.4, R11.5, R11.6, R11.7
- R15.1, R15.3, R15.4, R15.5, R15.6 (network/security hardening — implemented)
- R14.1 (one Langfuse project + distinct key set per BU — implemented via `var.business_units` → `langfuse_project_bindings`)
- R14.4 (per-BU collector routing consumes `langfuse_project_bindings`)
