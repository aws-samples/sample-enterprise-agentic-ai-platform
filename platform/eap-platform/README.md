# EAP Platform

Platform-level Terraform configuration for the Enterprise Agentic AI Platform (EAP).

## Purpose

Manages cross-cutting governance, identity, and domain provisioning:

- **Config Rules** — AWS Config Rules for resource compliance (R18.1–R18.6)
- **SCPs** — Service Control Policies for account-level guardrails (R18.4)
- **IAM Access Analyzer** — Permission validation for gateway access scoping (R18.5)
- **Identity** — Identity provider federation setup (R15.1, R15.2)
- **Domains** — Domain provisioning with isolation boundaries (R17.1)

## Structure

```
eap-platform/
├── main.tf              # Root module referencing sub-configs
├── variables.tf         # Root variables (region, account_id, environment, pipelines)
├── outputs.tf           # Root outputs
├── versions.tf          # Provider requirements (aws >= 6.0, terraform >= 1.5)
├── backend.tf           # S3+DynamoDB backend (TFC alternative in comments)
├── config-rules/        # AWS Config Rule definitions (post-MVP)
├── scps/                # Service Control Policies (post-MVP)
├── iam-access-analyzer/ # IAM Access Analyzer config (post-MVP)
├── identity/            # Cognito User Pool + resource server
├── domains/             # Per-domain Cognito group + IAM boundary
├── ecr/                 # Shared ECR repository
├── pipelines/           # Per-domain/use-case CodePipeline provisioning
└── state-backend/       # S3 + DynamoDB for Terraform state
```

## State Backend

Two backend options are provided in `backend.tf`:

1. **S3 + DynamoDB** (self-managed) — Uncomment the S3 backend block
2. **Terraform Cloud** (managed) — Uncomment the cloud block

## Usage

```bash
# Initialize with chosen backend
terraform init

# Plan changes
terraform plan -var="account_id=123456789012"

# Apply changes
terraform apply -var="account_id=123456789012"
```

## Requirements

- Terraform >= 1.5
- AWS Provider >= 6.0
- AWS credentials with appropriate permissions
