# =============================================================================
# ENTERPRISE preset — hardened, no public ingress. The one you deploy in a
# customer account. Supersedes the former `poc` and `pilot` presets (ADR-036):
# there are now just TWO presets, `demo` (show-it-works) and `enterprise`
# (hardened). "POC" and "Pilot" are no longer separate files — they are
# MATURITY STAGES of this one preset, reached by progressively filling in the
# OVERRIDE blocks at the bottom (bring-your-own VPC / IdP / OTLP / CMK / roles).
#
#   terraform apply -var-file=configs/enterprise.tfvars -var 'studio_build_image=false'
#
# BASE POSTURE (this file, as-is — the self-contained "reference enterprise"
# stage, runnable in your own account with NO bring-your-own inputs):
#   * NO public console — BYO UI hosted internally (deploy_console=false).
#   * AgentCore agents run IN a VPC. With vpc_id empty (default) the platform
#     CREATES the VPC (+ NAT + endpoints) and runs agents in it; supply vpc_id to
#     import the enterprise VPC instead (override below).
#   * Identity = platform Cognito reference IdP. Swap for an external OIDC IdP by
#     setting oidc_discovery_url (override below) — that also removes the Cognito
#     hosted-UI public endpoint, giving ZERO public endpoints.
#   * Observability = AWS-native CloudWatch/X-Ray only. Self-hosted Langfuse is
#     OFF by default; turn it on (deploy_langfuse=true) OR ship to your own OTLP
#     backend (otel_backend_endpoint) — overrides below.
#   * IAM roles = platform-created by default. Externalize the 5 standalone roles
#     by supplying their ARNs (override below); the 10 pipeline roles stay
#     platform-created (ADR-033).
#   * Encryption = AWS-managed keys. Supply a CMK (kms_key_arn) to use your own.
#
# MATURITY STAGES (how the former poc/pilot map onto this preset):
#   * "POC" stage  = this file as-is (reference components, platform-created VPC
#     + roles + Cognito, Langfuse off) — used as-is pending Enterprise
#     Architecture approval.
#   * "Pilot" stage = uncomment the OVERRIDE blocks to swap in your own VPC,
#     external OIDC IdP, external OTLP backend, CMK, and pre-created roles.
#
# See platform/DEPLOY-RUNBOOK.md and docs/adr/036-*.md (two-preset model).
# =============================================================================

# --- No public console (BYO UI hosted internally) ----------------------------
deploy_console = false

# --- Agent traffic: in-VPC ----------------------------------------------------
# VPC mode takes effect once a VPC resolves. With vpc_id empty the platform
# CREATES one (see the VPC override to import your own instead).
agent_network_mode = "VPC"

# --- Observability: AWS-native only by default (Langfuse OFF) -----------------
# Turn on self-hosted Langfuse (deploy_langfuse=true) for a private in-VPC
# third-party backend, OR ship to your own OTLP backend (override below). With
# both off, agents emit only the AWS-native CloudWatch/X-Ray leg.
deploy_langfuse = false

# --- AWS-native observability — X-Ray Transaction Search OFF ------------------
# Account+region-wide singleton enterprises manage centrally; agents still emit
# AWS-native traces, just not indexed as queryable summaries until enabled.
enable_transaction_search = false

# =============================================================================
# OVERRIDE BLOCKS — uncomment/fill to advance from the reference "POC" stage to
# the "Pilot" stage (bring your own enterprise components). Each is independent.
# =============================================================================

# --- OVERRIDE: import your enterprise VPC (else the platform creates one) ------
# vpc_id             = "vpc-xxxxxxxx"
# private_subnet_ids = ["subnet-private-az1", "subnet-private-az2"]  # agents + observability
# public_subnet_ids  = ["subnet-alb-az1", "subnet-alb-az2"]         # internal ALB only (>=2 AZ)

# --- OVERRIDE: external OIDC IdP — skips Cognito entirely ---------
# oidc_discovery_url = "https://<your-idp>/.well-known/openid-configuration"
# oidc_issuer        = "https://<your-idp>/"   # only if it differs from the discovery host
# oidc_audience      = "<your-api-audience>"   # only if required by your IdP
# console_url        = "https://<your-internal-ui-host>"  # OAuth callback base

# --- OVERRIDE: external OTLP observability backend (Datadog/Grafana/Fiddler) ---
# deploy_langfuse              = false   # keep Langfuse off when shipping externally
# otel_backend_endpoint        = "https://<your-otlp-backend>"
# otel_backend_auth_secret_arn = "<arn:aws:secretsmanager:...:secret:otlp-auth>"  # or "" if none
# otel_backend_mode            = "replace"  # replace | add

# --- OVERRIDE: customer-managed KMS key (CMK) at rest (ADR-035) ---------------
# Also `export TF_STATE_KMS_KEY_ARN=<same-arn>` before the first bootstrap to
# encrypt the Terraform state bucket (S3 SSE is not retroactive).
# kms_key_arn = "arn:aws:kms:...:key/..."

# --- OVERRIDE: externalize the 5 standalone IAM roles (ADR-033) ---------------
# Pre-create these from docs/iam/ and supply the ARNs; the platform then creates
# no IAM for them. The 10 pipeline roles stay platform-created (empty default).
# gateway_role_arn           = "arn:aws:iam::<acct>:role/<gateway-role>"
# studio_runtime_role_arn    = "arn:aws:iam::<acct>:role/<studio-runtime-role>"
# studio_read_role_arn       = "arn:aws:iam::<acct>:role/<studio-read-role>"
# commit_validation_role_arn = "arn:aws:iam::<acct>:role/<commit-validation-role>"
# observability_role_arn     = "arn:aws:iam::<acct>:role/<observability-role>"
