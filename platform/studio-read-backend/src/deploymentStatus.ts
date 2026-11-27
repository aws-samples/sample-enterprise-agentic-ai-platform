/**
 * Deployment_Status_Service — `GET /api/deployment-status/:executionId` (task 2.8)
 *
 * Polled by the Console Build workspace's Deployment_Tracker every ~10s after
 * ADE starts a deployment (Req 7.2). Returns the current CodePipeline stage +
 * normalized status for the given execution, and — on success — resolves the
 * authoritative pattern and every matching AgentCore runtime ARN so the tracker
 * can surface the deployed runtimes and feed the invocation allow-list (Req 7.3).
 *
 * Behavior (design Backend Route #3, Requirements 7.3, 12.3):
 *   - `GetPipelineExecution` → normalized status
 *     (succeeded|failed|cancelled|stopped|in_progress|superseded|unknown).
 *   - `GetPipelineState` (best-effort) → the stage currently running the
 *     execution; failures here are non-fatal and leave `stage` empty.
 *   - On `succeeded` + `app_name`: read `{pattern_folder}/{app}/application.yaml`
 *     to resolve the authoritative pattern (reusing the pure `parseArchitecture`
 *     from runtimeAllowList), then match runtimes via the shared discovery
 *     primitives (`listAgentRuntimes` + `matchRuntimesToApp`) so the same
 *     runtime→app matching stays authoritative server-side.
 *
 * Response JSON:
 *   `{ executionId, status, stage, error, pattern,
 *      runtimes: { name, runtime_arn, endpoint_qualifier }[] }`.
 *
 * Exports `deploymentStatus`, a RouteHandler compatible with the `index.ts`
 * router. Route wiring and IAM are handled by task 2.13.
 *
 * _Requirements: 7.3, 12.3_
 */

import {
  CodePipelineClient,
  GetPipelineExecutionCommand,
  GetPipelineStateCommand,
} from '@aws-sdk/client-codepipeline';
import { CodeCommitClient, GetFileCommand } from '@aws-sdk/client-codecommit';
import type { ApiGatewayV2Event, ApiGatewayResult, RouteHandler } from './index';
import { jsonResponse } from './index';
import {
  listAgentRuntimes,
  matchRuntimesToApp,
  deriveEndpointQualifier,
  parseArchitecture,
} from './runtimeAllowList';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Default studio deploy pipeline when the caller does not supply `pipeline`. */
const DEFAULT_PIPELINE_NAME = 'nocode-user-nocode-user-deploy-deploy';

/** Default CodeCommit repo when the caller does not supply `repo`. */
const DEFAULT_REPO = process.env.STUDIO_TARGET_REPO || 'nocode-user';

/**
 * Deploy domain prefixed onto AgentCore runtime names by the pipeline
 * (e.g. `nocode-user`). Runtime names take the form
 * `{domain}_{app}[-{random}]` / `{domain}_{app}_{agent}[-{random}]`, so the
 * match needle is `{domain}_{app}` with dashes normalized to underscores.
 */
const STUDIO_DEPLOY_DOMAIN = process.env.STUDIO_DEPLOY_DOMAIN || 'nocode-user';

function pipelineName(override: string): string {
  return override || process.env.STUDIO_PIPELINE_NAME || DEFAULT_PIPELINE_NAME;
}

// Reuse clients across warm invocations (region resolved from AWS_REGION).
const cpClient = new CodePipelineClient({});
const ccClient = new CodeCommitClient({
  region: process.env.AWS_REGION || 'us-east-1',
});

// ---------------------------------------------------------------------------
// Pure status normalization (exported for testability)
// ---------------------------------------------------------------------------

/** Normalized status vocabulary the Console tracker understands. */
export type NormalizedStatus =
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'stopped'
  | 'in_progress'
  | 'superseded'
  | 'unknown';

/** Terminal statuses that carry an error indication for the tracker. */
const ERROR_STATUSES: readonly NormalizedStatus[] = ['failed', 'cancelled', 'stopped'];

/**
 * Map an AWS CodePipeline execution status to the normalized vocabulary.
 * Unknown/absent AWS statuses fall through to `unknown`.
 */
export function normalizeStatus(awsStatus: string | undefined | null): NormalizedStatus {
  const map: Record<string, NormalizedStatus> = {
    Succeeded: 'succeeded',
    Failed: 'failed',
    Cancelled: 'cancelled',
    Stopped: 'stopped',
    InProgress: 'in_progress',
    Superseded: 'superseded',
  };
  return map[awsStatus || ''] || 'unknown';
}

// ---------------------------------------------------------------------------
// Helpers (AWS-backed, per-request)
// ---------------------------------------------------------------------------

/**
 * Best-effort resolution of the stage currently associated with the execution.
 * Returns '' when the state cannot be read or no stage matches — never throws.
 */
