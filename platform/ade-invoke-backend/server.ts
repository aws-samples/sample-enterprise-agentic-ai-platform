// EAP ADE Invoke Backend (ADR-040)
// -----------------------------------------------------------------------------
// Always-on ECS/Fargate service that streams the Agent Deployment Engineer
// (ADE) console chat turn token-by-token. It replaces the buffered invoke-proxy
// Lambda path for the Build-workspace chat, while preserving the two guarantees
// that path provided:
//   1. Cognito/OIDC JWT authentication on every invoke (src/auth.ts).
//   2. The Requirement-11 runtime allow-list from the lifecycle DynamoDB store
//      (src/runtimeAllowList.ts) — a caller can only invoke a deployed runtime.
// The agent is always invoked with THIS service's task role, never the caller's.
//
// Ingress (ADR-040):
//   * demo       — fronted by the console CloudFront distribution (/ade-api/*),
//                  reusing the ADR-037 origin-secret + WAF hardening.
//   * enterprise — the ALB is INTERNAL only (VPC/VPN/corp-network reachable);
//                  the customer's BYO UI calls it directly. No public edge.
//
// Routes:
//   GET  /healthz          — ALB target-group health check
//   POST /ade-api/invoke   — SigV4 AgentCore message/stream, streamed as SSE

import express, { Request, Response } from 'express'
import cors from 'cors'
import { invokeAgentRuntimeStream, type Attachment } from './src/agentcore.js'
import { validateJwt, extractAuthHeader, assertAuthConfigured } from './src/auth.js'
import {
  isValidRuntimeArn,
  listDiscoveredRuntimeQualifiers,
  assertAllowListConfigured,
} from './src/runtimeAllowList.js'

// Fail fast on a misconfigured deploy (no auth issuer / no lifecycle table)
// rather than running open or 503-ing every request.
assertAuthConfigured()
assertAllowListConfigured()

const app = express()
app.use(cors())
// Raised from 1mb to accommodate inline base64 file attachments (images/PDFs).
// Base64 inflates ~33%, so a ~10MB raw upload cap (enforced client-side) lands
// near ~13.5MB on the wire; 16mb gives headroom. This is the binding request
// cap in the path (ALB is fine); keep it under AgentCore's InvokeAgentRuntime
// payload ceiling — the client also guards total upload size.
app.use(express.json({ limit: '16mb' }))

const PORT = parseInt(process.env.PORT || '8080', 10)

// The default target when the caller sends no runtimeArn: the platform-owned
// Studio/ADE runtime (injected by Terraform). Mirrors invoke-proxy's
// AGENT_RUNTIME_ARN / ENDPOINT_QUALIFIER defaulting (resolveTarget).
const ADE_RUNTIME_ARN = process.env.ADE_RUNTIME_ARN || ''
const ADE_ENDPOINT_QUALIFIER = process.env.ADE_ENDPOINT_QUALIFIER || ''

// --- Health check (ALB target group) — at root, not under the API prefix ----
app.get('/healthz', (_req: Request, res: Response) => {
  res.json({ ok: true, service: 'eap-ade-invoke-backend' })
})

const api = express.Router()
app.use('/ade-api', api)

/**
 * Resolve + authorize the invocation target (Requirement 11), matching the
 * invoke-proxy Lambda's resolveTarget semantics:
 *   - no ARN            → the default ADE/Studio runtime + its qualifier.
 *   - malformed ARN     → 400 (rejected before any membership check).
 *   - well-formed but not in the discovered allow-list → 403.
 *   - member            → the caller's qualifier if given, else the discovered
 *                         default.
 */
async function resolveTarget(
  agentArn: string | undefined,
  targetEndpoint: string | undefined,
): Promise<{ ok: true; arn: string; qualifier?: string } | { ok: false; status: number; error: string }> {
  const rawArn = (agentArn || '').trim()

  if (!rawArn) {
    return { ok: true, arn: ADE_RUNTIME_ARN, qualifier: ADE_ENDPOINT_QUALIFIER || undefined }
  }
  if (!isValidRuntimeArn(rawArn)) {
    return { ok: false, status: 400, error: 'Invalid target runtime' }
  }

  let allow: Map<string, string>
  try {
    allow = await listDiscoveredRuntimeQualifiers()
  } catch {
    return { ok: false, status: 503, error: 'Unable to validate target runtime' }
  }
  if (!allow.has(rawArn)) {
    return { ok: false, status: 403, error: 'Target runtime is not authorized' }
  }

  const provided = (targetEndpoint || '').trim()
  return { ok: true, arn: rawArn, qualifier: provided || allow.get(rawArn) || undefined }
}

// Sentinel returned by parseAttachments on a malformed payload (vs. an empty
// array, which is the valid "no attachments" case).
const INVALID_ATTACHMENTS = Symbol('invalid-attachments')

