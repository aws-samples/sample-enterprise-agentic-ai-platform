# Gateway Deploy Template — Variables
# Only needs platform state reference + region. Gateway is platform-owned.

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "domain" {
  type        = string
  default     = "shared-services"
  description = "Domain this integration pipeline deploys for"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Platform environment"
}

variable "platform_state_bucket" {
  type        = string
  description = "S3 bucket containing eap-platform state"
}

variable "platform_state_key" {
  type        = string
  default     = "terraform.tfstate"
  description = "State file key in the platform state bucket"
}
