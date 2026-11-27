# EAP Platform — Outputs

# --- Identity / OIDC outputs (ADR-028) ---
# Cognito-specific outputs are null when an external OIDC IdP is supplied
# (module.identity is not created). oidc_discovery_url below is the resolved,
# IdP-agnostic value every consumer uses.

output "oidc_discovery_url" {
  description = "Resolved OIDC discovery URL used platform-wide for JWT validation — the external IdP when oidc_discovery_url is set, otherwise the platform-created Cognito pool."
  value       = local.oidc_discovery_url
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID for agent identity. Null when an external OIDC IdP is used."
  value       = one(module.identity[*].user_pool_id)
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN. Null when an external OIDC IdP is used."
  value       = one(module.identity[*].user_pool_arn)
}

output "cognito_oidc_discovery_url" {
  description = "OIDC discovery URL of the platform-created Cognito pool. Null when an external OIDC IdP is used. Prefer oidc_discovery_url for the resolved value."
  value       = one(module.identity[*].oidc_discovery_url)
}

output "cognito_token_endpoint" {
  description = "OAuth2 token endpoint for client credentials flow. Null when an external OIDC IdP is used."
  value       = one(module.identity[*].token_endpoint)
}

output "cognito_gateway_scope" {
  description = "Full scope identifier for gateway tools invoke. Null when an external OIDC IdP is used."
  value       = one(module.identity[*].gateway_scope_invoke)
}

output "cognito_agent_scope" {
  description = "Full scope identifier for agent invoke. Null when an external OIDC IdP is used."
  value       = one(module.identity[*].agent_scope_invoke)
}

output "bedrock_model_access_policy_arn" {
  description = "IAM policy ARN for Bedrock model invocation"
  value       = module.bedrock_model_access.policy_arn
}

output "domain_cognito_groups" {
  description = "Map of domain name to Cognito group name"
  value       = module.domains.domain_cognito_groups
}

output "domain_boundary_arns" {
  description = "Map of domain name to IAM permission boundary ARN"
  value       = module.domains.domain_boundary_arns
}

# --- Pipeline outputs ---

output "pipeline_names" {
  description = "Map of pipeline key to CodePipeline name"
  value       = module.pipelines.pipeline_names
}

output "pipeline_arns" {
  description = "Map of pipeline key to CodePipeline ARN"
  value       = module.pipelines.pipeline_arns
}

# --- Source repo outputs ---

output "source_repository_clone_urls" {
  description = "Map of repo name to CodeCommit clone URL"
  value       = module.source_repos.repository_clone_urls
}

# --- Gateway outputs (consumed by integration/governance pipelines via terraform_remote_state) ---

output "gateway_id" {
  description = "AgentCore Gateway ID for downstream target attachment"
  value       = module.gateway.id
}

output "gateway_arn" {
  description = "AgentCore Gateway ARN"
  value       = module.gateway.arn
}

output "gateway_url" {
  description = "AgentCore Gateway URL endpoint"
  value       = module.gateway.url
}

output "policy_engine_id" {
  description = "Cedar policy engine ID for governance repo to attach policies"
  value       = module.gateway.policy_engine_id
}

output "policy_engine_arn" {
  description = "Cedar policy engine ARN"
  value       = module.gateway.policy_engine_arn
}

# --- ECR outputs ---

output "ecr_repository_url" {
  description = "ECR repository URL for agent images"
  value       = module.ecr.repository_url
}

output "ecr_base_image_repository_url" {
  description = "ECR repository URL for base images"
  value       = module.ecr.base_image_repository_url
}

# --- Observability outputs ---

output "observability_role_arn" {
  description = "ARN of the read-only Observability_Role (Deep_Link_Service / Telemetry_API_Service). Resolves to the deployer-supplied observability_role_arn when set (ADR-033), else the platform-created role. Null when the role is neither supplied nor created (enable_observability_role = false)."
  value       = local.observability_role_arn
}

output "observability_role_name" {
  description = "Name of the platform-created Observability_Role. Null when enable_observability_role is false OR an external observability_role_arn was supplied (the platform did not create the role)."
  value       = one(aws_iam_role.observability[*].name)
}

