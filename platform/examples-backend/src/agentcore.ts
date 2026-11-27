// AgentCore invoke helper — SigV4-signs an InvokeAgentRuntime call and unwraps
// the A2A JSON-RPC response. Example-agnostic: the caller passes the target
// runtime ARN (resolved by the console from the lifecycle table), so this
// module knows nothing about any specific example.
//
// Ported from the demo-ui server.ts backends (aws-architect-ui,
// research-swarm-ui), consolidated into one signer (ADR-037).

import { SignatureV4 } from '@smithy/signature-v4'
import { HttpRequest } from '@smithy/protocol-http'
import { Sha256 } from '@aws-crypto/sha256-js'
import { fromNodeProviderChain } from '@aws-sdk/credential-providers'

const REGION = process.env.AWS_REGION || 'us-east-1'
const SERVICE = 'bedrock-agentcore'

export interface InvokeArgs {
  /** AgentCore runtime ARN to invoke (the entrypoint runtime for the app). */
  runtimeArn: string
  /** The user prompt text. */
  prompt: string
  /** Optional endpoint qualifier (?qualifier=). */
  qualifier?: string
  /**
   * Optional AgentCore runtime session id. When present it is sent as the
   * `x-amzn-bedrock-agentcore-runtime-session-id` header (standalone chat
   * uses this for conversation continuity; the swarm sends none).
   */
  sessionId?: string
}

export interface InvokeResult {
  response: string
  a2aRequest: unknown
  rawResponse: string
  duration: number
  sessionId: string
}

/**
 * Build the A2A JSON-RPC 2.0 envelope the runtimes expect.
 *
 * `method` selects the transport:
 *   - `message/send`   — buffered: the runtime returns ONE JSON envelope with
 *     the complete answer (used by the buffered `invokeAgentRuntime`).
 *   - `message/stream` — streamed: the runtime returns SSE `data:` frames — an
 *     initial `task`, then a series of `artifact-update` deltas carrying
 *     incremental text, then a terminal `status-update` with `final: true`
 *     (used by `invokeAgentRuntimeStream` so the UI renders token-by-token).
 *
 * The strands base image enables this via `enable_a2a_compliant_streaming=True`
 * (base-images/strands/entrypoint.py). Previously the streaming caller used
 * `message/send`, which returns a single buffered blob — so the UI only ever
 * saw one chunk at the very end (no progressive rendering).
 */
function buildA2APayload(prompt: string, msgId: string, method: 'message/send' | 'message/stream' = 'message/send') {
  return {
    jsonrpc: '2.0',
    method,
    id: msgId,
    params: {
      message: {
        role: 'user',
        parts: [{ kind: 'text', text: prompt }],
        messageId: msgId,
      },
    },
  }
}

/**
 * Extract concatenated text from an A2A `artifact-update` streaming frame's
 * `result.artifact.parts[]`. Returns '' for non-artifact frames (task /
 * status-update) so the caller can skip them.
 */
function extractArtifactDeltaText(result: any): string {
  const parts = result?.artifact?.parts
  if (!Array.isArray(parts)) return ''
  return parts
    .filter((p: any) => p?.kind === 'text' || p?.type === 'text')
    .map((p: any) => p?.text ?? '')
    .join('')
}

/**
 * Extract display text from an A2A response. Mirrors the extraction the
 * demo-ui backends used: unwrap a stringified `response`, then read
 * `result.artifacts[0].parts[].text`, falling back to `result.message.parts`.
 */
function extractResponseText(result: any): string {
  let a2aResult = result
  let responseText = ''

  if (typeof result?.response === 'string') {
    try {
      a2aResult = JSON.parse(result.response)
    } catch {
      return result.response
    }
  }

  if (a2aResult?.result) {
    const r = a2aResult.result
    const artifacts = r.artifacts || []
    if (artifacts.length > 0) {
      const texts = (artifacts[0].parts || [])
        .filter((p: any) => p.kind === 'text' || p.type === 'text')
        .map((p: any) => p.text)
      if (texts.length > 0) responseText = texts.join('\n')
    }
    if (!responseText && r.message?.parts) {
      const texts = r.message.parts
        .filter((p: any) => p.kind === 'text' || p.type === 'text')
        .map((p: any) => p.text)
      if (texts.length > 0) responseText = texts.join('\n')
    }
  } else if (a2aResult?.error) {
    responseText = `Agent error: ${a2aResult.error.message || JSON.stringify(a2aResult.error)}`
  }

  return responseText || JSON.stringify(result)
}

