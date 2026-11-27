/**
 * Shared types + JSON response helper for the studio-read backend routes.
 *
 * The per-route handlers (deployedAgents, deploymentStatus, resolvePattern,
 * latestDeployment, gatewayProxy, agentCard) were ported verbatim from the
 * studio-read Lambda and import `ApiGatewayV2Event` / `ApiGatewayResult` /
 * `RouteHandler` / `jsonResponse` from this module. Keeping the same event
 * shape means the handlers are reused UNCHANGED — `server.ts` provides a thin
 * Express adapter that builds this event shape from `req` and applies the
 * result to `res`.
 *
 * (Unlike the Lambda's index.ts, there is no `handler`/`ROUTES` here — the
 * Express router in server.ts owns dispatch.)
 */

// ---------------------------------------------------------------------------
// Types — the buffered event/result shape the ported handlers consume.
// (Named "ApiGatewayV2Event" purely for source-compatibility with the ported
// handlers; the Express adapter fills the same fields from an Express request.)
// ---------------------------------------------------------------------------

export interface ApiGatewayV2Event {
  version?: string;
  rawPath?: string;
  rawQueryString?: string;
  body?: string;
  isBase64Encoded?: boolean;
  headers?: Record<string, string>;
  queryStringParameters?: Record<string, string>;
  pathParameters?: Record<string, string>;
  requestContext?: {
    routeKey?: string;
    http?: {
      method?: string;
      path?: string;
    };
  };
}

export interface ApiGatewayResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

/** The shape every per-route handler implements. */
export type RouteHandler = (event: ApiGatewayV2Event) => Promise<ApiGatewayResult>;

// ---------------------------------------------------------------------------
// Shared JSON response helper (identical to the Lambda's).
// ---------------------------------------------------------------------------

export function jsonResponse(statusCode: number, obj: unknown): ApiGatewayResult {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(obj),
  };
}
