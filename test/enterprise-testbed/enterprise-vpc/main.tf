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
  az_count = length(var.availability_zones)
  # One NAT shared, or one per AZ.
  nat_count = var.single_nat_gateway ? 1 : local.az_count

  tags = merge(var.tags, {
    "eap:testbed"   = "true"
    "eap:component" = "enterprise-vpc"
    Name            = var.name
  })
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true # required for VPC-endpoint private DNS on import
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Internet Gateway — public tier egress/ingress (NAT + optional manual jumphost)
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

# ---------------------------------------------------------------------------
# Subnets — public (NAT/jumphost) + private (platform workloads)
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # NAT uses an Elastic IP and the jumphost sits in a private subnet, so no
  # auto-assigned public IPs are needed.
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name}-public-${var.availability_zones[count.index]}"
    tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.tags, {
    Name = "${var.name}-private-${var.availability_zones[count.index]}"
    tier = "private"
  })
}

# ---------------------------------------------------------------------------
# NAT — one (shared) or one per AZ; lives in the public tier.
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count      = local.nat_count
  domain     = "vpc"
  tags       = merge(local.tags, { Name = "${var.name}-nat-eip-${count.index}" })
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on    = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ. Each routes to a NAT (shared index 0 when
# single_nat_gateway, else the per-AZ NAT).
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-private-rt-${var.availability_zones[count.index]}" })
}

resource "aws_route" "private_nat" {
  count                  = local.az_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# GATEWAY VPC endpoints (S3 + DynamoDB) — the imported-VPC gap.
#
# These associate to the PRIVATE route tables, keeping ECR image-LAYER pulls
# (layers are S3-backed) and the platform Lambdas' DynamoDB lifecycle-table
# reads on the AWS backbone. The platform cannot create these for an imported
# VPC (it does not own these route tables), so the test bed provides them —
# exactly what a real enterprise would pre-provision. Free.
#
# NOTE on posture: a GATEWAY endpoint keeps traffic on the AWS backbone (off the
# public internet) but the destination is S3/DynamoDB PUBLIC IPs. If your
# requirement is strictly private-IP (ENI-in-subnet), use an S3/DynamoDB
# INTERFACE endpoint instead — not done here to keep the fixture simple/free.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.tags, { Name = "${var.name}-s3-gw" })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.tags, { Name = "${var.name}-dynamodb-gw" })
}
