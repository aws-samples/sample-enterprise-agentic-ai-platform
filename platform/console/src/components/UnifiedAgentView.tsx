import { useState } from 'react'
import { Tabs, type TabDef } from './Tabs'
import { AgentLogs } from './AgentLogs'
import { ChatRenderer, MarkdownView } from './ChatRenderer'
import { PatternPanel } from '../workspaces/build/PatternPanel'
import { PresetPrompts } from '../examples/renderers/PresetPrompts'
import { useSfnRun, deriveStepStatus } from '../examples/renderers/useSfnRun'
import type { AgentViewModel } from './agentViewModel'
import type { ExamplePresentation } from '../examples/registry'
import type { DiscoveredExample } from '../hooks/useExamples'

/**
 * UnifiedAgentView — the shared agent surface, built on the ADE detail-view
 * layout as the base template: a run/chat pane on the LEFT and an inspector
 * RIGHT rail that overlays Architecture (topology) + OTel Logs. Every surface
 * (ADE detail overlay, the Examples gallery) renders this same layout from a
 * normalized {@link AgentViewModel}; the header is owned by the parent.
 *
 * LEFT (run/chat):
 *   - runMode 'chat' → {@link ChatRenderer} (standalone / swarm / ADE deployed
 *     agents), streamed via the unified `streamAgent` client.
 *   - runMode 'sfn'  → a chat-shaped run box (supervisor / sequential): the send
 *     starts the Step Functions execution behind the scenes ({@link useSfnRun})
 *     and renders the fused/pipelined result. The user still just "chats"; the
 *     state machine is an implementation detail surfaced in the right rail.
 *     (Future: the entrypoint runtime itself will own this orchestration.)
 *
 * RIGHT rail (overlay, ADE parity): a small Architecture | Logs tab switch.
 *   - Architecture → {@link PatternPanel} (topology graph). For SFN patterns it
 *     also shows the live step tracker of the current run.
 *   - Logs → {@link AgentLogs} polling the runtime prefix while a turn/run runs.
 */

export interface UnifiedAgentViewProps {
  vm: AgentViewModel
  /** Optional preset-prompt overlay (Examples); chips render above the run pane. */
  presentation?: ExamplePresentation
  /** DiscoveredExample backing an SFN run (required when runMode === 'sfn'). */
  sfnExample?: DiscoveredExample
  /** Stable chat session id (chat runMode). */
  sessionId?: string
  /** Max chat message length (chat runMode). */
  maxLength?: number
}

const ARCH_KEY = 'architecture'
const LOGS_KEY = 'logs'

export function UnifiedAgentView({
  vm,
  presentation,
  sfnExample,
  sessionId,
  maxLength,
}: UnifiedAgentViewProps) {
  const isSfn = vm.runMode === 'sfn'
  const hasTopology = !!vm.architectureAgent?.topology
  const hasLogs = !!vm.runtimePrefix

  // Right-rail tab (Architecture | Logs). Default to Architecture when present.
  const [rail, setRail] = useState<string>(hasTopology ? ARCH_KEY : LOGS_KEY)
  // Prompt the parent wants auto-sent into the chat (from a preset chip).
  const [pendingInput, setPendingInput] = useState<string>('')
  // Whether a turn/run is in flight (drives the Logs live-poll).
  const [busy, setBusy] = useState(false)

  // SFN run driver (only meaningful for runMode 'sfn'; harmless otherwise).
  const sfn = useSfnRun(sfnExample ?? ({ stateMachineArn: '', runtimePrefix: vm.runtimePrefix } as DiscoveredExample))
  const running = isSfn ? sfn.loading : busy

  const railTabs: TabDef[] = [
    { key: ARCH_KEY, label: 'Architecture', hidden: !hasTopology },
    { key: LOGS_KEY, label: 'Logs', hidden: !hasLogs },
  ]
  const hasRail = hasTopology || hasLogs

  return (
    <div className="flex min-h-0 flex-1 gap-4">
      {/* LEFT — run/chat pane (the ADE chat column). */}
      <section className="flex min-w-0 flex-1 flex-col gap-3" aria-label="Agent run">
        {presentation && (
          <PresetPrompts
            presentation={presentation}
            onPick={(p) => (isSfn ? sfn.run(p) : setPendingInput(p))}
            disabled={running}
          />
        )}

        {isSfn ? (
          <SfnRunPane vm={vm} sfn={sfn} />
        ) : (
          <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg border border-surface-border">
            <ChatRenderer
              agentEndpoint={vm.runtimeArn || vm.name}
              agentName={vm.chatCacheName || vm.name}
              agentDescription={vm.description}
              agentArn={vm.runtimeArn}
              architecture={vm.pattern}
              sessionId={sessionId}
              invokeEndpoint={vm.invokeEndpoint}
              authMode={vm.authMode}
              maxLength={maxLength}
              pendingInput={pendingInput}
              onPendingInputConsumed={() => setPendingInput('')}
              onUserMessage={() => setBusy(true)}
              onAgentMessage={() => setBusy(false)}
            />
          </div>
        )}
      </section>

      {/* RIGHT — inspector rail: Architecture | Logs (ADE parity + overlay). */}
      {hasRail && (
        <aside
          className="flex w-96 shrink-0 flex-col overflow-hidden rounded-lg border border-surface-border bg-surface-panel"
          aria-label="Agent inspector"
        >
          <div className="border-b border-surface-border px-3 py-2">
            <Tabs tabs={railTabs} active={rail} onChange={setRail} />
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-3">
            {rail === ARCH_KEY && hasTopology && (
              <div className="space-y-3">
                {isSfn && <SfnStepTracker vm={vm} events={sfn.events} status={sfn.status} />}
                <PatternPanel agent={vm.architectureAgent} />
              </div>
            )}
            {rail === LOGS_KEY && hasLogs && (
              <AgentLogs runtimePrefix={vm.runtimePrefix!} active={running} heightClass="max-h-[70vh]" />
            )}
          </div>
        </aside>
      )}
    </div>
  )
}

