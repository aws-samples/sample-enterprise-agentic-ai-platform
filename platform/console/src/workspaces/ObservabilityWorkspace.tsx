import { useEffect, useMemo, useState } from 'react'
import { WorkspaceHeader } from '../components/WorkspaceHeader'
import { useAgents, AgentLifecycleItem } from '../hooks/useAgents'
import { useBU } from '../hooks/useBU'
import { usePermissions } from '../auth/usePermissions'

/**
 * ObservabilityWorkspace — the persona-gated, BU-scoped observability surface.
 *
 * The embedded Langfuse trace/prompt/eval UI is the PRIMARY in-console trace
 * surface (task 9.3). The two AWS-native surfaces are additive and filled in by
 * their own tasks:
 *   - "View in CloudWatch" federated deep-link (task 2.14)
 *   - Native on-brand AWS telemetry panels (task 4.11)
 *
 * Requirements: 3.1, 4.2, 10.1, 10.3, 13.1, 13.4, 14.2.
 */

/**
 * Origin (scheme + host) of the self-hosted Langfuse stack, injected at build
 * time as `VITE_LANGFUSE_EMBED_ORIGIN` (task 12.1). An empty/unset value disables
 * the in-console embed and the workspace renders a "Langfuse unavailable" state.
 */
function getLangfuseEmbedOrigin(): string {
  return (import.meta.env.VITE_LANGFUSE_EMBED_ORIGIN || '').trim()
}

/** Restrict the agent list to the caller's selected Business_Unit (Requirement 4.2). */
function filterAgentsByBU(agents: AgentLifecycleItem[], selectedBU: string): AgentLifecycleItem[] {
  if (!selectedBU) return agents
  // Include agents explicitly tagged for the BU; records without a `bu` tag are
  // treated as visible (legacy lifecycle rows) so scoping never hides untagged agents.
  return agents.filter((a) => !a.bu || a.bu === selectedBU)
}

/**
 * Build the embedded Langfuse iframe `src`, scoped to the caller's Business_Unit
 * where the Langfuse URL supports it (Requirements 13.1, 14.2).
 *
 * Returns `null` when no origin is configured (or the origin is malformed), which
 * disables the embed. Tenant isolation is enforced authoritatively server-side —
 * the Langfuse_ALB Cognito auth and the per-BU Langfuse project (via the collector
 * routing) — this `bu` hint only steers Langfuse to the correct project view.
 */
export function buildLangfuseEmbedUrl(origin: string, bu: string): string | null {
  const trimmed = (origin || '').trim()
  if (!trimmed) return null
  try {
    // ADR-038: the embed origin is normally a same-origin relative path
    // ("/langfuse") served through the console CloudFront. Resolve relative
    // paths against the current origin; absolute origins still work as before.
    const base = typeof window !== 'undefined' ? window.location.origin : 'http://localhost'
    const url = new URL(trimmed, base)
    if (bu) url.searchParams.set('bu', bu)
    return url.toString()
  } catch {
    return null
  }
}

// Langfuse launch card (ADR-039), the primary trace/prompt/eval surface
// (Requirements 13.1, 13.4). Renders a clear "Langfuse unavailable" state when
// the origin is missing/empty, without crashing the workspace.
// Langfuse is a full app served from its own
// hardened CloudFront; it ships anti-clickjacking headers (X-Frame-Options /
// frame-ancestors) and uses first-party auth cookies, so it is opened in a NEW
// TAB rather than iframe-embedded (embedding was refused by the browser and
// cross-origin cookies made in-frame login unreliable). This mirrors the "View
// in CloudWatch" deep-link pattern below.
function LangfuseEmbedSection({ embedUrl, agentName }: { embedUrl: string | null; agentName: string }) {
  const unavailable = !embedUrl

  return (
    <div className="bg-surface-panel border border-surface-border rounded-lg overflow-hidden">
      <div className="p-4 border-b border-surface-border flex items-center justify-between gap-4">
        <div>
          <h2 className="text-sm font-medium text-brand-200">GenAI Observability / Langfuse</h2>
          <p className="text-brand-200/50 text-xs">
            Primary trace, prompt, and evaluation surface for {agentName}.
          </p>
        </div>
        <span className="shrink-0 text-[10px] font-medium uppercase tracking-wider text-accent-fg border border-accent/30 rounded px-2 py-0.5">
          Primary
        </span>
      </div>

      {unavailable ? (
        <div className="p-8 text-center" role="alert" aria-label="Langfuse unavailable">
          <p className="text-brand-200 text-base mb-1">Langfuse unavailable</p>
          <p className="text-brand-200/60 text-sm max-w-md mx-auto">
            The GenAI Observability backend isn't configured for this deployment. Use the
            AWS-native surfaces below — View in CloudWatch and the native panels — to inspect
            this agent's telemetry.
          </p>
        </div>
      ) : (
        <div className="p-6 flex flex-col items-center text-center gap-3">
          <p className="text-brand-200/70 text-sm max-w-md">
            Open Langfuse to explore distributed traces, prompt versions, and evaluation
            scores for {agentName}. Opens in a new tab (first-party login).
          </p>
          <a
            href={embedUrl!}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-2 px-4 py-2 rounded bg-accent text-white text-sm font-medium hover:bg-accent-hover transition-colors"
          >
            Open GenAI Observability
            <span aria-hidden="true">↗</span>
          </a>
        </div>
      )}
    </div>
  )
}

function PlaceholderSection({ title, description }: { title: string; description: string }) {
  return (
    <div className="bg-surface-panel border border-surface-border rounded-lg p-4">
      <h2 className="text-sm font-medium text-brand-200 mb-1">{title}</h2>
      <p className="text-brand-200/50 text-xs">{description}</p>
    </div>
  )
}

