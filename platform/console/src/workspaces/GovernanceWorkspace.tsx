import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, AgentLifecycleItem } from '../hooks/useAgents'

const STAGES = ['enrolled', 'training', 'validated', 'graduated', 'production'] as const

const STAGE_STYLES: Record<string, { border: string; bg: string; header: string }> = {
  enrolled: { border: 'border-gray-500/30', bg: 'bg-gray-500/5', header: 'bg-gray-500/20 text-gray-300' },
  training: { border: 'border-yellow-500/30', bg: 'bg-yellow-500/5', header: 'bg-yellow-500/20 text-yellow-300' },
  validated: { border: 'border-blue-500/30', bg: 'bg-blue-500/5', header: 'bg-blue-500/20 text-blue-300' },
  graduated: { border: 'border-green-500/30', bg: 'bg-green-500/5', header: 'bg-green-500/20 text-green-300' },
  production: { border: 'border-emerald-500/30', bg: 'bg-emerald-500/5', header: 'bg-emerald-500/20 text-emerald-300' },
}

function StageColumn({
  stage,
  agents,
}: {
  stage: string
  agents: AgentLifecycleItem[]
}) {
  const style = STAGE_STYLES[stage] || STAGE_STYLES.enrolled

  return (
    <div className={`border ${style.border} rounded-lg ${style.bg} min-h-[200px] flex flex-col`}>
      <div className={`${style.header} px-3 py-2 rounded-t-lg text-xs font-medium uppercase tracking-wider flex items-center justify-between`}>
        <span>{stage}</span>
        <span className="opacity-70">{agents.length}</span>
      </div>
      <div className="p-2 space-y-2 flex-1">
        {agents.length === 0 && (
          <p className="text-brand-200/30 text-xs text-center py-4">No agents</p>
        )}
        {agents.map((agent) => (
          <div
            key={agent.agent_name}
            className="bg-surface-panel border border-surface-border rounded p-2"
          >
            <p className="text-xs font-mono text-brand-200 truncate">{agent.agent_name}</p>
            <div className="flex items-center justify-between mt-1">
              <span className="text-[10px] text-brand-200/50 font-mono">v{agent.version}</span>
              <span className="text-[10px] text-brand-200/40">
                {agent.last_transition
                  ? new Date(agent.last_transition).toLocaleDateString()
                  : ''}
              </span>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

export function GovernanceWorkspace() {
  const { data: agents, isLoading, error } = useAgents()

  // Group agents by current_state
  const grouped: Record<string, AgentLifecycleItem[]> = {}
  for (const stage of STAGES) {
    grouped[stage] = []
  }
  if (agents) {
    for (const agent of agents) {
      const stage = agent.current_state || 'enrolled'
      if (!grouped[stage]) grouped[stage] = []
      grouped[stage].push(agent)
    }
  }

  return (
    <div>
      <WorkspaceHeader icon="🛡️" title="Governance" subtitle="Agent School Progression" persona="AI Governance & Risk" />

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading governance data…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4">
          <p className="text-red-400 text-sm">Failed to load governance data: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && agents && agents.length === 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center">
          <p className="text-brand-200 text-lg mb-2">No agents in pipeline</p>
          <p className="text-brand-200/60 text-sm">Agent School stage progression will appear here as agents are enrolled.</p>
        </div>
      )}

      {!isLoading && !error && agents && agents.length > 0 && (
        <>
          {/* Stage progression arrows */}
          <div className="flex items-center justify-center gap-1 mb-4 text-xs text-brand-200/40">
            {STAGES.map((stage, i) => (
              <span key={stage} className="flex items-center gap-1">
                <span className="capitalize">{stage}</span>
                {i < STAGES.length - 1 && <span>→</span>}
              </span>
            ))}
          </div>

          {/* Kanban columns */}
          <div className="grid grid-cols-1 md:grid-cols-5 gap-3">
            {STAGES.map((stage) => (
              <StageColumn key={stage} stage={stage} agents={grouped[stage]} />
            ))}
          </div>
        </>
      )}
    </div>
  )
}
