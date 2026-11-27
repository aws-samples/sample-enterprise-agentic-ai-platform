import { useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, AgentLifecycleItem } from '../hooks/useAgents'

const SYNC_STATUS_STYLES: Record<string, { bg: string; text: string }> = {
  synced: { bg: 'bg-green-500/20', text: 'text-green-400' },
  syncing: { bg: 'bg-yellow-500/20', text: 'text-yellow-400' },
  error: { bg: 'bg-red-500/20', text: 'text-red-400' },
  pending: { bg: 'bg-gray-500/20', text: 'text-gray-400' },
}

function SyncBadge({ status }: { status: string }) {
  const style = SYNC_STATUS_STYLES[status] || SYNC_STATUS_STYLES.pending
  return (
    <span className={`${style.bg} ${style.text} text-xs px-2 py-0.5 rounded-full font-medium`}>
      {status}
    </span>
  )
}

function formatTime(iso: string | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}

export function DataWorkspace() {
  const { data: agents, isLoading, error } = useAgents()
  const [selectedKB, setSelectedKB] = useState<AgentLifecycleItem | null>(null)
  const [triggeringSync, setTriggeringSync] = useState(false)

  const kbAgents = (agents || []).filter(
    (a: AgentLifecycleItem) => a.kb_status || a.kb_name || (a.data_sources && a.data_sources.length > 0)
  )

  const handleTriggerSync = async () => {
    setTriggeringSync(true)
    // In production: call pipeline service to start KB sync
    await new Promise(r => setTimeout(r, 1000))
    setTriggeringSync(false)
  }

  // Detail view
  if (selectedKB) {
    return (
      <div>
        <WorkspaceHeader icon="🗄️" title="Data" subtitle="Knowledge Base Detail" persona="GenAI Data Engineer" />
        <button onClick={() => setSelectedKB(null)} className="text-sm text-gray-400 hover:text-white mb-4">← Back to list</button>

        <div className="bg-surface-panel border border-surface-border rounded-lg p-6 space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-lg font-semibold text-white">{selectedKB.kb_name || 'Unnamed KB'}</h2>
              <p className="text-sm text-gray-400">Bound to: {selectedKB.agent_name}</p>
            </div>
            <SyncBadge status={selectedKB.kb_status || 'pending'} />
          </div>

          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-gray-500 text-xs uppercase mb-1">Embedding Model</p>
              <p className="text-gray-200">amazon.titan-embed-text-v2</p>
            </div>
            <div>
              <p className="text-gray-500 text-xs uppercase mb-1">Last Sync</p>
              <p className="text-gray-200">{formatTime(selectedKB.kb_last_sync)}</p>
            </div>
            <div>
              <p className="text-gray-500 text-xs uppercase mb-1">Sync Schedule</p>
              <p className="text-gray-200">Every 6 hours</p>
            </div>
            <div>
              <p className="text-gray-500 text-xs uppercase mb-1">Gateway Target</p>
              <p className="text-gray-200 font-mono text-xs">{selectedKB.kb_name || '—'}</p>
            </div>
          </div>

          {/* Data sources */}
          <div>
            <p className="text-gray-500 text-xs uppercase mb-2">Data Sources</p>
            {selectedKB.data_sources && selectedKB.data_sources.length > 0 ? (
              <div className="space-y-2">
                {selectedKB.data_sources.map((ds, i) => (
                  <div key={i} className="flex items-center justify-between bg-gray-800 rounded px-3 py-2">
                    <span className="text-sm text-gray-200 font-mono">{ds}</span>
                    <span className="text-xs text-green-400">Connected</span>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-gray-600 text-sm">No data sources configured</p>
            )}
          </div>

          {/* Trigger sync button */}
          <button
            onClick={handleTriggerSync}
            disabled={triggeringSync || selectedKB.kb_status === 'syncing'}
            className="px-4 py-2 bg-blue-600 text-white text-sm rounded hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {triggeringSync ? 'Triggering…' : selectedKB.kb_status === 'syncing' ? 'Sync in Progress' : 'Trigger Sync'}
          </button>

          {/* Pipeline progress (shown when syncing) */}
          {selectedKB.kb_status === 'syncing' && (
            <div>
              <p className="text-gray-500 text-xs uppercase mb-2">Pipeline Progress</p>
              <div className="flex items-center gap-2">
                {['Validate', 'Plan', 'Apply'].map((stage, i) => (
                  <div key={stage} className="flex items-center">
                    <span className={`text-xs px-2 py-1 rounded ${i === 0 ? 'bg-green-600 text-white' : i === 1 ? 'bg-yellow-600 text-white animate-pulse' : 'bg-gray-700 text-gray-400'}`}>
                      {stage}
                    </span>
                    {i < 2 && <span className="text-gray-600 mx-1">→</span>}
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    )
  }

  // List view
  return (
    <div>
      <WorkspaceHeader icon="🗄️" title="Data" subtitle="Knowledge Base Management" persona="GenAI Data Engineer" />

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading knowledge bases…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4">
          <p className="text-red-400 text-sm">Failed to load data: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && kbAgents.length === 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center">
          <p className="text-brand-200 text-lg mb-2">No knowledge bases configured</p>
          <p className="text-brand-200/60 text-sm">Agents with knowledge base bindings will appear here once deployed.</p>
        </div>
      )}

      {!isLoading && !error && kbAgents.length > 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-surface-border text-left text-brand-200/60 text-xs uppercase tracking-wider">
                <th className="px-4 py-3">Knowledge Base</th>
                <th className="px-4 py-3">Agent</th>
                <th className="px-4 py-3">Sync Status</th>
                <th className="px-4 py-3">Last Sync</th>
                <th className="px-4 py-3">Data Sources</th>
                <th className="px-4 py-3">Gateway Target</th>
              </tr>
            </thead>
            <tbody>
              {kbAgents.map((agent: AgentLifecycleItem, i: number) => (
                <tr
                  key={agent.agent_name}
                  onClick={() => setSelectedKB(agent)}
                  className={`border-b border-surface-border/50 cursor-pointer hover:bg-gray-700/30 ${i % 2 === 0 ? 'bg-surface-panel' : 'bg-surface-panel/50'}`}
                >
                  <td className="px-4 py-3 text-brand-200 text-xs">{agent.kb_name || '—'}</td>
                  <td className="px-4 py-3 font-mono text-brand-200 text-xs">{agent.agent_name}</td>
                  <td className="px-4 py-3"><SyncBadge status={agent.kb_status || 'pending'} /></td>
                  <td className="px-4 py-3 text-brand-200/70 text-xs">{formatTime(agent.kb_last_sync)}</td>
                  <td className="px-4 py-3 text-brand-200/60 text-xs">{agent.data_sources?.length || 0} sources</td>
                  <td className="px-4 py-3 text-brand-200/60 text-xs font-mono">{agent.kb_name || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
