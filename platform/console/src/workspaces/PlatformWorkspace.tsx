import { useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, AgentLifecycleItem } from '../hooks/useAgents'
import { usePipelines } from '../hooks/usePipelines'
import { KanbanBoard, KanbanColumn } from '../components/KanbanBoard'

type PlatformTab = 'overview' | 'state' | 'kanban'

function MetricCard({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return (
    <div className="bg-surface-panel border border-surface-border rounded-lg p-4">
      <p className="text-brand-200/60 text-xs uppercase tracking-wider mb-1">{label}</p>
      <p className="text-2xl font-semibold text-brand-200">{value}</p>
      {sub && <p className="text-brand-200/40 text-xs mt-1">{sub}</p>}
    </div>
  )
}

function computeTimeInStage(lastTransition: string): string {
  if (!lastTransition) return '—'
  const ms = Date.now() - new Date(lastTransition).getTime()
  const hours = Math.floor(ms / 3600000)
  if (hours < 1) return '<1h'
  if (hours < 24) return `${hours}h`
  const days = Math.floor(hours / 24)
  return `${days}d`
}

function buildKanbanColumns(agents: AgentLifecycleItem[]): KanbanColumn[] {
  const stages = ['enrolled', 'training', 'validated', 'graduated', 'production'] as const
  return stages.map(stage => {
    const stageAgents = agents.filter(a => a.current_state === stage)
    return {
      stage,
      count: stageAgents.length,
      agents: stageAgents.map(a => ({
        agentName: a.agent_name,
        appName: a.agent_name.split('/')[0] || a.agent_name,
        version: a.version,
        timeInStage: computeTimeInStage(a.last_transition),
        isStuck: Date.now() - new Date(a.last_transition).getTime() > 24 * 3600000,
        stateHistory: a.state_history?.map(h => ({ state: h.to_state, timestamp: h.timestamp })),
        evaluationScores: a.eval_score ? { overall: a.eval_score } : undefined,
        graduationReports: a.graduation_reports?.map(r => ({ version: r.version, verdict: r.verdict, timestamp: r.timestamp })),
      })),
    }
  })
}

export function PlatformWorkspace() {
  const { data: agents, isLoading: agentsLoading, error: agentsError } = useAgents()
  const { data: executions, isLoading: pipelinesLoading, error: pipelinesError } = usePipelines()
  const [activeTab, setActiveTab] = useState<PlatformTab>('overview')
  const [selectedAgent, setSelectedAgent] = useState<AgentLifecycleItem | null>(null)

  const isLoading = agentsLoading || pipelinesLoading
  const error = agentsError || pipelinesError

  const totalAgents = agents?.length || 0
  const stageCount: Record<string, number> = {}
  if (agents) {
    for (const agent of agents) {
      stageCount[agent.current_state || 'unknown'] = (stageCount[agent.current_state || 'unknown'] || 0) + 1
    }
  }
  const totalPipelines = executions?.length || 0
  const failedPipelines = executions?.filter(e => e.status === 'Failed').length || 0
  const inProgressPipelines = executions?.filter(e => e.status === 'InProgress').length || 0

  return (
    <div className="flex flex-col h-full">
      <WorkspaceHeader icon="🏗️" title="Platform" subtitle="State & Operations" persona="Platform Operator" />

      {/* Tab bar */}
      <div className="flex gap-1 mb-4" role="tablist">
        {(['overview', 'state', 'kanban'] as PlatformTab[]).map(tab => (
          <button
            key={tab}
            role="tab"
            aria-selected={activeTab === tab}
            onClick={() => setActiveTab(tab)}
            className={`px-4 py-2 text-sm rounded-t capitalize ${activeTab === tab ? 'bg-gray-700 text-white border-b-2 border-blue-500' : 'text-gray-400 hover:text-white'}`}
          >
            {tab === 'kanban' ? 'Agent School' : tab}
          </button>
        ))}
      </div>

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4 mb-4">
          <p className="text-red-400 text-sm">Failed to load: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && activeTab === 'overview' && (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
            <MetricCard label="Total Agents" value={totalAgents} sub="Across all stages" />
            <MetricCard label="In Production" value={stageCount['production'] || 0} sub="Live agents" />
            <MetricCard label="Pipeline Runs" value={totalPipelines} sub="Recent executions" />
            <MetricCard label="Failures" value={failedPipelines} sub={inProgressPipelines > 0 ? `${inProgressPipelines} in progress` : 'None active'} />
          </div>

          {/* Stage breakdown */}
          <div className="bg-surface-panel border border-surface-border rounded-lg p-4 mb-6">
            <h2 className="text-sm font-medium text-brand-200 mb-3">Agents by Stage</h2>
            <div className="flex items-end gap-2 h-24">
              {(['enrolled', 'training', 'validated', 'graduated', 'production'] as const).map(stage => {
                const count = stageCount[stage] || 0
                const maxCount = Math.max(...Object.values(stageCount), 1)
                const height = Math.max((count / maxCount) * 100, 8)
                const colors: Record<string, string> = { enrolled: 'bg-gray-500', training: 'bg-yellow-500', validated: 'bg-blue-500', graduated: 'bg-green-500', production: 'bg-emerald-500' }
                return (
                  <div key={stage} className="flex-1 flex flex-col items-center gap-1">
                    <span className="text-xs text-brand-200 font-medium">{count}</span>
                    <div className={`w-full rounded-t ${colors[stage]}`} style={{ height: `${height}%` }} />
                    <span className="text-[10px] text-brand-200/50 capitalize truncate w-full text-center">{stage}</span>
                  </div>
                )
              })}
            </div>
          </div>

          {/* Active pipelines */}
          {inProgressPipelines > 0 && executions && (
            <div className="bg-surface-panel border border-surface-border rounded-lg p-4">
              <h2 className="text-sm font-medium text-brand-200 mb-3">Active Pipelines</h2>
              <div className="space-y-2">
                {executions.filter(e => e.status === 'InProgress').map(exec => (
                  <div key={exec.executionId} className="flex items-center justify-between py-2 border-b border-surface-border/30 last:border-0">
                    <span className="font-mono text-xs text-brand-200">{exec.pipelineName.replace(/^eap-/, '')}</span>
                    <span className="bg-yellow-500/20 text-yellow-400 text-xs px-2 py-0.5 rounded-full animate-pulse">In Progress</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </>
      )}

      {!isLoading && !error && activeTab === 'state' && (
        <div className="space-y-4">
          {/* Unified state view — list all agents with drill-down */}
          <div className="bg-surface-panel border border-surface-border rounded-lg overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-surface-border text-left text-brand-200/60 text-xs uppercase tracking-wider">
                  <th className="px-4 py-3">Agent</th>
                  <th className="px-4 py-3">State</th>
                  <th className="px-4 py-3">Version</th>
                  <th className="px-4 py-3">Last Transition</th>
                  <th className="px-4 py-3">History</th>
                  <th className="px-4 py-3">Graduations</th>
                </tr>
              </thead>
              <tbody>
                {(agents || []).map((agent, i) => (
                  <tr
                    key={agent.agent_name}
                    onClick={() => setSelectedAgent(agent)}
                    className={`border-b border-surface-border/50 cursor-pointer hover:bg-gray-700/30 ${i % 2 === 0 ? 'bg-surface-panel' : 'bg-surface-panel/50'}`}
                  >
                    <td className="px-4 py-3 font-mono text-brand-200 text-xs">{agent.agent_name}</td>
                    <td className="px-4 py-3 text-xs capitalize text-brand-200/70">{agent.current_state}</td>
                    <td className="px-4 py-3 text-xs font-mono text-brand-200/70">{agent.version}</td>
                    <td className="px-4 py-3 text-xs text-brand-200/60">{agent.last_transition ? new Date(agent.last_transition).toLocaleDateString() : '—'}</td>
                    <td className="px-4 py-3 text-xs text-brand-200/60">{agent.state_history?.length || 0} transitions</td>
                    <td className="px-4 py-3 text-xs text-brand-200/60">{agent.graduation_reports?.length || 0} reports</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Detail panel for selected agent */}
          {selectedAgent && (
            <div className="bg-surface-panel border border-surface-border rounded-lg p-4">
              <div className="flex items-center justify-between mb-3">
                <h3 className="text-sm font-semibold text-white">{selectedAgent.agent_name}</h3>
                <button onClick={() => setSelectedAgent(null)} className="text-gray-400 hover:text-white text-sm">✕</button>
              </div>
              {/* Lifecycle timeline */}
              <div className="mb-4">
                <p className="text-xs text-gray-400 uppercase mb-2">Lifecycle Timeline</p>
                <div className="flex items-center gap-1 overflow-x-auto">
                  {(selectedAgent.state_history || [])
                    .sort((a, b) => a.timestamp.localeCompare(b.timestamp))
                    .map((h, i) => (
                      <div key={i} className="flex items-center">
                        <div className="flex-shrink-0 px-2 py-1 bg-gray-700 rounded text-xs text-gray-200">
                          <span className="capitalize">{h.to_state}</span>
                          <span className="block text-[10px] text-gray-500">{new Date(h.timestamp).toLocaleDateString()}</span>
                        </div>
                        {i < (selectedAgent.state_history || []).length - 1 && <span className="text-gray-600 mx-1 text-xs">→</span>}
                      </div>
                    ))}
                </div>
              </div>
              {/* Graduation reports */}
              {selectedAgent.graduation_reports?.length > 0 && (
                <div>
                  <p className="text-xs text-gray-400 uppercase mb-2">Graduation Reports</p>
                  <div className="space-y-1">
                    {selectedAgent.graduation_reports.map((r, i) => (
                      <div key={i} className="flex items-center justify-between bg-gray-800 rounded px-3 py-2 text-xs">
                        <span className="text-gray-300">v{r.version} ({r.environment})</span>
                        <span className={r.verdict === 'PASS' ? 'text-green-400' : 'text-red-400'}>{r.verdict}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {!isLoading && !error && activeTab === 'kanban' && agents && (
        <div className="flex-1 min-h-0">
          <KanbanBoard columns={buildKanbanColumns(agents)} />
        </div>
      )}
    </div>
  )
}
