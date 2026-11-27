# EAP Platform VPC
#
# A dedicated platform VPC ("eap") for workloads that need to run inside
# a customer network — currently the third-party observability leg
# (Langfuse_Stack + OTel_Collector). Structurally independent of the AWS-native
# observability leg (CloudWatch/X-Ray), which needs no VPC.
#
# Layout (2 AZs):
#   - 2 public subnets  — internet-facing Langfuse_ALB, NAT gateway
#   - 2 private subnets — Fargate tasks + datastores (Aurora/ClickHouse/Redis)
#   - 1 NAT gateway (single, cost-conscious for dev) for private egress
#   - S3 gateway endpoint is created by the Langfuse module against the private
#     route tables this module exposes.

variable "name" {
  type        = string
  default     = "eap"
  description = "Name prefix / Name tag for the VPC and its resources"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment"
}

variable "cidr_block" {
  type        = string
  default     = "10.20.0.0/16"
  description = "Primary IPv4 CIDR block for the VPC"
}

variable "availability_zones" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "AZs to spread public/private subnets across (>=2, distinct)"

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.20.0.0/20", "10.20.16.0/20"]
  description = "Public subnet CIDRs (one per AZ, same order as availability_zones)"
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = ["10.20.128.0/20", "10.20.144.0/20"]
  description = "Private subnet CIDRs (one per AZ, same order as availability_zones)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all resources"
}

locals {
  az_count = length(var.availability_zones)

  tags = merge(var.tags, {
    "eap:managed"   = "true"
    "eap:component" = "vpc"
    Name            = var.name
  })
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Internet Gateway — public subnet egress/ingress
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # Nothing launched here needs an auto-assigned public IP: the NAT gateway uses
  # an Elastic IP and internet-facing ALBs get their own addresses.
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                     = "${var.name}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/role/elb" = "1"
    tier                     = "public"
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
# NAT Gateway — single, in the first public subnet (dev cost-conscious).
# Provides egress for private-subnet Fargate tasks (image pulls, AWS APIs).
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat-eip" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.tags, { Name = "${var.name}-nat" })

  depends_on = [aws_internet_gateway.this]
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

# One private route table per AZ (each routes to the single NAT gateway).
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-private-rt-${var.availability_zones[count.index]}" })
}

resource "aws_route" "private_nat" {
  count                  = local.az_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "vpc_id" {
  description = "ID of the eap VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (internet-facing ALB)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (Fargate tasks + datastores)"
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Private route table IDs (for S3 gateway VPC endpoint association)"
  value       = aws_route_table.private[*].id
}
