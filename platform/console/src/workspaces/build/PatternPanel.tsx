import type { DeployedAgent, DeployedRuntime, TopologyAgent } from './types'

// PatternPanel — deployed-architecture diagram for the Agent_Detail_View pane.
//
// Renders a faithful, STATIC topology diagram per pattern (standalone /
// sequential / supervisor / swarm), styled after the reference demo UIs
// (aws-architect-ui-v2, data-pipeline-ui, rrf-search-ui, research-swarm-ui).
// This is the deployed architecture graph — NOT a live Step Functions
// execution view.
//
// Source of truth is `agent.topology` (from each app's application.yaml,
// recorded in the lifecycle DynamoDB store and returned by studio-read). When
// topology is absent (older deployments), it falls back to deriving the graph
// from the discovered peer runtimes using the orchestrator-name heuristic.
//
// _Requirements: 9.5, 9.6, 9.7, 9.8, 9.9, 16.2_

export interface PatternPanelProps {
  agent: DeployedAgent
}

/** Regex identifying an orchestrator/supervisor/coordinator node by name/role. */
const ORCHESTRATOR_RE = /orchestrator|supervisor|coordinator/i

/** A normalized topology node the diagrams render. */
interface Node {
  key: string
  label: string
  role: string
  calls: string[]
  can_call: string[]
  depends_on: string[]
  /** matched peer runtime (for ARN/status/endpoint detail), if any */
  runtime?: DeployedRuntime
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function normalizePattern(pattern: string): string {
  return (pattern || '').trim().toLowerCase().replace(/\s+/g, '-')
}

function norm(s: string): string {
  return (s || '').toLowerCase().replace(/[-\s]+/g, '_')
}

function lastArnSegment(arn: string): string {
  if (!arn) return ''
  const parts = arn.split('/')
  return parts[parts.length - 1] || arn
}

function isOrchestratorRole(role: string, name: string): boolean {
  const r = (role || '').toLowerCase()
  if (r === 'orchestrator' || r === 'supervisor' || r === 'coordinator') return true
  return ORCHESTRATOR_RE.test(name)
}

/** Best-effort match of a topology node to a discovered peer runtime. */
function matchRuntime(
  nodeName: string,
  runtimes: DeployedRuntime[],
): DeployedRuntime | undefined {
  const n = norm(nodeName)
  // 1) exact agent_key match (authoritative)
  const byKey = runtimes.find((r) => r.agent_key && norm(r.agent_key) === n)
  if (byKey) return byKey
  // 2) runtime name contains the (normalized) node name
  return runtimes.find((r) => norm(r.runtime_name).includes(n))
}

/**
 * Build the normalized node list. Prefer `agent.topology.agents`; fall back to
 * deriving nodes from the discovered peer runtimes when topology is absent.
 */
function buildNodes(agent: DeployedAgent): Node[] {
  const topoAgents: TopologyAgent[] = agent.topology?.agents ?? []
  if (topoAgents.length > 0) {
    return topoAgents.map((a) => ({
      key: a.name,
      label: a.name,
      role: a.role || (isOrchestratorRole(a.role, a.name) ? 'orchestrator' : 'worker'),
      calls: a.calls ?? [],
      can_call: a.can_call ?? [],
      depends_on: a.depends_on ?? [],
      runtime: matchRuntime(a.name, agent.runtimes),
    }))
  }

  // Fallback: derive from discovered runtimes (no manifest topology recorded).
  return agent.runtimes.map((r) => {
    const label = r.agent_key || r.runtime_name
    const role =
      (r.agent_role && r.agent_role.toLowerCase()) ||
      (isOrchestratorRole('', r.runtime_name) ? 'orchestrator' : 'worker')
    return { key: label, label, role, calls: [], can_call: [], depends_on: [], runtime: r }
  })
}

/** Topological order by depends_on; stable fallback to input order. */
function orderByDependency(nodes: Node[]): Node[] {
  const byKey = new Map(nodes.map((n) => [norm(n.key), n]))
  const visited = new Set<string>()
  const out: Node[] = []
  const visit = (n: Node) => {
    const k = norm(n.key)
    if (visited.has(k)) return
    visited.add(k)
    for (const dep of n.depends_on) {
      const d = byKey.get(norm(dep))
      if (d) visit(d)
    }
    out.push(n)
  }
  for (const n of nodes) visit(n)
  return out
}

// ---------------------------------------------------------------------------
// Presentational primitives
// ---------------------------------------------------------------------------

type Tone = 'orchestrator' | 'worker' | 'standalone'

const toneClasses: Record<Tone, string> = {
  orchestrator: 'border-indigo-400/70 bg-indigo-600/20 text-indigo-100',
  worker: 'border-sky-500/60 bg-sky-700/20 text-sky-100',
  standalone: 'border-emerald-500/60 bg-emerald-700/20 text-emerald-100',
}

const toneDot: Record<Tone, string> = {
  orchestrator: 'bg-indigo-400',
  worker: 'bg-sky-400',
  standalone: 'bg-emerald-400',
}

function toneFor(role: string): Tone {
  const r = (role || '').toLowerCase()
  if (r === 'orchestrator' || r === 'supervisor' || r === 'coordinator') return 'orchestrator'
  if (r === 'standalone') return 'standalone'
  return 'worker'
}

function NodeCard({
  label,
  role,
  sub,
}: {
  label: string
  role: string
  sub?: string
}) {
  const tone = toneFor(role)
  return (
    <div
      className={`rounded-lg border px-3 py-2 shadow-sm ${toneClasses[tone]}`}
      title={sub || label}
    >
      <div className="flex items-center gap-1.5">
        <span className={`h-2 w-2 shrink-0 rounded-full ${toneDot[tone]}`} />
        <span className="text-[10px] uppercase tracking-wider opacity-70">
          {role || 'agent'}
        </span>
      </div>
      <div className="mt-0.5 break-words text-sm font-medium text-white">
        {label}
      </div>
      {sub && (
        <div className="mt-0.5 break-all font-mono text-[10px] opacity-60">
          {sub}
        </div>
      )}
    </div>
  )
}

/** A vertical connector with a downward arrowhead. */
function DownConnector() {
  return (
    <div className="flex flex-col items-center py-1" aria-hidden>
      <div className="h-4 w-px bg-gray-500" />
      <div className="-mt-1 text-gray-500">▾</div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Per-pattern diagrams
// ---------------------------------------------------------------------------

/** Standalone: single agent node + config detail card (aws-architect style). */
function StandaloneDiagram({ agent, nodes }: { agent: DeployedAgent; nodes: Node[] }) {
  const node = nodes[0]
  const primary =
    node?.runtime ||
    agent.runtimes.find((r) => r.runtime_arn === agent.primary_runtime_arn) ||
    agent.runtimes[0]
  const label =
    node?.label || primary?.runtime_name || lastArnSegment(agent.primary_runtime_arn)

  return (
    <div className="space-y-3">
      <div className="mx-auto max-w-[16rem]">
        <NodeCard label={label || agent.app_name} role="standalone" />
      </div>
      <ConfigCard primary={primary} />
    </div>
  )
}

/** Sequential: vertical arrowed chain in depends_on order (data-pipeline style). */
function SequentialDiagram({ nodes }: { nodes: Node[] }) {
  const ordered = orderByDependency(nodes)
  return (
    <div className="flex flex-col items-stretch">
      {ordered.map((n, i) => (
        <div key={n.key}>
          <NodeCard
            label={n.label}
            role={n.role || 'stage'}
            sub={n.runtime?.status}
          />
          {i < ordered.length - 1 && <DownConnector />}
        </div>
      ))}
    </div>
  )
}

/** Supervisor: orchestrator on top, workers fanned out as a connected tree. */
function SupervisorDiagram({ nodes }: { nodes: Node[] }) {
  const orchestrators = nodes.filter((n) => isOrchestratorRole(n.role, n.label))
  const workers = nodes.filter((n) => !isOrchestratorRole(n.role, n.label))
  const head = orchestrators[0]

  return (
    <div className="space-y-2">
      {head && (
        <div className="mx-auto max-w-[16rem]">
          <NodeCard label={head.label} role={head.role || 'orchestrator'} sub={head.runtime?.status} />
        </div>
      )}

      {workers.length > 0 && (
        <>
          <DownConnector />
          {/* Fan-out tree: left rail with connectors into each worker. */}
          <div className="ml-2 border-l border-gray-600 pl-3">
            <div className="space-y-2">
              {workers.map((w) => (
                <div key={w.key} className="relative">
                  <span
                    className="absolute -left-3 top-4 h-px w-3 bg-gray-600"
                    aria-hidden
                  />
                  <NodeCard label={w.label} role={w.role || 'worker'} sub={w.runtime?.status} />
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  )
}

/** Swarm: SVG peer mesh with bidirectional A2A edges (research-swarm style). */
function SwarmDiagram({ nodes }: { nodes: Node[] }) {
  if (nodes.length === 0) return null

  const cx = 200
  const cy = 150
  const radius = nodes.length === 1 ? 0 : 105
  const angleStep = (2 * Math.PI) / nodes.length
  const pos = nodes.map((_, i) => ({
    x: cx + radius * Math.cos(angleStep * i - Math.PI / 2),
    y: cy + radius * Math.sin(angleStep * i - Math.PI / 2),
  }))

  const idxOf = (name: string) => nodes.findIndex((n) => norm(n.key) === norm(name))

  // Build undirected edge set from can_call (dedup A↔B). If no can_call edges
  // are present, fall back to a full peer mesh.
  const seen = new Set<string>()
  const edges: Array<[number, number]> = []
  let hasEdges = false
  nodes.forEach((n, i) => {
    for (const target of n.can_call) {
      const j = idxOf(target)
      if (j < 0 || j === i) continue
      hasEdges = true
      const key = i < j ? `${i}-${j}` : `${j}-${i}`
      if (seen.has(key)) continue
      seen.add(key)
      edges.push([i, j])
    }
  })
  if (!hasEdges) {
    for (let i = 0; i < nodes.length; i++)
      for (let j = i + 1; j < nodes.length; j++) edges.push([i, j])
  }

  const short = (s: string) => (s.length > 10 ? s.slice(0, 10) + '…' : s)

  return (
    <div>
      <svg viewBox="0 0 400 300" className="mx-auto w-full max-w-md">
        {edges.map(([i, j], k) => (
          <line
            key={k}
            x1={pos[i].x}
            y1={pos[i].y}
            x2={pos[j].x}
            y2={pos[j].y}
            stroke="#6366f1"
            strokeWidth={1.25}
            strokeOpacity={0.6}
          />
        ))}
        {nodes.map((n, i) => (
          <g key={n.key}>
            <circle
              cx={pos[i].x}
              cy={pos[i].y}
              r={26}
              fill="#312e81"
              stroke="#818cf8"
              strokeWidth={2}
            />
            <text
              x={pos[i].x}
              y={pos[i].y + 4}
              textAnchor="middle"
              className="fill-white text-[10px]"
            >
              {short(n.label)}
            </text>
          </g>
        ))}
      </svg>
    </div>
  )
}

/** Config card listing the primary runtime's ARN / endpoint / status. */
function ConfigCard({ primary }: { primary?: DeployedRuntime }) {
  if (!primary) return null
  const rows: Array<{ label: string; value: string }> = []
  if (primary.runtime_name) rows.push({ label: 'Runtime', value: primary.runtime_name })
  if (primary.runtime_arn) rows.push({ label: 'ARN', value: primary.runtime_arn })
  if (primary.endpoint_qualifier)
    rows.push({ label: 'Endpoint', value: primary.endpoint_qualifier })
  if (primary.status) rows.push({ label: 'Status', value: primary.status })
  if (rows.length === 0) return null

  return (
    <div className="rounded-lg border border-gray-700 bg-gray-800/60 p-3">
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-gray-400">
        Configuration
      </h4>
      <dl className="space-y-2">
        {rows.map((row) => (
          <div key={row.label} className="space-y-0.5">
            <dt className="text-[10px] uppercase tracking-wider text-gray-500">
              {row.label}
            </dt>
            <dd className="break-all font-mono text-xs text-gray-200">{row.value}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

/** Peer list — every discovered runtime with its status (all patterns). */
function RuntimeList({ runtimes }: { runtimes: DeployedRuntime[] }) {
  if (runtimes.length === 0) return null
  return (
    <div className="rounded-lg border border-gray-700 bg-gray-800/60 p-3">
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-gray-400">
        Runtimes ({runtimes.length})
      </h4>
      <ul className="space-y-1.5">
        {runtimes.map((r) => (
          <li key={r.runtime_arn || r.runtime_name} className="flex items-center gap-2">
            <span className="truncate font-mono text-[11px] text-gray-300" title={r.runtime_name}>
              {r.runtime_name}
            </span>
            {r.status && (
              <span className="ml-auto shrink-0 rounded bg-gray-700 px-1.5 py-0.5 text-[10px] text-gray-300">
                {r.status}
              </span>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

export function PatternPanel({ agent }: PatternPanelProps) {
  const pattern = normalizePattern(agent.topology?.pattern || agent.pattern)
  const nodes = buildNodes(agent)

  let diagram: JSX.Element
  switch (pattern) {
    case 'supervisor':
    case 'multi-agent':
    case 'router':
      diagram = <SupervisorDiagram nodes={nodes} />
      break
    case 'sequential':
    case 'sequential-workflow':
    case 'workflow':
      diagram = <SequentialDiagram nodes={nodes} />
      break
    case 'swarm':
    case 'choreography':
      diagram = <SwarmDiagram nodes={nodes} />
      break
    case 'standalone':
    default:
      diagram = <StandaloneDiagram agent={agent} nodes={nodes} />
      break
  }

  return (
    <div className="space-y-4 p-4">
      <div>
        <div className="mb-3 flex items-center gap-2">
          <span className="rounded bg-gray-700 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wider text-gray-300">
            {pattern || 'standalone'}
          </span>
          <span className="text-xs text-gray-500">deployed topology</span>
        </div>
        {diagram}
      </div>

      {/* Standalone already shows its config card inline; others get the peer list. */}
      {pattern !== 'standalone' && <RuntimeList runtimes={agent.runtimes} />}
    </div>
  )
}
