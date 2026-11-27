/**
 * lifecycleStore.ts — AWS-backed ARN↔BU ownership resolution.
 *
 * This is the *thin* AWS boundary that produces the `AgentOwnership` record the
 * pure `authorizeAgentForBu` decision (see `ownership.ts`) consumes. It mirrors
 * the DynamoDB access pattern of `studio-read/src/runtimeAllowList.ts` (and the
 * invoke-proxy allow-list): the same lifecycle table, the same env-var
 * conventions, the same lazily-constructed DynamoDB document client, and a
 * `Scan` + `FilterExpression` read (the table's key schema is
 * `agent_name` hash + `app-index` GSI on `app_name`; there is no `runtime_arn`
 * index, so a filtered scan is the matching access pattern).
 *
 * Keeping this separate from `ownership.ts` preserves the pure decision
 * function's property-testability: nothing here is imported by the pure logic.
 *
 * Failure semantics (design Error Handling; Requirement 4.3):
 *   - Agent not found in the store → resolves to `null` (the pure decision then
 *     denies with OWNERSHIP_NOT_FOUND → the handler returns a generic 403).
 *   - DynamoDB read failure → throws (the handler catches it and fails closed
 *     with a 503; no partial/stale result is ever returned).
 */

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, ScanCommand } from '@aws-sdk/lib-dynamodb';

import type { AgentOwnership } from './types';

// ---------------------------------------------------------------------------
// Configuration (matches studio-read / invoke-proxy conventions)
// ---------------------------------------------------------------------------

const REGION = process.env.AWS_REGION || 'us-east-1';

/**
 * The lifecycle DynamoDB store is the single source of truth for deployed-agent
 * facts (real runtime ARNs, app grouping, owning BU). Same env var + default as
 * `studio-read/src/runtimeAllowList.ts`.
 */
const LIFECYCLE_TABLE =
  process.env.LIFECYCLE_TABLE || 'agent-school-lifecycle-team-bu-1-dev';

// Lazily-created DynamoDB document client so importing this module never
// constructs a client (keeps consumers/tests light and avoids AWS wiring at
// import time — same pattern as runtimeAllowList.ts).
let _ddbDoc: DynamoDBDocumentClient | null = null;

function ddbDoc(): DynamoDBDocumentClient {
  if (!_ddbDoc) {
    _ddbDoc = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));
  }
  return _ddbDoc;
}

// ---------------------------------------------------------------------------
// Lifecycle item shape (subset we read) — snake_case wire shape, as written by
// the deploy pipeline / backfill (see runtimeAllowList.ts LifecycleItem).
// ---------------------------------------------------------------------------

interface LifecycleItem {
  agent_name?: string;
  runtime_arn?: string;
  endpoint_qualifier?: string;
  /** Owning business unit / domain (single shared-table discriminator). */
  bu?: string;
}

/** Map a raw lifecycle item to the shared `AgentOwnership` shape. */
function toAgentOwnership(item: LifecycleItem): AgentOwnership {
  return {
    runtime_arn: item.runtime_arn || '',
    agent_name: item.agent_name || '',
    bu: item.bu || '',
    endpoint_qualifier: item.endpoint_qualifier || '',
  };
}

// ---------------------------------------------------------------------------
// Ownership resolution — R4.1, R4.2, R4.3
// ---------------------------------------------------------------------------

/**
 * Resolve the ARN↔BU ownership record for an AgentCore runtime ARN.
 *
 * Scans the lifecycle store for the row whose `runtime_arn` matches `agentArn`
 * (mirroring the studio-read `Scan` + `FilterExpression` access pattern, since
 * `runtime_arn` is not a table key). Returns the mapped `AgentOwnership`, or
 * `null` when no matching row exists.
 *
 * The pure `authorizeAgentForBu` decision consumes the result: a `null` return
 * (agent not found) denies fail-closed. A DynamoDB failure is *thrown* here so
 * the caller can distinguish it and fail closed with a 503 rather than treat a
 * transient error as "not found".
 */
export async function resolveAgentOwnership(
  agentArn: string,
): Promise<AgentOwnership | null> {
  const arn = (agentArn || '').trim();
  if (!arn) return null;

  let lastKey: Record<string, unknown> | undefined;
  do {
    const page = await ddbDoc().send(
      new ScanCommand({
        TableName: LIFECYCLE_TABLE,
        FilterExpression: 'runtime_arn = :arn',
        ExpressionAttributeValues: { ':arn': arn },
        ExclusiveStartKey: lastKey,
      }),
    );
    const items = (page.Items || []) as LifecycleItem[];
    const match = items.find((it) => it.runtime_arn === arn);
    if (match) return toAgentOwnership(match);
    lastKey = page.LastEvaluatedKey as Record<string, unknown> | undefined;
  } while (lastKey);

  return null;
}
