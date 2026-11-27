# Terraform-snapshot test — per-BU Langfuse project isolation (task 10.5)
#
# Asserts the module renders EXACTLY one Langfuse_Project per Business_Unit with
# DISTINCT key refs — no two BUs share a project id or a Secrets Manager secret
# (Requirement 14.1). Uses `command = plan` so the assertions run against the
# rendered plan shape.
#
# REQUIRES: Terraform >= 1.6 (the `.tftest.hcl` / `run` test format). The repo's
# currently-pinned Terraform 1.5.x uses the legacy experimental test framework
# and will report "No tests defined" for this file — run it with Terraform 1.6+.
#
# NOTE: this module reads live data sources (aws_vpc, aws_caller_identity,
# aws_region, the CloudFront managed prefix list), so `terraform test` needs AWS
# credentials + network reachability to resolve them during plan. Terraform
# < 1.7 has no `mock_provider`, so the test cannot be made fully hermetic here;
# run it in an environment with read access to the target account/region. All
# ASSERTIONS themselves are on plan-known, offline-computable values (project
# ids and secret NAMES derived from inputs), not on any AWS-returned data.
#
# Requirements: R14.1

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0aaa1111bbbb2222c", "subnet-0ddd3333eeee4444f"]
  public_subnet_ids  = ["subnet-0ggg5555hhhh6666i", "subnet-0jjj7777kkkk8888l"]

  acm_certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/11111111-2222-3333-4444-555555555555"

  # Local-testing posture: skip the CloudFront prefix-list data source and the
  # Cognito/console seams so the plan focuses on the per-BU project shape.
  restrict_alb_to_cloudfront_prefix_list = false

  business_units = [
    { bu = "team-bu-1" },
    { bu = "team-bu-2", name = "Business Unit Two" },
    { bu = "team-bu-3" },
  ]
}

# ---------------------------------------------------------------------------
# One distinct Langfuse project + key set per BU (R14.1)
# ---------------------------------------------------------------------------
run "one_project_per_bu_with_distinct_keys" {
  command = plan

  # Exactly one LangfuseProjectBinding per Business_Unit.
  assert {
    condition     = length(output.langfuse_project_bindings) == length(var.business_units)
    error_message = "Expected exactly one Langfuse project binding per Business_Unit."
  }

  # Every BU's projectId is distinct — no two BUs share a project.
  assert {
    condition     = length(distinct([for b in values(output.langfuse_project_bindings) : b.projectId])) == length(var.business_units)
    error_message = "Langfuse projectIds must be distinct across Business_Units (no shared project)."
  }

  # Exactly one public-key secret per BU, all with distinct names.
  assert {
    condition     = length(distinct([for s in aws_secretsmanager_secret.langfuse_project_public_key : s.name])) == length(var.business_units)
    error_message = "Each BU must have its own distinct public-key secret."
  }

  # Exactly one secret-key secret per BU, all with distinct names.
  assert {
    condition     = length(distinct([for s in aws_secretsmanager_secret.langfuse_project_secret_key : s.name])) == length(var.business_units)
    error_message = "Each BU must have its own distinct secret-key secret."
  }

  # Exactly one OTLP Basic-auth secret per BU, all with distinct names.
  assert {
    condition     = length(distinct([for s in aws_secretsmanager_secret.langfuse_project_otlp_basic_auth : s.name])) == length(var.business_units)
    error_message = "Each BU must have its own distinct OTLP Basic-auth secret."
  }

  # No secret is shared across BUs OR across the three key roles: all 3 x N
  # secret names are globally distinct (public != secret != basic-auth, per BU).
  assert {
    condition = length(distinct(concat(
      [for s in aws_secretsmanager_secret.langfuse_project_public_key : s.name],
      [for s in aws_secretsmanager_secret.langfuse_project_secret_key : s.name],
      [for s in aws_secretsmanager_secret.langfuse_project_otlp_basic_auth : s.name],
    ))) == length(var.business_units) * 3
    error_message = "Every per-BU key ref (public/secret/basic-auth) must be a distinct secret; no BU may share a secret."
  }

  # Each binding's projectId is the stable, per-BU derived id (not another BU's).
  assert {
    condition     = alltrue([for bu, b in output.langfuse_project_bindings : endswith(b.projectId, "-proj-${bu}")])
    error_message = "Each binding's projectId must be derived from its own BU key."
  }
}

# ---------------------------------------------------------------------------
# Empty business_units => no per-BU projects provisioned (default posture).
# ---------------------------------------------------------------------------
run "no_projects_when_no_business_units" {
  command = plan

  variables {
    business_units = []
  }

  assert {
    condition     = length(output.langfuse_project_bindings) == 0
    error_message = "With no business_units, no Langfuse project bindings should be produced."
  }
}
