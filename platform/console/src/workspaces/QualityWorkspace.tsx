import { useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, AgentLifecycleItem } from '../hooks/useAgents'

function ScoreBadge({ score }: { score: number | undefined }) {
  if (score === undefined) return <span className="text-brand-200/40 text-xs">—</span>
  const pct = (score * 100).toFixed(0)
  let color = 'text-red-400'
  if (score >= 0.8) color = 'text-green-400'
  else if (score >= 0.6) color = 'text-yellow-400'
  return <span className={`${color} font-medium text-xs`}>{pct}%</span>
}

function RedTeamBadge({ pass }: { pass: boolean | undefined }) {
  if (pass === undefined) return <span className="text-brand-200/40 text-xs">—</span>
  return pass ? (
    <span className="bg-green-500/20 text-green-400 text-xs px-2 py-0.5 rounded-full">PASS</span>
  ) : (
    <span className="bg-red-500/20 text-red-400 text-xs px-2 py-0.5 rounded-full">FAIL</span>
  )
}

function formatTime(iso: string | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function QualityWorkspace() {
  const { data: agents, isLoading, error } = useAgents()
  const [promoting, setPromoting] = useState<string | null>(null)
  const [changeControlId, setChangeControlId] = useState('')
  const [showProdDialog, setShowProdDialog] = useState<string | null>(null)

  // Show agents that have evaluation data or graduation reports
  const evalAgents = (agents || []).filter(
    (a: AgentLifecycleItem) =>
      a.eval_score !== undefined ||
      a.red_team_pass !== undefined ||
      (a.graduation_reports && a.graduation_reports.length > 0)
  )

  const handlePromoteToQA = async (agentName: string, _version: string) => {
    setPromoting(agentName)
    try {
      // In production: call pipeline service to trigger QA pipeline
      await new Promise(r => setTimeout(r, 1500))
    } finally {
      setPromoting(null)
    }
  }

  const handlePromoteToProd = async (agentName: string, _version: string) => {
    if (!changeControlId.trim()) return
    setPromoting(agentName)
    try {
      // In production: call pipeline service with change control ID
      await new Promise(r => setTimeout(r, 1500))
    } finally {
      setPromoting(null)
      setShowProdDialog(null)
      setChangeControlId('')
    }
  }

  const canPromoteToQA = (agent: AgentLifecycleItem) => agent.current_state === 'validated'
  const canPromoteToProd = (agent: AgentLifecycleItem) =>
    (agent.graduation_reports || []).some(r => r.verdict === 'PASS')

  return (
    <div>
      <WorkspaceHeader icon="✅" title="Quality" subtitle="Evaluation & Graduation" persona="QA Engineer" />

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading evaluation data…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4">
          <p className="text-red-400 text-sm">Failed to load quality data: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && evalAgents.length === 0 && (
        <div className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center">
          <p className="text-brand-200 text-lg mb-2">No evaluation results yet</p>
          <p className="text-brand-200/60 text-sm">Evaluation scores and red team results will appear here once agents are assessed.</p>
        </div>
      )}

      {!isLoading && !error && evalAgents.length > 0 && (
        <>
          <div className="bg-surface-panel border border-surface-border rounded-lg overflow-hidden mb-6">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-surface-border text-left text-brand-200/60 text-xs uppercase tracking-wider">
                  <th className="px-4 py-3">Agent</th>
                  <th className="px-4 py-3">Stage</th>
                  <th className="px-4 py-3">Eval Score</th>
                  <th className="px-4 py-3">Red Team</th>
                  <th className="px-4 py-3">Last Evaluated</th>
                  <th className="px-4 py-3">Reports</th>
                  <th className="px-4 py-3">Actions</th>
                </tr>
              </thead>
              <tbody>
                {evalAgents.map((agent: AgentLifecycleItem, i: number) => (
                  <tr
                    key={agent.agent_name}
                    className={`border-b border-surface-border/50 ${i % 2 === 0 ? 'bg-surface-panel' : 'bg-surface-panel/50'}`}
                  >
                    <td className="px-4 py-3 font-mono text-brand-200 text-xs">
                      {agent.agent_name}
                    </td>
                    <td className="px-4 py-3 text-brand-200/70 text-xs capitalize">
                      {agent.current_state}
                    </td>
                    <td className="px-4 py-3">
                      <ScoreBadge score={agent.eval_score} />
                    </td>
                    <td className="px-4 py-3">
                      <RedTeamBadge pass={agent.red_team_pass} />
                    </td>
                    <td className="px-4 py-3 text-brand-200/70 text-xs">
                      {formatTime(agent.last_evaluated)}
                    </td>
                    <td className="px-4 py-3 text-brand-200/60 text-xs">
                      {(agent.graduation_reports || []).length > 0
                        ? `${agent.graduation_reports.length} report${agent.graduation_reports.length > 1 ? 's' : ''}`
                        : '—'}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex gap-1">
                        {canPromoteToQA(agent) && (
                          <button
                            onClick={() => handlePromoteToQA(agent.agent_name, agent.version)}
                            disabled={promoting === agent.agent_name}
                            className="text-xs px-2 py-1 bg-blue-600 text-white rounded hover:bg-blue-500 disabled:opacity-50"
                          >
                            {promoting === agent.agent_name ? '…' : 'Promote to QA'}
                          </button>
                        )}
                        {canPromoteToProd(agent) && (
                          <button
                            onClick={() => setShowProdDialog(agent.agent_name)}
                            disabled={promoting === agent.agent_name}
                            className="text-xs px-2 py-1 bg-green-600 text-white rounded hover:bg-green-500 disabled:opacity-50"
                          >
                            Promote to Prod
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Graduation report details */}
          {evalAgents.some((a: AgentLifecycleItem) => a.graduation_reports && a.graduation_reports.length > 0) && (
            <div>
              <h2 className="text-sm font-medium text-brand-200 mb-3">Recent Graduation Reports</h2>
              <div className="space-y-3">
                {evalAgents
                  .flatMap((a: AgentLifecycleItem) =>
                    (a.graduation_reports || []).map((r) => ({ ...r, agent_name: a.agent_name }))
                  )
                  .sort((a, b) => b.timestamp.localeCompare(a.timestamp))
                  .slice(0, 5)
                  .map((report) => (
                    <div
                      key={report.report_id}
                      className="bg-surface-panel border border-surface-border rounded-lg p-4"
                    >
                      <div className="flex items-center justify-between mb-2">
                        <span className="font-mono text-xs text-brand-200">{report.agent_name}</span>
                        <span
                          className={`text-xs px-2 py-0.5 rounded-full ${
                            report.verdict === 'PASS'
                              ? 'bg-green-500/20 text-green-400'
                              : 'bg-red-500/20 text-red-400'
                          }`}
                        >
                          {report.verdict}
                        </span>
                      </div>
                      <div className="grid grid-cols-2 md:grid-cols-4 gap-2 text-xs text-brand-200/70">
                        <div>
                          <span className="block text-brand-200/40">Version</span>
                          <span className="font-mono">{report.version}</span>
                        </div>
                        <div>
                          <span className="block text-brand-200/40">Environment</span>
                          <span className="uppercase">{report.environment}</span>
                        </div>
                        <div>
                          <span className="block text-brand-200/40">Scores</span>
                          <span>
                            {Object.entries(report.scores)
                              .map(([k, v]) => `${k}: ${(v * 100).toFixed(0)}%`)
                              .join(', ')}
                          </span>
                        </div>
                        <div>
                          <span className="block text-brand-200/40">Date</span>
                          <span>{formatTime(report.timestamp)}</span>
                        </div>
                      </div>
                    </div>
                  ))}
              </div>
            </div>
          )}
        </>
      )}

      {/* Promote to Prod dialog */}
      {showProdDialog && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-gray-800 border border-gray-600 rounded-lg p-6 w-96">
            <h3 className="text-sm font-semibold text-white mb-3">Promote to Production</h3>
            <p className="text-xs text-gray-400 mb-3">Agent: <span className="font-mono">{showProdDialog}</span></p>
            <label className="block text-xs text-gray-300 mb-1">Change Control ID (required)</label>
            <input
              type="text"
              value={changeControlId}
              onChange={e => setChangeControlId(e.target.value)}
              placeholder="e.g. CHG-12345"
              className="w-full bg-gray-700 text-white rounded px-3 py-2 text-sm mb-3 focus:outline-none focus:ring-2 focus:ring-green-500"
            />
            <div className="flex gap-2 justify-end">
              <button onClick={() => { setShowProdDialog(null); setChangeControlId('') }} className="px-3 py-1.5 text-sm text-gray-300 hover:text-white">Cancel</button>
              <button
                onClick={() => handlePromoteToProd(showProdDialog, '')}
                disabled={!changeControlId.trim() || promoting !== null}
                className="px-3 py-1.5 bg-green-600 text-white text-sm rounded hover:bg-green-500 disabled:opacity-50"
              >
                {promoting ? 'Promoting…' : 'Confirm Promotion'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
