// ADE Invoke Backend — Requirement-11 runtime allow-list (ADR-040)
// -----------------------------------------------------------------------------
// Self-contained port of the authoritative allow-list the invoke-proxy Lambda
// enforced (studio-read/src/runtimeAllowList.ts). The lifecycle DynamoDB table
// is the single source of truth (ADR-026): the deploy pipeline records every
// deployed agent's real runtime ARN + default endpoint qualifier there, so a
// caller can only invoke a runtime that has actually been deployed.
//
// Kept as a copy (not a cross-module import) because this service ships as a
// self-contained container image, unlike the Lambda which esbuild-bundles the
// shared module. Keep the ARN regex + membership semantics in lockstep with
// studio-read/src/runtimeAllowList.ts.

import { DynamoDBClient } from '@aws-sdk/client-dynamodb'
import { DynamoDBDocumentClient, ScanCommand } from '@aws-sdk/lib-dynamodb'

const REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1'

// Injected by Terraform. No fallback: a missing table is a deploy
// misconfiguration and must fail loudly rather than silently allow-list nothing
// (which would 503 every invoke) or, worse, everything.
const LIFECYCLE_TABLE = process.env.LIFECYCLE_TABLE || ''

/** Fail fast at boot if the lifecycle table isn't wired. */
export function assertAllowListConfigured(): void {
  if (!LIFECYCLE_TABLE) {
    throw new Error(
      'LIFECYCLE_TABLE env var is required (injected by Terraform) — the Requirement-11 allow-list reads it as the single source of truth.',
    )
  }
}

/**
 * Bedrock AgentCore runtime ARN syntax (kept identical to studio-read):
 *   arn:aws<partition?>:bedrock-agentcore:<region>:<account>:runtime/<runtimeId>
 */
const RUNTIME_ARN_RE =
  /^arn:aws[a-z-]*:bedrock-agentcore:[a-z0-9-]+:\d{12}:runtime\/[A-Za-z0-9_.-]+$/

/** Requirement 11.4 — malformed ARNs are rejected before any membership check. */
export function isValidRuntimeArn(arn: string): boolean {
  return typeof arn === 'string' && RUNTIME_ARN_RE.test(arn)
}

interface LifecycleItem {
  runtime_arn?: string
  endpoint_qualifier?: string
  app_name?: string
}

let _client: DynamoDBDocumentClient | null = null
function ddbDoc(): DynamoDBDocumentClient {
  if (!_client) {
    _client = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }))
  }
  return _client
}

// 60s in-memory cache (same TTL as studio-read). A read failure propagates so
// the caller returns 503 rather than a partial/stale allow-list (Req 8.8).
interface Cache {
  at: number
  map: Map<string, string>
}
let _cache: Cache | null = null
const CACHE_TTL_MS = 60_000

async function scanDeployedRuntimeQualifiers(): Promise<Map<string, string>> {
  const map = new Map<string, string>()
  let lastKey: Record<string, unknown> | undefined
  do {
    const page = await ddbDoc().send(
      new ScanCommand({
        TableName: LIFECYCLE_TABLE,
        FilterExpression: 'attribute_exists(app_name) AND attribute_exists(runtime_arn)',
        ExclusiveStartKey: lastKey,
      }),
    )
    for (const it of (page.Items || []) as LifecycleItem[]) {
      if (it.runtime_arn) map.set(it.runtime_arn, it.endpoint_qualifier || '')
    }
    lastKey = page.LastEvaluatedKey as Record<string, unknown> | undefined
  } while (lastKey)
  return map
}

/**
 * The authoritative allow-list as a map from runtime ARN to its default
 * endpoint qualifier (Requirements 11.3, 11.7). Backed by a 60s cache;
 * `force` bypasses it. `map.has(arn)` answers membership (Req 11.5) and
 * `map.get(arn)` supplies the discovered default qualifier (Req 11.7).
 */
export async function listDiscoveredRuntimeQualifiers(force = false): Promise<Map<string, string>> {
  const now = Date.now()
  if (!force && _cache && now - _cache.at < CACHE_TTL_MS) return _cache.map
  const map = await scanDeployedRuntimeQualifiers()
  _cache = { at: now, map }
  return map
}
