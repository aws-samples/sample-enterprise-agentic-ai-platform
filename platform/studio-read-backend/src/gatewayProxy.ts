/**
 * Gateway_Proxy — POST /api/gateway  (studio-read backend route, task 2.10)
 *
 * Forwards MCP JSON-RPC requests (`tools/list` / `tools/call`) from the Console
 * Build workspace to the AgentCore Gateway.
 *
 * CRITICAL (Req 13.4): the user's Cognito JWT is taken from the INCOMING
 * `Authorization` header and forwarded verbatim to the gateway as
 * `Authorization: Bearer <that same token>`. This route NEVER substitutes a
 * service credential. The token is intentionally NOT read from the request
 * body.
 *
 * Behavior (Req 4.2, 12.6, 13.4):
 *   - Extract the Bearer token from the request's Authorization header.
 *   - Wrap the requested MCP method/params in a JSON-RPC 2.0 envelope.
 *   - POST it to the gateway (env GATEWAY_URL) with the forwarded Bearer token.
 *   - Return the gateway's JSON response to the caller.
 *
 * Tolerance (Req 4.4): on any upstream error (network failure, non-JSON body,
 * missing gateway config, or a gateway that returns no tools) the route returns
 * a tolerated `{ error: { code, message } }` payload with HTTP 200 rather than
 * failing the whole route, so the UI treats it as an empty tool list without
 * interrupting the chat experience.
 *
 * The only genuinely fatal case is a missing user token: without it there is
 * nothing to forward, so the route returns 401 and the Console re-triggers the
 * Cognito login flow (Req 13.2, 13.3).
 */

// ---------------------------------------------------------------------------
// Types — buffered event / result (mirrors index.ts so the exported handler is
// assignable to index.ts's RouteHandler type).
// ---------------------------------------------------------------------------

interface ApiGatewayV2Event {
  body?: string;
  isBase64Encoded?: boolean;
  headers?: Record<string, string>;
}

interface ApiGatewayResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

// ---------------------------------------------------------------------------
// Local JSON response helper (kept independent of index.ts so this module is
// self-contained and unit-testable in isolation).
// ---------------------------------------------------------------------------

function jsonResponse(statusCode: number, obj: unknown): ApiGatewayResult {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(obj),
  };
}

// ---------------------------------------------------------------------------
// Pure, testable helpers (task 2.11 property test targets these)
// ---------------------------------------------------------------------------

/**
 * Extract the raw Bearer token from a headers map.
 *
 * Header-name lookup is case-insensitive (callers/tests may send any casing).
 * Accepts either the full `Bearer <token>` form (scheme stripped,
 * case-insensitive) or a bare token. Returns `null` when no usable token is
 * present.
 *
 * This is the single source of truth for how the user JWT is read: from the
 * request HEADER, never from the body (Req 13.4).
 */
export function extractBearerToken(headers?: Record<string, string>): string | null {
  if (!headers) {
    return null;
  }

  let rawValue: string | undefined;
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === 'authorization') {
      rawValue = value;
      break;
    }
  }

  if (typeof rawValue !== 'string') {
    return null;
  }

  const trimmed = rawValue.trim();
  if (trimmed === '') {
    return null;
  }

  // Strip a leading "Bearer " scheme if present (case-insensitive).
  const match = /^Bearer\s+(.+)$/i.exec(trimmed);
  const token = match ? match[1].trim() : trimmed;

  return token === '' ? null : token;
}

/**
 * Build the MCP JSON-RPC 2.0 request envelope forwarded to the gateway.
 * `id` is injected for determinism/testability; production callers omit it and
 * a timestamped id is generated.
 */
export function buildJsonRpcRequest(
  method: string,
  params?: Record<string, unknown>,
  id?: string,
): { jsonrpc: '2.0'; method: string; id: string; params: Record<string, unknown> } {
  return {
    jsonrpc: '2.0',
    method,
    id: id ?? `gw-${Date.now()}`,
    params: params ?? {},
  };
}

/**
 * Parse the incoming request body into `{ method, params }`, handling
 * base64-encoded bodies. Returns `null` on absent/invalid JSON.
 */
export function parseGatewayRequestBody(
  event: ApiGatewayV2Event,
): { method?: string; params?: Record<string, unknown> } | null {
  if (!event.body) {
    return null;
  }
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body, 'base64').toString('utf-8')
      : event.body;
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') {
      return parsed as { method?: string; params?: Record<string, unknown> };
    }
    return null;
  } catch {
    return null;
  }
}

/** Shape of the tolerated error payload the UI treats as "empty" (Req 4.4). */
function toleratedError(message: string): ApiGatewayResult {
  return jsonResponse(200, { error: { code: -1, message } });
}

// ---------------------------------------------------------------------------
// Route handler
// ---------------------------------------------------------------------------

/**
 * POST /api/gateway handler. Assignable to index.ts's `RouteHandler`.
 */
export const gatewayProxyHandler = async (
  event: ApiGatewayV2Event,
): Promise<ApiGatewayResult> => {
  // 1. Take the user's JWT from the Authorization HEADER (never the body).
  const token = extractBearerToken(event.headers);
  if (!token) {
    // No token to forward → the request is unauthenticated. Return 401 so the
    // Console re-triggers the Cognito login flow (Req 13.2, 13.3).
    return jsonResponse(401, { error: 'Authorization required. Login first.' });
  }

  // 2. Gateway URL must be configured server-side.
  const gatewayUrl = process.env.GATEWAY_URL;
  if (!gatewayUrl) {
    // Tolerated: the UI shows an empty tool list rather than breaking (Req 4.4).
    return toleratedError('GATEWAY_URL is not configured');
  }

  // 3. Parse the MCP method/params from the body.
  const parsed = parseGatewayRequestBody(event);
  const method = parsed?.method;
  if (!method || typeof method !== 'string') {
    return toleratedError('method is required');
  }

  // 4. Forward the JSON-RPC request to the gateway with the user's Bearer token.
  const rpcRequest = buildJsonRpcRequest(method, parsed?.params);

  try {
    const response = await fetch(gatewayUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // The SAME user token from the incoming request — never a service cred.
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(rpcRequest),
    });

    let data: unknown;
    try {
      data = await response.json();
    } catch {
      // Upstream returned a non-JSON (or empty) body — tolerate as empty.
      return toleratedError(
        `Gateway returned a non-JSON response (status ${response.status})`,
      );
    }

    // Return the gateway's JSON-RPC response verbatim (whether result or error).
    return jsonResponse(200, data);
  } catch (err) {
    // Network / fetch failure — tolerate as empty so chat is uninterrupted.
    const message = err instanceof Error ? err.message : String(err);
    return toleratedError(message);
  }
};

export default gatewayProxyHandler;
