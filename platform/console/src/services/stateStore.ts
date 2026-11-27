import { DynamoDBClient } from '@aws-sdk/client-dynamodb'
import { DynamoDBDocumentClient, QueryCommand, GetCommand } from '@aws-sdk/lib-dynamodb'
import { fromCognitoIdentityPool } from '@aws-sdk/credential-provider-cognito-identity'

const REGION = import.meta.env.VITE_COGNITO_REGION || 'us-east-1'
const IDENTITY_POOL_ID = import.meta.env.VITE_IDENTITY_POOL_ID || ''
const USER_POOL_ID = import.meta.env.VITE_USER_POOL_ID || ''
const TABLE_NAME = import.meta.env.VITE_STATE_TABLE || 'platform-state-store-dev'
const GSI1_INDEX = 'domain-index'

// --- Types matching the Platform State Store schema ---

export interface MetadataRecord {
  PK: string
  SK: 'metadata'
  app_name: string
  domain: string
  architecture: string
  pattern_folder: string
  version: string
  runtime_arn: string
  endpoint_qualifier: string
  status: 'active' | 'deploying' | 'failed' | 'inactive'
  last_deploy_timestamp: string
  description: string
}

export interface AgentRecord {
  PK: string
  SK: string
  agent_name: string
  app_name: string
  domain: string
  current_state: 'enrolled' | 'training' | 'validated' | 'graduated' | 'production'
  version: string
  last_transition: string
  state_history: Array<{ state: string; timestamp: string; actor?: string }>
}

export interface EvaluatorRecord {
  PK: string
  SK: string
  evaluator_name: string
  target_app: string
  threshold: number
  model_id: string
  last_run_timestamp?: string
  last_score?: number
  passed?: boolean
}

export interface GraduationRecord {
  PK: string
  SK: string
  environment: string
  version: string
  timestamp: string
  scores: Record<string, number>
  red_team_pass: boolean
  verdict: 'PASS' | 'FAIL'
  report_id: string
  approver: string
}

// --- Client factory ---

function createDocClient(token: string | null): DynamoDBDocumentClient {
  const credentials = token
    ? fromCognitoIdentityPool({
        clientConfig: { region: REGION },
        identityPoolId: IDENTITY_POOL_ID,
        logins: {
          [`cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`]: token,
        },
      })
    : undefined

  const client = new DynamoDBClient({ region: REGION, credentials })
  return DynamoDBDocumentClient.from(client)
}

// --- Query functions ---

export async function getAppMetadata(
  domain: string,
  appName: string,
  token: string | null
): Promise<MetadataRecord | null> {
  const docClient = createDocClient(token)
  const result = await docClient.send(
    new GetCommand({
      TableName: TABLE_NAME,
      Key: { PK: `${domain}/${appName}`, SK: 'metadata' },
    })
  )
  return (result.Item as MetadataRecord) || null
}

export async function listMetadataByDomain(
  domain: string,
  token: string | null
): Promise<MetadataRecord[]> {
  const docClient = createDocClient(token)
  const result = await docClient.send(
    new QueryCommand({
      TableName: TABLE_NAME,
      IndexName: GSI1_INDEX,
      KeyConditionExpression: 'PK = :domain AND SK = :sk',
      ExpressionAttributeValues: { ':domain': domain, ':sk': 'metadata' },
    })
  )
  return (result.Items as MetadataRecord[]) || []
}

export async function listAgentsByDomain(
  domain: string,
  token: string | null
): Promise<AgentRecord[]> {
  const docClient = createDocClient(token)
  const result = await docClient.send(
    new QueryCommand({
      TableName: TABLE_NAME,
      IndexName: GSI1_INDEX,
      KeyConditionExpression: 'PK = :domain AND begins_with(SK, :prefix)',
      ExpressionAttributeValues: { ':domain': domain, ':prefix': 'agent/' },
    })
  )
  return (result.Items as AgentRecord[]) || []
}

export async function listEvaluatorsByDomain(
  domain: string,
  token: string | null
): Promise<EvaluatorRecord[]> {
  const docClient = createDocClient(token)
  const result = await docClient.send(
    new QueryCommand({
      TableName: TABLE_NAME,
      IndexName: GSI1_INDEX,
      KeyConditionExpression: 'PK = :domain AND begins_with(SK, :prefix)',
      ExpressionAttributeValues: { ':domain': domain, ':prefix': 'evaluator/' },
    })
  )
  return (result.Items as EvaluatorRecord[]) || []
}

export async function getGraduationHistory(
  domain: string,
  appName: string,
  token: string | null
): Promise<GraduationRecord[]> {
  const docClient = createDocClient(token)
  const result = await docClient.send(
    new QueryCommand({
      TableName: TABLE_NAME,
      KeyConditionExpression: 'PK = :pk AND begins_with(SK, :prefix)',
      ExpressionAttributeValues: {
        ':pk': `${domain}/${appName}`,
        ':prefix': 'graduation/',
      },
    })
  )
  return (result.Items as GraduationRecord[]) || []
}

export async function getAgentLifecycleStates(
  domain: string,
  token: string | null
): Promise<AgentRecord[]> {
  // Same as listAgentsByDomain — agents carry lifecycle state
  return listAgentsByDomain(domain, token)
}
