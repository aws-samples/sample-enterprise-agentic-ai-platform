terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  tags = merge(var.tags, {
    "eap:testbed"   = "true"
    "eap:component" = "ssm-jumphost"
    Name            = var.name
  })
}

# Latest Amazon Linux 2023 arm64 AMI (matches t4g.* instance types).
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------------------------------------------------------------------------
# IAM — instance role + profile with the SSM managed policy (SSM-only access).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jumphost" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.jumphost.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jumphost" {
  name = var.name
  role = aws_iam_role.jumphost.name
  tags = local.tags
}

# ---------------------------------------------------------------------------
# Security group — egress-only (SSM needs outbound 443; NO inbound).
# ---------------------------------------------------------------------------
resource "aws_security_group" "jumphost" {
  name        = "${var.name}-sg"
  description = "POC SSM jumphost - egress-only (no inbound; SSM Session Manager)."
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.jumphost.id
  description       = "All outbound (SSM 443 + reaching internal ALBs in-VPC)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Jumphost instance — private subnet, no public IP, SSM-managed. Session
# Manager reaches it through the SSM interface endpoints below; NAT covers any
# other outbound traffic.
# ---------------------------------------------------------------------------
resource "aws_instance" "jumphost" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.jumphost.id]
  iam_instance_profile        = aws_iam_instance_profile.jumphost.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    encrypted = true
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# SSM interface VPC endpoints — give the SSM agent a reliable, private path to
# Systems Manager. Session Manager uses ssmmessages specifically; ssm +
# ec2messages complete the set. The NAT/IGW egress alone proved flaky for
# sustaining the ssmmessages WebSocket, so provide the endpoints. Placed in the
# private subnet the jumphost uses; private_dns_enabled so the agent resolves the
# default regional names to the endpoint ENIs.
#
# NOTE: this is also the enterprise-correct pattern — a no-public-egress VPC
# REQUIRES these endpoints for SSM to work at all.
# ---------------------------------------------------------------------------
data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "ssm_endpoints" {
  name        = "${var.name}-ssm-endpoints-sg"
  description = "HTTPS from within the VPC to the SSM interface endpoints."
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "ssm_https" {
  security_group_id = aws_security_group.ssm_endpoints.id
  description       = "HTTPS from within the VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "ssm_all" {
  security_group_id = aws_security_group.ssm_endpoints.id
  description       = "Endpoint ENIs egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Only ssmmessages + ec2messages here. The platform (ADR-032, VPC mode) already
# creates the `ssm` interface endpoint with private DNS, so adding another would
# conflict (one private-DNS endpoint per service per VPC). ssmmessages is the
# one Session Manager's interactive channel actually needs.
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssmmessages", "ec2messages"])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.name}-${each.key}" })
}