/**
 * SigV4-sign the InvokeAgentRuntime request and return the raw `fetch` Response.
 * Shared by the buffered (invokeAgentRuntime) and streaming
 * (invokeAgentRuntimeStream) callers. The returned Response's `body` is a
 * ReadableStream that the streaming caller iterates incrementally.
 */
async function signedInvoke(
  args: InvokeArgs,
  method: 'message/send' | 'message/stream' = 'message/send'
): Promise<{
  response: Response
  a2aPayload: ReturnType<typeof buildA2APayload>
  sid: string
}> {
  const { runtimeArn, prompt, qualifier, sessionId } = args
  const msgId = `console-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  // AgentCore requires runtimeSessionId length >= 33. Use the caller's session
  // id when supplied, else generate one; then pad to satisfy the constraint so
  // a short client value can never trigger a 400 validation error.
  const rawSid = sessionId || `session-${Date.now()}-${Math.random().toString(36).slice(2)}`
  const sid = rawSid.length >= 33 ? rawSid : rawSid.padEnd(33, '0')

  const a2aPayload = buildA2APayload(prompt, msgId, method)
  const body = JSON.stringify(a2aPayload)

  const credentials = await fromNodeProviderChain()()
  const hostname = `${SERVICE}.${REGION}.amazonaws.com`
  const encodedArn = encodeURIComponent(runtimeArn)
  const basePath = `/runtimes/${encodedArn}/invocations`
  const query: Record<string, string> = {}
  if (qualifier) query['qualifier'] = qualifier

  const headers: Record<string, string> = {
    host: hostname,
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
  }
  // Standalone chat threads a session id; swarm omits it.
  if (sessionId) headers['x-amzn-bedrock-agentcore-runtime-session-id'] = sid

  const signer = new SignatureV4({ credentials, region: REGION, service: SERVICE, sha256: Sha256 })
  const request = new HttpRequest({
    method: 'POST',
    protocol: 'https:',
    hostname,
    path: basePath,
    query,
    headers,
    body,
  })

  const signed = await signer.sign(request, { unsignableHeaders: new Set(['content-length']) })
  const fullPath = qualifier ? `${basePath}?qualifier=${encodeURIComponent(qualifier)}` : basePath
  const finalHeaders: Record<string, string> = {
    ...(signed.headers as Record<string, string>),
    'content-length': Buffer.byteLength(body).toString(),
  }

  const response = await fetch(`https://${hostname}${fullPath}`, {
    method: 'POST',
    headers: finalHeaders,
    body,
  })
  return { response, a2aPayload, sid }
}

/** SigV4-sign and POST an InvokeAgentRuntime request; return the parsed A2A result. */
export async function invokeAgentRuntime(args: InvokeArgs): Promise<InvokeResult> {
  const startTime = Date.now()
  const { response, a2aPayload, sid } = await signedInvoke(args)
  if (!response.ok) {
    const errText = await response.text()
    throw new Error(`AgentCore ${response.status}: ${errText}`)
  }

  const result = await response.json()
  return {
    response: extractResponseText(result),
    a2aRequest: a2aPayload,
    rawResponse: JSON.stringify(result),
    duration: Date.now() - startTime,
    sessionId: sid,
  }
}

/** A streamed event yielded to the SSE writer. */
export interface StreamEvent {
  type: 'chunk' | 'final' | 'error'
  text: string
}

/**
 * Streaming variant of invokeAgentRuntime. Iterates the AgentCore response body
 * incrementally and yields A2A text as it arrives, so a long agent turn streams
 * to the browser instead of being buffered into one JSON blob (which blows past
 * CloudFront's 30s origin-response timeout). The route wraps each yielded event
 * as an SSE `data:` line; a `final` event carries the fully-extracted text.
 *
 * AgentCore may return either a single JSON envelope or `data:`-framed chunks;
 * we handle both. Incremental `chunk` emission is best-effort (partial JSON is
 * skipped); the terminal `final` always carries the complete extracted answer,
 * so the client renders the full response even if mid-stream parsing missed
 * fragments.
 */
