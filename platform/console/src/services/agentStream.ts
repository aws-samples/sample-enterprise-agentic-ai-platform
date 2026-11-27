/**
 * agentStream — the single streaming-invoke client for the whole console.
 *
 * Every agent chat surface (ADE Build, per-agent App-Directory chat, and all
 * Examples patterns) streams a turn through here, so there is ONE SSE reader
 * and ONE terminal-`[DONE]` handling path (the fix that unlocks the input
 * promptly lives here, not duplicated across a2aClient + examplesApi).
 *
 * The two historical divergences are absorbed by props:
 *   - endpoint:  /ade-api/invoke (ADE) · /api/invoke (per-agent, buffered) ·
 *                /examples-api/invoke (Examples). All emit the same SSE wire
 *                shape `data: {type,text}\n\n` terminated by `data: [DONE]`.
 *   - auth:      'cognito' forwards the user's bearer JWT (validated by the
 *                ade/api backends). 'none' sends no auth header (the
 *                examples-backend does server-side SigV4).
 *
 * Request body is normalized to carry both the ADE/api fields (message,
 * sessionId, agentArn) and the Examples fields (prompt, runtimeArn, qualifier)
 * so a single call shape serves all three backends; each backend reads the
 * fields it understands.
 */

export interface AgentStreamEvent {
  type: 'chunk' | 'final' | 'error' | 'session'
  text?: string
  sessionId?: string
}

export type AuthMode = 'cognito' | 'none'

/**
 * A file the user attached to the turn. Sent inline as base64; the ADE backend
 * forwards it as an A2A FilePart and the Strands executor maps it to a Bedrock
 * image/document content block by `mimeType`.
 */
export interface Attachment {
  /** Base64-encoded file bytes (no data: prefix). */
  bytes: string
  /** MIME type, e.g. `image/png`, `application/pdf`, `text/plain`. */
  mimeType: string
  /** Original file name. */
  name: string
}

export interface AgentStreamParams {
  /** First-party endpoint: /ade-api/invoke | /api/invoke | /examples-api/invoke. */
  endpoint: string
  /** User prompt text. */
  message: string
  /** Stable session id (>= 33 chars enforced server-side; padded there if short). */
  sessionId: string
  /** 'cognito' → forward the bearer JWT; 'none' → no auth header (Examples). */
  authMode: AuthMode
  /** Cognito JWT (required when authMode === 'cognito'). */
  token?: string
  /** Optional invocation target ARN (per-agent chat / Examples runtimeArn). */
  agentArn?: string
  /** Optional endpoint qualifier (Examples). */
  qualifier?: string
  /** Optional file attachments sent inline (ADE backend → A2A FileParts). */
  attachments?: Attachment[]
  /** Called on a 401 so the UI can trigger re-login (cognito mode). */
  onUnauthorized?: () => void
}

/**
 * Invoke an agent and yield SSE events as they arrive. Breaks immediately on
 * the terminal `[DONE]` sentinel and cancels the reader, so the caller's
 * loading flag clears the moment the turn ends (not when the socket closes).
 */
export async function* streamAgent(params: AgentStreamParams): AsyncGenerator<AgentStreamEvent> {
  const { endpoint, message, sessionId, authMode, token, agentArn, qualifier, attachments, onUnauthorized } =
    params

  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (authMode === 'cognito' && token) headers.Authorization = `Bearer ${token}`

  // Normalized body: carry both naming conventions so any backend can read it.
  const body: Record<string, unknown> = { message, prompt: message, sessionId }
  if (agentArn) {
    body.agentArn = agentArn
    body.runtimeArn = agentArn
  }
  if (attachments && attachments.length) body.attachments = attachments
  if (qualifier) body.qualifier = qualifier

  let response: Response
  try {
    response = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify(body) })
  } catch (e) {
    yield { type: 'error', text: (e as Error).message || 'Network error' }
    return
  }

  if (!response.ok) {
    if (response.status === 401) {
      onUnauthorized?.()
      yield { type: 'error', text: 'Session expired. Redirecting to login...' }
      return
    }
    if (response.status === 403) {
      yield { type: 'error', text: 'Authorization failed. Please re-login.' }
      return
    }
    // Try to surface a JSON error body; fall back to a status message.
    let msg = `Agent returned status ${response.status}`
    try {
      const data = await response.json()
      if (data?.error) msg = typeof data.error === 'string' ? data.error : JSON.stringify(data.error)
    } catch {
      /* body was not JSON */
    }
    yield { type: 'error', text: msg }
    return
  }

  if (!response.body) {
    yield { type: 'error', text: 'No response body from agent.' }
    return
  }

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  let seenDone = false

  const parseLine = (line: string): AgentStreamEvent | null => {
    const trimmed = line.trimStart()
    if (trimmed.startsWith(':')) return null // SSE heartbeat comment
    if (!line.startsWith('data: ')) return null
    const data = line.slice(6)
    if (data === '[DONE]') {
      seenDone = true
      return null
    }
    try {
      return JSON.parse(data) as AgentStreamEvent
    } catch {
      return null // partial / non-JSON frame
    }
  }

  try {
    while (!seenDone) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split('\n')
      buffer = lines.pop() || ''
      for (const line of lines) {
        const evt = parseLine(line)
        if (evt) yield evt
        if (seenDone) break
      }
    }
    if (buffer && !seenDone) {
      const evt = parseLine(buffer)
      if (evt) yield evt
    }
  } catch {
    yield { type: 'error', text: '[Connection interrupted]' }
  } finally {
    try {
      await reader.cancel()
    } catch {
      /* ignore */
    }
  }
}
