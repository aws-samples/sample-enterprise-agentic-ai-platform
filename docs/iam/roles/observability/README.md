# observability role (read-only console observability)

**Terraform variable:** `observability_role_arn`
**Trust:** AWS principal — the console observability service role(s)
(Deep_Link_Service / Telemetry_API_Service) that assume this role.

Replace `<OBSERVABILITY_TRUSTED_ROLE_ARN>` in `trust-policy.json` with the ARN(s)
of the console service role(s) permitted to assume it (the platform builds this
from its deep-link/telemetry service role ARN(s) + `observability_trusted_role_arns`).
Only relevant when `enable_observability_role = true`.

The permission policy is read-only (CloudWatch metrics, Logs Insights query
lifecycle, X-Ray reads). `Resource: "*"` is by design — these control-plane read
APIs do not support resource-level ARNs; the platform narrows per-BU at
AssumeRole time via a session policy.
