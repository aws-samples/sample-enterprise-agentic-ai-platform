output "vpc_id" {
  description = "Enterprise VPC ID — feed into enterprise.tfvars vpc_id."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs — where the platform runs agents/Lambdas/Langfuse. Feed into enterprise.tfvars private_subnet_ids AND the internal-ALB slot (public_subnet_ids — an internal ALB only needs AZ coverage, not internet)."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs — NAT + optional manual jumphost only. NOT handed to the platform."
  value       = aws_subnet.public[*].id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

# Ready-to-paste snippet for configs/enterprise.tfvars (network block). The
# 04-gen-tfvars.sh script consumes the structured outputs above; this is a
# human-friendly convenience.
output "enterprise_tfvars_network_snippet" {
  description = "Copy into configs/enterprise.tfvars (or let 04-gen-tfvars.sh do it)."
  value       = <<-EOT
    vpc_id             = "${aws_vpc.this.id}"
    private_subnet_ids = ${jsonencode(aws_subnet.private[*].id)}
    public_subnet_ids  = ${jsonencode(aws_subnet.private[*].id)}  # internal ALB — private subnets are correct
  EOT
}