/**
 * SfnRunPane — the LEFT pane for Step Functions patterns. A chat-shaped input
 * whose send starts the state-machine execution (behind the scenes) and renders
 * the fused/pipelined result. The live step tracker is shown in the right rail's
 * Architecture pane, so this pane stays focused on query → answer like a chat.
 */
function SfnRunPane({
  vm,
  sfn,
}: {
  vm: AgentViewModel
  sfn: ReturnType<typeof useSfnRun>
}) {
  const [query, setQuery] = useState('')
  const { loading, error, output, run } = sfn

  const submit = () => {
    const q = query.trim()
    if (!q || loading) return
    run(q)
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg border border-surface-border">
      {/* Result / transcript area */}
      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        {error && <div className="text-sm text-status-error">{error}</div>}
        {!error && output == null && !loading && (
          <div className="text-sm text-brand-400">
            Ask {vm.name} a question. It coordinates its agents and returns a single answer.
          </div>
        )}
        {loading && output == null && (
          <div className="text-sm text-brand-300">Running…</div>
        )}
        {output != null && (
          <MarkdownView
            className="prose prose-invert prose-sm max-w-none text-brand-100"
            text={formatOutput(output)}
          />
        )}
      </div>

      {/* Input row (chat-shaped) */}
      <div className="flex items-end gap-2 border-t border-surface-border p-3">
        <textarea
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              submit()
            }
          }}
          placeholder={`Message ${vm.name}…`}
          rows={2}
          className="flex-1 resize-none rounded-md border border-surface-border bg-surface-elevated px-3 py-2 text-sm text-brand-50 placeholder:text-brand-500 focus:border-accent focus:outline-none"
        />
        <button
          onClick={submit}
          disabled={loading || !query.trim()}
          className="rounded-md bg-accent px-4 py-2 text-sm font-medium text-white hover:bg-accent/90 disabled:opacity-50"
        >
          {loading ? 'Running…' : 'Send'}
        </button>
      </div>
    </div>
  )
}

/** Live per-step tracker for an SFN run, shown atop the Architecture pane. */
function SfnStepTracker({
  vm,
  events,
  status,
}: {
  vm: AgentViewModel
  events: ReturnType<typeof useSfnRun>['events']
  status: string | null
}) {
  const matchers: Record<string, string[]> =
    vm.pattern === 'supervisor'
      ? { Dispatch: ['dispatch', 'orchestrat', 'plan'], Retrieve: ['search', 'retriev', 'kb', 'web'], Fuse: ['fuse', 'rank', 'rrf', 'aggregate', 'combine'] }
      : { Extract: ['extract'], Enrich: ['enrich'], Summarize: ['summar'] }
  const stepStatus = deriveStepStatus(events, matchers)

  return (
    <div className="rounded-md border border-surface-border bg-surface-elevated p-3">
      <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-brand-400">
        Live run
      </div>
      <div className="flex flex-wrap items-center gap-2">
        {Object.entries(stepStatus).map(([step, st]) => (
          <span
            key={step}
            className={`rounded-full border px-3 py-1 text-xs ${
              st === 'done'
                ? 'border-status-success/50 bg-status-success/10 text-status-success'
                : st === 'running'
                  ? 'border-accent/50 bg-accent/10 text-accent animate-pulse'
                  : 'border-surface-border bg-surface-panel text-brand-400'
            }`}
          >
            {step} {st === 'done' ? '✓' : st === 'running' ? '…' : ''}
          </span>
        ))}
        {status && <span className="text-xs text-brand-400">state: {status}</span>}
      </div>
    </div>
  )
}

/** Best-effort render of an SFN output (string, or common {result}/{text} shapes). */
function formatOutput(output: unknown): string {
  if (typeof output === 'string') {
    try {
      return formatOutput(JSON.parse(output))
    } catch {
      return output
    }
  }
  if (output && typeof output === 'object') {
    const o = output as Record<string, unknown>
    for (const k of ['result', 'text', 'summary', 'output', 'answer']) {
      if (typeof o[k] === 'string') return o[k] as string
    }
    return '```json\n' + JSON.stringify(output, null, 2) + '\n```'
  }
  return String(output)
}
