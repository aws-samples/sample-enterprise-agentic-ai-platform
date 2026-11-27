/**
 * React Query hook to fetch all agents from the DynamoDB lifecycle table.
 * Returns agent lifecycle state for use across workspaces.
 */
import { useQuery } from '@tanstack/react-query'
import { ScanCommand } from '@aws-sdk/lib-dynamodb'
import { useAuth } from '../auth/CognitoProvider'
import { getDocClient, LIFECYCLE_TABLE, isDevBypass } from '../services/awsClients'

// --- Types matching the lifecycle state schema ---
export interface AgentLifecycleItem {
  agent_name: string
  current_state: 'enrolled' | 'training' | 'validated' | 'graduated' | 'production'
  version: string
  commit_sha: string
  last_transition: string
  state_history: Array<{
    from_state: string
    to_state: string
    timestamp: string
    trigger: string
    version: string
    commit_sha: string
    pipeline_execution_id?: string
  }>
  graduation_reports: Array<{
    report_id: string
    environment: string
    version: string
    timestamp: string
    scores: Record<string, number>
    red_team_pass: boolean
    verdict: string
    approver: string
  }>
  // Optional fields that may be present
  kb_status?: string
  kb_name?: string
  kb_last_sync?: string
  data_sources?: string[]
  eval_score?: number
  red_team_pass?: boolean
  last_evaluated?: string
  bu?: string
  domain?: string
  image_tag?: string
}

