output "instance_id" {
  description = "SSM jumphost instance id — the --target for aws ssm start-session."
  value       = aws_instance.jumphost.id
}

# Convenience: the exact port-forward command to reach an internal service.
# Fill in the internal ALB DNS (e.g. terraform output langfuse_base_url host).
output "ssm_port_forward_hint" {
  description = "Template SSM port-forward command; substitute the internal host + port."
  value       = <<-EOT
    aws ssm start-session --region ${var.aws_region} \
      --target ${aws_instance.jumphost.id} \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters '{"host":["<internal-alb-dns>"],"portNumber":["<port>"],"localPortNumber":["3000"]}'
    # then open http://localhost:3000
  EOT
}
