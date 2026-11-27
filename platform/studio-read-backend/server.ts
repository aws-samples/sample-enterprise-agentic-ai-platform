// EAP Studio-Read Backend
// -----------------------------------------------------------------------------
// Always-on ECS/Fargate service serving the Console Build workspace's read-only
// routes. It replaces the studio-read Lambda + HTTP API Gateway path with an
// ALB→Fargate backend, so every console backend now runs on ALB/Fargate (the
// ADR-040 pattern applied for consistency).
//
// The 7 per-route handlers are reused UNCHANGED from the Lambda (they consume a
// buffered `{queryStringParameters, pathParameters, headers, body}` event and
// return `{statusCode, headers, body}`). This file provides a thin Express
// adapter that builds that event shape from `req` and applies the result to
// `res`, plus the JWT gate the API Gateway Cognito authorizer used to provide.
//
// Ingress:
//   * demo       — fronted by the console CloudFront distribution (/api/*),
//                  reusing the origin-secret + WAF hardening.
//   * enterprise — the ALB is INTERNAL only (VPC/VPN/corp-network reachable);
//                  the customer's BYO UI calls it directly. No public edge.
//
// Routes (buffered JSON — no streaming):
//   GET  /healthz                              — ALB target-group health check
//   GET  /api/my-deployed-agents               — Deployed_Agents_Service
//   GET  /api/deployment-status/:executionId   — Deployment_Status_Service
//   GET  /api/resolve-pattern                  — Pattern_Resolver
//   GET  /api/latest-deployment                — Latest_Deployment_Service
//   POST /api/gateway                          — Gateway_Proxy
//   GET  /api/agent-card                       — Agent_Card
//   GET  /api/config                           — Config

import express, { Request, Response, NextFunction } from 'express';
import cors from 'cors';

import type { ApiGatewayV2Event, ApiGatewayResult, RouteHandler } from './src/index.js';
import { validateJwt, extractAuthHeader, assertAuthConfigured } from './src/auth.js';

import { deployedAgentsHandler } from './src/deployedAgents.js';
import { deploymentStatus } from './src/deploymentStatus.js';
import { resolvePatternHandler } from './src/resolvePattern.js';
import { latestDeployment } from './src/latestDeployment.js';
import { gatewayProxyHandler } from './src/gatewayProxy.js';
import { agentCardHandler, configHandler } from './src/agentCard.js';

// Fail fast on a misconfigured deploy (no auth issuer) rather than running open.
assertAuthConfigured();

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

const PORT = parseInt(process.env.PORT || '8080', 10);

// ---------------------------------------------------------------------------
// Health check (ALB target group) — at root, not under the API prefix, and NOT
// behind the JWT gate.
// ---------------------------------------------------------------------------
app.get('/healthz', (_req: Request, res: Response) => {
  res.json({ ok: true, service: 'eap-studio-read-backend' });
});

// ---------------------------------------------------------------------------
// JWT gate — parity with the removed API Gateway Cognito authorizer. Applied to
// every /api/* route; a missing/expired/invalid token → 401 so the console can
// re-trigger login. (Gateway_Proxy also reads the token to forward it upstream;
// gating here first matches the old authorizer-then-handler flow.)
// ---------------------------------------------------------------------------
const api = express.Router();

api.use(async (req: Request, res: Response, next: NextFunction) => {
  const jwt = await validateJwt(extractAuthHeader(req.headers as Record<string, unknown>));
  if (!jwt.valid) {
    res.status(401).json({ error: jwt.error || 'Unauthorized' });
    return;
  }
  next();
});

// ---------------------------------------------------------------------------
// Adapter — build the handlers' buffered event from an Express request, run the
// handler, and apply its {statusCode, headers, body} result to the response.
// ---------------------------------------------------------------------------
function toEvent(req: Request): ApiGatewayV2Event {
  // Normalize header values to strings (Express can surface string | string[]).
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (typeof v === 'string') headers[k] = v;
    else if (Array.isArray(v)) headers[k] = v.join(', ');
  }

  // Query params as a flat string map (matches API Gateway's shape).
  const queryStringParameters: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.query)) {
    if (typeof v === 'string') queryStringParameters[k] = v;
    else if (Array.isArray(v) && typeof v[0] === 'string') queryStringParameters[k] = v[0] as string;
  }

  // Path params (only deployment-status has one: executionId).
  const pathParameters: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.params)) {
    if (typeof v === 'string') pathParameters[k] = v;
  }

  // express.json() already parsed the body; re-serialize so handlers that
  // JSON.parse(event.body) (e.g. gatewayProxy) get the string form they expect.
  const body =
    req.body !== undefined && req.body !== null && Object.keys(req.body).length > 0
      ? JSON.stringify(req.body)
      : undefined;

  return {
    headers,
    queryStringParameters,
    pathParameters,
    body,
    isBase64Encoded: false,
  };
}

function adapt(handler: RouteHandler) {
  return async (req: Request, res: Response): Promise<void> => {
    try {
      const result: ApiGatewayResult = await handler(toEvent(req));
      res
        .status(result.statusCode)
        .set(result.headers || { 'Content-Type': 'application/json' })
        .send(result.body);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error('studio-read-backend handler error:', message);
      res.status(500).json({ error: 'Internal error' });
    }
  };
}

// ---------------------------------------------------------------------------
// Routes (mounted under /api, gated by the JWT middleware above).
// ---------------------------------------------------------------------------
api.get('/my-deployed-agents', adapt(deployedAgentsHandler));
api.get('/deployment-status/:executionId', adapt(deploymentStatus));
api.get('/resolve-pattern', adapt(resolvePatternHandler));
api.get('/latest-deployment', adapt(latestDeployment));
api.post('/gateway', adapt(gatewayProxyHandler));
api.get('/agent-card', adapt(agentCardHandler));
api.get('/config', adapt(configHandler));

app.use('/api', api);

app.listen(PORT, () => {
  console.log(`eap-studio-read-backend listening on :${PORT}`);
});
