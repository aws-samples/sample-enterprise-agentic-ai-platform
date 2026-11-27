# EAP Platform — Bedrock Model Access
# IAM policy for foundation model invocation, scoped to allowed models per domain.
# Requirements: R21.6, R21.8

variable "environment" {
  type    = string
  default = "dev"
}

variable "allowed_models" {
  type        = list(string)
  default     = ["us.anthropic.claude-sonnet-5"]
  description = "List of Bedrock foundation model IDs allowed for invocation"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# IAM policy that can be attached to agent runtime roles
resource "aws_iam_policy" "bedrock_model_access" {
  name        = "eap-bedrock-model-access-${var.environment}"
  path        = "/eap/"
  description = "Allows invocation of approved Bedrock foundation models"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockModelInvocation"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          for model_id in var.allowed_models :
          "arn:aws:bedrock:*::foundation-model/${model_id}"
        ]
      }
    ]
  })

  tags = merge(var.tags, {
    eap_module = "bedrock-model-access"
  })
}

output "policy_arn" {
  description = "ARN of the Bedrock model access IAM policy"
  value       = aws_iam_policy.bedrock_model_access.arn
}

output "allowed_models" {
  description = "List of allowed foundation model IDs"
  value       = var.allowed_models
}
