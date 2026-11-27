# Enterprise VPC — POC test-bed fixture.
#
# Simulates a customer's governed VPC that the EAP platform is imported
# INTO (POC mode). Deliberately a test fixture: it stands in for the network the
# enterprise would bring. It is NOT platform code and is never shipped to a
# customer.
#
# Shape: 3 AZs, public + private tiers.
#   - public  : IGW + a single NAT gateway (and room for a manual jumphost).
#               No platform workloads run here.
#   - private : agents, platform Lambdas, and the Langfuse stack run here.
#               Default route -> NAT for egress; S3 + DynamoDB reachable via the
#               GATEWAY VPC endpoints below (the imported-VPC gap the platform
#               does not fill).
#
# The platform auto-creates the INTERFACE endpoints (AgentCore, ECR api+dkr,
# Logs, monitoring, CodePipeline, CodeCommit, SSM, execute-api) on import, so we
# deliberately do NOT create those here (they would collide). We only create the
# S3 + DynamoDB GATEWAY endpoints, which the platform cannot create for an
# imported VPC (they attach to route tables it does not own).

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Region for the test-bed VPC."
}

variable "name" {
  type        = string
  default     = "enterprise-vpc"
  description = "Name prefix / Name tag."
}

variable "cidr_block" {
  type        = string
  default     = "10.30.0.0/16"
  description = "VPC CIDR. Distinct from the platform-created VPC's 10.20.0.0/16 to avoid confusion."
}

variable "availability_zones" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
  description = <<-EOT
    AZs to spread the public/private subnets across (3). NOTE: AgentCore requires
    its workloads to land on SUPPORTED AZ IDs (not just names). Verify with:
      aws ec2 describe-subnets --subnet-ids <id> --query 'Subnets[0].AvailabilityZoneId'
    and cross-reference the AgentCore VPC docs' supported-AZ table before deploy.
  EOT

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.30.0.0/20", "10.30.16.0/20", "10.30.32.0/20"]
  description = "Public subnet CIDRs (one per AZ, same order as availability_zones)."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = ["10.30.128.0/20", "10.30.144.0/20", "10.30.160.0/20"]
  description = "Private subnet CIDRs (one per AZ, same order as availability_zones)."
}

variable "single_nat_gateway" {
  type        = bool
  default     = true
  description = "true (default, cost-conscious) => one NAT gateway shared by all private subnets. false => one NAT per AZ (HA)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all resources."
}
