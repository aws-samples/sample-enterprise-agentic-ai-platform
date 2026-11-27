# EAP Browser Module — Outputs

output "id" {
  description = "Unique identifier of the Browser"
  value       = aws_bedrockagentcore_browser.this.browser_id
}

output "arn" {
  description = "ARN of the Browser"
  value       = aws_bedrockagentcore_browser.this.browser_arn
}

output "name" {
  description = "Name of the Browser"
  value       = aws_bedrockagentcore_browser.this.name
}

output "domain" {
  description = "Domain this browser belongs to"
  value       = var.domain
}
