# EAP Platform — CodeCommit Source Repositories
# Provisions CodeCommit repos for app team agent code.
# Platform_Admin owns repo creation; app teams push code.

variable "repositories" {
  type = map(object({
    description = optional(string, "")
  }))
  description = "Map of repository name to configuration"
  default = {
    team-bu-1 = {
      description = "Agentic AI agents for Business Unit 1"
    }
    nocode-user = {
      description = "Agents created by non-technical users via the Agent Deployment Engineer"
    }
    mcp-integrations = {
      description = "MCP server + tool/data integrations — Gateway YAML sources"
    }
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_codecommit_repository" "this" {
  for_each = var.repositories

  repository_name = each.key
  description     = each.value.description

  tags = merge(var.tags, {
    "eap:managed"   = "true"
    "eap:component" = "source-repo"
  })
}

output "repository_clone_urls" {
  description = "Map of repo name to clone URL (GRC format)"
  value       = { for k, v in aws_codecommit_repository.this : k => v.clone_url_http }
}

output "repository_arns" {
  description = "Map of repo name to ARN"
  value       = { for k, v in aws_codecommit_repository.this : k => v.arn }
}
