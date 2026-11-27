# ===========================================================================
# Agent network posture (ADR-031) — run AgentCore agent workloads in the VPC
# ===========================================================================
# When agent_network_mode = "VPC" (the enterprise default) AND a VPC is
# resolvable (imported or platform-created), AgentCore attaches ENIs for every
# agent runtime (and the built-in Browser/Code-Interpreter tools, if/when the
# platform instantiates them) in the resolved private subnets. This keeps all
# agent egress inside the enterprise network boundary.
#
# This file provisions the shared network scaffolding that VPC-mode agents need:
#   - a dedicated agent security group (egress-only), and
#   - the VPC endpoints AgentCore + its image/log path require so the boundary
#     holds even without public internet (see agent-endpoints.tf resources
#     below).
# Everything here is GATED on local.agent_vpc_enabled, so a PUBLIC deployment
# (or one with no resolvable VPC) provisions none of it and incurs no cost.
#
# Grounding: AgentCore VPC connectivity — runtimes/tools attach ENIs via the
# service-linked role AWSServiceRoleForBedrockAgentCoreNetwork and only ever
# INITIATE outbound connections (no inbound rules needed on the agent SG):
# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html

# Resolve the VPC CIDR (imported or created) for intra-VPC egress rules. Looked
# up only in VPC mode.
data "aws_vpc" "agents" {
  count = local.agent_vpc_enabled ? 1 : 0
  id    = local.vpc_id
}

# ---------------------------------------------------------------------------
# Agent security group — attached to the AgentCore agent ENIs.
# Egress-only: agents initiate outbound calls (Bedrock/model APIs over 443,
# datastores/tools inside the VPC). No inbound rules — AgentCore runtimes never
# accept inbound connections on these ENIs. Created only when the platform is
# providing the SG (i.e. the deployer did not supply agent_security_group_ids).
# ---------------------------------------------------------------------------
resource "aws_security_group" "agents" {
  count = local.agent_vpc_enabled && length(var.agent_security_group_ids) == 0 ? 1 : 0

  name        = "eap-agents-${var.environment}"
  description = "AgentCore agent ENIs (ADR-031): egress-only; agents only initiate outbound connections."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, {
    Component = "agent-network"
    ManagedBy = "eap-platform"
  })
}

# HTTPS egress to AWS service endpoints (Bedrock model invocation, AgentCore
# control/data APIs, ECR, CloudWatch Logs, Secrets Manager, etc. — reached via
# the VPC endpoints below or the NAT path).
resource "aws_vpc_security_group_egress_rule" "agents_https" {
  count = local.agent_vpc_enabled && length(var.agent_security_group_ids) == 0 ? 1 : 0

  security_group_id = aws_security_group.agents[0].id
  description       = "HTTPS to AWS APIs / VPC endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Intra-VPC egress so agents can reach in-VPC tools/datastores (e.g. gateways,
# databases, the OTel collector) on any port within the VPC CIDR.
resource "aws_vpc_security_group_egress_rule" "agents_intra_vpc" {
  count = local.agent_vpc_enabled && length(var.agent_security_group_ids) == 0 ? 1 : 0

  security_group_id = aws_security_group.agents[0].id
  description       = "All traffic to resources within the VPC (tools, datastores, collector)"
  ip_protocol       = "-1"
  cidr_ipv4         = data.aws_vpc.agents[0].cidr_block
}

# ---------------------------------------------------------------------------
# Lambda security group (ADR-032) — attached to the platform Lambda ENIs when
# they run in-VPC. Same egress-only shape as the agent SG (Lambdas only make
# outbound calls: AgentCore/DynamoDB/CodePipeline/CodeCommit/Logs via the VPC
# endpoints, plus in-VPC targets). Kept SEPARATE from the agent SG so the two
# tiers can evolve independently. Created only in VPC mode.
# ---------------------------------------------------------------------------
resource "aws_security_group" "lambdas" {
  count = local.agent_vpc_enabled ? 1 : 0

  name        = "eap-lambdas-${var.environment}"
  description = "Platform Lambda ENIs (ADR-032): egress-only; Lambdas only initiate outbound connections."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, {
    Component = "agent-network"
    ManagedBy = "eap-platform"
  })
}

