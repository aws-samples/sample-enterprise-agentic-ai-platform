# EAP Code Interpreter Module — Outputs

output "id" {
  description = "Unique identifier of the Code Interpreter"
  value       = aws_bedrockagentcore_code_interpreter.this.code_interpreter_id
}

output "arn" {
  description = "ARN of the Code Interpreter"
  value       = aws_bedrockagentcore_code_interpreter.this.code_interpreter_arn
}

output "name" {
  description = "Name of the Code Interpreter"
  value       = aws_bedrockagentcore_code_interpreter.this.name
}

output "domain" {
  description = "Domain this code interpreter belongs to"
  value       = var.domain
}
