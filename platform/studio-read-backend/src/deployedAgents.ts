/**
 * Deployed_Agents_Service — `GET /api/my-deployed-agents` (task 2.4)
 *
 * Returns the authoritative, application-grouped list of the user's deployed
 * agents. All of the heavy lifting — walking the CodeCommit pattern folders,
 * reading each `application.yaml` `architecture` field, listing AgentCore
 * runtimes, matching runtimes to applications by case-insensitive name prefix,
 * selecting each application's primary runtime, and the 60s in-memory cache
 * with force-bypass — lives in the shared `runtimeAllowList` module
 * (Requirements 8.1–8.7, already implemented in task 2.2). This route is a thin
 * wrapper that:
 *   - resolves the `repo` / `force` query params,
 *   - reports whether the result was served from cache, and
 *   - handles the read-failure case (Requirement 8.8): on CodeCommit or
 *     `ListAgentRuntimes` failure it returns a 5xx error and NO partial or
 *     stale results.
 *
 * Response (design Backend Route #2): `{ cached: boolean, apps: DiscoveredApp[] }`.
 *
 * Exports `deployedAgentsHandler`, a RouteHandler compatible with the router in
 * `index.ts`. Route wiring and IAM are handled by task 2.13.
 *
 * _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 12.2_
 */

import type { ApiGatewayV2Event, ApiGatewayResult, RouteHandler } from './index';
import { jsonResponse } from './index';
import { discoverApps, isAppsCacheFresh } from './runtimeAllowList';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Default CodeCommit repo when the caller does not supply `repo`. */
const DEFAULT_REPO = process.env.TARGET_REPO || 'nocode-user';

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

/**
 * GET /api/my-deployed-agents
 *
 * Query params:
 *   repo  — optional, defaults to env TARGET_REPO / `nocode-user`.
 *   force — optional; `1` bypasses the 60s discovery cache (Requirement 8.7).
 *
 * Success: `200 { cached, apps }`.
 * Failure: `5xx { error, apps: [] }` — no partial/stale results (Requirement 8.8).
 */
export const deployedAgentsHandler: RouteHandler = async (
  event: ApiGatewayV2Event,
): Promise<ApiGatewayResult> => {
  const query = event.queryStringParameters ?? {};
  const repo = (query.repo ?? '').trim() || DEFAULT_REPO;
  const force = query.force === '1';

  try {
    // Observe cache freshness BEFORE discovery, since discoverApps repopulates
    // the cache on a miss (which would otherwise always look "cached").
    const cached = isAppsCacheFresh(repo, force);
    const apps = await discoverApps(repo, force);
    return jsonResponse(200, { cached, apps });
  } catch (err) {
    // Read failure (CodeCommit or ListAgentRuntimes): surface an error and
    // return NO partial or stale results (Requirement 8.8).
    const message = err instanceof Error ? err.message : String(err);
    console.error('my-deployed-agents error:', message);
    return jsonResponse(500, { error: message, apps: [] });
  }
};
