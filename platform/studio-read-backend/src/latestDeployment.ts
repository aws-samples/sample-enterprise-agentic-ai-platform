/**
 * Latest_Deployment_Service — `GET /api/latest-deployment` (task 2.9)
 *
 * Convenience route that returns the most recent CodePipeline execution for the
 * studio deploy pipeline. Useful when an ADE reply did not include an execution
 * ID and the user just wants to know "did my last deploy finish?".
 *
 * Behavior (design Backend Route #5, Req 12.5):
 *   - `ListPipelineExecutions` with `maxResults: 1` on the studio deploy pipeline
 *     (env `STUDIO_PIPELINE_NAME`, default `nocode-user-nocode-user-deploy-deploy`).
 *   - Response JSON: `{ executionId, status, startTime }`.
 *   - When the pipeline has no executions, returns empty/`unknown` values.
 *
 * Exports `latestDeployment`, a RouteHandler compatible with the `index.ts`
 * router. Route wiring and IAM are handled by task 2.13.
 */

import {
  CodePipelineClient,
  ListPipelineExecutionsCommand,
} from '@aws-sdk/client-codepipeline';
import type { RouteHandler } from './index';
import { jsonResponse } from './index';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const DEFAULT_PIPELINE_NAME = 'nocode-user-nocode-user-deploy-deploy';

function pipelineName(): string {
  return process.env.STUDIO_PIPELINE_NAME || DEFAULT_PIPELINE_NAME;
}

// Reuse a single client across warm invocations (region resolved from the
// runtime's AWS_REGION).
const cpClient = new CodePipelineClient({});

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export const latestDeployment: RouteHandler = async () => {
  try {
    const resp = await cpClient.send(
      new ListPipelineExecutionsCommand({
        pipelineName: pipelineName(),
        maxResults: 1,
      }),
    );

    const latest = resp.pipelineExecutionSummaries?.[0];
    if (!latest) {
      return jsonResponse(200, {
        executionId: '',
        status: 'unknown',
        startTime: '',
      });
    }

    return jsonResponse(200, {
      executionId: latest.pipelineExecutionId || '',
      status: latest.status || 'Unknown',
      startTime: latest.startTime?.toISOString() || '',
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('latest-deployment error:', message);
    return jsonResponse(500, { error: message });
  }
};
