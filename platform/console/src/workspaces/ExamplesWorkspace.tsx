import { useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useExamples, type DiscoveredExample, type ExampleStatus } from '../hooks/useExamples'
import { resolvePresentation } from '../examples/registry'
import { UnifiedAgentView } from '../components/UnifiedAgentView'
import { fromExample } from '../components/agentViewModel'

// The curated set of example apps we present as marketing cards even before
// they're deployed (Behavior A). Discovered apps beyond these still render.
const FEATURED = [
  { appName: 'research-swarm', pattern: 'swarm' as const },
  { appName: 'aws-architect-agent', pattern: 'standalone' as const },
  { appName: 'rrf-search-app', pattern: 'supervisor' as const },
  { appName: 'data-pipeline-app', pattern: 'sequential-workflow' as const },
]

function statusBadge(status: ExampleStatus) {
  const map: Record<ExampleStatus, { label: string; cls: string }> = {
    ready: { label: 'Ready', cls: 'bg-green-500' },
    deploying: { label: 'Deploying…', cls: 'bg-yellow-500' },
    not_deployed: { label: 'Not deployed', cls: 'bg-gray-500' },
  }
  const { label, cls } = map[status]
  return <span className={`${cls} text-white text-xs px-2 py-0.5 rounded-full`}>{label}</span>
}

/**
 * Render a launched example via the shared UnifiedAgentView — the SAME tabbed
 * Chat/Run | Architecture | Logs template used by the ADE detail overlay (one
 * UI template across the platform). Chat patterns (standalone/swarm) get a
 * ChatRenderer; SFN patterns (supervisor/sequential) get the Step Functions run
 * panel. Swarm's mesh + the SFN step viz both live in the Architecture tab.
 */
function renderExample(example: DiscoveredExample) {
  const presentation = resolvePresentation(example.appName, example.pattern)
  const vm = fromExample(example, presentation)
  return (
    <UnifiedAgentView
      vm={vm}
      presentation={presentation}
      sfnExample={vm.runMode === 'sfn' ? example : undefined}
    />
  )
}

export function ExamplesWorkspace() {
  const { data, isLoading, error } = useExamples()
  const [selected, setSelected] = useState<DiscoveredExample | null>(null)

  const discovered = data?.examples ?? []
  const pipelineRunning = data?.pipelineRunning ?? false
  const byName = new Map(discovered.map((e) => [e.appName, e]))

  // Merge featured (always shown) with discovered (may include extras).
  const featuredNames = new Set(FEATURED.map((f) => f.appName))
  const cards: Array<{ appName: string; pattern: DiscoveredExample['pattern']; example?: DiscoveredExample }> = [
    ...FEATURED.map((f) => ({ ...f, example: byName.get(f.appName) })),
    ...discovered
      .filter((e) => !featuredNames.has(e.appName))
      .map((e) => ({ appName: e.appName, pattern: e.pattern, example: e })),
  ]

  // Drill-in view. Uses a bounded-height column so the shared ADE layout
  // (chat-left + inspector rail, both min-h-0 flex-1) gets a real scroll height.
  if (selected) {
    const presentation = resolvePresentation(selected.appName, selected.pattern)
    return (
      <div className="flex h-[calc(100vh-72px-3rem)] flex-col">
        <button
          onClick={() => setSelected(null)}
          className="text-sm text-brand-300 hover:text-brand-50 mb-4 self-start"
        >
          ← Back to Examples
        </button>
        <div className="mb-4">
          <h1 className="text-lg font-semibold text-brand-50">
            {presentation.icon} {presentation.title}
          </h1>
          <p className="text-sm text-brand-300 mt-0.5">{presentation.tagline}</p>
        </div>
        {renderExample(selected)}
      </div>
    )
  }

  return (
    <div>
      <WorkspaceHeader title="Examples" subtitle="Try the platform's agent patterns" persona="Showcase" />

      {pipelineRunning && (
        <div className="mb-4 bg-yellow-500/10 border border-yellow-500/30 rounded-lg p-3 text-sm text-yellow-300">
          Agents are deploying — cards will activate automatically as the pipeline completes.
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4 mb-4">
          <p className="text-red-400 text-sm">Failed to load examples: {error.message}</p>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {cards.map(({ appName, pattern, example }) => {
          const presentation = resolvePresentation(appName, pattern)
          const status: ExampleStatus = example
            ? 'ready'
            : pipelineRunning
              ? 'deploying'
              : 'not_deployed'
          const launchable = status === 'ready' && !!example
          return (
            <div
              key={appName}
              className="bg-surface-panel border border-surface-border rounded-lg p-4 flex flex-col"
            >
              <div className="flex items-start justify-between mb-2">
                <span className="text-2xl">{presentation.icon}</span>
                {statusBadge(status)}
              </div>
              <h3 className="text-sm font-semibold text-brand-100">{presentation.title}</h3>
              <p className="text-xs text-brand-300 mt-1 flex-1">{presentation.tagline}</p>
              <div className="mt-3 flex items-center justify-between">
                <span className="text-xs text-brand-400 capitalize">{pattern.replace('-', ' ')}</span>
                <button
                  onClick={() => example && setSelected(example)}
                  disabled={!launchable}
                  title={launchable ? 'Launch example' : 'Seed team-bu-1 to activate this example'}
                  className="text-xs px-3 py-1.5 rounded bg-accent text-white font-medium disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  {launchable ? 'Launch' : status === 'deploying' ? 'Deploying…' : 'Not deployed'}
                </button>
              </div>
            </div>
          )
        })}
      </div>

      {isLoading && <p className="text-sm text-brand-300 mt-4">Loading examples…</p>}
    </div>
  )
}
