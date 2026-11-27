import { useState } from 'react'

export interface KanbanCard {
  agentName: string
  appName: string
  version: string
  timeInStage: string
  isStuck: boolean
  lastTransition?: string
  stateHistory?: Array<{ state: string; timestamp: string }>
  evaluationScores?: Record<string, number>
  graduationReports?: Array<{ version: string; verdict: string; timestamp: string }>
}

export interface KanbanColumn {
  stage: 'enrolled' | 'training' | 'validated' | 'graduated' | 'production'
  agents: KanbanCard[]
  count: number
}

interface KanbanBoardProps {
  columns: KanbanColumn[]
  stuckThresholdHours?: number
}

const stageLabels: Record<string, string> = {
  enrolled: 'Enrolled',
  training: 'Training',
  validated: 'Validated',
  graduated: 'Graduated',
  production: 'Production',
}

const stageColors: Record<string, string> = {
  enrolled: 'border-t-gray-500',
  training: 'border-t-yellow-500',
  validated: 'border-t-blue-500',
  graduated: 'border-t-purple-500',
  production: 'border-t-green-500',
}

/**
 * Kanban board showing agent lifecycle stages.
 * Displays agents grouped by current lifecycle state with
 * stuck indicators and click-to-detail functionality.
 */
export function KanbanBoard({ columns }: KanbanBoardProps) {
  const [selectedCard, setSelectedCard] = useState<KanbanCard | null>(null)

  return (
    <div className="flex flex-col h-full">
      {/* Board */}
      <div className="flex gap-3 overflow-x-auto flex-1 p-4">
        {columns.map(col => (
          <div key={col.stage} className={`flex-shrink-0 w-56 flex flex-col rounded-lg bg-gray-800 border-t-4 ${stageColors[col.stage]}`}>
            {/* Column header */}
            <div className="flex items-center justify-between px-3 py-2 border-b border-gray-700">
              <span className="text-sm font-medium text-white">{stageLabels[col.stage]}</span>
              <span className="text-xs bg-gray-600 text-gray-200 px-2 py-0.5 rounded-full">{col.count}</span>
            </div>
            {/* Cards */}
            <div className="flex-1 overflow-y-auto p-2 space-y-2">
              {col.agents.map((card, i) => (
                <button
                  key={`${card.appName}-${card.agentName}-${i}`}
                  onClick={() => setSelectedCard(card)}
                  className={`w-full text-left p-3 rounded-md border transition-colors ${
                    card.isStuck
                      ? 'border-amber-500 bg-amber-900/20 hover:bg-amber-900/30'
                      : 'border-gray-600 bg-gray-750 hover:bg-gray-700'
                  }`}
                >
                  <p className="text-sm font-medium text-white truncate">{card.agentName}</p>
                  <p className="text-xs text-gray-400 truncate">{card.appName}</p>
                  <div className="flex items-center justify-between mt-1">
                    <span className="text-xs text-gray-500">v{card.version}</span>
                    <span className={`text-xs ${card.isStuck ? 'text-amber-400' : 'text-gray-500'}`}>
                      {card.isStuck && '⚠ '}{card.timeInStage}
                    </span>
                  </div>
                </button>
              ))}
              {col.agents.length === 0 && (
                <p className="text-xs text-gray-600 text-center py-4">No agents</p>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* Detail panel */}
      {selectedCard && (
        <div className="border-t border-gray-700 bg-gray-800 p-4">
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-sm font-semibold text-white">{selectedCard.agentName} — {selectedCard.appName}</h3>
            <button onClick={() => setSelectedCard(null)} className="text-gray-400 hover:text-white text-sm">✕</button>
          </div>
          <div className="grid grid-cols-3 gap-4 text-xs">
            {/* State history */}
            <div>
              <p className="text-gray-400 font-medium mb-1">State History</p>
              {selectedCard.stateHistory?.length ? (
                <ul className="space-y-1">
                  {selectedCard.stateHistory.map((h, i) => (
                    <li key={i} className="text-gray-300">
                      <span className="capitalize">{h.state}</span>
                      <span className="text-gray-500 ml-1">{new Date(h.timestamp).toLocaleDateString()}</span>
                    </li>
                  ))}
                </ul>
              ) : <p className="text-gray-600">No history</p>}
            </div>
            {/* Evaluation scores */}
            <div>
              <p className="text-gray-400 font-medium mb-1">Evaluation Scores</p>
              {selectedCard.evaluationScores ? (
                <ul className="space-y-1">
                  {Object.entries(selectedCard.evaluationScores).map(([k, v]) => (
                    <li key={k} className="text-gray-300 flex justify-between">
                      <span className="capitalize">{k}</span>
                      <span className={v >= 0.8 ? 'text-green-400' : 'text-red-400'}>{(v * 100).toFixed(0)}%</span>
                    </li>
                  ))}
                </ul>
              ) : <p className="text-gray-600">No scores</p>}
            </div>
            {/* Graduation reports */}
            <div>
              <p className="text-gray-400 font-medium mb-1">Graduation Reports</p>
              {selectedCard.graduationReports?.length ? (
                <ul className="space-y-1">
                  {selectedCard.graduationReports.map((r, i) => (
                    <li key={i} className="text-gray-300">
                      v{r.version} — <span className={r.verdict === 'PASS' ? 'text-green-400' : 'text-red-400'}>{r.verdict}</span>
                    </li>
                  ))}
                </ul>
              ) : <p className="text-gray-600">No reports</p>}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
