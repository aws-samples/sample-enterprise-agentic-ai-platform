# KB Deploy Template — Outputs

output "kb_arns" {
  description = "Map of KB name to ARN"
  value = {
    for name, kb in aws_bedrockagent_knowledge_base.this : name => kb.arn
  }
}

output "gateway_target_names" {
  description = "Map of KB name to gateway target name"
  value = {
    for name, target in aws_bedrockagentcore_gateway_target.kb : name => target.name
  }
}
