/**
 * runtimeAllowList.ts — shared runtime discovery, matching, selection, and cache.
 *
 * Ported verbatim from the studio-read Lambda (studio-read/src/runtimeAllowList.ts).
 * Kept as a self-contained copy (not a cross-module import) because this service
 * ships as a self-contained container image. Single source of truth for:
 *   - discovering deployed applications and their AgentCore runtimes,
 *   - matching runtimes to applications,
 *   - selecting an application's primary runtime,
 *   - a 60s in-memory cache with force-bypass.
 *
 * The lifecycle DynamoDB table is the authoritative store (ADR-026).
 */

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, ScanCommand } from '@aws-sdk/lib-dynamodb';
import {
  BedrockAgentCoreControlClient,
  ListAgentRuntimesCommand,
} from '@aws-sdk/client-bedrock-agentcore-control';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const REGION = process.env.AWS_REGION || 'us-east-1';
const DEFAULT_REPO = process.env.STUDIO_TARGET_REPO || 'nocode-user';

// DynamoDB lifecycle store is the single source of truth for deployed-agent
// facts (real runtime ARNs, app grouping, entrypoint).
const LIFECYCLE_TABLE =
  process.env.LIFECYCLE_TABLE || 'agent-school-lifecycle-team-bu-1-dev';

/** In-memory cache TTL for discovery results (Requirement 8.7). */
export const RUNTIME_CACHE_TTL_MS = 60_000;

/**
 * CodeCommit pattern folders to scan for deployed applications. `standalone` is
 * fast-pathed (no application.yaml) to the standalone pattern.
 */
export const PATTERN_FOLDERS: readonly string[] = [
  'standalone',
  'orchestration/supervisor',
  'orchestration/sequential',
  'orchestration/router',
  'choreography/swarm',
];

// Lazily-created clients so importing the pure helpers never constructs a client.
let _ddbDoc: DynamoDBDocumentClient | null = null;
let _acClient: BedrockAgentCoreControlClient | null = null;

function ddbDoc(): DynamoDBDocumentClient {
  if (!_ddbDoc) {
    _ddbDoc = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));
  }
  return _ddbDoc;
}

function acClient(): BedrockAgentCoreControlClient {
  if (!_acClient) _acClient = new BedrockAgentCoreControlClient({ region: REGION });
  return _acClient;
}

/**
 * List every AgentCore runtime, paging through ListAgentRuntimes. Used by the
 * Deployment_Status_Service to resolve a freshly-deployed agent's runtime ARN
 * immediately after a pipeline succeeds (before the lifecycle store row exists).
 */