async function resolveStage(pipeline: string, executionId: string): Promise<string> {
  try {
    const state = await cpClient.send(new GetPipelineStateCommand({ name: pipeline }));
    let stageName = '';
    for (const stage of state.stageStates || []) {
      const latest = stage.latestExecution;
      if (latest?.pipelineExecutionId === executionId) {
        stageName = stage.stageName || '';
        // Prefer the stage that is actively running this execution.
        if (latest.status === 'InProgress') break;
      }
    }
    return stageName;
  } catch {
    // Non-fatal — stage is only advisory while in progress.
    return '';
  }
}

/**
 * Resolve the authoritative pattern for a succeeded app by reading its
 * `application.yaml` from CodeCommit. A missing file (standalone apps have
 * none) yields `standalone`; a present manifest with no `architecture` field
 * defaults to `multi-agent`. Other read errors leave the pattern empty.
 */
async function resolvePattern(
  repo: string,
  patternFolder: string,
  appName: string,
): Promise<string> {
  if (!patternFolder) return '';
  try {
    const resp = await ccClient.send(
      new GetFileCommand({
        repositoryName: repo,
        filePath: `${patternFolder}/${appName}/application.yaml`,
      }),
    );
    const yamlText = resp.fileContent
      ? Buffer.from(resp.fileContent).toString('utf-8')
      : '';
    return parseArchitecture(yamlText, 'multi-agent');
  } catch (err) {
    const e = err as { name?: string; message?: string };
    if (e.name === 'FileDoesNotExistException') {
      return 'standalone';
    }
    console.warn('deployment-status application.yaml lookup failed:', e.message || String(err));
    return '';
  }
}

/**
 * Resolve every AgentCore runtime that matches the app on success. Reuses the
 * shared discovery primitives so runtime→app matching stays authoritative and
 * consistent with the Deployed_Agents_Service allow-list. Failures are
 * non-fatal and yield an empty list.
 */
async function resolveRuntimes(
  appName: string,
): Promise<Array<{ name: string; runtime_arn: string; endpoint_qualifier: string }>> {
  const needle = `${STUDIO_DEPLOY_DOMAIN}_${appName}`.replace(/-/g, '_');
  try {
    const runtimes = await listAgentRuntimes();
    return matchRuntimesToApp(needle, runtimes).map((rt) => ({
      name: rt.name,
      runtime_arn: rt.arn,
      endpoint_qualifier: deriveEndpointQualifier(rt.name),
    }));
  } catch (err) {
    console.warn('deployment-status ListAgentRuntimes failed:', (err as Error).message);
    return [];
  }
}

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

/**
 * GET /api/deployment-status/:executionId
 *
 * Path param:
 *   executionId — required CodePipeline execution id.
 * Query params:
 *   app_name       — optional; when present on success, resolves ARNs.
 *   pattern_folder — optional; when present on success, resolves the pattern.
 *   repo           — optional CodeCommit repo (default: nocode-user).
 *   pipeline       — optional pipeline name override (default: env / studio pipeline).
 *
 * Response: `{ executionId, status, stage, error, pattern, runtimes[] }`.
 */
export const deploymentStatus: RouteHandler = async (
  event: ApiGatewayV2Event,
): Promise<ApiGatewayResult> => {
  const executionId = (event.pathParameters?.executionId ?? '').trim();
  const query = event.queryStringParameters ?? {};
  const appName = (query.app_name ?? '').trim();
  const patternFolder = (query.pattern_folder ?? '').trim();
  const repo = (query.repo ?? '').trim() || DEFAULT_REPO;
  const pipeline = pipelineName((query.pipeline ?? '').trim());

  if (!executionId) {
    return jsonResponse(400, { error: 'executionId required' });
  }

  try {
    const execResp = await cpClient.send(
      new GetPipelineExecutionCommand({
        pipelineName: pipeline,
        pipelineExecutionId: executionId,
      }),
    );
    const awsStatus = execResp.pipelineExecution?.status || 'Unknown';
    const status = normalizeStatus(awsStatus);

    const stage = await resolveStage(pipeline, executionId);

    let pattern = '';
    let runtimes: Array<{ name: string; runtime_arn: string; endpoint_qualifier: string }> = [];

    if (status === 'succeeded' && appName) {
      // Resolve pattern and matching runtimes in parallel — independent reads.
      [pattern, runtimes] = await Promise.all([
        resolvePattern(repo, patternFolder, appName),
        resolveRuntimes(appName),
      ]);
    }

    const error = ERROR_STATUSES.includes(status) ? `Pipeline ${awsStatus}` : null;

    return jsonResponse(200, {
      executionId,
      status,
      stage,
      error,
      pattern,
      runtimes,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('deployment-status error:', message);
    return jsonResponse(500, {
      executionId,
      status: 'unknown',
      stage: '',
      error: message,
      pattern: '',
      runtimes: [],
    });
  }
};
