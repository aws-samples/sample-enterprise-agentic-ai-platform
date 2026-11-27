# Externalized hardened IAM roles — POC test-bed fixture (Option A).
#
# Creates the 5 STANDALONE EAP roles from the platform's published
# docs/iam/roles/<role>/{trust-policy,permissions-policy-hardened}.json, with
# the <TOKENS> substituted, so the POC exercises the ADR-033 externalized-IAM
# path with the HARDENED (least-privilege) policies:
#   gateway, studio-runtime, studio-read, commit-validation, observability
#
# The 10 PIPELINE service roles are NOT created here — they are left to the
# platform (empty *_role_arn default), because their hardened policies reference
# platform-created resources (Cognito pool id, artifact buckets) that are not
# knowable before the apply (see ADR-033).
#
# It also emits a scoped iam:PassRole grant so the deploy principal can hand
# these roles to their services (runtime -> AgentCore, Lambdas -> Lambda).

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Region — must match the platform deploy region."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Platform environment (dev|staging|prod). Feeds <ENVIRONMENT> and deterministic resource names."
}

variable "domain" {
  type        = string
  default     = "nocode-user"
  description = <<-EOT
    The ADE/Studio deploy domain used by the studio-runtime + studio-read
    hardened policies (<DEPLOY_REPO>, <DEPLOY_PIPELINE>, <TARGET_REPO>). The
    platform's studio modules use the nocode-user deploy constants, so this
    defaults to nocode-user to match.
  EOT
}

variable "lifecycle_table" {
  type        = string
  default     = ""
  description = <<-EOT
    Lifecycle DynamoDB table name for the studio-read hardened policy
    (<LIFECYCLE_TABLE>). Empty (default) => computed as
    agent-school-lifecycle-<domain>-<environment> to match the platform's
    deterministic naming. Override only if you customize the table name.
  EOT
}

variable "role_name_prefix" {
  type        = string
  default     = "eap-poc"
  description = "Prefix for the created role names, so the test-bed roles are clearly identifiable and non-colliding."
}

variable "deploy_principal_arn" {
  type        = string
  default     = ""
  description = <<-EOT
    ARN of the principal that runs the platform terraform apply (your creds).
    Used as: (a) the observability role's trusted principal
    (<OBSERVABILITY_TRUSTED_ROLE_ARN>), and (b) the grantee of the scoped
    iam:PassRole policy. Empty (default) => resolved to the current caller
    identity's ARN via a data source.
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all roles."
}
