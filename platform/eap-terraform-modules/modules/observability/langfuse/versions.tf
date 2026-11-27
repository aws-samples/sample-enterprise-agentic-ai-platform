# EAP Langfuse_Stack Module — Providers
#
# The default third-party OTLP backend platform component (Requirement 11.7).
# Requirements: R11.1

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}