// --- Mock data for dev bypass mode ---
const MOCK_AGENTS: AgentLifecycleItem[] = [
  {
    agent_name: 'rrf-search-app/orchestrator',
    current_state: 'graduated',
    version: '1.3.0',
    commit_sha: 'a1b2c3d4',
    last_transition: '2024-12-15T10:30:00Z',
    state_history: [
      { from_state: '(new)', to_state: 'enrolled', timestamp: '2024-12-01T08:00:00Z', trigger: 'pipeline:enrolled', version: '1.0.0', commit_sha: 'abc123' },
      { from_state: 'enrolled', to_state: 'training', timestamp: '2024-12-05T09:00:00Z', trigger: 'pipeline:training', version: '1.1.0', commit_sha: 'def456' },
      { from_state: 'training', to_state: 'validated', timestamp: '2024-12-10T14:00:00Z', trigger: 'pipeline:validated', version: '1.2.0', commit_sha: 'ghi789' },
      { from_state: 'validated', to_state: 'graduated', timestamp: '2024-12-15T10:30:00Z', trigger: 'pipeline:graduated', version: '1.3.0', commit_sha: 'a1b2c3d4' },
    ],
    graduation_reports: [
      { report_id: 'rpt-001', environment: 'qa', version: '1.3.0', timestamp: '2024-12-15T10:00:00Z', scores: { safety: 0.95, correctness: 0.88, helpfulness: 0.82 }, red_team_pass: true, verdict: 'PASS', approver: 'pipeline:automated' },
    ],
    kb_status: 'synced',
    kb_name: 'rrf-knowledge-base',
    kb_last_sync: '2024-12-15T08:00:00Z',
    eval_score: 0.88,
    red_team_pass: true,
    last_evaluated: '2024-12-15T10:00:00Z',
  },
  {
    agent_name: 'claims-processor/main',
    current_state: 'training',
    version: '0.2.0',
    commit_sha: 'xyz789',
    last_transition: '2024-12-14T16:00:00Z',
    state_history: [
      { from_state: '(new)', to_state: 'enrolled', timestamp: '2024-12-10T12:00:00Z', trigger: 'pipeline:enrolled', version: '0.1.0', commit_sha: 'lmn456' },
      { from_state: 'enrolled', to_state: 'training', timestamp: '2024-12-14T16:00:00Z', trigger: 'pipeline:training', version: '0.2.0', commit_sha: 'xyz789' },
    ],
    graduation_reports: [],
    eval_score: 0.65,
    red_team_pass: false,
    last_evaluated: '2024-12-14T15:00:00Z',
  },
  {
    agent_name: 'policy-search-agent/v2',
    current_state: 'production',
    version: '2.1.0',
    commit_sha: 'prod123',
    last_transition: '2024-12-12T09:00:00Z',
    state_history: [
      { from_state: '(new)', to_state: 'enrolled', timestamp: '2024-11-20T10:00:00Z', trigger: 'pipeline:enrolled', version: '1.0.0', commit_sha: 'init01' },
      { from_state: 'enrolled', to_state: 'training', timestamp: '2024-11-22T14:00:00Z', trigger: 'pipeline:training', version: '1.1.0', commit_sha: 'trn01' },
      { from_state: 'training', to_state: 'validated', timestamp: '2024-11-28T11:00:00Z', trigger: 'pipeline:validated', version: '2.0.0', commit_sha: 'val01' },
      { from_state: 'validated', to_state: 'graduated', timestamp: '2024-12-05T16:00:00Z', trigger: 'pipeline:graduated', version: '2.0.0', commit_sha: 'grad01' },
      { from_state: 'graduated', to_state: 'production', timestamp: '2024-12-12T09:00:00Z', trigger: 'pipeline:production', version: '2.1.0', commit_sha: 'prod123' },
    ],
    graduation_reports: [
      { report_id: 'rpt-002', environment: 'qa', version: '2.0.0', timestamp: '2024-12-05T15:00:00Z', scores: { safety: 0.97, correctness: 0.92, helpfulness: 0.90 }, red_team_pass: true, verdict: 'PASS', approver: 'pipeline:automated' },
      { report_id: 'rpt-003', environment: 'prod', version: '2.1.0', timestamp: '2024-12-12T08:30:00Z', scores: { safety: 0.96, correctness: 0.91, helpfulness: 0.89 }, red_team_pass: true, verdict: 'PASS', approver: 'pipeline:automated' },
    ],
    kb_status: 'synced',
    kb_name: 'policy-knowledge-base',
    kb_last_sync: '2024-12-14T06:00:00Z',
    data_sources: ['policy-docs-s3', 'claims-history-s3'],
    eval_score: 0.92,
    red_team_pass: true,
    last_evaluated: '2024-12-12T08:30:00Z',
  },
  {
    agent_name: 'policy-qa-bot/chat',
    current_state: 'validated',
    version: '1.0.0',
    commit_sha: 'pqa100',
    last_transition: '2024-12-13T11:00:00Z',
    state_history: [
      { from_state: '(new)', to_state: 'enrolled', timestamp: '2024-12-08T09:00:00Z', trigger: 'pipeline:enrolled', version: '0.1.0', commit_sha: 'pqa01' },
      { from_state: 'enrolled', to_state: 'training', timestamp: '2024-12-10T10:00:00Z', trigger: 'pipeline:training', version: '0.2.0', commit_sha: 'pqa02' },
      { from_state: 'training', to_state: 'validated', timestamp: '2024-12-13T11:00:00Z', trigger: 'pipeline:validated', version: '1.0.0', commit_sha: 'pqa100' },
    ],
    graduation_reports: [],
    kb_status: 'syncing',
    kb_name: 'policy-docs-kb',
    kb_last_sync: '2024-12-13T10:00:00Z',
    eval_score: 0.78,
    red_team_pass: true,
    last_evaluated: '2024-12-13T10:30:00Z',
  },
  // Multi-agent application: rrf-search-app has multiple agents
  {
    agent_name: 'rrf-search-app/web-retriever',
    current_state: 'graduated',
    version: '1.3.0',
    commit_sha: 'a1b2c3d4',
    last_transition: '2024-12-15T10:30:00Z',
    state_history: [
      { from_state: '(new)', to_state: 'enrolled', timestamp: '2024-12-01T08:00:00Z', trigger: 'pipeline:enrolled', version: '1.0.0', commit_sha: 'abc123' },
      { from_state: 'enrolled', to_state: 'training', timestamp: '2024-12-05T09:00:00Z', trigger: 'pipeline:training', version: '1.1.0', commit_sha: 'def456' },
      { from_state: 'training', to_state: 'validated', timestamp: '2024-12-10T14:00:00Z', trigger: 'pipeline:validated', version: '1.2.0', commit_sha: 'ghi789' },
      { from_state: 'validated', to_state: 'graduated', timestamp: '2024-12-15T10:30:00Z', trigger: 'pipeline:graduated', version: '1.3.0', commit_sha: 'a1b2c3d4' },
    ],
    graduation_reports: [],
    eval_score: 0.90,
    red_team_pass: true,
    last_evaluated: '2024-12-15T10:00:00Z',
  },
  {
    agent_name: 'rrf-search-app/academic-retriever',
    current_state: 'graduated',
    version: '1.3.0',
    commit_sha: 'a1b2c3d4',
    last_transition: '2024-12-15T10:30:00Z',
    state_history: [
      { from_state: '(new)', to_state: 'enrolled', timestamp: '2024-12-01T08:00:00Z', trigger: 'pipeline:enrolled', version: '1.0.0', commit_sha: 'abc123' },
      { from_state: 'enrolled', to_state: 'training', timestamp: '2024-12-05T09:00:00Z', trigger: 'pipeline:training', version: '1.1.0', commit_sha: 'def456' },
      { from_state: 'training', to_state: 'validated', timestamp: '2024-12-10T14:00:00Z', trigger: 'pipeline:validated', version: '1.2.0', commit_sha: 'ghi789' },
      { from_state: 'validated', to_state: 'graduated', timestamp: '2024-12-15T10:30:00Z', trigger: 'pipeline:graduated', version: '1.3.0', commit_sha: 'a1b2c3d4' },
    ],
    graduation_reports: [],
    eval_score: 0.87,
    red_team_pass: true,
    last_evaluated: '2024-12-15T10:00:00Z',
  },
]

