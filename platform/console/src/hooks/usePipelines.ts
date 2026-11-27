/**
 * React Query hook to fetch CodePipeline executions for eap-* pipelines.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  ListPipelineExecutionsCommand,
  StartPipelineExecutionCommand,
  ListPipelinesCommand,
} from '@aws-sdk/client-codepipeline'
import { useAuth } from '../auth/CognitoProvider'
import { getPipelineClient, isDevBypass } from '../services/awsClients'

export interface PipelineExecutionSummary {
  pipelineName: string
  executionId: string
  status: string
  startTime: string
  lastUpdateTime: string
  trigger?: string
}

// --- Mock data for dev bypass mode ---
const MOCK_EXECUTIONS: PipelineExecutionSummary[] = [
  {
    pipelineName: 'eap-rrf-search-app-orchestrator',
    executionId: 'exec-001-abc',
    status: 'Succeeded',
    startTime: '2024-12-15T10:00:00Z',
    lastUpdateTime: '2024-12-15T10:25:00Z',
    trigger: 'CodeCommit push',
  },
  {
    pipelineName: 'eap-claims-processor-main',
    executionId: 'exec-002-def',
    status: 'Failed',
    startTime: '2024-12-14T15:30:00Z',
    lastUpdateTime: '2024-12-14T15:45:00Z',
    trigger: 'Manual trigger',
  },
  {
    pipelineName: 'eap-policy-search-agent-v2',
    executionId: 'exec-003-ghi',
    status: 'Succeeded',
    startTime: '2024-12-12T08:00:00Z',
    lastUpdateTime: '2024-12-12T09:00:00Z',
    trigger: 'CodeCommit push',
  },
  {
    pipelineName: 'eap-policy-qa-bot-chat',
    executionId: 'exec-004-jkl',
    status: 'InProgress',
    startTime: '2024-12-15T11:00:00Z',
    lastUpdateTime: '2024-12-15T11:05:00Z',
    trigger: 'Scheduled',
  },
  {
    pipelineName: 'eap-rrf-search-app-orchestrator',
    executionId: 'exec-005-mno',
    status: 'Succeeded',
    startTime: '2024-12-14T08:00:00Z',
    lastUpdateTime: '2024-12-14T08:20:00Z',
    trigger: 'CodeCommit push',
  },
]

async function fetchPipelineExecutions(token: string | null): Promise<PipelineExecutionSummary[]> {
  if (isDevBypass(token)) {
    return MOCK_EXECUTIONS
  }

  const client = getPipelineClient(token)

  // First, list all pipelines in the account (all are platform-managed via Terraform)
  const pipelinesResult = await client.send(new ListPipelinesCommand({}))
  const allPipelines = (pipelinesResult.pipelines || [])
    .map((p) => p.name!)
    .filter(Boolean)

  // Fetch recent executions for each pipeline
  const allExecutions: PipelineExecutionSummary[] = []

  await Promise.all(
    allPipelines.map(async (pipelineName) => {
      try {
        const result = await client.send(
          new ListPipelineExecutionsCommand({
            pipelineName,
            maxResults: 5,
          })
        )
        const executions = (result.pipelineExecutionSummaries || []).map((s) => ({
          pipelineName,
          executionId: s.pipelineExecutionId || '',
          status: s.status || 'Unknown',
          startTime: s.startTime?.toISOString() || '',
          lastUpdateTime: s.lastUpdateTime?.toISOString() || '',
          trigger: s.trigger?.triggerType || undefined,
        }))
        allExecutions.push(...executions)
      } catch {
        // Skip pipelines that error (permission issues, etc.)
      }
    })
  )

  // Sort by start time descending
  allExecutions.sort((a, b) => (b.startTime || '').localeCompare(a.startTime || ''))
  return allExecutions
}

/**
 * Hook to fetch recent pipeline executions.
 */
export function usePipelines() {
  const { token } = useAuth()

  return useQuery<PipelineExecutionSummary[], Error>({
    queryKey: ['pipelines', token],
    queryFn: () => fetchPipelineExecutions(token),
    enabled: !!token,
  })
}

/**
 * Hook to trigger a pipeline execution (promote action).
 */
export function useStartPipeline() {
  const { token } = useAuth()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (pipelineName: string) => {
      if (isDevBypass(token)) {
        return 'mock-execution-id'
      }
      const client = getPipelineClient(token)
      const result = await client.send(
        new StartPipelineExecutionCommand({ name: pipelineName })
      )
      return result.pipelineExecutionId || null
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pipelines'] })
    },
  })
}
