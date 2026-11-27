import { useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, AgentLifecycleItem, groupByApplication, ApplicationGroup } from '../hooks/useAgents'
import { useStartPipeline } from '../hooks/usePipelines'

function formatTime(iso: string | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function AdminWorkspace() {
  const { data: agents, isLoading, error } = useAgents()
  const startPipeline = useStartPipeline()
  const [expandedApp, setExpandedApp] = useState<string | null>(null)

  const applications = agents ? groupByApplication(agents) : []

  const NEXT_STAGE: Record<string, string> = {
    enrolled: 'Training',
    training: 'Validation',
    validated: 'QA Graduation',
    graduated: 'Production',
    production: 'Redeploy',
  }

  const getPromoteLabel = (state: string): string => {
    return `Advance to ${NEXT_STAGE[state] || 'Next Stage'}`
  }

  const handlePromote = (appName: string, currentState: string) => {
    const pipelineName = `eap-${appName}`
    const target = NEXT_STAGE[currentState] || 'next stage'
    if (confirm(`Advance ${appName} to ${target}?\n\nThis will start pipeline: ${pipelineName}`)) {
      startPipeline.mutate(pipelineName)
    }
  }

  return (
    <div>
      <WorkspaceHeader icon="⚙️" title="Admin" subtitle="Agent Lifecycle Management" persona="BU Admin" />

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading admin data…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4">
          <p className="text-red-400 text-sm">Failed to load agents: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && agents && agents.length === 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center">
          <p className="text-brand-200 text-lg mb-2">No applications to manage</p>
          <p className="text-brand-200/60 text-sm">Applications will appear here once enrolled in Agent School.</p>
        </div>
      )}

      {startPipeline.isSuccess && (
        <div className="bg-green-900/20 border border-green-500/30 rounded-lg p-3 mb-4">
          <p className="text-green-400 text-sm">Pipeline execution started successfully.</p>
        </div>
      )}

      {startPipeline.isError && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-3 mb-4">
          <p className="text-red-400 text-sm">Failed to start pipeline: {(startPipeline.error as Error)?.message}</p>
        </div>
      )}

      {!isLoading && !error && applications.length > 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-surface-border text-left text-brand-200/60 text-xs uppercase tracking-wider">
                <th className="px-4 py-3">Application</th>
                <th className="px-4 py-3">Architecture</th>
                <th className="px-4 py-3">Agents</th>
                <th className="px-4 py-3">State</th>
                <th className="px-4 py-3">Version</th>
                <th className="px-4 py-3">Last Transition</th>
                <th className="px-4 py-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              {applications.map((app: ApplicationGroup, i: number) => (
                <>
                  <tr
                    key={app.appName}
                    className={`border-b border-surface-border/50 ${i % 2 === 0 ? 'bg-surface-panel' : 'bg-surface-panel/50'}`}
                  >
                    <td className="px-4 py-3 font-mono text-brand-200 text-xs">
                      <button
                        onClick={() => setExpandedApp(expandedApp === app.appName ? null : app.appName)}
                        className="hover:text-accent-fg flex items-center gap-1"
                      >
                        <span className="text-brand-300 text-[10px]">{expandedApp === app.appName ? '▼' : '▶'}</span>
                        {app.appName}
                      </button>
                    </td>
                    <td className="px-4 py-3 text-brand-200/70 text-xs capitalize">
                      {app.architecture}
                    </td>
                    <td className="px-4 py-3 text-brand-200/70 text-xs">
                      {app.agentCount} agent{app.agentCount > 1 ? 's' : ''}
                    </td>
                    <td className="px-4 py-3 text-brand-200/70 text-xs capitalize">
                      {app.current_state}
                    </td>
                    <td className="px-4 py-3 font-mono text-brand-200/70 text-xs">
                      {app.version}
                    </td>
                    <td className="px-4 py-3 text-brand-200/70 text-xs">
                      {formatTime(app.last_transition)}
                    </td>
                    <td className="px-4 py-3">
                      <button
                        onClick={() => handlePromote(app.appName, app.current_state)}
                        disabled={startPipeline.isPending}
                        className="text-xs bg-accent/20 text-accent-fg px-2 py-1 rounded hover:bg-accent/30 disabled:opacity-50 transition-colors"
                      >
                        {getPromoteLabel(app.current_state)}
                      </button>
                    </td>
                  </tr>
                  {/* Expanded agent details */}
                  {expandedApp === app.appName && app.agents.map((agent: AgentLifecycleItem) => (
                    <tr key={agent.agent_name} className="bg-surface-elevated/30 border-b border-surface-border/30">
                      <td className="px-4 py-2 pl-10 font-mono text-brand-300 text-xs">
                        └ {agent.agent_name.split('/')[1] || agent.agent_name}
                      </td>
                      <td className="px-4 py-2 text-xs text-brand-400">—</td>
                      <td className="px-4 py-2 text-xs text-brand-400">—</td>
                      <td className="px-4 py-2 text-xs text-brand-300 capitalize">{agent.current_state}</td>
                      <td className="px-4 py-2 font-mono text-xs text-brand-300">{agent.version}</td>
                      <td className="px-4 py-2 text-xs text-brand-400">{formatTime(agent.last_transition)}</td>
                      <td className="px-4 py-2 text-xs text-brand-400">—</td>
                    </tr>
                  ))}
                </>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
