# commit-validation Lambda role

**Terraform variable:** `commit_validation_role_arn`
**Trust:** `lambda.amazonaws.com`

Replace `<CODECOMMIT_REPO_ARNS>` with the ARNs of the source repos the
validation trigger attaches to (one entry per repo, e.g.
`arn:<PARTITION>:codecommit:<REGION>:<ACCOUNT_ID>:team-bu-1`). The
**`LambdaVpcEni`** statement is only needed in VPC mode (ADR-032); omit it for a
PUBLIC-mode deploy.
