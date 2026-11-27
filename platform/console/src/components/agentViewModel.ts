/**
 * agentViewModel — the normalized shape the shared UnifiedAgentView renders,
 * plus adapters from the two source models (Examples' DiscoveredExample and the
 * Build workspace's DeployedAgent) into it.
 *
 * This is the glue that lets ONE agent-view template serve every surface: the
 * Examples gallery, the ADE Build workspace, and the App-Directory detail view
 * all produce an AgentViewModel and hand it to UnifiedAgentView.
 */
import type { DiscoveredExample } from '../hooks/useExamples'
import type { DeployedAgent, AppTopology, TopologyAgent } from '../workspaces/build/types'
import type { ApplicationGroup } from '../hooks/useAgents'

/** How the "Run" tab behaves for this agent. */
export type RunMode = 'chat' | 'sfn'

export interface AgentViewModel {
  /** Display name. */
  name: string
  /** One-line description/tagline. */
  description?: string
  /** Normalized pattern (standalone | swarm | supervisor | sequential | ...). */
  pattern: string
  /** 'chat' → ChatRenderer; 'sfn' → Step Functions run panel. */
  runMode: RunMode
  /** Chat transport endpoint (chat runMode). */
  invokeEndpoint?: string
  /** Chat auth mode (chat runMode). */
  authMode?: 'cognito' | 'none'
  /** Invocation target ARN (chat runMode). */
  runtimeArn?: string
  endpointQualifier?: string
  /** Step Functions ARN (sfn runMode). */
  stateMachineArn?: string
  /** CloudWatch runtime log-group prefix for the Logs tab. */
  runtimePrefix?: string
  /** DeployedAgent shape fed to PatternPanel for the Architecture tab. */
  architectureAgent: DeployedAgent
  /** Curated preset prompts (flat) + optional grouped-by-tab. */
  presetPrompts?: string[]
  promptGroups?: Record<string, string[]>
  /**
   * Optional override for the ChatRenderer localStorage cache key
   * (`console-chat:{userId}:{cacheName}`). Defaults to `name`. The ADE detail
   * overlay passes a `detail:<app>` prefix so its conversation never collides
   * with an ADE design-session cache.
   */
  chatCacheName?: string
}

/** SFN patterns run a state machine; the rest are conversational. */
function runModeFor(pattern: string): RunMode {
  const p = (pattern || '').toLowerCase()
  if (p === 'supervisor' || p === 'sequential' || p === 'sequential-workflow') return 'sfn'
  return 'chat'
}

/**
 * Build the DeployedAgent shape PatternPanel expects from a topology graph +
 * pattern. Examples don't carry per-peer DeployedRuntime[]; PatternPanel falls
 * back gracefully to topology-only rendering when runtimes is empty.
 */
function toArchitectureAgent(
  appName: string,
  pattern: string,
  topology: AppTopology | null,
  primaryRuntimeArn: string,
  primaryQualifier: string,
): DeployedAgent {
  return {
    app_name: appName,
    pattern,
    pattern_folder: '',
    primary_runtime_arn: primaryRuntimeArn,
    primary_endpoint_qualifier: primaryQualifier,
    runtimes: [],
    topology: topology ?? null,
  }
}

/** Adapt an Examples DiscoveredExample into the unified view model. */
export function fromExample(
  ex: DiscoveredExample,
  presentation: { title: string; tagline: string; presetPrompts: string[]; promptGroups?: Record<string, string[]> },
): AgentViewModel {
  const runMode = runModeFor(ex.pattern)
  return {
    name: presentation.title,
    description: presentation.tagline,
    pattern: ex.pattern,
    runMode,
    // Examples chat streams through the examples backend, which verifies the
    // caller's Cognito JWT (ADR-046).
    invokeEndpoint: '/examples-api/invoke',
    authMode: 'cognito',
    runtimeArn: ex.runtimeArn,
    endpointQualifier: ex.endpointQualifier,
    stateMachineArn: ex.stateMachineArn,
    runtimePrefix: ex.runtimePrefix,
    architectureAgent: toArchitectureAgent(
      ex.appName,
      ex.pattern,
      ex.topology as AppTopology | null,
      ex.runtimeArn,
      ex.endpointQualifier,
    ),
    presetPrompts: presentation.presetPrompts,
    promptGroups: presentation.promptGroups,
  }
}

/**
 * Adapt a Build-workspace DeployedAgent into the unified view model. These are
 * chat agents streamed through the JWT-validated `/ade-api/invoke` ECS/Fargate
 * backend against their primary runtime — the SAME always-on streaming path the
 * ADE design chat uses, invoked with the agent's `primary_runtime_arn` as the
 * target (the backend enforces the Requirement-11 allow-list, so any deployed
 * runtime is accepted). No API Gateway is involved: every console backend now
 * runs on ALB/Fargate. The Architecture tab uses the agent's own
 * DeployedRuntime[] + topology.
 */
