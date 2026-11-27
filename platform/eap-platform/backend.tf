# State Backend Configuration
#
# S3 + DynamoDB backend for durable, shared state with locking.
# Prerequisites: Run ./bootstrap.sh ONCE before first terraform init.
# The bootstrap script creates the S3 bucket and DynamoDB lock table.
#
# NOTE — the state bucket name is intentionally NOT hardcoded here. S3 bucket
# names are GLOBALLY unique across all AWS accounts, so a fixed literal like
# "eap-platform-state" risks a BucketAlreadyExists collision. Instead the
# bucket is account-scoped ("eap-platform-state-<ACCOUNT_ID>") and supplied
# at init via partial backend config. Terraform backend blocks cannot use
# variables, so this must be passed on the CLI:
#
#   terraform init -backend-config="bucket=eap-platform-state-<ACCOUNT_ID>"
#
# `bootstrap.sh` creates the correctly-named bucket and prints the exact command.
# The DynamoDB lock table name is NOT global (account+region scoped), so it stays
# a literal here.

terraform {
  backend "s3" {
    # bucket = supplied via -backend-config (see note above)
    key            = "platform/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "eap-platform-locks"
  }
}

# Option 2: Terraform Cloud (managed)
# Uncomment the block below instead of the S3 backend for Terraform Cloud.

# terraform {
#   cloud {
#     organization = "eap"
#     workspaces {
#       name = "eap-platform"
#     }
#   }
# }
