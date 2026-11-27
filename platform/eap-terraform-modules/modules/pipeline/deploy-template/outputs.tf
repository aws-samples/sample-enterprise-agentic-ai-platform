# Deploy Template Outputs

output "runtime_endpoints" {
  description = "Map of agent dir → endpoint ARN"
  value       = { for dir, rt in module.runtime : dir => rt.endpoint_arn }
}

output "runtime_ids" {
  description = "Map of agent dir → runtime ID"
  value       = { for dir, rt in module.runtime : dir => rt.id }
}

# ---------------------------------------------------------------------------
# Deployed-agent state — authoritative records for the lifecycle DynamoDB store
# (single source of truth for the console "My Deployed Agents" view).
#
# The Deploy stage buildspec reads `terraform output -json deployed_agents` and
# upserts each record (adding `bu` + `deployed_by`) into the shared table. This
# covers BOTH standalone agents (module.runtime) and multi-agent application
# agents (module.app_runtime), and carries the per-app topology graph parsed
# from application.yaml so the console renders the deployed architecture.
# ---------------------------------------------------------------------------
locals {
  # AgentCore runtime ARN is derivable from the runtime id (the runtime module
  # intentionally does not output `arn` to avoid TF graph cycles).
  _acct   = data.aws_caller_identity.current.account_id
  _region = data.aws_region.current.name

  _orchestrator_roles = ["orchestrator", "supervisor", "coordinator"]

  # Step Functions state-machine ARN per application (empty for non-SFN apps).
  # The console Examples surface (ADR-037) resolves SFN examples by reading this
  # off the lifecycle table — supervisor/sequential-workflow apps invoke the
  # state machine via StartExecution, not an AgentCore runtime directly.
  # module.orchestration is keyed by app_name and only instantiated for
  # local.sfn_apps, so guard the lookup for A2A/standalone apps.
  app_state_machine_arn = {
    for app_name, app in local.apps_by_name : app_name =>
    contains(keys(module.orchestration), app_name) ? module.orchestration[app_name].state_machine_arn : ""
  }

  # Per-application topology graph (pattern + agent edges), JSON-encoded once
  # per app and attached to every agent record of that app.
  app_topology_json = {
    for app_name, app in local.apps_by_name : app_name => jsonencode({
      pattern = try(app.architecture, "multi-agent")
      agents = [
        for ag in try(app.agents, app.steps, []) : {
          name       = ag.name
          role       = lower(try(ag.role, ""))
          calls      = try(ag.calls, [])
          called_by  = try(ag.called_by, [])
          can_call   = try(ag.can_call, [])
          depends_on = try(ag.depends_on, [])
        }
      ]
    })
  }

  # Standalone agents — each is its own single-node "app". module.runtime is
  # keyed by agent NAME (for_each = local.agents_by_name), not by directory.
  standalone_deployed_records = [
    for name, agent in local.agents_by_name : {
      agent_name         = module.runtime[name].name
      app_name           = name
      agent_key          = name
      agent_role         = "standalone"
      pattern            = "standalone"
      runtime_arn        = "arn:aws:bedrock-agentcore:${local._region}:${local._acct}:runtime/${module.runtime[name].id}"
      state_machine_arn  = ""
      endpoint_qualifier = ""
      is_entrypoint      = true
      app_topology = jsonencode({
        pattern = "standalone"
        agents = [{
          name  = name, role = "standalone",
          calls = [], called_by = [], can_call = [], depends_on = []
        }]
      })
    }
  ]

  # Multi-agent application agents.
  multi_deployed_records = [
    for key, a in local.app_agents : {
      agent_name         = local.app_agent_runtime_names[key]
      app_name           = a.app_name
      agent_key          = a.agent_name
      agent_role         = lower(try(a.topology.role, "worker"))
      pattern            = try(a.architecture, "multi-agent")
      runtime_arn        = "arn:aws:bedrock-agentcore:${local._region}:${local._acct}:runtime/${module.app_runtime[key].id}"
      state_machine_arn  = try(local.app_state_machine_arn[a.app_name], "")
      endpoint_qualifier = ""
      is_entrypoint      = contains(local._orchestrator_roles, lower(try(a.topology.role, "")))
      app_topology       = local.app_topology_json[a.app_name]
    }
  ]

  deployed_agent_records = concat(local.standalone_deployed_records, local.multi_deployed_records)
}

output "deployed_agents" {
  description = "Authoritative deployed-agent records upserted into the shared lifecycle table by the Deploy stage (runtime ARN, state machine ARN for SFN apps, app grouping, entrypoint, per-app topology)."
  value       = local.deployed_agent_records
}