export function ObservabilityWorkspace() {
  const { canAccess } = usePermissions()
  const { data: agents, isLoading, error } = useAgents()
  const { selectedBU } = useBU()
  const [selectedAgent, setSelectedAgent] = useState<string>('')

  // Authoritative tenant boundary for this workspace. Every BU-scoped surface —
  // the agent selector AND the embedded Langfuse iframe — derives from this SINGLE
  // value so their scoping can never diverge (Requirements 4.2, 10.2, 13.4). This
  // is applied identically for every persona; no persona branches around scoping.
  const scopedBU = selectedBU

  const buAgents = useMemo(
    () => filterAgentsByBU(agents || [], scopedBU),
    [agents, scopedBU]
  )

  // Only an agent within the BU-scoped list can ever be active/embedded. Deriving
  // from `buAgents` (not the raw agent set) means an agent from another BU is never
  // selectable and never reaches the embed (Requirement 4.2).
  const activeAgent = buAgents.find((a) => a.agent_name === selectedAgent) || null

  // BU-scoped Langfuse iframe target (null when the embed origin is unset). It uses
  // the SAME authoritative `scopedBU` as the agent selector above (Requirements
  // 13.4, 14.2), so the embed can never carry a different BU than the agent list.
  const langfuseOrigin = getLangfuseEmbedOrigin()
  const langfuseEmbedUrl = useMemo(
    () => buildLangfuseEmbedUrl(langfuseOrigin, scopedBU),
    [langfuseOrigin, scopedBU]
  )

  // When the selected BU changes, a previously selected agent may no longer belong
  // to the caller's BU. Clear the stale selection so no cross-BU agent stays active
  // or embedded after a BU switch (Requirement 4.2).
  useEffect(() => {
    if (selectedAgent && !buAgents.some((a) => a.agent_name === selectedAgent)) {
      setSelectedAgent('')
    }
  }, [buAgents, selectedAgent])

  // Persona gate (Requirements 10.1, 10.3). The nav entry is already hidden for
  // unauthorized callers, but the /observability route is directly addressable —
  // guarding here closes the gap so the workspace never renders its surfaces to a
  // caller lacking an authorized persona, regardless of how the route is reached.
  if (!canAccess('observability')) {
    return (
      <div className="flex flex-col h-full">
        <WorkspaceHeader
          icon="📊"
          title="Observability"
          subtitle="GenAI Observability · Langfuse & Traces"
          persona="Operator · Governance · Developer"
        />
        <div
          className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center"
          role="alert"
          aria-label="Observability access denied"
        >
          <p className="text-brand-200 text-lg mb-2">Access restricted</p>
          <p className="text-brand-200/60 text-sm max-w-md mx-auto">
            Observability is available to Platform Operator, AI Governance &amp; Risk, and
            Developer personas. Your account doesn't hold an authorized persona for this
            workspace.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col h-full">
      <WorkspaceHeader
        icon="📊"
        title="Observability"
        subtitle="GenAI Observability · Langfuse & Traces"
        persona="Operator · Governance · Developer"
      />

      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-accent" />
          <span className="ml-3 text-brand-200">Loading agents…</span>
        </div>
      )}

      {error && (
        <div className="bg-red-900/20 border border-red-500/30 rounded-lg p-4 mb-4">
          <p className="text-red-400 text-sm">Failed to load agents: {error.message}</p>
        </div>
      )}

      {!isLoading && !error && (
        <>
          {/* BU-scoped agent selector (Requirement 4.2) */}
          <div className="bg-surface-panel border border-surface-border rounded-lg p-4 mb-6">
            <label className="block text-brand-200/60 text-xs uppercase tracking-wider mb-2" htmlFor="observability-agent">
              Agent{selectedBU ? ` · ${selectedBU}` : ''}
            </label>
            {buAgents.length === 0 ? (
              <p className="text-brand-200/40 text-sm">No agents available for this business unit.</p>
            ) : (
              <select
                id="observability-agent"
                value={selectedAgent}
                onChange={(e) => setSelectedAgent(e.target.value)}
                className="bg-brand-700 text-white text-sm rounded px-3 py-2 border border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-300 w-full max-w-md"
                aria-label="Select an agent"
              >
                <option value="">Select an agent…</option>
                {buAgents.map((agent) => (
                  <option key={agent.agent_name} value={agent.agent_name}>
                    {agent.agent_name} (v{agent.version})
                  </option>
                ))}
              </select>
            )}
          </div>

          {!activeAgent ? (
            <div className="bg-surface-panel border border-surface-border rounded-lg p-8 text-center">
              <p className="text-brand-200 text-lg mb-2">Select an agent</p>
              <p className="text-brand-200/60 text-sm">
                Choose an agent above to view its observability surfaces.
              </p>
            </div>
          ) : (
            <div className="space-y-4">
              {/* Primary in-console trace surface — embedded Langfuse (task 9.3). */}
              <LangfuseEmbedSection embedUrl={langfuseEmbedUrl} agentName={activeAgent.agent_name} />
              <PlaceholderSection
                title="View in CloudWatch"
                description="A federated, read-only deep-link to the CloudWatch GenAI Observability page for this agent, opened in a new tab. (Coming soon)"
              />
              <PlaceholderSection
                title="Native AWS Panels"
                description="On-brand session, latency, token-usage, error, trace-list, and span drill-down panels read from CloudWatch and X-Ray. (Coming soon)"
              />
            </div>
          )}
        </>
      )}
    </div>
  )
}
