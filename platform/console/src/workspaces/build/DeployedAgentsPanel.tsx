import type { DeployedAgent } from './types'

// DeployedAgentsPanel — the sidebar "My Deployed Agents" tiles.
//
// Renders exactly one tile per deployed application (Req 8.9), each showing the
// application name and its architecture pattern as a badge. Selecting a tile
// invokes {@link DeployedAgentsPanelProps.onSelect} with the full
// `DeployedAgent`; the parent (BuildWorkspace) wires this to open the
// Agent_Detail_View overlay (tasks 9.1 / 10.3). Each tile has a dismiss control
// that invokes {@link DeployedAgentsPanelProps.onDismiss} to hide it
// client-side without any runtime-mutating backend call (Req 8.10).
//
// Styling mirrors the sibling side panels (SamplePrompts.tsx, AgentCardPanel.tsx,
// GatewayToolsPanel.tsx): a small uppercase section heading over a list of
// dark, rounded, hover-highlighted rows.
//
// _Requirements: 8.9, 8.10_

export interface DeployedAgentsPanelProps {
  /** Applications to render — one tile each (already dismiss-filtered). */
  agents: DeployedAgent[]
  /**
   * Invoked with the selected application when a tile is clicked. The parent
   * opens the Agent_Detail_View overlay for the chosen agent.
   */
  onSelect: (agent: DeployedAgent) => void
  /**
   * Invoked with the application name when its dismiss control is used. The
   * parent hides the tile client-side (via `useDeployedAgents().dismiss`),
   * leaving the underlying runtime untouched (Req 8.10).
   */
  onDismiss: (appName: string) => void
  /** When true, shows a loading hint instead of the empty state. */
  loading?: boolean
  /** Optional app name to highlight as the active chat target. */
  activeAppName?: string
}

/**
 * Sidebar panel listing the current user's deployed agents as tiles.
 */
export function DeployedAgentsPanel({
  agents,
  onSelect,
  onDismiss,
  loading = false,
  activeAppName,
}: DeployedAgentsPanelProps) {
  return (
    <div className="space-y-2">
      <h3 className="text-xs font-medium text-brand-400 uppercase tracking-wider px-1">
        My Deployed Agents
      </h3>

      {agents.length > 0 ? (
        <ul className="space-y-1" aria-label="Deployed agents">
          {/* One tile per application (Req 8.9). */}
          {agents.map((agent) => {
            const isActive = activeAppName === agent.app_name
            return (
              <li key={agent.app_name}>
                <div
                  role="button"
                  tabIndex={0}
                  aria-label={`Open ${agent.app_name}`}
                  onClick={() => onSelect(agent)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault()
                      onSelect(agent)
                    }
                  }}
                  className={`group flex items-start justify-between gap-2 rounded px-2 py-1.5 cursor-pointer transition-colors ${
                    isActive
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                  }`}
                >
                  <div className="min-w-0 space-y-0.5">
                    <p className="text-xs font-medium break-words">{agent.app_name}</p>
                    {agent.pattern && (
                      // Each tile displays its application's pattern (Req 8.9).
                      <span className="inline-block rounded bg-gray-900/50 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-gray-300">
                        {agent.pattern}
                      </span>
                    )}
                  </div>

                  {/* Client-side dismiss — no backend mutation (Req 8.10). */}
                  <button
                    type="button"
                    aria-label={`Dismiss ${agent.app_name}`}
                    title="Hide until next refresh"
                    onClick={(e) => {
                      e.stopPropagation()
                      onDismiss(agent.app_name)
                    }}
                    className="shrink-0 text-gray-400 hover:text-white text-sm leading-none px-1"
                  >
                    ×
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
      ) : (
        <p className="text-xs text-gray-500 px-1">
          {loading ? 'Loading deployed agents…' : 'No deployed agents yet'}
        </p>
      )}
    </div>
  )
}
