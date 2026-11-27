// Examples Backend — target allow-list (ADR-046)
// -----------------------------------------------------------------------------
// Even an authenticated caller may only target resources the platform actually
// deployed. The lifecycle DynamoDB table is the single source of truth
// (ADR-026): the deploy pipeline records each agent's runtime_arn and, for
// Step Functions patterns, its state_machine_arn. The console's Examples list
// is built from the same records, so legitimate requests always pass.
//
// The runtime ARN regex + scan semantics match ade-invoke-backend's
// runtimeAllowList.ts (kept as a copy: each backend is a self-contained image).

import { DynamoDBClient } from '@aws-sdk/client-dynamodb'
import { DynamoDBDocumentClient, ScanCommand } from '@aws-sdk/lib-dynamodb'

const REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1'
const LIFECYCLE_TABLE = process.env.LIFECYCLE_TABLE || ''

if (!LIFECYCLE_TABLE) {
  throw new Error('LIFECYCLE_TABLE env var is required (injected by Terraform) for the target allow-list.')
}

const RUNTIME_ARN_RE = /^arn:aws[a-z-]*:bedrock-agentcore:[a-z0-9-]+:\d{12}:runtime\/[A-Za-z0-9_.-]+$/
const STATE_MACHINE_ARN_RE = /^arn:aws[a-z-]*:states:[a-z0-9-]+:\d{12}:stateMachine:[A-Za-z0-9_-]+$/
const EXECUTION_ARN_RE = /^(arn:aws[a-z-]*:states:[a-z0-9-]+:\d{12}):execution:([A-Za-z0-9_-]+):[A-Za-z0-9_.-]+$/
// Log-group name prefix, e.g. "team_bu_1_rrf_search_app_". Plain identifier
// characters only — it is also interpolated into a RegExp in logs.ts.
const RUNTIME_PREFIX_RE = /^[A-Za-z0-9_-]{1,128}$/

interface Targets {
  runtimes: Set<string>
  stateMachines: Set<string>
}

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }))
const CACHE_TTL_MS = 60_000
let cache: { at: number; targets: Targets } | null = null

async function scanTargets(): Promise<Targets> {
  const targets: Targets = { runtimes: new Set(), stateMachines: new Set() }
  let lastKey: Record<string, unknown> | undefined
  do {
    const page = await ddb.send(
      new ScanCommand({
        TableName: LIFECYCLE_TABLE,
        FilterExpression: 'attribute_exists(app_name)',
        ProjectionExpression: 'runtime_arn, state_machine_arn',
        ExclusiveStartKey: lastKey,
      }),
    )
    for (const it of page.Items || []) {
      if (typeof it.runtime_arn === 'string' && it.runtime_arn) targets.runtimes.add(it.runtime_arn)
      if (typeof it.state_machine_arn === 'string' && it.state_machine_arn) {
        targets.stateMachines.add(it.state_machine_arn)
      }
    }
    lastKey = page.LastEvaluatedKey as Record<string, unknown> | undefined
  } while (lastKey)
  return targets
}

// A read failure propagates so the route returns 503, never a stale or empty
// allow-list.
async function deployedTargets(): Promise<Targets> {
  if (cache && Date.now() - cache.at < CACHE_TTL_MS) return cache.targets
  const targets = await scanTargets()
  cache = { at: Date.now(), targets }
  return targets
}

export async function isAllowedRuntime(arn: unknown): Promise<boolean> {
  if (typeof arn !== 'string' || !RUNTIME_ARN_RE.test(arn)) return false
  return (await deployedTargets()).runtimes.has(arn)
}

export async function isAllowedStateMachine(arn: unknown): Promise<boolean> {
  if (typeof arn !== 'string' || !STATE_MACHINE_ARN_RE.test(arn)) return false
  return (await deployedTargets()).stateMachines.has(arn)
}

/** An execution is allowed when it belongs to an allowed state machine. */
export async function isAllowedExecution(arn: unknown): Promise<boolean> {
  if (typeof arn !== 'string') return false
  const m = EXECUTION_ARN_RE.exec(arn)
  if (!m) return false
  return isAllowedStateMachine(`${m[1]}:stateMachine:${m[2]}`)
}

export function isValidRuntimePrefix(prefix: unknown): prefix is string {
  return typeof prefix === 'string' && RUNTIME_PREFIX_RE.test(prefix)
}