output "otel_collector_otlp_grpc_endpoint" {
  description = "In-VPC OTLP/gRPC endpoint of the platform OTel_Collector (third-party leg). The collector is always deployed (ADR-030). The base-image Additional_Span_Exporter resolves the OTLP/HTTP endpoint from SSM; this gRPC endpoint is exposed for reference."
  value       = module.otel_collector.otlp_grpc_endpoint
}

output "otel_collector_task_role_arn" {
  description = "IAM task role ARN of the OTel_Collector (third-party auth secrets read only; no telemetry write)."
  value       = module.otel_collector.task_role_arn
}

output "langfuse_base_url" {
  description = "Private internal base URL (http://<internal-alb-dns>) of the self-hosted Langfuse stack. Null when deploy_langfuse=false."
  value       = one(module.langfuse[*].langfuse_base_url)
}

output "langfuse_otlp_endpoint" {
  description = "Langfuse OTLP receiver endpoint used as the default third-party exporter by the OTel_Collector. Null when the third-party observability leg is not enabled."
  value       = one(module.langfuse[*].langfuse_otlp_endpoint)
}

output "collector_endpoint_ssm_param_name" {
  description = "Fixed SSM parameter NAME publishing the OTel_Collector's stable OTLP/HTTP endpoint (third-party leg). Deploy paths reference this name only to scope the agent role's ssm:GetParameter grant; the base image reads the value at boot from the same fixed path. Stable constant regardless of whether the parameter is currently published."
  value       = local.collector_endpoint_ssm_param_name
}

output "collector_endpoint_ssm_param_arn" {
  description = "ARN of the published collector-endpoint SSM parameter. Null when the third-party observability leg is not enabled or the collector exposes no resolvable endpoint. Deploy paths scope ssm:GetParameter to this ARN."
  value       = one(aws_ssm_parameter.collector_endpoint[*].arn)
}

# --- Platform VPC ("eap") ---

output "vpc_id" {
  description = "ID of the platform-CREATED eap VPC (used for the observability leg and, in VPC mode, agent ENIs). Null when a VPC was imported (var.vpc_id set) rather than created. For the VPC actually in use either way, see agent_network_vpc_id."
  value       = one(module.vpc[*].vpc_id)
}

output "vpc_public_subnet_ids" {
  description = "Public subnet IDs of the platform-created eap VPC. Null when a VPC was imported."
  value       = one(module.vpc[*].public_subnet_ids)
}

output "vpc_private_subnet_ids" {
  description = "Private subnet IDs of the platform-created eap VPC. Null when a VPC was imported."
  value       = one(module.vpc[*].private_subnet_ids)
}

# --- Agent network posture (ADR-031) ---

output "agent_network_posture" {
  description = "Effective network posture for AgentCore agent workloads. 'VPC' means agent ENIs run in the resolved VPC's private subnets (enterprise boundary). 'PUBLIC' means AgentCore-managed public endpoints — either because agent_network_mode=PUBLIC was set, or VPC was requested but no VPC resolved."
  value       = local.agent_effective_network_mode
}

output "agent_network_vpc_id" {
  description = "The VPC ID agents run in when in VPC mode (imported or platform-created). Empty string in PUBLIC mode."
  value       = local.agent_vpc_enabled ? local.vpc_id : ""
}

output "agent_security_group_ids" {
  description = "Security group IDs attached to the AgentCore agent ENIs in VPC mode (platform-created agent SG or deployer-supplied). Empty in PUBLIC mode."
  value       = local.agent_security_group_ids
}

# Surface the PUBLIC fallback at plan/apply time so it is a conscious choice,
# not a silent default. This fires only when VPC was REQUESTED (the enterprise
# default) but could not be honored because no VPC resolved — the one case a
# deployer most likely did not intend.
check "agent_network_posture" {
  assert {
    condition     = !(local.agent_vpc_requested && !local.agent_vpc_enabled)
    error_message = "agent_network_mode = \"VPC\" was requested but no VPC resolved (set var.vpc_id to import one, or leave it empty to have the platform create one). Agents will fall back to AgentCore-managed PUBLIC endpoints — traffic will NOT stay within the enterprise VPC boundary. Set agent_network_mode = \"PUBLIC\" to make this explicit, or provide a VPC."
  }
}