async function fetchAgents(token: string | null): Promise<AgentLifecycleItem[]> {
  if (isDevBypass(token)) {
    return MOCK_AGENTS
  }

  const docClient = getDocClient(token)
  const items: AgentLifecycleItem[] = []
  let lastEvaluatedKey: Record<string, unknown> | undefined

  // Paginated scan of the lifecycle table
  do {
    const result = await docClient.send(
      new ScanCommand({
        TableName: LIFECYCLE_TABLE,
        ExclusiveStartKey: lastEvaluatedKey,
      })
    )
    if (result.Items) {
      items.push(...(result.Items as AgentLifecycleItem[]))
    }
    lastEvaluatedKey = result.LastEvaluatedKey as Record<string, unknown> | undefined
  } while (lastEvaluatedKey)

  return items
}

/**
 * Hook to fetch all agents from the lifecycle DynamoDB table.
 */
export function useAgents() {
  const { token } = useAuth()

  return useQuery<AgentLifecycleItem[], Error>({
    queryKey: ['agents', token],
    queryFn: () => fetchAgents(token),
    enabled: !!token,
  })
}

// --- Application grouping ---

export interface ApplicationGroup {
  appName: string
  agents: AgentLifecycleItem[]
  // Derived from the "primary" agent (first one / orchestrator)
  current_state: AgentLifecycleItem['current_state']
  version: string
  last_transition: string
  architecture: 'standalone' | 'supervisor' | 'sequential' | 'swarm'
  agentCount: number
}

/**
 * Groups flat agent records into application-level entities.
 * For multi-agent architectures, the application is the deployable unit.
 */
export function groupByApplication(agents: AgentLifecycleItem[]): ApplicationGroup[] {
  const appMap = new Map<string, AgentLifecycleItem[]>()

  for (const agent of agents) {
    const slashIdx = agent.agent_name.indexOf('/')
    const appName = slashIdx > 0 ? agent.agent_name.substring(0, slashIdx) : agent.agent_name
    if (!appMap.has(appName)) appMap.set(appName, [])
    appMap.get(appName)!.push(agent)
  }

  return Array.from(appMap.entries()).map(([appName, appAgents]) => {
    // Primary agent is the orchestrator, or first agent alphabetically
    const primary = appAgents.find(a => a.agent_name.includes('orchestrator'))
      || appAgents.find(a => a.agent_name.includes('main'))
      || appAgents[0]

    const architecture: ApplicationGroup['architecture'] =
      appAgents.length > 1
        ? (appAgents.some(a => a.agent_name.includes('orchestrator')) ? 'supervisor' : 'swarm')
        : 'standalone'

    return {
      appName,
      agents: appAgents,
      current_state: primary.current_state,
      version: primary.version,
      last_transition: primary.last_transition,
      architecture,
      agentCount: appAgents.length,
    }
  })
}
