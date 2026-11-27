/**
 * Client for the generic Examples backend (ADR-037).
 *
 * All calls go to same-origin `/examples-api/*`, which CloudFront routes to the
 * ALB→Fargate signer service (and the Vite dev proxy forwards to the local
 * backend). A distinct prefix avoids colliding with the console's existing
 * `/api/*` (API Gateway invoke path). The frontend passes the resolved target
 * (runtimeArn / stateMachineArn / runtimePrefix) — the backend is
 * example-agnostic.
 */

const BASE = '/examples-api'

export interface InvokeResponse {
  response: string
  a2aRequest: unknown
  rawResponse: string
  duration: number
  sessionId: string
}

export interface SfnStartResponse {
  executionArn: string
  executionName: string
}

export interface SfnStatusResponse {
  status?: string
  startDate?: string
  stopDate?: string
  output: unknown
}

export interface A2APayloadEntry {
  agent: string
  direction: 'request' | 'response'
  timestamp: string
  payload: unknown
  eventId: number
}

export interface SfnHistoryResponse {
  events: Array<{ id?: number; type?: string; timestamp?: string; details: unknown }>
  a2aPayloads: A2APayloadEntry[]
}

export interface LogEntry {
  agent: string
  timestamp: number
  message: string
  level: string
  traceId?: string
  spanId?: string
}

/**
 * The examples backend requires the caller's Cognito JWT on every route
 * (ADR-046). CognitoProvider persists it under `console_token`; read it per
 * request so a fresh login is picked up without re-rendering callers.
 */
function authHeaders(): Record<string, string> {
  const token = localStorage.getItem('console_token')
  return token ? { Authorization: `Bearer ${token}` } : {}
}

async function errorMessage(res: Response, path: string): Promise<string> {
  if (res.status === 401) return 'Your session has expired. Please sign in again.'
  try {
    const data = await res.json()
    if (data?.error) return data.error
  } catch {
    /* body was not JSON */
  }
  return `${path} failed (${res.status})`
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error(await errorMessage(res, path))
  return (await res.json()) as T
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: authHeaders() })
  if (!res.ok) throw new Error(await errorMessage(res, path))
  return (await res.json()) as T
}

/** A streamed invoke event (matches the examples-backend SSE contract). */
export interface InvokeStreamEvent {
  type: 'chunk' | 'final' | 'error'
  text: string
}

/**
 * SigV4 AgentCore invoke (standalone chat + swarm), STREAMED.
 *
 * The backend streams Server-Sent Events (`data: {type,text}\n\n`, terminated by
 * `data: [DONE]`) so long agent turns render progressively instead of being
 * buffered into one response that exceeds CloudFront's origin-response timeout.
 * Yields `chunk` events as text arrives and a terminal `final` with the full
 * answer; `error` events carry an inline error message.
 */
export async function* invokeAgent(args: {
  runtimeArn: string
  prompt: string
  qualifier?: string
  sessionId?: string
}): AsyncGenerator<InvokeStreamEvent> {
  const res = await fetch(`${BASE}/invoke`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(args),
  })

  if (!res.ok || !res.body) {
    // Non-streaming failure (401 auth, 403 allow-list, 400 validation, or no
    // body). Surface the JSON error; fall back to a generic message.
    yield { type: 'error', text: await errorMessage(res, 'invoke') }
    return
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  // Set once we see the `data: [DONE]` sentinel. We stop reading immediately
  // rather than waiting for the HTTP body to physically close — otherwise the
  // caller's `loading` flag (which disables the chat input) stays true for the
  // extra seconds it takes the connection to tear down through CloudFront/ALB,
  // so the input appears locked well after the answer has finished rendering.
  let seenDone = false

  const parseLine = (line: string): InvokeStreamEvent | null => {
    if (!line.startsWith('data: ')) return null
    const data = line.slice(6)
    if (data === '[DONE]') {
      seenDone = true
      return null
    }
    try {
      return JSON.parse(data) as InvokeStreamEvent
    } catch {
      return null // heartbeat comment or partial frame
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
        if (line.trimStart().startsWith(':')) continue // SSE heartbeat comment
        const evt = parseLine(line)
        if (evt) yield evt
        if (seenDone) break // terminal [DONE] seen — stop before draining more
      }
    }
    if (buffer && !seenDone) {
      const evt = parseLine(buffer)
      if (evt) yield evt
    }
  } catch {
    yield { type: 'error', text: '[Connection interrupted]' }
  } finally {
    // Release the connection instead of waiting for the server to close it, so
    // the generator returns promptly and the chat input re-enables at once.
    try {
      await reader.cancel()
    } catch {
      /* ignore */
    }
  }
}

/** Start a Step Functions execution. */
export function startSfn(stateMachineArn: string, query: string): Promise<SfnStartResponse> {
  return post<SfnStartResponse>(`${BASE}/sfn/start`, { stateMachineArn, query })
}

/** Poll a Step Functions execution status. */
export function getSfnStatus(executionArn: string): Promise<SfnStatusResponse> {
  return get<SfnStatusResponse>(`${BASE}/sfn/status?executionArn=${encodeURIComponent(executionArn)}`)
}

/** Get execution history (events + reconstructed A2A pairs). */
export function getSfnHistory(
  executionArn: string,
  runtimePrefix?: string
): Promise<SfnHistoryResponse> {
  const q = new URLSearchParams({ executionArn })
  if (runtimePrefix) q.set('runtimePrefix', runtimePrefix)
  return get<SfnHistoryResponse>(`${BASE}/sfn/history?${q.toString()}`)
}

/** Read recent AgentCore runtime logs for an app. */
export function getLogs(runtimePrefix: string, since?: number): Promise<{ logs: LogEntry[] }> {
  const q = new URLSearchParams({ runtimePrefix })
  if (since) q.set('since', String(since))
  return get<{ logs: LogEntry[] }>(`${BASE}/logs?${q.toString()}`)
}