export async function* invokeAgentRuntimeStream(args: InvokeArgs): AsyncGenerator<StreamEvent> {
  let response: Response
  try {
    // message/stream — the runtime emits incremental A2A artifact-update deltas
    // (base image: enable_a2a_compliant_streaming=True) instead of one buffered
    // envelope, so the UI can render token-by-token.
    ;({ response } = await signedInvoke(args, 'message/stream'))
  } catch (err) {
    yield { type: 'error', text: (err as Error).message }
    return
  }

  if (!response.ok) {
    const errText = await response.text().catch(() => '')
    yield { type: 'error', text: `AgentCore ${response.status}: ${errText}` }
    return
  }
  if (!response.body) {
    yield { type: 'error', text: 'No response body from AgentCore' }
    return
  }

  const decoder = new TextDecoder()
  let buffer = '' // rolling buffer for SSE line parsing
  let accumulated = '' // running answer assembled from artifact-update deltas
  let streamError = '' // an A2A-level error surfaced mid-stream
  let terminal = false // set once the terminal status-update / [DONE] is seen

  // Parse one raw SSE line and emit any incremental text it carries.
  //
  // The A2A message/stream wire format (confirmed against the deployed strands
  // runtime) is single-`\n`-delimited `data:` lines whose JSON `result.kind` is
  // one of:
  //   - "task"           — initial acknowledgement (no text)
  //   - "artifact-update"— a text delta: result.artifact.parts[].text. The first
  //                        has append:false, the rest append:true; concatenating
  //                        every artifact-update's text in order yields the full
  //                        answer.
  //   - "status-update"  — lifecycle; the terminal one carries final:true /
  //                        status.state:"completed" (no text).
  const emitFromLine = function* (line: string): Generator<StreamEvent> {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith(':')) return // blank or SSE heartbeat comment
    if (!trimmed.startsWith('data:')) return
    const payload = trimmed.slice(5).trim()
    if (!payload) return
    if (payload === '[DONE]') {
      terminal = true
      return
    }
    let obj: any
    try {
      obj = JSON.parse(payload)
    } catch {
      return // partial/non-JSON frame — skip
    }
    if (obj?.error) {
      streamError = obj.error?.message || JSON.stringify(obj.error)
      terminal = true
      return
    }
    const result = obj?.result
    if (!result) return
    if (result.kind === 'artifact-update') {
      const delta = extractArtifactDeltaText(result)
      if (delta) {
        accumulated += delta
        yield { type: 'chunk', text: delta }
      }
      // The A2A-compliant streaming path (Strands enable_a2a_compliant_streaming)
      // marks the final artifact frame with lastChunk:true. AgentCore may hold
      // the SSE socket open AFTER this, and the trailing status-update:completed
      // can be delayed or coalesced — so treat lastChunk as terminal too.
      // Without this, the read loop waits for the socket to close, which is what
      // makes the chat input stay locked for seconds after the answer finishes.
      if (result.lastChunk === true) {
        terminal = true
      }
    } else if (result.kind === 'status-update') {
      // The terminal status-update carries final:true / a completed|failed|
      // canceled state. AgentCore may hold the SSE connection open AFTER this
      // event, so we must detect it and stop reading ourselves — otherwise the
      // read loop blocks forever, the route never sends [DONE]/res.end(), and
      // the client's chat input stays locked.
      const state = result.status?.state
      if (result.final === true || state === 'completed' || state === 'failed' || state === 'canceled') {
        if (state === 'failed' || state === 'canceled') {
          streamError = streamError || `Agent turn ${state}`
        }
        terminal = true
      }
    }
    // task frames carry no display text — ignored; the terminal `final` is
    // emitted after the stream drains.
  }

  const reader = (response.body as ReadableStream<Uint8Array>).getReader()
  try {
    while (!terminal) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split(/\r?\n/)
      buffer = lines.pop() || ''
      for (const line of lines) {
        yield* emitFromLine(line)
        if (terminal) break
      }
    }
    if (buffer && !terminal) yield* emitFromLine(buffer)
  } catch (err) {
    yield { type: 'error', text: `Stream interrupted: ${(err as Error).message}` }
    return
  } finally {
    // Terminal reached (or error) — stop reading and release the upstream
    // connection instead of waiting for AgentCore to close it.
    try {
      await reader.cancel()
    } catch {
      /* ignore */
    }
  }

  if (streamError) {
    yield { type: 'error', text: `Agent error: ${streamError}` }
    return
  }

  // Terminal: the authoritative full answer is the concatenation of all deltas.
  // The client replaces its progressive buffer with this final text.
  yield { type: 'final', text: accumulated || '(no response)' }
}
