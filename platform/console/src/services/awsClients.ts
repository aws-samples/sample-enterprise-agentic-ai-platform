/**
 * Shared AWS client factory with lazy initialization.
 * Creates DynamoDB Document Client and CodePipeline client
 * using Cognito Identity Pool credentials when available,
 * or undefined credentials for dev bypass mode.
 */
import { DynamoDBClient } from '@aws-sdk/client-dynamodb'
import { DynamoDBDocumentClient, ScanCommand } from '@aws-sdk/lib-dynamodb'
import { CodePipelineClient } from '@aws-sdk/client-codepipeline'
import { fromCognitoIdentityPool } from '@aws-sdk/credential-provider-cognito-identity'

const REGION = import.meta.env.VITE_COGNITO_REGION || 'us-east-1'
const IDENTITY_POOL_ID = import.meta.env.VITE_IDENTITY_POOL_ID || ''
const USER_POOL_ID = import.meta.env.VITE_USER_POOL_ID || ''

export const LIFECYCLE_TABLE = import.meta.env.VITE_STATE_TABLE || 'agent-school-lifecycle-team-bu-1-dev'

// Cache clients per token to avoid re-creating on every call
let cachedToken: string | null = null
let cachedDocClient: DynamoDBDocumentClient | null = null
let cachedPipelineClient: CodePipelineClient | null = null

function buildCredentials(token: string | null) {
  if (!token || token === 'dev-bypass-token' || !IDENTITY_POOL_ID) {
    return undefined
  }
  return fromCognitoIdentityPool({
    clientConfig: { region: REGION },
    identityPoolId: IDENTITY_POOL_ID,
    logins: {
      [`cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`]: token,
    },
  })
}

/**
 * Get a DynamoDB Document Client. Lazily creates and caches per token.
 */
export function getDocClient(token: string | null): DynamoDBDocumentClient {
  if (cachedDocClient && cachedToken === token) return cachedDocClient

  const credentials = buildCredentials(token)
  const client = new DynamoDBClient({ region: REGION, credentials })
  cachedDocClient = DynamoDBDocumentClient.from(client, {
    marshallOptions: { removeUndefinedValues: true },
  })
  cachedToken = token
  return cachedDocClient
}

/**
 * Get a CodePipeline Client. Lazily creates and caches per token.
 */
export function getPipelineClient(token: string | null): CodePipelineClient {
  if (cachedPipelineClient && cachedToken === token) return cachedPipelineClient

  const credentials = buildCredentials(token)
  cachedPipelineClient = new CodePipelineClient({ region: REGION, credentials })
  cachedToken = token
  return cachedPipelineClient
}

/**
 * Check if we're in dev bypass mode (no real AWS credentials).
 */
export function isDevBypass(token: string | null): boolean {
  return !token || token === 'dev-bypass-token' || !IDENTITY_POOL_ID
}

export { ScanCommand }
