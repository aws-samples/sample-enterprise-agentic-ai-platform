import { useEffect, useRef, useState } from 'react'
import { getLogs, type LogEntry } from '../services/examplesApi'

/**
 * AgentLogs — reusable OTel/CloudWatch log pane for a deployed agent.
 *
 * Extracted from the SwarmGraph inline logs pane so every surface (ADE Build,
 * every Examples pattern, the App Directory detail view) can show the same
 * live agent-log stream. Backed by `examplesApi.getLogs(runtimePrefix, since)`
 * → `readAgentLogs` in examples-backend, which reads the app's
 * `/aws/bedrock-agentcore/runtimes/<runtimePrefix>` log groups. The prefix is
 * agent-agnostic, so this works for the ADE runtime as well as example apps.
 *
 * Polling model:
 *   - When `active` is true (a turn/run is in flight), poll every `pollMs`
 *     from `since` so the pane animates as the agent works.
 *   - When `active` becomes false, one final fetch captures the tail, then
 *     polling stops (avoids hammering CloudWatch while idle).
 *   - A manual Refresh button always does a one-off fetch.
 *
 * `onLogs` lets a parent (e.g. the swarm mesh) observe the latest entries to
 * derive active-agent / handoff animation without re-fetching.
 */

const LOG_COLORS = ['#58a6ff', '#f0883e', '#3fb950', '#a371f7', '#f778ba']

function colorForAgent(agent: string, agents: string[]): string {
  const i = agents.indexOf(agent)
  return LOG_COLORS[(i < 0 ? agents.length : i) % LOG_COLORS.length]
}

function levelClass(level: string): string {
  const l = (level || '').toUpperCase()
  if (l === 'ERROR') return 'text-status-error'
  if (l === 'WARNING' || l === 'WARN') return 'text-yellow-400'
  return 'text-brand-400'
}

export interface AgentLogsProps {
  /** Runtime log-group prefix, e.g. "team_bu_1_rrf_search_app_". Empty = disabled. */
  runtimePrefix: string
  /** Poll while true (a turn/run is in flight); do a final fetch when it flips false. */
  active?: boolean
  /** Epoch ms lower bound for log events. Defaults to (mount time − 5 min). */
  since?: number
  /** Poll interval while active (ms). */
  pollMs?: number
  /** Observe the latest fetched entries (e.g. to animate a topology graph). */
  onLogs?: (logs: LogEntry[]) => void
  /** Optional fixed height for the scroll area (Tailwind class). */
  heightClass?: string
}

export function AgentLogs({
  runtimePrefix,
  active = false,
  since,
  pollMs = 2000,
  onLogs,
  heightClass = 'max-h-96',
}: AgentLogsProps) {
  const [logs, setLogs] = useState<LogEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const sinceRef = useRef<number>(since ?? Date.now() - 5 * 60 * 1000)
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const onLogsRef = useRef(onLogs)
  onLogsRef.current = onLogs

  const distinctAgents = Array.from(new Set(logs.map((l) => l.agent)))

  const fetchOnce = async () => {
    if (!runtimePrefix) return
    setLoading(true)
    try {
      const { logs: fetched } = await getLogs(runtimePrefix, sinceRef.current)
      setLogs(fetched)
      setError(null)
      onLogsRef.current?.(fetched)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }

  // Poll while active; final fetch + stop when active turns off.
  useEffect(() => {
    if (!runtimePrefix) return
    if (active) {
      // Reset the window to the start of this run so the pane shows only it.
      sinceRef.current = since ?? Date.now()
      void fetchOnce()
      pollRef.current = setInterval(() => void fetchOnce(), pollMs)
      return () => {
        if (pollRef.current) clearInterval(pollRef.current)
        pollRef.current = null
      }
    }
    // Not active: capture the tail once (covers the final flush after a turn).
    void fetchOnce()
    return undefined
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, runtimePrefix])

  if (!runtimePrefix) {
    return (
      <div className="bg-surface-panel border border-surface-border rounded-lg p-4">
        <h3 className="text-sm font-semibold text-brand-100 mb-2">📡 OTel Agent Logs</h3>
        <div className="text-xs text-brand-400">
          Logs are unavailable for this agent (no runtime prefix resolved).
        </div>
      </div>
    )
  }

  return (
    <div className="bg-surface-panel border border-surface-border rounded-lg p-4">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-brand-100">📡 OTel Agent Logs</h3>
        <button
          onClick={() => {
            sinceRef.current = Date.now() - 5 * 60 * 1000
            void fetchOnce()
          }}
          disabled={loading}
          className="text-xs px-2 py-0.5 rounded border border-surface-border text-brand-300 hover:text-brand-50 hover:border-accent/50 disabled:opacity-50"
        >
          {loading ? 'Loading…' : 'Refresh'}
        </button>
      </div>
      <div className={`${heightClass} overflow-y-auto space-y-1 text-xs font-mono`}>
        {error && <div className="text-status-error">{error}</div>}
        {!error && logs.length === 0 && (
          <div className="text-brand-400">
            No recent logs. Send a message/run a query, then refresh.
          </div>
        )}
        {logs.map((log, i) => (
          <div key={i} className="border-b border-surface-border/50 pb-1">
            <span className={`mr-2 ${levelClass(log.level)}`}>{log.level}</span>
            <span style={{ color: colorForAgent(log.agent, distinctAgents) }}>{log.agent}</span>
            {log.spanId && <span className="ml-2 text-brand-500">span {log.spanId.slice(0, 8)}</span>}
            <div className="text-brand-200 whitespace-pre-wrap break-words">{log.message}</div>
          </div>
        ))}
      </div>
    </div>
  )
}
