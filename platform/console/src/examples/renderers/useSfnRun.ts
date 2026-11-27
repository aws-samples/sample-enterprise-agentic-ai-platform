import { useRef, useState } from 'react'
import {
  startSfn,
  getSfnStatus,
  getSfnHistory,
  getLogs,
  type SfnHistoryResponse,
  type LogEntry,
} from '../../services/examplesApi'
import type { DiscoveredExample } from '../../hooks/useExamples'

export interface SfnEvent {
  id?: number
  type?: string
  timestamp?: string
  details: any
}

export interface SfnRunState {
  loading: boolean
  error: string | null
  status: string | null
  output: unknown
  events: SfnEvent[]
  a2aPayloads: SfnHistoryResponse['a2aPayloads']
  logs: LogEntry[]
  run: (query: string) => void
}

const TERMINAL = ['SUCCEEDED', 'FAILED', 'TIMED_OUT', 'ABORTED']

/**
 * Shared Step Functions run driver for the supervisor + sequential renderers.
 * Starts an execution, then polls status + history + logs every second until a
 * terminal state, exposing everything the renderers need to visualize.
 */
export function useSfnRun(example: DiscoveredExample): SfnRunState {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [output, setOutput] = useState<unknown>(null)
  const [events, setEvents] = useState<SfnEvent[]>([])
  const [a2aPayloads, setA2aPayloads] = useState<SfnHistoryResponse['a2aPayloads']>([])
  const [logs, setLogs] = useState<LogEntry[]>([])
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const run = async (query: string) => {
    const q = query.trim()
    if (!q || loading) return
    setError(null)
    setStatus(null)
    setOutput(null)
    setEvents([])
    setA2aPayloads([])
    setLogs([])
    setLoading(true)
    const startTime = Date.now()

    try {
      const { executionArn } = await startSfn(example.stateMachineArn, q)
      setStatus('RUNNING')
      pollRef.current = setInterval(async () => {
        try {
          const [st, hist, lg] = await Promise.all([
            getSfnStatus(executionArn),
            getSfnHistory(executionArn, example.runtimePrefix || undefined),
            example.runtimePrefix
              ? getLogs(example.runtimePrefix, startTime)
              : Promise.resolve({ logs: [] as LogEntry[] }),
          ])
          setEvents(hist.events as SfnEvent[])
          setA2aPayloads(hist.a2aPayloads)
          setLogs(lg.logs)
          if (st.status) setStatus(st.status)
          if (st.status && TERMINAL.includes(st.status)) {
            if (pollRef.current) clearInterval(pollRef.current)
            setOutput(st.output)
            if (st.status !== 'SUCCEEDED') setError(`Execution ${st.status.toLowerCase()}`)
            setLoading(false)
          }
        } catch {
          /* keep polling */
        }
      }, 1000)
    } catch (e) {
      if (pollRef.current) clearInterval(pollRef.current)
      setError((e as Error).message)
      setLoading(false)
    }
  }

  return { loading, error, status, output, events, a2aPayloads, logs, run }
}

/** Map SFN events to per-step status by matching state name substrings. */
export function deriveStepStatus(
  events: SfnEvent[],
  matchers: Record<string, string[]>
): Record<string, 'pending' | 'running' | 'done'> {
  const out: Record<string, 'pending' | 'running' | 'done'> = {}
  for (const key of Object.keys(matchers)) out[key] = 'pending'
  for (const e of events) {
    const name = (e.details?.name || '').toLowerCase()
    const t = e.type || ''
    for (const [key, subs] of Object.entries(matchers)) {
      if (subs.some((s) => name.includes(s))) {
        if (t.includes('Entered') || t.includes('Scheduled')) {
          if (out[key] !== 'done') out[key] = 'running'
        }
        if (t.includes('Exited') || t.includes('Succeeded')) out[key] = 'done'
      }
    }
  }
  return out
}
