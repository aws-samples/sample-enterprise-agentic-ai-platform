# EAP Module Library

Terraform module library for the Enterprise Agentic AI Platform (EAP), built on Amazon Bedrock AgentCore.

## Overview

One Terraform module per AgentCore primitive (1:1 mapping), plus platform-specific modules for domain administration and pipeline orchestration. Published to a private Terraform Registry, versioned independently via semver.

## Modules

| Module | AgentCore Primitive | Primary Consumer |
|--------|---------------------|------------------|
| `modules/runtime` | Runtime | App_Team |
| `modules/memory` | Memory | App_Team |
| `modules/gateway` | Gateway | Shared_Services_Team |
| `modules/identity` | Identity | Platform_Admin |
| `modules/policy` | Policy | Platform_Admin / Domain_Admin |
| `modules/observability` | Observability | Platform_Admin |
| `modules/evaluations` | Evaluations | App_Team / Domain_Admin |
| `modules/code-interpreter` | Code Interpreter | App_Team |
| `modules/browser` | Browser | App_Team |
| `modules/domain` | _(platform)_ | Platform_Admin |
| `modules/pipeline` | _(platform)_ | App_Team |

## Usage

```hcl
module "agent_runtime" {
  source  = "app.terraform.io/eap/runtime/aws"
  version = "~> 1.0"

  name   = "my-agent"
  domain = "my-domain"
  # ...
}
```

## License

Internal use only.
