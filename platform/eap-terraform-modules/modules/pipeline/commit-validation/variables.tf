# EAP Commit Validation Module — Variables

variable "codecommit_repo_arns" {
  type        = list(string)
  description = "List of CodeCommit repository ARNs to attach the commit validation trigger to"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Standard resource tags"
}

variable "vpc_config" {
  description = "VPC configuration for the commit-validation Lambda ENIs (ADR-032). When set (VPC mode), the Lambda runs in the enterprise VPC's private subnets and the module grants the ENI-management permissions Lambda-in-VPC requires. Null (default) runs the Lambda outside a VPC."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "role_arn" {
  description = "Pre-created IAM role ARN for the commit-validation Lambda (ADR-033). Empty (default) => the module creates the role + its policies; supplied => the module creates neither and the Lambda uses this ARN."
  type        = string
  default     = ""
}