resource "aws_vpc_security_group_egress_rule" "lambdas_https" {
  count = local.agent_vpc_enabled ? 1 : 0

  security_group_id = aws_security_group.lambdas[0].id
  description       = "HTTPS to AWS APIs / VPC endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "lambdas_intra_vpc" {
  count = local.agent_vpc_enabled ? 1 : 0

  security_group_id = aws_security_group.lambdas[0].id
  description       = "All traffic to resources within the VPC"
  ip_protocol       = "-1"
  cidr_ipv4         = data.aws_vpc.agents[0].cidr_block
}

# ===========================================================================
# VPC endpoints for VPC-mode agents (ADR-031)
# ===========================================================================
# So the enterprise boundary holds even when the VPC has no public egress,
# provide private paths to the services VPC-mode agents depend on:
#   - AgentCore data plane / control plane / gateway (AWS PrivateLink), so
#     in-VPC callers reach Runtime/Memory/Identity/Built-in-Tools + Gateway
#     APIs without internet traversal (the managed AgentCore services can't be
#     "placed" in the VPC — this is how their traffic stays private).
#   - ECR (api + dkr) + S3 gateway (ECR image layers) so AgentCore can pull the
#     agent container image; CloudWatch Logs for agent logging.
# Everything here is gated on local.agent_vpc_enabled, so PUBLIC deployments
# provision (and pay for) none of it.
#
# Service names verified against:
# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/vpc-interface-endpoints.html
#   data plane   = com.amazonaws.<region>.bedrock-agentcore
#   control plane = com.amazonaws.<region>.bedrock-agentcore-control
#   gateway      = com.amazonaws.<region>.bedrock-agentcore.gateway

locals {
  # Interface endpoints created in VPC mode. Two groups:
  #   - AgentCore (data/control/gateway) + the container image/log path
  #     (ECR api/dkr + Logs) — needed by the AgentCore agent runtimes (ADR-031).
  #   - The control-plane services the platform Lambdas call in-VPC (ADR-032):
  #     CodePipeline, CodeCommit API (codecommit — GetFolder/GetFile via SDK,
  #     distinct from the Git endpoint), CloudWatch (monitoring, for
  #     PutMetricData), SSM (base image reads the collector-endpoint param at
  #     boot), and execute-api (prerequisite for a future PRIVATE REST API).
  #     The Git endpoint (git-codecommit) is also included so a no-egress
  #     install can `git pull` during pipeline/image builds.
  # S3 + DynamoDB are separate GATEWAY endpoints (below). Keyed so the map
  # drives a single aws_vpc_endpoint resource.
  agent_interface_endpoints = local.agent_vpc_enabled ? {
    agentcore_data    = "com.amazonaws.${var.aws_region}.bedrock-agentcore"
    agentcore_control = "com.amazonaws.${var.aws_region}.bedrock-agentcore-control"
    agentcore_gateway = "com.amazonaws.${var.aws_region}.bedrock-agentcore.gateway"
    ecr_api           = "com.amazonaws.${var.aws_region}.ecr.api"
    ecr_dkr           = "com.amazonaws.${var.aws_region}.ecr.dkr"
    logs              = "com.amazonaws.${var.aws_region}.logs"
    codepipeline      = "com.amazonaws.${var.aws_region}.codepipeline"
    codecommit_api    = "com.amazonaws.${var.aws_region}.codecommit"
    codecommit_git    = "com.amazonaws.${var.aws_region}.git-codecommit"
    monitoring        = "com.amazonaws.${var.aws_region}.monitoring"
    ssm               = "com.amazonaws.${var.aws_region}.ssm"
    execute_api       = "com.amazonaws.${var.aws_region}.execute-api"
  } : {}

  # Gateway endpoints (S3 + DynamoDB) associate to ROUTE TABLES, which the
  # platform only knows for a VPC IT created. For an IMPORTED VPC the deployer
  # owns their VPC's gateway endpoints/routing (see runbook), so we skip them.
  #
  # Gate on local.create_vpc (a PLAN-TIME-KNOWN input: var.vpc_id == "") rather
  # than length(local.private_route_table_ids) > 0 — the latter is unknown at
  # plan for a platform-created VPC (the route tables don't exist yet), which
  # made this count unresolvable and forced a -target'd staged apply. The route
  # table IDs still flow into the resource body below (unknown args resolve at
  # apply); only the COUNT must be known at plan. create_vpc==true implies the
  # platform-created VPC WILL have private route tables, so this is equivalent.
  create_gateway_endpoints = local.agent_vpc_enabled && local.create_vpc

  # A GATEWAY endpoint adds a prefix-list route to the WHOLE route table, so at
  # most ONE per (service, route table) — a second create errors RouteAlreadyExists.
  # The optional Langfuse stack already creates an S3 gateway endpoint on these
  # same private route tables (it shares local.private_route_table_ids), and that
  # single endpoint serves every instance in the subnets (agents included) — so
  # our own agent_s3 would duplicate it exactly when deploy_langfuse is on.
  # Create agent_s3 only when Langfuse is NOT providing one; DynamoDB has no such
  # peer (Langfuse creates only S3), so it stays on create_gateway_endpoints.
  create_s3_gateway_endpoint = local.create_gateway_endpoints && !local.deploy_langfuse
}

