import { useCallback, useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { ChatRenderer } from '../components/ChatRenderer'
import { useDesignSessions } from './build/useDesignSessions'
import { usePhaseIndicator } from './build/usePhaseIndicator'
import { useDeploymentTracker } from './build/useDeploymentTracker'
import { useDeployedAgents } from './build/useDeployedAgents'
import { SamplePrompts } from './build/SamplePrompts'
import { AgentCardPanel } from './build/AgentCardPanel'
import { AgentToolsPanel } from './build/AgentToolsPanel'
import { GatewayToolsPanel } from './build/GatewayToolsPanel'
import { DeployedAgentsPanel } from './build/DeployedAgentsPanel'
import { AgentDetailView } from './build/AgentDetailView'
import { extractManifestBlocks } from './build/manifest'
import type { DeployedAgent, ManifestBlock } from './build/types'

// BuildWorkspace — three-region, Studio-parity Build workspace (task 9.1).
//
// Assembles the already-implemented Build pieces under ./build/ into the layout
// described in design.md ("BuildWorkspace composition"):
//   - LEFT  : New Design Session, SamplePrompts, DeployedAgentsPanel, session list
//   - CENTER: PhaseIndicator, active-deployment tray, ADE ChatRenderer, manifests
//   - RIGHT : AgentCardPanel + GatewayToolsPanel
//   - OVERLAY: AgentDetailView when a deployed-agent tile is selected
//
// The hooks are the source of truth; this component only orchestrates them and
// renders. Completed ADE turns are fed (via ChatRenderer.onAgentMessage) into
// phase advancement, deployment-execution-ID tracking, and manifest extraction.
//
// _Requirements: 1.1, 2.1, 2.5, 3.1, 6.1, 7.1, 8.9, 10.3, 16.1, 16.3_

// The Studio (ADE) runtime endpoint. ADE chat uses the default target (no
// agentArn override), so the invoke proxy routes to the Studio runtime.
const STUDIO_AGENT_ENDPOINT =
  import.meta.env.VITE_STUDIO_AGENT_ENDPOINT ||
  'https://runtime.agentcore.amazonaws.com/agents/agent-deployment-engineer'

/** Status → tailwind text colour for the deployment tray. */
function statusColor(status: string, timedOut?: boolean): string {
  if (timedOut) return 'text-yellow-400'
  switch (status) {
    case 'succeeded':
      return 'text-green-400'
    case 'failed':
    case 'cancelled':
    case 'stopped':
    case 'superseded':
      return 'text-red-400'
    case 'in_progress':
      return 'text-blue-400'
    default:
      return 'text-gray-400'
  }
}

/** Collapsible, copyable manifest panel with copy confirmation (Req 10.3). */
function ManifestPreview({ block }: { block: ManifestBlock }) {
  const [copied, setCopied] = useState(false)

  const copy = useCallback(() => {
    void navigator.clipboard
      .writeText(block.content)
      .then(() => {
        setCopied(true)
        setTimeout(() => setCopied(false), 1500)
      })
      .catch(() => {
        // Clipboard unavailable — leave the panel intact.
      })
  }, [block.content])

  return (
    <details className="rounded border border-gray-700 bg-gray-800">
      <summary className="flex cursor-pointer items-center justify-between gap-2 px-3 py-2 text-xs">
        <span className="flex items-center gap-2 min-w-0">
          <span className="rounded bg-gray-900/60 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-gray-400">
            {block.language}
          </span>
          <span className="truncate font-medium text-gray-200">{block.label}</span>
        </span>
        <button
          type="button"
          onClick={(e) => {
            e.preventDefault()
            copy()
          }}
          className="shrink-0 rounded border border-gray-600 px-2 py-0.5 text-[11px] text-gray-300 hover:border-gray-400 hover:text-white"
          aria-label={`Copy ${block.label}`}
        >
          {copied ? 'Copied ✓' : 'Copy'}
        </button>
      </summary>
      <pre className="max-h-64 overflow-auto border-t border-gray-700 px-3 py-2 text-[11px] leading-relaxed text-gray-300">
        <code>{block.content}</code>
      </pre>
    </details>
  )
}

export function BuildWorkspace() {
  const sessions = useDesignSessions()
  const {
    sessions: sessionList,
    activeSessionId,
    activeSession,
    persistError,
    createSession,
    selectSession,
    deleteSession,
    setPhase,
    appendMessage,
  } = sessions

  const phaseIndicator = usePhaseIndicator({
    phase: activeSession?.phase ?? 0,
    onAdvance: setPhase,
  })

  const deployedAgents = useDeployedAgents()

  // On a successful deployment, force-refresh the deployed-agents list (Req 7.4).
  const tracker = useDeploymentTracker({
    onSucceeded: () => {
      void deployedAgents.refresh(true)
    },
  })

  // Overlay state: the selected deployed agent (Req 9.1).
  const [selectedAgent, setSelectedAgent] = useState<DeployedAgent | null>(null)

  // Manifests extracted from the most recent ADE turn (Req 10).
  const [manifests, setManifests] = useState<ManifestBlock[]>([])

  // A sample prompt to programmatically send into the ADE chat (Req 3.3).
  // Passed to ChatRenderer as `pendingInput`; cleared via onPendingInputConsumed.
  const [pendingInput, setPendingInput] = useState<string | undefined>(undefined)

  // Completed ADE turn: advance phase (Req 6.2), register deployment execution
  // IDs (Req 7.1), and extract manifest panels (Req 10.1).
  const handleAgentMessage = useCallback(
    (text: string) => {
      phaseIndicator.handleAgentMessage(text)
      tracker.register(text)
      setManifests(extractManifestBlocks(text))
    },
    [phaseIndicator, tracker],
  )

  // Sample-prompt selection (Req 3.3). Ensure a design session exists, then
  // hand the prompt to ChatRenderer via `pendingInput`, which populates the
  // input and auto-sends it once. The ADE chat mounts (keyed by activeSessionId)
  // as soon as createSession sets the active id, so the pending prompt is
  // delivered on the next render.
  const handleSelectPrompt = useCallback(
    (prompt: string) => {
      if (!activeSessionId) createSession()
      setPendingInput(prompt)
    },
    [activeSessionId, createSession],
  )

  return (
    <div className="flex h-[calc(100vh-72px-3rem)] flex-col">
      <WorkspaceHeader
        icon="🛠️"
        title="Build"
        subtitle="Agent Deployment Engineer"
        persona="Business User"
      />

      {persistError && (
        <div
          role="alert"
          className="mb-2 rounded border border-yellow-600/50 bg-yellow-900/30 px-3 py-1.5 text-xs text-yellow-300"
        >
          Could not save session changes to this browser. Your work is kept in
          memory for now.
        </div>
      )}

      <div className="flex min-h-0 flex-1 gap-4">
        {/* ---------- LEFT SIDEBAR ---------- */}
        <aside className="flex w-72 shrink-0 flex-col gap-4 overflow-y-auto pr-1">
          <button
            type="button"
            onClick={() => createSession()}
            className="w-full rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500"
          >
            + New Design Session
          </button>

          <SamplePrompts onSelect={handleSelectPrompt} />

          <DeployedAgentsPanel
            agents={deployedAgents.agents}
            loading={deployedAgents.loading}
            onSelect={setSelectedAgent}
            onDismiss={deployedAgents.dismiss}
            activeAppName={selectedAgent?.app_name}
          />

          {/* Design Sessions list (Req 1.4, 1.5) */}
          <div className="space-y-2">
            <h3 className="px-1 text-xs font-medium uppercase tracking-wider text-brand-400">
              Design Sessions
            </h3>
            {sessionList.length === 0 ? (
              <p className="px-1 text-xs text-gray-500">No sessions yet</p>
            ) : (
              <ul className="space-y-1" aria-label="Design sessions">
                {sessionList.map((session) => {
                  const isActive = session.id === activeSessionId
                  return (
                    <li key={session.id}>
                      <div
                        className={`group flex items-center justify-between gap-2 rounded px-2 py-1.5 transition-colors ${
                          isActive
                            ? 'bg-blue-600 text-white'
                            : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                        }`}
                      >
                        <button
                          type="button"
                          onClick={() => selectSession(session.id)}
                          className="min-w-0 flex-1 text-left"
                        >
                          <p className="truncate text-xs font-medium">{session.title}</p>
                          <p className="text-[10px] opacity-70">
                            {new Date(session.createdAt).toLocaleDateString()}
                          </p>
                        </button>
                        <button
                          type="button"
                          onClick={() => deleteSession(session.id)}
                          aria-label={`Delete ${session.title}`}
                          className="shrink-0 px-1 text-sm leading-none text-gray-400 hover:text-red-300"
                        >
                          ×
                        </button>
                      </div>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        </aside>

        {/* ---------- CENTER ---------- */}
        <section className="flex min-w-0 flex-1 flex-col gap-3">
          {/* Phase indicator (Req 6.1) */}
          <div className="flex flex-wrap items-center gap-1">
            {phaseIndicator.phases.map((label, i) => (
              <div key={label} className="flex items-center">
                <span
                  className={`rounded px-2 py-0.5 text-xs ${
                    i <= phaseIndicator.phase
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-700 text-gray-400'
                  }`}
                  aria-current={i === phaseIndicator.phase ? 'step' : undefined}
                >
                  {label}
                </span>
                {i < phaseIndicator.phases.length - 1 && (
                  <span className="mx-1 text-xs text-gray-600">→</span>
                )}
              </div>
            ))}
          </div>

          {/* Active-deployment tray (Req 7) */}
          {tracker.list.length > 0 && (
            <div className="space-y-1" aria-label="Active deployments">
              {tracker.list.map((d) => (
                <div
                  key={d.executionId}
                  className="flex items-center justify-between gap-2 rounded bg-gray-800 px-3 py-1.5 text-xs"
                >
                  <span className="truncate font-mono text-gray-300">
                    {d.appName || d.executionId.slice(0, 8)}
                    {d.stage ? ` · ${d.stage}` : ''}
                  </span>
                  <span className={statusColor(d.status, d.timedOut)}>
                    {d.timedOut ? 'timed out' : d.error ? `${d.status} · error` : d.status}
                  </span>
                </div>
              ))}
            </div>
          )}

          {/* ADE chat (Req 2, 16.1, 16.3) */}
          <div className="min-h-0 flex-1 overflow-hidden rounded-lg border border-gray-700">
            {activeSessionId ? (
              <ChatRenderer
                key={activeSessionId}
                agentEndpoint={STUDIO_AGENT_ENDPOINT}
                agentName={`ade:${activeSessionId}`}
                agentDescription="Design and deploy agents with natural language"
                sessionId={activeSessionId}
                // ADR-040: stream the ADE chat token-by-token via the always-on
                // ECS/Fargate backend (/ade-api/invoke) instead of the buffered
                // /api/invoke Lambda path. Same SSE contract + Cognito bearer JWT.
                invokeEndpoint="/ade-api/invoke"
                onAgentMessage={handleAgentMessage}
                onUserMessage={(text) =>
                  appendMessage({ role: 'user', text, timestamp: Date.now() })
                }
                pendingInput={pendingInput}
                onPendingInputConsumed={() => setPendingInput(undefined)}
              />
            ) : (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <p className="text-sm text-brand-200">No active design session</p>
                <button
                  type="button"
                  onClick={() => createSession()}
                  className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500"
                >
                  + New Design Session
                </button>
              </div>
            )}
          </div>

          {/* Manifest previews (Req 10) */}
          {manifests.length > 0 && (
            <div className="max-h-48 space-y-1 overflow-y-auto" aria-label="Generated manifests">
              {manifests.map((block, i) => (
                <ManifestPreview key={`${block.label}-${i}`} block={block} />
              ))}
            </div>
          )}
        </section>

        {/* ---------- RIGHT ---------- */}
        <aside className="flex w-80 shrink-0 flex-col gap-4 overflow-y-auto pl-1">
          <AgentCardPanel />
          <AgentToolsPanel />
          <GatewayToolsPanel />
        </aside>
      </div>

      {/* ---------- OVERLAY ---------- */}
      {selectedAgent && (
        <AgentDetailView agent={selectedAgent} onClose={() => setSelectedAgent(null)} />
      )}
    </div>
  )
}
