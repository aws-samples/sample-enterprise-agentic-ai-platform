output "gateway_role_arn" {
  value = aws_iam_role.this["gateway"].arn
}

output "studio_runtime_role_arn" {
  value = aws_iam_role.this["studio-runtime"].arn
}

output "studio_read_role_arn" {
  value = aws_iam_role.this["studio-read"].arn
}

output "commit_validation_role_arn" {
  value = aws_iam_role.this["commit-validation"].arn
}

output "observability_role_arn" {
  value = aws_iam_role.this["observability"].arn
}

output "passrole_policy_arn" {
  description = "Attach this to the deploy principal so the platform apply can iam:PassRole the externalized roles."
  value       = aws_iam_policy.passrole.arn
}

# Ready-to-paste snippet for configs/enterprise.tfvars (IAM block). 04-gen-tfvars.sh
# consumes the structured outputs above; this is a human-friendly convenience.
output "enterprise_tfvars_iam_snippet" {
  value = <<-EOT
    gateway_role_arn           = "${aws_iam_role.this["gateway"].arn}"
    studio_runtime_role_arn    = "${aws_iam_role.this["studio-runtime"].arn}"
    studio_read_role_arn       = "${aws_iam_role.this["studio-read"].arn}"
    commit_validation_role_arn = "${aws_iam_role.this["commit-validation"].arn}"
    observability_role_arn     = "${aws_iam_role.this["observability"].arn}"
    # (10 pipeline *_role_arn left empty => platform-created)
  EOT
}
