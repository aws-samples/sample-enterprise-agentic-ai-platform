import { useEffect, useRef } from 'react'
import { UnifiedAgentView } from '../../components/UnifiedAgentView'
import { fromDeployedAgent } from '../../components/agentViewModel'
import { DETAIL_VIEW_MAX_LEN } from './messageGuard'
import type { DeployedAgent } from './types'

// AgentDetailView — full-screen overlay for a selected deployed application.
//
// Opened from a deployed-agent tile in the Build workspace (Req 9.1). The body
// is the shared UnifiedAgentView, whose layout IS this detail view's original
// ADE shape — chat on the LEFT, an inspector rail on the RIGHT — now with the
// right rail overlaying BOTH Architecture and OTel Logs. The Examples surface
// renders the same layout (one UI template across the platform).
//   - Chat (left)  : per-agent chat scoped to the app's primary runtime, via
//                    the streaming /ade-api path (Req 9.2, 9.3, 9.4).
//   - Architecture : PatternPanel matching the application's pattern (Req 9.5).
//   - Logs         : OTel/CloudWatch logs for the app's runtimes.
//
// Escape closes the overlay (Req 9.12). Invoke failures/timeouts are handled
// inside ChatRenderer, which preserves prior conversation content and
// re-enables input (Req 9.11) — no extra handling is required here.
//
// _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.10, 9.11, 9.12_

export interface AgentDetailViewProps {
  agent: DeployedAgent
  onClose: () => void
}

export function AgentDetailView({ agent, onClose }: AgentDetailViewProps) {
  // Overlay-only session identity, DISJOINT from the ADE design sessions
  // (Req 9.4). `agentName` also partitions ChatRenderer's per-conversation
  // localStorage cache (`console-chat:{userId}:{agentName}`), so the `detail:`
  // prefix guarantees the overlay conversation never collides with an ADE
  // session cache. The timestamped `sessionId` is generated once per mount and
  // held in a ref so it stays stable across re-renders.
  const sessionIdRef = useRef<string>(`detail:${agent.app_name}:${Date.now()}`)

  // Normalize the deployed app into the shared view-model. Chat targets the
  // primary runtime through the JWT-validated /api/invoke path; the Logs tab
  // uses the derived `${bu}_${app}_` runtime prefix; Architecture uses the
  // app's own topology + runtimes.
  const vm = fromDeployedAgent(agent)

  // Escape closes the overlay and returns to the Build workspace (Req 9.12).
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  return (
    <div
      className="fixed inset-0 z-50 flex flex-col bg-gray-900"
      role="dialog"
      aria-modal="true"
      aria-label={`Deployed agent detail: ${agent.app_name}`}
    >
      {/* Header */}
      <div className="flex items-center justify-between border-b border-gray-700 bg-gray-800 px-6 py-3">
        <div className="min-w-0">
          <h2 className="truncate text-lg font-semibold text-white">
            {agent.app_name}
          </h2>
          <p className="text-xs uppercase tracking-wider text-gray-400">
            {agent.pattern || 'standalone'}
          </p>
        </div>
        <button
          onClick={onClose}
          className="rounded border border-gray-600 px-3 py-1.5 text-sm text-gray-300 hover:border-gray-400 hover:text-white"
          aria-label="Close detail view"
        >
          Close (Esc)
        </button>
      </div>

      {/* Body: the shared ADE layout — chat-left + a right rail overlaying
          Architecture + Logs. `maxLength={DETAIL_VIEW_MAX_LEN}` enforces the
          >10,000-char cap so all three clauses of Req 9.10 hold at the chat
          call site (ChatRenderer applies the shared `canSend` guard). The
          overlay-only `sessionId` keeps this conversation's localStorage cache
          disjoint from the ADE design sessions (Req 9.4). */}
      <div className="flex min-h-0 flex-1 p-4">
        <UnifiedAgentView
          vm={vm}
          sessionId={sessionIdRef.current}
          maxLength={DETAIL_VIEW_MAX_LEN}
        />
      </div>
    </div>
  )
}

// Note: the detail-view message length cap (Req 9.10) is DETAIL_VIEW_MAX_LEN
// (10000), defined in messageGuard and passed to ChatRenderer via the
// `maxLength` prop above. ChatRenderer applies the shared `canSend` guard, so
// empty/whitespace-only and over-10,000-char messages are all blocked before
// an invoke.