export async function listAgentRuntimes(): Promise<RuntimeSummary[]> {
  const out: RuntimeSummary[] = [];
  let nextToken: string | undefined;
  do {
    const page = await acClient().send(new ListAgentRuntimesCommand({ nextToken }));
    for (const rt of page.agentRuntimes || []) {
      out.push({
        name: rt.agentRuntimeName || '',
        arn: rt.agentRuntimeArn || '',
        status: (rt as { status?: string }).status || '',
      });
    }
    nextToken = page.nextToken;
  } while (nextToken);
  return out;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** A raw AgentCore runtime as returned by ListAgentRuntimes. */
export interface RuntimeSummary {
  name: string;
  arn: string;
  status: string;
}

/** An application folder discovered while walking the CodeCommit repo. */
export interface DiscoveredAppFolder {
  appName: string;
  patternFolder: string;
}

/** One peer runtime within a discovered application (wire shape, snake_case). */
export interface DiscoveredPeerRuntime {
  agent_name: string;
  runtime_name: string;
  runtime_arn: string;
  endpoint_qualifier: string;
  status: string;
  agent_role: string;
  agent_key: string;
}

/** One node in an application's deployed topology graph. */
export interface TopologyAgent {
  name: string;
  role: string;
  calls: string[];
  called_by: string[];
  can_call: string[];
  depends_on: string[];
}

/** The authoritative deployed-architecture graph for an application. */
export interface AppTopology {
  pattern: string;
  agents: TopologyAgent[];
}

/** One discovered application, grouping all matched peer runtimes. */
export interface DiscoveredApp {
  app_name: string;
  bu: string;
  pattern: string;
  pattern_folder: string;
  primary_runtime_arn: string;
  primary_endpoint_qualifier: string;
  runtimes: DiscoveredPeerRuntime[];
  topology: AppTopology | null;
}

/** Generic in-memory cache entry, keyed by repo. */
export interface CacheEntry<T> {
  at: number;
  repo: string;
  data: T;
}

// ---------------------------------------------------------------------------
// Pure, deterministic helpers
// ---------------------------------------------------------------------------

/** Match runtimes to an application (Requirement 8.2). */
export function matchRuntimesToApp<T extends { name: string }>(
  appName: string,
  runtimes: readonly T[],
): T[] {
  const needle = (appName || '').toLowerCase();
  if (!needle) return [];
  return runtimes.filter(
    (rt) => typeof rt.name === 'string' && rt.name.toLowerCase().startsWith(needle),
  );
}

/** Select the primary runtime for an application (Requirement 8.4). */
export function selectPrimaryRuntime<T extends { name: string }>(
  appName: string,
  peers: readonly T[],
): T | undefined {
  if (peers.length === 0) return undefined;
  const needle = (appName || '').toLowerCase();
  const exact = peers.find((p) => (p.name || '').toLowerCase() === needle);
  if (exact) return exact;
  return [...peers].sort((a, b) =>
    (a.name || '').toLowerCase().localeCompare((b.name || '').toLowerCase()),
  )[0];
}

/**
 * Derive an endpoint qualifier from a runtime name by stripping the random
 * `-XXXXXXXXXX` suffix AgentCore appends, then adding `_endpoint`.
 */
export function deriveEndpointQualifier(runtimeName: string): string {
  const base = (runtimeName || '').replace(/-[A-Za-z0-9]{10}$/, '');
  return `${base}_endpoint`;
}

/** Whether a cache entry may be served (Requirement 8.7). */
export function isCacheEntryFresh<T>(
  entry: CacheEntry<T> | null | undefined,
  repo: string,
  nowMs: number,
  force: boolean,
  ttlMs: number = RUNTIME_CACHE_TTL_MS,
): boolean {
  if (force) return false;
  if (!entry) return false;
  if (entry.repo !== repo) return false;
  return nowMs - entry.at < ttlMs;
}

/**
 * Extract the `architecture` value from application.yaml text. Returns the
 * lowercased pattern, or the caller-supplied default when the field is absent.
 */
export function parseArchitecture(yamlText: string, fallback = 'standalone'): string {
  const match = yamlText.match(/^architecture:\s*([a-z0-9_-]+)\s*$/im);
  return match ? match[1].toLowerCase() : fallback;
}

/**
 * Bedrock AgentCore runtime ARN syntax:
 *   arn:aws<partition?>:bedrock-agentcore:<region>:<account>:runtime/<runtimeId>
 */
const RUNTIME_ARN_RE =
  /^arn:aws[a-z-]*:bedrock-agentcore:[a-z0-9-]+:\d{12}:runtime\/[A-Za-z0-9_.-]+$/;

/** Whether a string is a syntactically valid AgentCore runtime ARN. */
export function isValidRuntimeArn(arn: string): boolean {
  return typeof arn === 'string' && RUNTIME_ARN_RE.test(arn);
}

// ---------------------------------------------------------------------------
// Discovery primitives — DynamoDB lifecycle store (single source of truth)
// ---------------------------------------------------------------------------

/** One deployed-agent row as written by the deploy pipeline / backfill. */
interface LifecycleItem {
  agent_name?: string;
  app_name?: string;
  agent_key?: string;
  agent_role?: string;
  pattern?: string;
  pattern_folder?: string;
  runtime_arn?: string;
  runtime_name?: string;
  endpoint_qualifier?: string;
  status?: string;
  is_entrypoint?: boolean;
  bu?: string;
  app_topology?: string;
}

/** Parse an `app_topology` JSON string into an AppTopology (defensive). */
export function parseAppTopology(raw: string | undefined | null): AppTopology | null {
  if (!raw || typeof raw !== 'string') return null;
  try {
    const doc = JSON.parse(raw) as Partial<AppTopology>;
    if (!doc || typeof doc !== 'object') return null;
    const agents: TopologyAgent[] = Array.isArray(doc.agents)
      ? doc.agents.map((a) => ({
          name: String((a as TopologyAgent)?.name ?? ''),
          role: String((a as TopologyAgent)?.role ?? '').toLowerCase(),
          calls: normalizeStringList((a as TopologyAgent)?.calls),
          called_by: normalizeStringList((a as TopologyAgent)?.called_by),
          can_call: normalizeStringList((a as TopologyAgent)?.can_call),
          depends_on: normalizeStringList((a as TopologyAgent)?.depends_on),
        }))
      : [];
    return { pattern: String(doc.pattern ?? '').toLowerCase(), agents };
  } catch {
    return null;
  }
}

/** Coerce an unknown edge value to a string[] (accepts string | string[]). */
function normalizeStringList(val: unknown): string[] {
  if (Array.isArray(val)) return val.map((x) => String(x));
  if (typeof val === 'string' && val) return [val];
  return [];
}

/**
 * Scan the lifecycle table for deployed-agent rows (those carrying both an
 * app_name and a runtime_arn). Throws on API failure so callers surface an
 * error rather than return partial/stale results (Requirement 8.8).
 */
export async function scanDeployedAgentItems(): Promise<LifecycleItem[]> {
  const out: LifecycleItem[] = [];
  let lastKey: Record<string, unknown> | undefined;
  do {
    const page = await ddbDoc().send(
      new ScanCommand({
        TableName: LIFECYCLE_TABLE,
        FilterExpression:
          'attribute_exists(app_name) AND attribute_exists(runtime_arn)',
        ExclusiveStartKey: lastKey,
      }),
    );
    for (const it of (page.Items || []) as LifecycleItem[]) {
      if (it.runtime_arn) out.push(it);
    }
    lastKey = page.LastEvaluatedKey as Record<string, unknown> | undefined;
  } while (lastKey);
  return out;
}

/** Group lifecycle rows into DiscoveredApp records by app_name. */
export function groupItemsIntoApps(items: readonly LifecycleItem[]): DiscoveredApp[] {
  const byApp = new Map<string, LifecycleItem[]>();
  for (const it of items) {
    const app = it.app_name || '';
    if (!app) continue;
    const bucket = byApp.get(app);
    if (bucket) bucket.push(it);
    else byApp.set(app, [it]);
  }

  const apps: DiscoveredApp[] = [];
  for (const [appName, rows] of byApp) {
    const peers: DiscoveredPeerRuntime[] = rows.map((r) => ({
      agent_name: r.agent_name || r.runtime_name || '',
      runtime_name: r.runtime_name || r.agent_name || '',
      runtime_arn: r.runtime_arn || '',
      endpoint_qualifier: r.endpoint_qualifier || '',
      status: r.status || '',
      agent_role: (r.agent_role || '').toLowerCase(),
      agent_key: r.agent_key || '',
    }));
    const primaryRow = rows.find((r) => r.is_entrypoint) ?? rows[0];
    const pattern = rows.find((r) => r.pattern)?.pattern || 'standalone';
    const patternFolder = rows.find((r) => r.pattern_folder)?.pattern_folder || '';
    const topology = parseAppTopology(rows.find((r) => r.app_topology)?.app_topology);
    const bu = rows.find((r) => r.bu)?.bu || '';
    apps.push({
      app_name: appName,
      bu,
      pattern,
      pattern_folder: patternFolder,
      primary_runtime_arn: primaryRow?.runtime_arn || '',
      primary_endpoint_qualifier: primaryRow?.endpoint_qualifier || '',
      runtimes: peers,
      topology,
    });
  }
  return apps;
}

// ---------------------------------------------------------------------------
// Discovery orchestration + cache
// ---------------------------------------------------------------------------

let _appsCache: CacheEntry<DiscoveredApp[]> | null = null;

/**
 * Discover every deployed application grouped with its peer runtimes, reading
 * the authoritative lifecycle DynamoDB store. Results are cached in memory for
 * 60s; `force` bypasses the cache. Any read failure propagates (Requirement 8.8).
 */
export async function discoverApps(
  repo: string = DEFAULT_REPO,
  force = false,
): Promise<DiscoveredApp[]> {
  if (isCacheEntryFresh(_appsCache, repo, Date.now(), force)) {
    return _appsCache!.data;
  }

  const items = await scanDeployedAgentItems();
  const apps = groupItemsIntoApps(items);

  _appsCache = { at: Date.now(), repo, data: apps };
  return apps;
}

/**
 * Report whether a subsequent `discoverApps(repo, force)` call would be served
 * from the in-memory cache (Requirement 8.7). Read-only; does not mutate state.
 */
export function isAppsCacheFresh(
  repo: string = DEFAULT_REPO,
  force = false,
  nowMs: number = Date.now(),
): boolean {
  return isCacheEntryFresh(_appsCache, repo, nowMs, force);
}

/** Test/maintenance helper: clear the in-memory discovery cache. */
export function clearRuntimeCache(): void {
  _appsCache = null;
}
