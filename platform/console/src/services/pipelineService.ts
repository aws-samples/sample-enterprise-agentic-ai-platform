import {
  CodePipelineClient,
  StartPipelineExecutionCommand,
  GetPipelineExecutionCommand,
  ListPipelineExecutionsCommand,
} from '@aws-sdk/client-codepipeline'
import { fromCognitoIdentityPool } from '@aws-sdk/credential-provider-cognito-identity'

const REGION = import.meta.env.VITE_COGNITO_REGION || 'us-east-1'
const IDENTITY_POOL_ID = import.meta.env.VITE_IDENTITY_POOL_ID || ''
const USER_POOL_ID = import.meta.env.VITE_USER_POOL_ID || ''

// --- Types ---

export interface PipelineExecution {
  pipelineExecutionId: string
  status: string
  startTime?: Date
  lastUpdateTime?: Date
}

// --- Client factory ---

function createPipelineClient(token: string | null): CodePipelineClient {
  const credentials = token
    ? fromCognitoIdentityPool({
        clientConfig: { region: REGION },
        identityPoolId: IDENTITY_POOL_ID,
        logins: {
          [`cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`]: token,
        },
      })
    : undefined

  return new CodePipelineClient({ region: REGION, credentials })
}

// --- Pipeline operations ---

export async function startPipelineExecution(
  pipelineName: string,
  token: string | null
): Promise<string | null> {
  const client = createPipelineClient(token)
  const result = await client.send(
    new StartPipelineExecutionCommand({ name: pipelineName })
  )
  return result.pipelineExecutionId || null
}

export async function getPipelineExecution(
  pipelineName: string,
  executionId: string,
  token: string | null
): Promise<PipelineExecution | null> {
  const client = createPipelineClient(token)
  const result = await client.send(
    new GetPipelineExecutionCommand({
      pipelineName,
      pipelineExecutionId: executionId,
    })
  )
  const exec = result.pipelineExecution
  if (!exec) return null
  return {
    pipelineExecutionId: exec.pipelineExecutionId || executionId,
    status: exec.status || 'Unknown',
    startTime: undefined,
    lastUpdateTime: undefined,
  }
}

export async function listPipelineExecutions(
  pipelineName: string,
  token: string | null,
  maxResults = 10
): Promise<PipelineExecution[]> {
  const client = createPipelineClient(token)
  const result = await client.send(
    new ListPipelineExecutionsCommand({
      pipelineName,
      maxResults,
    })
  )
  return (result.pipelineExecutionSummaries || []).map((s) => ({
    pipelineExecutionId: s.pipelineExecutionId || '',
    status: s.status || 'Unknown',
    startTime: s.startTime,
    lastUpdateTime: s.lastUpdateTime,
  }))
}
