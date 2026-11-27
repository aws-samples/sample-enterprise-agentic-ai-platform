# Agent School Lifecycle Store

## IMPORTANT: This is a child module

This module is consumed by the platform root (`platform/eap-platform/main.tf`):

```hcl
module "lifecycle_store" {
  source = "./lifecycle-store"
  environment = var.environment
  domain      = var.domain
}
```

**Do NOT run `terraform apply` directly in this directory.** The resources are managed by the platform root state at `platform/eap-platform/terraform.tfstate`.

Running `terraform plan` here will show resources to create because this directory has no state — the actual state lives in the parent module.

## What it provisions

- DynamoDB table: `agent-school-lifecycle-{domain}-{environment}`
- SSM parameter: `/eap/{environment}/{domain}/agent-school/lifecycle-table`

## To modify

Edit `main.tf` here, then apply from the platform root:

```bash
cd platform/eap-platform
terraform plan
terraform apply
```
