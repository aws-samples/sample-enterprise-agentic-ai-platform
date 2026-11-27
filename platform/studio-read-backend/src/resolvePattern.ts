/**
 * Pattern_Resolver — GET /api/resolve-pattern
 *
 * Best-effort architecture-pattern resolution for a deployed application.
 * The Console calls this when it has a deployed-agent entry with no recorded
 * pattern (e.g. one added before pattern detection existed).
 *
 * Strategy (mirrors the standalone Studio BFF `/api/resolve-pattern`):
 *   1. Scan the well-known CodeCommit pattern folders for
 *      `{folder}/{app}/application.yaml`.
 *   2. Return the file's lowercased `architecture` field and the folder it was
 *      found in.
 *   3. If no `application.yaml` is found, or none carries a readable
 *      `architecture` field, the app is classified as `standalone`
 *      (Requirements 8.3, 12.4).
 *
 * The pure YAML-parsing logic is exported separately (`parseArchitecture`) so
 * it can be property-tested without AWS calls (task 2.7).
 *
 * _Requirements: 8.3, 12.4_
 */

import {
  CodeCommitClient,
  GetFileCommand,
} from '@aws-sdk/client-codecommit';
import type { ApiGatewayV2Event, ApiGatewayResult, RouteHandler } from './index';
import { jsonResponse } from './index';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Default CodeCommit repo when the caller does not supply `repo`. */
const DEFAULT_REPO = process.env.TARGET_REPO || 'nocode-user';

/** Pattern classification used when no architecture can be resolved. */
export const DEFAULT_PATTERN = 'standalone';

/**
 * Well-known pattern folders in the nocode-user repo layout. Scanned in order;
 * the first folder that yields a readable `architecture` wins.
 */
export const CANDIDATE_FOLDERS: readonly string[] = [
  'orchestration/supervisor',
  'orchestration/sequential',
  'orchestration/router',
  'choreography/swarm',
];

// ---------------------------------------------------------------------------
// Pure logic (exported for testability — task 2.7)
// ---------------------------------------------------------------------------

/**
 * Extract the lowercased `architecture` field from an `application.yaml` body.
 *
 * Matches a top-level `architecture:` key whose value is a simple token
 * (letters, digits, `_`, `-`). Returns `null` when the field is absent,
 * empty, or the input is unreadable, so callers can apply the standalone
 * default (Requirements 8.3, 12.4).
 */
export function parseArchitecture(yamlText: string | undefined | null): string | null {
  if (!yamlText) {
    return null;
  }
  const match = yamlText.match(/^architecture:\s*["']?([a-z0-9_-]+)["']?\s*$/im);
  if (!match) {
    return null;
  }
  const value = match[1].trim().toLowerCase();
  return value.length > 0 ? value : null;
}

// ---------------------------------------------------------------------------
// AWS client (module-scoped for connection reuse across invocations)
// ---------------------------------------------------------------------------

const ccClient = new CodeCommitClient({
  region: process.env.AWS_REGION || 'us-east-1',
});

/**
 * Read `{folder}/{app}/application.yaml` from CodeCommit and return its
 * parsed architecture, or `null` when the file is missing/unreadable. A
 * missing file (`FileDoesNotExistException`) is expected while scanning and
 * is not logged; other errors are logged and treated as unresolved.
 */
async function readArchitecture(
  repo: string,
  folder: string,
  appName: string,
): Promise<string | null> {
  try {
    const resp = await ccClient.send(
      new GetFileCommand({
        repositoryName: repo,
        filePath: `${folder}/${appName}/application.yaml`,
      }),
    );
    const yamlText = resp.fileContent
      ? Buffer.from(resp.fileContent).toString('utf-8')
      : '';
    return parseArchitecture(yamlText);
  } catch (err) {
    const e = err as { name?: string };
    if (e.name !== 'FileDoesNotExistException') {
      console.warn(
        `resolve-pattern GetFile error (${folder}/${appName}):`,
        (err as Error).message,
      );
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

/**
 * GET /api/resolve-pattern
 *
 * Query params:
 *   app_name — required.
 *   repo     — optional, defaults to env TARGET_REPO / `nocode-user`.
 *
 * Response: `{ appName, pattern, patternFolder }`.
 */
export const resolvePatternHandler: RouteHandler = async (
  event: ApiGatewayV2Event,
): Promise<ApiGatewayResult> => {
  const query = event.queryStringParameters ?? {};
  const appName = (query.app_name ?? '').trim();
  const repo = (query.repo ?? '').trim() || DEFAULT_REPO;

  if (!appName) {
    return jsonResponse(400, { error: 'app_name required' });
  }

  for (const folder of CANDIDATE_FOLDERS) {
    const pattern = await readArchitecture(repo, folder, appName);
    if (pattern) {
      return jsonResponse(200, { appName, pattern, patternFolder: folder });
    }
  }

  // No readable application.yaml architecture found → standalone.
  return jsonResponse(200, {
    appName,
    pattern: DEFAULT_PATTERN,
    patternFolder: DEFAULT_PATTERN,
  });
};