export function fromDeployedAgent(
  agent: DeployedAgent,
  opts?: { runtimePrefix?: string; invokeEndpoint?: string },
): AgentViewModel {
  return {
    name: agent.app_name,
    description: `${agent.pattern || 'standalone'} agent`,
    pattern: agent.pattern || 'standalone',
    runMode: 'chat',
    invokeEndpoint: opts?.invokeEndpoint ?? '/ade-api/invoke',
    authMode: 'cognito',
    runtimeArn: agent.primary_runtime_arn,
    endpointQualifier: agent.primary_endpoint_qualifier,
    runtimePrefix: opts?.runtimePrefix ?? deriveRuntimePrefix(agent),
    architectureAgent: agent,
    // Keep the overlay chat cache disjoint from ADE design sessions.
    chatCacheName: `detail:${agent.app_name}`,
  }
}

/**
 * Derive the CloudWatch runtime log-group prefix (`${bu}_${app}_`, dashes →
 * underscores) for a deployed application, matching
 * `useExamples.deriveRuntimePrefix`. Returns '' when bu/app are unknown, which
 * disables the Logs tab (the pane renders a friendly "no prefix" note).
 */
export function deriveRuntimePrefix(agent: DeployedAgent): string {
  const bu = (agent.bu || '').replace(/-/g, '_')
  const app = (agent.app_name || '').replace(/-/g, '_')
  return bu && app ? `${bu}_${app}_` : ''
}

/**
 * Adapt a directory {@link ApplicationGroup} (from `useAgents` — the lifecycle
 * listing) into the unified view model, for the AppsWorkspace case where the
 * authoritative Deployed_Agents_Service record is NOT available (the directory
 * lists an app the service didn't return). Previously this fell back to a bare
 * ChatRenderer with no right rail; this keeps every selected app on the shared
 * ADE layout (chat-left + Architecture/Logs rail).
 *
 * Honest limits of a directory-only record:
 *   - It carries NO runtime ARN (the directory is lifecycle state, not runtime
 *     wiring). We deliberately do NOT fabricate one — `runtimeArn` stays
 *     undefined, so ChatRenderer renders its normal "unavailable" path rather
 *     than invoking a bogus target. If the app later appears in the
 *     Deployed_Agents_Service, AppsWorkspace prefers `fromDeployedAgent` and
 *     chat works against the real runtime.
 *   - We synthesize a topology from the grouped agent names so the Architecture
 *     tab still renders the pattern; and derive the `${bu}_${app}_` prefix from
 *     the primary agent's `bu` so the Logs tab works. Tabs auto-hide in
 *     UnifiedAgentView when their data is absent.
 */
export function fromApplicationGroup(app: ApplicationGroup): AgentViewModel {
  const pattern = app.architecture || 'standalone'
  // Node name = the part after "app/" in agent_name (e.g. "rrf-search-app/
  // orchestrator" → "orchestrator"); fall back to the full name for standalone.
  const topologyAgents: TopologyAgent[] = app.agents.map((a) => {
    const slash = a.agent_name.indexOf('/')
    const node = slash > 0 ? a.agent_name.slice(slash + 1) : a.agent_name
    const isOrchestrator = /orchestrator|supervisor/i.test(node)
    return {
      name: node,
      role: isOrchestrator ? 'orchestrator' : app.agents.length > 1 ? 'worker' : 'standalone',
      calls: [],
      called_by: [],
      can_call: [],
      depends_on: [],
    }
  })
  const topology: AppTopology | null = topologyAgents.length ? { pattern, agents: topologyAgents } : null

  // Primary agent (orchestrator first, else first) supplies the bu for the
  // Logs runtime prefix — matches how groupByApplication picks its primary.
  const primary = app.agents.find((a) => /orchestrator/i.test(a.agent_name)) ?? app.agents[0]
  const bu = (primary?.bu || '').replace(/-/g, '_')
  const appKey = (app.appName || '').replace(/-/g, '_')
  const runtimePrefix = bu && appKey ? `${bu}_${appKey}_` : ''

  const architectureAgent: DeployedAgent = {
    app_name: app.appName,
    bu: primary?.bu,
    pattern,
    pattern_folder: '',
    primary_runtime_arn: '',
    primary_endpoint_qualifier: '',
    runtimes: [],
    topology,
  }

  return {
    name: app.appName,
    description: `${pattern} agent • v${app.version || '—'}`,
    pattern,
    runMode: runModeFor(pattern),
    // Same transport/auth as a deployed agent; runtimeArn intentionally omitted.
    invokeEndpoint: '/ade-api/invoke',
    authMode: 'cognito',
    runtimeArn: undefined,
    runtimePrefix,
    architectureAgent,
    chatCacheName: `detail:${app.appName}`,
  }
}