# Security group for the interface-endpoint ENIs: allow 443 from within the VPC
# (agent ENIs + Fargate reach the endpoints); egress open (standard for
# endpoint SGs). Created only in VPC mode.
resource "aws_security_group" "agent_endpoints" {
  count = local.agent_vpc_enabled ? 1 : 0

  name        = "eap-agent-endpoints-${var.environment}"
  description = "AgentCore/ECR/Logs interface VPC endpoints (ADR-031): 443 ingress from within the VPC."
  vpc_id      = local.vpc_id

  tags = merge(var.tags, {
    Component = "agent-network"
    ManagedBy = "eap-platform"
  })
}

resource "aws_vpc_security_group_ingress_rule" "agent_endpoints_https" {
  count = local.agent_vpc_enabled ? 1 : 0

  security_group_id = aws_security_group.agent_endpoints[0].id
  description       = "HTTPS from within the VPC (agent ENIs reach the endpoints)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = data.aws_vpc.agents[0].cidr_block
}

resource "aws_vpc_security_group_egress_rule" "agent_endpoints_all" {
  count = local.agent_vpc_enabled ? 1 : 0

  security_group_id = aws_security_group.agent_endpoints[0].id
  description       = "Endpoint ENIs egress (all)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Interface endpoints — AgentCore (data/control/gateway) + ECR (api/dkr) + Logs.
# private_dns_enabled so agents resolve the default regional DNS names to the
# endpoint ENIs (no client-side endpoint override needed).
resource "aws_vpc_endpoint" "agent" {
  for_each = local.agent_interface_endpoints

  vpc_id              = local.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnet_ids
  security_group_ids  = [aws_security_group.agent_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name      = "eap-${replace(each.key, "_", "-")}-${var.environment}"
    Component = "agent-network"
    ManagedBy = "eap-platform"
  })
}

# S3 gateway endpoint — free; keeps ECR image-layer pulls (stored in S3) on the
# AWS backbone instead of the NAT path. Only for a platform-created VPC (we know
# its private route tables); imported-VPC deployers own their own (see runbook).
# Skipped when Langfuse is deployed — it already puts an S3 gateway endpoint on
# these same route tables, and one gateway endpoint serves the whole table (a
# second would error RouteAlreadyExists). See create_s3_gateway_endpoint above.
resource "aws_vpc_endpoint" "agent_s3" {
  count = local.create_s3_gateway_endpoint ? 1 : 0

  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = merge(var.tags, {
    Name      = "eap-s3-gateway-${var.environment}"
    Component = "agent-network"
    ManagedBy = "eap-platform"
  })
}

# DynamoDB gateway endpoint — free; keeps the platform services' reads of the
# lifecycle table (studio-read + ADE invoke backends) on the AWS backbone
# (ADR-032).
# Gateway type (like S3), so same created-VPC-only route-table association.
resource "aws_vpc_endpoint" "agent_dynamodb" {
  count = local.create_gateway_endpoints ? 1 : 0

  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = merge(var.tags, {
    Name      = "eap-dynamodb-gateway-${var.environment}"
    Component = "agent-network"
    ManagedBy = "eap-platform"
  })
}
