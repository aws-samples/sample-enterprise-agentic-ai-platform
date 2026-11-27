# Deploy Template Outputs

output "runtime_endpoints" {
  description = "Map of agent dir → endpoint ARN"
  value       = { for dir, rt in module.runtime : dir => rt.endpoint_arn }
}

output "runtime_ids" {
  description = "Map of agent dir → runtime ID"
  value       = { for dir, rt in module.runtime : dir => rt.id }
}
