import { useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, groupByApplication, ApplicationGroup } from '../hooks/useAgents'
import { UnifiedAgentView } from '../components/UnifiedAgentView'
import { fromDeployedAgent, fromApplicationGroup } from '../components/agentViewModel'
import { useDeployedAgents } from './build/useDeployedAgents'

const ARCHITECTURE_FILTERS = ['all', 'standalone', 'supervisor', 'sequential', 'swarm'] as const
type ArchFilter = (typeof ARCHITECTURE_FILTERS)[number]

const STATUS_COLORS: Record<string, string> = {
  production: 'bg-green-500',
  graduated: 'bg-emerald-500',
  validated: 'bg-blue-500',
  training: 'bg-yellow-500',
  enrolled: 'bg-gray-500',
}

function statusBadge(state: string) {
  const color = STATUS_COLORS[state] || 'bg-gray-400'
  return (
    <span className={`${color} text-white text-xs px-2 py-0.5 rounded-full whitespace-nowrap`}>
      {state}
    </span>
  )
}

function AgentCard({ app, onSelect }: { app: ApplicationGroup; onSelect: () => void }) {
  return (
    <button
      onClick={onSelect}
      className="w-full text-left bg-surface-panel border border-surface-border rounded-lg p-4 hover:border-accent/50 transition-colors"
    >
      <div className="flex items-start justify-between mb-2">
        <h3 className="text-sm font-medium text-brand-200 truncate flex-1">{app.appName}</h3>
        {statusBadge(app.current_state)}
      </div>
      <div className="space-y-1 text-xs text-brand-200/70">
        <div className="flex justify-between">
          <span>Version</span>
          <span className="font-mono">{app.version || '—'}</span>
        </div>
        <div className="flex justify-between">
          <span>Architecture</span>
          <span className="capitalize">{app.architecture}</span>
        </div>
        <div className="flex justify-between">
          <span>Agents</span>
          <span>{app.agentCount} agent{app.agentCount > 1 ? 's' : ''}</span>
        </div>
        <div className="flex justify-between">
          <span>Last Updated</span>
          <span>{app.last_transition ? new Date(app.last_transition).toLocaleDateString() : '—'}</span>
        </div>
      </div>
    </button>
  )
}

export function AppsWorkspace() {
  const { data: agents, isLoading, error } = useAgents()
  // Authoritative deployed-agent records (topology + bu + primary runtime ARN)
  // from the Deployed_Agents_Service — the SAME source the Build detail overlay
  // uses. Lets the selected-app view render the shared UnifiedAgentView layout
  // (chat-left + Architecture/Logs rail) instead of a bare chat.
  const { agents: deployedAgents } = useDeployedAgents()
  const [search, setSearch] = useState('')
  const [archFilter, setArchFilter] = useState<ArchFilter>('all')
  const [selectedApp, setSelectedApp] = useState<ApplicationGroup | null>(null)

  const applications = agents ? groupByApplication(agents) : []

  const filtered = applications.filter(app => {
    const matchesSearch = !search ||
      app.appName.toLowerCase().includes(search.toLowerCase())
    const matchesArch = archFilter === 'all' || app.architecture === archFilter
    return matchesSearch && matchesArch
  })

  // If an app is selected, show the shared ADE layout — chat-left + a right rail
  // overlaying Architecture + OTel Logs (same template as the Build detail
  // overlay). We match the selected app to its authoritative DeployedAgent
  // record (which carries topology + bu + primary runtime ARN); when found,
  // UnifiedAgentView renders the full layout with a live chat. If the directory
  // lists an app the Deployed_Agents_Service doesn't return, we still render the
  // SAME layout from a directory-only view model (fromApplicationGroup) —
  // Architecture/Logs from the directory record, chat degraded honestly (no
  // fabricated runtime ARN) — so the view never drops to a bare chat.
  if (selectedApp) {
    const deployed = deployedAgents.find((a) => a.app_name === selectedApp.appName)
    return (
      <div className="flex flex-col h-[calc(100vh-72px-3rem)]">
        <div className="flex items-center gap-2 px-4 py-2 border-b border-gray-700 bg-gray-800">
          <button
            onClick={() => setSelectedApp(null)}
            className="text-sm text-gray-400 hover:text-white"
          >
            ← Back to Directory
          </button>
          <div className="min-w-0">
            <span className="text-sm font-medium text-white">{selectedApp.appName}</span>
            <span className="ml-2 text-xs text-gray-400">
              v{selectedApp.version} • {selectedApp.architecture} • {selectedApp.agentCount} agent
              {selectedApp.agentCount > 1 ? 's' : ''}
            </span>
          </div>
        </div>
        <div className="flex min-h-0 flex-1 p-4">
          {/* Prefer the authoritative Deployed_Agents_Service record (carries the
              real runtime ARN, so chat works). When the directory lists an app
              the service didn't return, fall back to a directory-only view model
              so the app STILL renders the shared ADE layout (chat-left +
              Architecture/Logs rail) instead of a bare chat — chat degrades
              honestly (no fabricated ARN) while Architecture/Logs still show. */}
          <UnifiedAgentView vm={deployed ? fromDeployedAgent(deployed) : fromApplicationGroup(selectedApp)} />
        </div>
      </div>
    )
  }

  return (
    <div>
      <WorkspaceHeader icon="📱" title="Apps" subtitle="Agent Directory" persona="End User" />

      {/* Search and filters */}
      <div className="flex flex-wrap items-center gap-3 mb-4">
        <input
          type="text"
          placeholder="Search agents..."
          value={search}
          onChange={e => setSearch(e.target.value)}
          className="bg-gray-700 text-white rounded-lg px-3 py-2 text-sm placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 w-64"
          aria-label="Search agents"
        />
        <div className="flex gap-1" role="group" aria-label="Architecture filter">
          {ARCHITECTURE_FILTERS.map(f => (
            <button
              key={f}
              onClick={() => setArchFilter(f)}
              className={`px-3 py-1 rounded text-xs capitalize ${
                archFilter === f
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
              }`}
            >
              {f}
            </button>
          ))}
        </div>
      </div>

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading agents…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4">
          <p className="text-red-400 text-sm">Failed to load agents: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && filtered.length === 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center">
          <p className="text-brand-200 text-lg mb-2">No applications found</p>
          <p className="text-brand-200/60 text-sm">
            {applications.length ? 'Try adjusting your search or filter.' : 'Applications will appear here once deployed.'}
          </p>
        </div>
      )}

      {!isLoading && !error && filtered.length > 0 && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {filtered.map(app => (
            <AgentCard
              key={app.appName}
              app={app}
              onSelect={() => setSelectedApp(app)}
            />
          ))}
        </div>
      )}
    </div>
  )
}
