export interface SwarmAgent {
  name: string
  isActive?: boolean
}

export interface SwarmConnection {
  from: string
  to: string
  isActive?: boolean
}

interface SwarmVizProps {
  agents?: SwarmAgent[]
  connections?: SwarmConnection[]
}

/**
 * Agent topology mesh — SVG view showing peer agents as nodes
 * with bidirectional A2A connections. Highlights active agent during execution.
 */
export function SwarmViz({ agents = [], connections = [] }: SwarmVizProps) {
  if (agents.length === 0) {
    return (
      <div className="flex items-center justify-center h-full text-gray-500">
        <p className="text-sm">No swarm topology data yet. Send a message to see agent handoffs.</p>
      </div>
    )
  }

  // Arrange agents in a circle
  const cx = 200
  const cy = 150
  const radius = 100
  const angleStep = (2 * Math.PI) / agents.length

  const positions = agents.map((_, i) => ({
    x: cx + radius * Math.cos(angleStep * i - Math.PI / 2),
    y: cy + radius * Math.sin(angleStep * i - Math.PI / 2),
  }))

  return (
    <div className="p-4">
      <h3 className="text-sm font-medium text-gray-300 mb-4">Agent Topology</h3>
      <svg viewBox="0 0 400 300" className="w-full max-w-md mx-auto">
        {/* Connections */}
        {connections.map((conn, i) => {
          const fromIdx = agents.findIndex(a => a.name === conn.from)
          const toIdx = agents.findIndex(a => a.name === conn.to)
          if (fromIdx < 0 || toIdx < 0) return null
          return (
            <line
              key={i}
              x1={positions[fromIdx].x}
              y1={positions[fromIdx].y}
              x2={positions[toIdx].x}
              y2={positions[toIdx].y}
              stroke={conn.isActive ? '#3b82f6' : '#4b5563'}
              strokeWidth={conn.isActive ? 2 : 1}
              strokeDasharray={conn.isActive ? undefined : '4 2'}
            />
          )
        })}
        {/* Agent nodes */}
        {agents.map((agent, i) => (
          <g key={i}>
            <circle
              cx={positions[i].x}
              cy={positions[i].y}
              r={24}
              fill={agent.isActive ? '#2563eb' : '#374151'}
              stroke={agent.isActive ? '#60a5fa' : '#6b7280'}
              strokeWidth={2}
            />
            <text
              x={positions[i].x}
              y={positions[i].y + 4}
              textAnchor="middle"
              className="text-[10px] fill-white"
            >
              {agent.name.length > 8 ? agent.name.slice(0, 8) + '…' : agent.name}
            </text>
          </g>
        ))}
      </svg>
    </div>
  )
}
