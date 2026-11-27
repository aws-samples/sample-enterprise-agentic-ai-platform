export interface StepState {
  name: string
  status: 'pending' | 'running' | 'done' | 'error'
  elapsed?: string
}

interface SupervisorVizProps {
  steps?: StepState[]
  executionArn?: string
}

const statusColors: Record<StepState['status'], string> = {
  pending: 'bg-gray-600 text-gray-300',
  running: 'bg-yellow-600 text-white animate-pulse',
  done: 'bg-green-600 text-white',
  error: 'bg-red-600 text-white',
}

const statusIcons: Record<StepState['status'], string> = {
  pending: '○',
  running: '◉',
  done: '✓',
  error: '✗',
}

/**
 * Step Functions state machine execution view.
 * Shows parallel fan-out and aggregation steps.
 */
export function SupervisorViz({ steps = [] }: SupervisorVizProps) {
  if (steps.length === 0) {
    return (
      <div className="flex items-center justify-center h-full text-gray-500">
        <p className="text-sm">No execution data yet. Send a message to start the supervisor flow.</p>
      </div>
    )
  }

  return (
    <div className="p-4 space-y-3">
      <h3 className="text-sm font-medium text-gray-300 mb-4">Step Functions Execution</h3>
      <div className="space-y-2">
        {steps.map((step, i) => (
          <div key={i} className="flex items-center gap-3">
            <div className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold ${statusColors[step.status]}`}>
              {statusIcons[step.status]}
            </div>
            <div className="flex-1">
              <p className="text-sm text-white">{step.name}</p>
              {step.elapsed && <p className="text-xs text-gray-400">{step.elapsed}</p>}
            </div>
            <span className={`text-xs px-2 py-0.5 rounded ${statusColors[step.status]}`}>
              {step.status}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
