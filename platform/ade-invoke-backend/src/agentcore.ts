// ADE Invoke Backend — AgentCore streaming signer (ADR-040)
// -----------------------------------------------------------------------------
// SigV4-signs an InvokeAgentRuntime call using the A2A `message/stream` method
// and yields incremental text deltas as they arrive, so the ADE chat renders
// token-by-token. This is the same streaming contract proven for the Examples
// surface (examples-backend/src/agentcore.ts): the strands base image sets
// enable_a2a_compliant_streaming=True, so message/stream returns SSE `data:`
// frames — an initial `task`, a series of `artifact-update` text deltas, then a
// terminal `status-update` with final:true.

import { SignatureV4 } from '@smithy/signature-v4'
import { HttpRequest } from '@smithy/protocol-http'
import { Sha256 } from '@aws-crypto/sha256-js'
import { fromNodeProviderChain } from '@aws-sdk/credential-providers'

const REGION = process.env.AWS_REGION || 'us-east-1'
const SERVICE = 'bedrock-agentcore'

/**
 * A user-uploaded file attached to the turn. Sent as an A2A FilePart; the
 * Strands A2AServer executor (v1.32.0) base64-decodes `bytes` and maps it to a
 * Bedrock image/document/video content block by `mimeType` (image/* → image,
 * application/pdf + text/* + application/* → document). No base-image change
 * needed — the executor already does this conversion.
 */
export interface Attachment {
  /** Base64-encoded file bytes (A2A convention — the executor b64decodes it). */
  bytes: string
  /** MIME type, e.g. `image/png`, `application/pdf`, `text/plain`. */
  mimeType: string
  /** Original file name (used for the document block name + format inference). */
  name: string
}

export interface InvokeArgs {
  /** AgentCore runtime ARN to invoke (resolved + allow-list-checked upstream). */
  runtimeArn: string
  /** The user prompt text. */
  prompt: string
  /** Optional endpoint qualifier (?qualifier=). */
  qualifier?: string
  /** Optional AgentCore runtime session id (>= 33 chars; padded if shorter). */
  sessionId?: string
  /** Optional uploaded files, sent as A2A FileParts alongside the text part. */
  attachments?: Attachment[]
}

/** A streamed event yielded to the SSE writer. */
export interface StreamEvent {
  type: 'chunk' | 'final' | 'error'
  text: string
}

/**
 * Build the A2A JSON-RPC 2.0 message/stream envelope. The message carries the
 * text prompt followed by one FilePart per attachment. FilePart uses the A2A
 * `FileWithBytes` shape (`file.bytes` = base64 string, `file.mimeType`,
 * `file.name`) — exactly what the Strands v1.32.0 `StrandsA2AExecutor`
 * `_convert_a2a_parts_to_content_blocks` reads and turns into Bedrock
 * image/document content blocks.
 */
function buildStreamPayload(prompt: string, msgId: string, attachments: Attachment[] = []) {
  const parts: Array<Record<string, unknown>> = [{ kind: 'text', text: prompt }]
  for (const a of attachments) {
    parts.push({
      kind: 'file',
      file: { bytes: a.bytes, mimeType: a.mimeType, name: a.name },
    })
  }
  return {
    jsonrpc: '2.0',
    method: 'message/stream',
    id: msgId,
    params: {
      message: {
        role: 'user',
        parts,
        messageId: msgId,
      },
    },
  }
}

/**
 * Extract concatenated text from an A2A `artifact-update` streaming frame's
 * `result.artifact.parts[]`. Returns '' for non-artifact frames.
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
 * SigV4-sign and POST an InvokeAgentRuntime (message/stream) request; yield
 * incremental `chunk` events per artifact-update delta, then a terminal `final`
 * carrying the full concatenated answer. A2A-level errors surface as `error`.
 *
 * The agent is invoked with THIS service's task-role credentials (resolved via
 * the default provider chain) — never the caller's identity.
 */
export async function* invokeAgentRuntimeStream(args: InvokeArgs): AsyncGenerator<StreamEvent> {
  const { runtimeArn, prompt, qualifier, sessionId, attachments } = args
  const msgId = `ade-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`

  // AgentCore requires runtimeSessionId length >= 33; pad a short caller value.
  const rawSid = sessionId || `ade-session-${Date.now()}-${Math.random().toString(36).slice(2)}`
  const sid = rawSid.length >= 33 ? rawSid : rawSid.padEnd(33, '0')

  const body = JSON.stringify(buildStreamPayload(prompt, msgId, attachments))

  let response: Response
  try {
    const credentials = await fromNodeProviderChain()()
    const hostname = `${SERVICE}.${REGION}.amazonaws.com`
    const basePath = `/runtimes/${encodeURIComponent(runtimeArn)}/invocations`
    const query: Record<string, string> = {}
    if (qualifier) query['qualifier'] = qualifier

    const headers: Record<string, string> = {
      host: hostname,
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
      'x-amzn-bedrock-agentcore-runtime-session-id': sid,
    }

    const signer = new SignatureV4({ credentials, region: REGION, service: SERVICE, sha256: Sha256 })
    const signed = await signer.sign(
      new HttpRequest({ method: 'POST', protocol: 'https:', hostname, path: basePath, query, headers, body }),
      { unsignableHeaders: new Set(['content-length']) },
    )
    const fullPath = qualifier ? `${basePath}?qualifier=${encodeURIComponent(qualifier)}` : basePath
    response = await fetch(`https://${hostname}${fullPath}`, {
      method: 'POST',
      headers: { ...(signed.headers as Record<string, string>), 'content-length': Buffer.byteLength(body).toString() },
      body,
    })
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
  let buffer = ''
  let accumulated = ''
  let streamError = ''
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
