/**
 * Discovery hook for the Examples surface (ADR-037, Behavior A).
 *
 * Reads the shared lifecycle DynamoDB table (same table/credentials as
 * useAgents) and groups deployed agents into per-app example entries keyed by
 * the `pattern` field. Each entry carries a 3-state status:
 *   'not_deployed' → 'deploying' → 'ready'
 * 'ready' comes from a lifecycle record existing; 'deploying' is derived from
 * the team-bu-1 deploy pipeline's live execution status. Cards auto-flip via
 * TanStack Query's refetchInterval.
 */
import { useQuery } from '@tanstack/react-query'
import { ScanCommand } from '@aws-sdk/lib-dynamodb'
import { ListPipelineExecutionsCommand } from '@aws-sdk/client-codepipeline'
import { useAuth } from '../auth/CognitoProvider'
import { getDocClient, getPipelineClient, LIFECYCLE_TABLE, isDevBypass } from '../services/awsClients'

// Poll interval for auto-flip (paused when tab unfocused by TanStack default).
const REFETCH_MS = 20_000

// The deploy pipeline that seeds team-bu-1 example agents (ADR-037 seed flow).
const DEPLOY_PIPELINE = import.meta.env.VITE_EXAMPLES_PIPELINE || 'team-bu-1-deploy-pipeline'

export type ExamplePattern = 'standalone' | 'swarm' | 'supervisor' | 'sequential-workflow'
export type ExampleStatus = 'not_deployed' | 'deploying' | 'ready'

export interface TopologyAgent {
  name: string
  role: string
  calls: string[]
  called_by: string[]
  can_call: string[]
  depends_on: string[]
}

export interface TopologyGraph {
  pattern: string
  agents: TopologyAgent[]
}

/** A discovered example = one deployed app, resolved for invocation + display. */
export interface DiscoveredExample {
  appName: string
  pattern: ExamplePattern
  status: ExampleStatus
  /** Entrypoint runtime ARN (standalone/swarm invoke target). */
  runtimeArn: string
  /** Step Functions ARN (supervisor/sequential-workflow invoke target). */
  stateMachineArn: string
  endpointQualifier: string
  /** Runtime name prefix for log/history lookups, e.g. "team_bu_1_rrf_search_app_". */
  runtimePrefix: string
  topology: TopologyGraph | null
  agentCount: number
}

// Raw lifecycle record shape (subset relevant to examples).
interface LifecycleRecord {
  agent_name: string
  app_name?: string
  agent_key?: string
  agent_role?: string
  pattern?: string
  runtime_arn?: string
  state_machine_arn?: string
  endpoint_qualifier?: string
  is_entrypoint?: boolean
  app_topology?: string
  bu?: string
}

function parseTopology(raw?: string): TopologyGraph | null {
  if (!raw) return null
  try {
    return JSON.parse(raw) as TopologyGraph
  } catch {
    return null
  }
}

/** Derive the runtime-name prefix from an entrypoint runtime ARN + app name. */
function deriveRuntimePrefix(record: LifecycleRecord): string {
  // runtime_arn tail is the runtime id; runtime_name is agent_name. The demo-ui
  // log groups use `${domain}_${app}_` — reconstruct from bu + app_name.
  const bu = (record.bu || '').replace(/-/g, '_')
  const app = (record.app_name || '').replace(/-/g, '_')
  if (bu && app) return `${bu}_${app}_`
  // Fallback: strip trailing agent segment from the runtime name.
  return ''
}

const KNOWN_PATTERNS: ExamplePattern[] = ['standalone', 'swarm', 'supervisor', 'sequential-workflow']

function normalizePattern(p?: string): ExamplePattern {
  if (p && (KNOWN_PATTERNS as string[]).includes(p)) return p as ExamplePattern
  // Unknown/multi-agent apps fall back to standalone rendering (rich chat).
  return 'standalone'
}

async function scanLifecycle(token: string | null): Promise<LifecycleRecord[]> {
  const docClient = getDocClient(token)
  const items: LifecycleRecord[] = []
  let lastEvaluatedKey: Record<string, unknown> | undefined
  do {
    const result = await docClient.send(
      new ScanCommand({ TableName: LIFECYCLE_TABLE, ExclusiveStartKey: lastEvaluatedKey })
    )
    if (result.Items) items.push(...(result.Items as LifecycleRecord[]))
    lastEvaluatedKey = result.LastEvaluatedKey as Record<string, unknown> | undefined
  } while (lastEvaluatedKey)
  return items
}

/** Is the deploy pipeline currently running (→ examples are "deploying")? */
async function isPipelineRunning(token: string | null): Promise<boolean> {
  if (isDevBypass(token)) return false
  try {
    const client = getPipelineClient(token)
    const res = await client.send(
      new ListPipelineExecutionsCommand({ pipelineName: DEPLOY_PIPELINE, maxResults: 1 })
    )
    const latest = res.pipelineExecutionSummaries?.[0]
    return latest?.status === 'InProgress'
  } catch {
    // No pipeline / no permission — treat as not running (not_deployed stays).
    return false
  }
}

function groupExamples(records: LifecycleRecord[]): DiscoveredExample[] {
  const byApp = new Map<string, LifecycleRecord[]>()
  for (const r of records) {
    const app = r.app_name || r.agent_name
    if (!app) continue
    if (!byApp.has(app)) byApp.set(app, [])
    byApp.get(app)!.push(r)
  }

  return Array.from(byApp.entries()).map(([appName, recs]) => {
    const entry =
      recs.find((r) => r.is_entrypoint) ||
      recs.find((r) => r.agent_role === 'standalone') ||
      recs[0]
    const pattern = normalizePattern(entry.pattern)
    const stateMachineArn = recs.map((r) => r.state_machine_arn).find((s) => s) || ''
    return {
      appName,
      pattern,
      status: 'ready' as ExampleStatus, // a lifecycle record exists → deployed
      runtimeArn: entry.runtime_arn || '',
      stateMachineArn,
      endpointQualifier: entry.endpoint_qualifier || '',
      runtimePrefix: deriveRuntimePrefix(entry),
      topology: parseTopology(entry.app_topology),
      agentCount: recs.length,
    }
  })
}

/**
 * Discover deployed examples. Returns { examples, pipelineRunning } so the
 * gallery can show a "deploying" banner even before any record lands.
 */
export function useExamples() {
  const { token } = useAuth()

  return useQuery({
    queryKey: ['examples', token],
    enabled: !!token,
    refetchInterval: REFETCH_MS,
    queryFn: async () => {
      const [records, pipelineRunning] = await Promise.all([
        scanLifecycle(token),
        isPipelineRunning(token),
      ])
      return { examples: groupExamples(records), pipelineRunning }
    },
  })
}
