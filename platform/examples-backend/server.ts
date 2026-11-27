// EAP Examples Backend (ADR-037)
// -----------------------------------------------------------------------------
// A single, generic, example-agnostic signer service that replaces the six
// demo-ui `server.ts` backends. It holds AWS credentials (its ECS task role in
// production; the local AWS profile in dev) and exposes five routes the console
// Examples surface calls. It knows nothing about any specific example — the
// frontend passes the resolved target (runtimeArn / stateMachineArn / log
// prefix), this service signs and forwards.
//
// Routes:
//   GET  /healthz                     — ALB target-group health check
//   POST /examples-api/invoke         — SigV4 AgentCore InvokeAgentRuntime (A2A)
//   POST /examples-api/sfn/start      — Step Functions StartExecution ({query})
//   GET  /examples-api/sfn/status     — DescribeExecution
//   GET  /examples-api/sfn/history    — GetExecutionHistory (+ A2A pairs)
//   GET  /examples-api/logs           — recent AgentCore runtime logs
//
// The /examples-api prefix matches the CloudFront path pattern that routes to
// this ALB (ADR-037), so no path rewriting is needed at the edge.
//
// Access control (ADR-046): every /examples-api/* route requires a verified
// bearer JWT (src/auth.ts), and the requested target must be a runtime / state
// machine recorded in the lifecycle table (src/allowList.ts). /healthz stays
// open for the ALB health check.

import express, { Request, Response } from 'express'
import cors from 'cors'
import { invokeAgentRuntimeStream } from './src/agentcore.js'
import { startExecution, describeExecution, getExecutionHistory } from './src/stepfunctions.js'
import { readAgentLogs } from './src/logs.js'
import { requireAuth } from './src/auth.js'
import {
  isAllowedExecution,
  isAllowedRuntime,
  isAllowedStateMachine,
  isValidRuntimePrefix,
} from './src/allowList.js'

/**
 * Run an allow-list check. Returns true when the target is allowed; otherwise
 * sends 403 (not deployed) or 503 (lifecycle table unreadable) and returns false.
 */
async function checkTarget(res: Response, check: () => Promise<boolean>): Promise<boolean> {
  try {
    if (await check()) return true
    res.status(403).json({ error: 'Target is not a deployed platform resource' })
  } catch {
    res.status(503).json({ error: 'Unable to validate target' })
  }
  return false
}

const app = express()
app.use(cors())
app.use(express.json({ limit: '1mb' }))

const PORT = parseInt(process.env.PORT || '8080', 10)

// --- Health check (ALB target group) — at root, not under the API prefix ----
app.get('/healthz', (_req: Request, res: Response) => {
  res.json({ ok: true, service: 'eap-examples-backend' })
})

// All API routes are mounted under /examples-api to match the CloudFront path
// pattern (ADR-037) — no edge path rewriting required.
const api = express.Router()
api.use(requireAuth)
app.use('/examples-api', api)

// --- AgentCore invoke (standalone chat + swarm) — STREAMED via SSE ----------
// A long agent turn buffered into one JSON blob blows past CloudFront's 30s
// origin-response timeout (per-packet). We stream Server-Sent Events instead:
// each `data: {type,text}` frame resets that timeout, and a heartbeat comment
// keeps the connection alive during silent stretches (e.g. long tool calls).
// Wire format matches the console's SSE reader: `data: {json}\n\n`, terminated
// by `data: [DONE]`. Errors are sent as an SSE `error` event (HTTP 200) so they
// render inline in the chat rather than surfacing as a transport failure.
api.post('/invoke', async (req: Request, res: Response) => {
  const { runtimeArn, prompt, qualifier, sessionId } = req.body || {}
  // Pre-stream validation can still use a normal JSON 400.
  if (!runtimeArn) return res.status(400).json({ error: 'runtimeArn is required' })
  if (!prompt) return res.status(400).json({ error: 'prompt is required' })
  if (!(await checkTarget(res, () => isAllowedRuntime(runtimeArn)))) return

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  })
  res.flushHeaders?.()

  const send = (obj: unknown) => res.write(`data: ${JSON.stringify(obj)}\n\n`)
  // Heartbeat: an SSE comment every 10s. Ignored by the client parser, but it
  // keeps a packet flowing so neither CloudFront (origin read timeout) nor the
  // ALB idle timeout severs a stream during long silent agent thinking.
  const heartbeat = setInterval(() => {
    if (!res.writableEnded) res.write(': keepalive\n\n')
  }, 10_000)

  try {
    for await (const evt of invokeAgentRuntimeStream({ runtimeArn, prompt, qualifier, sessionId })) {
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

// --- Step Functions: start --------------------------------------------------
api.post('/sfn/start', async (req: Request, res: Response) => {
  const { stateMachineArn, query } = req.body || {}
  if (!stateMachineArn) return res.status(400).json({ error: 'stateMachineArn is required' })
  if (!query) return res.status(400).json({ error: 'query is required' })
  if (!(await checkTarget(res, () => isAllowedStateMachine(stateMachineArn)))) return
  try {
    res.json(await startExecution(stateMachineArn, query))
  } catch (err) {
    res.status(500).json({ error: (err as Error).message })
  }
})

// --- Step Functions: status -------------------------------------------------
api.get('/sfn/status', async (req: Request, res: Response) => {
  const executionArn = req.query.executionArn as string | undefined
  if (!executionArn) return res.status(400).json({ error: 'executionArn is required' })
  if (!(await checkTarget(res, () => isAllowedExecution(executionArn)))) return
  try {
    res.json(await describeExecution(executionArn))
  } catch (err) {
    res.status(500).json({ error: (err as Error).message })
  }
})

// --- Step Functions: history (events + reconstructed A2A pairs) -------------
api.get('/sfn/history', async (req: Request, res: Response) => {
  const executionArn = req.query.executionArn as string | undefined
  const runtimePrefix = req.query.runtimePrefix as string | undefined
  if (!executionArn) return res.status(400).json({ error: 'executionArn is required' })
  if (runtimePrefix !== undefined && !isValidRuntimePrefix(runtimePrefix)) {
    return res.status(400).json({ error: 'Invalid runtimePrefix' })
  }
  if (!(await checkTarget(res, () => isAllowedExecution(executionArn)))) return
  try {
    res.json(await getExecutionHistory(executionArn, runtimePrefix))
  } catch (err) {
    res.status(500).json({ error: (err as Error).message })
  }
})

// --- CloudWatch logs --------------------------------------------------------
api.get('/logs', async (req: Request, res: Response) => {
  const runtimePrefix = req.query.runtimePrefix as string | undefined
  if (!runtimePrefix) return res.status(400).json({ error: 'runtimePrefix is required' })
  if (!isValidRuntimePrefix(runtimePrefix)) return res.status(400).json({ error: 'Invalid runtimePrefix' })
  const since = parseInt((req.query.since as string) || '', 10) || Date.now() - 5 * 60 * 1000
  try {
    res.json({ logs: await readAgentLogs(runtimePrefix, since) })
  } catch (err) {
    res.status(500).json({ error: (err as Error).message })
  }
})

app.listen(PORT, () => {
  console.log(`eap-examples-backend listening on :${PORT}`)
})
