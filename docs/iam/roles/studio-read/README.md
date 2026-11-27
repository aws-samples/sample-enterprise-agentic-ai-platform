# studio-read Lambda role

**Terraform variable:** `studio_read_role_arn`
**Trust:** `lambda.amazonaws.com`

`permissions-policy.json` combines the platform's inline read policy
(`studio-read-least-privilege`) + the scoped CloudWatch Logs policy
(`studio-read-logs`) into one document. The **`LambdaVpcEni`** statement is only
needed when the platform runs in VPC mode (ADR-032); omit it for a PUBLIC-mode
deploy.
