# =============================================================================
# DEMO preset — show it works. Least hardened; no deployer inputs required.
#
#   terraform apply -var-file=configs/demo.tfvars
#
# Posture:
#   * Public demo console (S3 + CloudFront) is deployed.
#   * AgentCore agents run IN a VPC (the platform default). The platform creates
#     a VPC and attaches agent ENIs to its private subnets, so agent egress stays
#     inside the boundary and agents can reach in-VPC services — notably the OTel
#     collector, whose Cloud Map private DNS only resolves in-VPC. (This is why
#     agent_network_mode is NOT overridden here: demo uses the VPC default, same
#     as enterprise. A public-agent posture would leave agents unable to resolve
#     the in-VPC collector and stall on failed telemetry export.)
#   * The same VPC also hosts the observability leg (self-hosted Langfuse + OTel
#     collector, private internal ALB).
#   * Identity = platform-provisioned Cognito (the reference IdP).
#   * IAM roles = platform-created.
#
# NOTE (cost): running agents in-VPC provisions the AgentCore/ECR/logs interface
# endpoints (hourly per-AZ) + NAT — a standing cost demo now pays for a correct,
# secure-by-default posture and working in-VPC telemetry.
#
# See platform/DEPLOY-RUNBOOK.md for full steps.
# =============================================================================

# --- Public console ----------------------------------------------------------
deploy_console = true

# --- Agent traffic: in-VPC (platform default) --------------------------------
# agent_network_mode is intentionally NOT set — it defaults to "VPC". Agents
# attach ENIs to the platform-created VPC's private subnets. (Future: this knob
# is slated for removal so VPC is the only posture — see
# ADR-031.)

# --- VPC: platform-created, hosts agents + the observability leg --------------
# Left empty => the platform creates the VPC (agents + Langfuse + OTel collector
# all run inside it).
vpc_id             = ""
private_subnet_ids = []
public_subnet_ids  = []

# --- Observability: self-hosted Langfuse (private internal ALB) ---------------
deploy_langfuse = true

# --- Identity: platform-provisioned Cognito (reference IdP) -------------------
oidc_discovery_url = ""

# --- AWS-native observability (always on) ------------------------------------
enable_transaction_search = true

# --- Encryption at rest (ADR-035) --------------------------------------------
# Demo uses each resource's AWS-provided default encryption (always encrypted,
# no customer key): AWS-managed aws/s3 for the state bucket, DynamoDB
# service-managed (AWS-owned) for the lifecycle table, AWS-managed keys for
# Langfuse. Leave kms_key_arn unset. Supply a CMK only for poc/pilot.
# kms_key_arn = null
