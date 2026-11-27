export interface PipelineStage {
  name: string
  status: 'pending' | 'running' | 'done' | 'error'
  elapsed?: string
}

interface SequentialVizProps {
  stages?: PipelineStage[]
}

const statusColors: Record<PipelineStage['status'], string> = {
  pending: 'border-gray-600 bg-gray-800 text-gray-400',
  running: 'border-yellow-500 bg-yellow-900/30 text-yellow-300',
  done: 'border-green-500 bg-green-900/30 text-green-300',
  error: 'border-red-500 bg-red-900/30 text-red-300',
}

/**
 * Linear pipeline stage view showing sequential agent execution.
 * Each stage shows name, status, and elapsed time.
 */
export function SequentialViz({ stages = [] }: SequentialVizProps) {
  if (stages.length === 0) {
    return (
      <div className="flex items-center justify-center h-full text-gray-500">
        <p className="text-sm">No pipeline data yet. Send a message to start the sequential flow.</p>
      </div>
    )
  }

  return (
    <div className="p-4">
      <h3 className="text-sm font-medium text-gray-300 mb-4">Pipeline Stages</h3>
      <div className="flex items-center gap-1 overflow-x-auto pb-2">
        {stages.map((stage, i) => (
          <div key={i} className="flex items-center">
            <div className={`flex-shrink-0 px-4 py-3 rounded-lg border-2 ${statusColors[stage.status]}`}>
              <p className="text-sm font-medium">{stage.name}</p>
              <p className="text-xs opacity-75">{stage.status}</p>
              {stage.elapsed && <p className="text-xs opacity-60">{stage.elapsed}</p>}
            </div>
            {i < stages.length - 1 && (
              <div className="flex-shrink-0 text-gray-500 text-lg ml-1">→</div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
