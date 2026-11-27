# SSM jumphost — POC test-bed fixture.
#
# A tiny EC2 in a PRIVATE subnet of the enterprise VPC (no public IP), used to reach the
# platform's INTERNAL-only services (e.g. the private Langfuse ALB) from a
# laptop via SSM Session Manager port-forwarding — no open SSH, no keypair.
#
# SSM only: the instance has the AmazonSSMManagedInstanceCore policy and an
# egress-only security group (no inbound). SSM's agent reaches Systems Manager
# over outbound 443 via the SSM interface endpoints (NAT as fallback). Access is then:
#   aws ssm start-session --target <id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"host":["<internal-alb-dns>"],"portNumber":["3000"],"localPortNumber":["3000"]}'
#
# Test scaffolding only — not platform code.

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "eap-poc-ssm-jumphost"
}

variable "vpc_id" {
  type        = string
  description = "Enterprise VPC id (from the enterprise-vpc fixture output)."
}

variable "subnet_id" {
  type        = string
  description = "A PRIVATE subnet id in the VPC (NAT route) for the jumphost. No public IP is assigned."
}

variable "instance_type" {
  type    = string
  default = "t4g.micro" # arm64, matches the AL2023 arm64 AMI below
}

variable "tags" {
  type    = map(string)
  default = {}
}