// Total decoded-bytes ceiling across all attachments in one turn. base64 in the
// JSON body is ~4/3 of this; the express.json 16mb limit sits above that. The
// client enforces the same cap, but the server re-checks (never trust the client).
const MAX_ATTACHMENTS_BYTES = 10 * 1024 * 1024 // 10 MB decoded
const MAX_ATTACHMENTS_COUNT = 10

/**
 * Validate and normalize the optional `attachments` field into Attachment[].
 * Returns [] when absent, the INVALID_ATTACHMENTS sentinel when malformed or
 * over the size/count cap, or the validated array.
 */
function parseAttachments(raw: unknown): Attachment[] | typeof INVALID_ATTACHMENTS {
  if (raw == null) return []
  if (!Array.isArray(raw)) return INVALID_ATTACHMENTS
  if (raw.length > MAX_ATTACHMENTS_COUNT) return INVALID_ATTACHMENTS

  const out: Attachment[] = []
  let totalBytes = 0
  for (const item of raw) {
    if (!item || typeof item !== 'object') return INVALID_ATTACHMENTS
    const { bytes, mimeType, name } = item as Record<string, unknown>
    if (typeof bytes !== 'string' || bytes.length === 0) return INVALID_ATTACHMENTS
    if (typeof mimeType !== 'string' || mimeType.length === 0) return INVALID_ATTACHMENTS
    if (typeof name !== 'string' || name.length === 0) return INVALID_ATTACHMENTS
    // Approx decoded size from base64 length (4 chars → 3 bytes).
    totalBytes += Math.floor((bytes.length * 3) / 4)
    if (totalBytes > MAX_ATTACHMENTS_BYTES) return INVALID_ATTACHMENTS
    out.push({ bytes, mimeType, name })
  }
  return out
}

// --- ADE invoke — STREAMED via SSE ------------------------------------------
// Wire format matches the console SSE reader: `data: {type,text}\n\n`,
// terminated by `data: [DONE]`. A 10s heartbeat comment keeps CloudFront's
// per-packet origin timeout / the ALB idle timeout from severing a slow turn.
// Auth + allow-list errors before the stream use normal HTTP status codes so
// the console can trigger re-login (401) or surface a clear failure.
api.post('/invoke', async (req: Request, res: Response) => {
  // --- Auth (parity with the removed API Gateway Cognito authorizer) ---
  const jwt = await validateJwt(extractAuthHeader(req.headers as Record<string, unknown>))
  if (!jwt.valid) {
    // 401 lets the console trigger re-login (missing/expired/invalid token).
    return res.status(401).json({ error: jwt.error || 'Unauthorized' })
  }

  // Accept either `prompt` (examples-style) or `message` (a2aClient/console
  // ChatRenderer sends this), and `runtimeArn` or the console's `agentArn`.
  const body = req.body || {}
  const prompt: unknown = body.prompt ?? body.message
  const runtimeArn: unknown = body.runtimeArn ?? body.agentArn
  const qualifier: unknown = body.qualifier ?? body.targetEndpoint
  const sessionId: unknown = body.sessionId
  if (!prompt || typeof prompt !== 'string' || prompt.trim() === '') {
    return res.status(400).json({ error: 'prompt is required' })
  }

  // Optional file attachments (A2A FileParts). Validate shape + total size; the
  // express.json 16mb limit is the hard cap, but reject early with a clear error
  // rather than relying on a body-parser 413. Each item must be
  // { bytes: base64, mimeType, name }.
  const attachments = parseAttachments(body.attachments)
  if (attachments === INVALID_ATTACHMENTS) {
    return res.status(400).json({ error: 'Invalid attachments payload' })
  }

  // --- Resolve + authorize the target runtime (Requirement 11) ---
  const target = await resolveTarget(
    typeof runtimeArn === 'string' ? runtimeArn : undefined,
    typeof qualifier === 'string' ? qualifier : undefined,
  )
  if (!target.ok) {
    return res.status(target.status).json({ error: target.error })
  }
  if (!target.arn) {
    // No caller ARN and no configured ADE default — misconfiguration.
    return res.status(500).json({ error: 'No target runtime configured' })
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  })
  res.flushHeaders?.()

  const send = (obj: unknown) => res.write(`data: ${JSON.stringify(obj)}\n\n`)
  const heartbeat = setInterval(() => {
    if (!res.writableEnded) res.write(': keepalive\n\n')
  }, 10_000)

  try {
    for await (const evt of invokeAgentRuntimeStream({
      runtimeArn: target.arn,
      prompt,
      qualifier: target.qualifier,
      sessionId: typeof sessionId === 'string' ? sessionId : undefined,
      attachments: attachments.length ? attachments : undefined,
    })) {
      send(evt)
    }
  } catch (err) {
    send({ type: 'error', text: (err as Error).message })
  } finally {
    clearInterval(heartbeat)
    res.write('data: [DONE]\n\n')
    res.end()
  }
})

app.listen(PORT, () => {
  console.log(`eap-ade-invoke-backend listening on :${PORT}`)
})
