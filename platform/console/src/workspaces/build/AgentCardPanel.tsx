import { useEffect, useState } from 'react'
import { useAuth } from '../../auth/CognitoProvider'
import type { AgentCard } from './types'

// AgentCardPanel — displays the ADE (Agent Deployment Engineer) Agent_Card.
//
// On load, fetches the ADE metadata from the studio-read backend route
// `GET /api/agent-card` (served behind the existing API Gateway; CloudFront
// routes `/api/*` to that origin, so a relative URL is used — the same
// convention `a2aClient` uses for `/api/invoke`). The Cognito JWT is sent as a
// Bearer credential so the API Gateway JWT authorizer accepts the request
// (Req 13.1).
//
// Renders the card's name, description, framework, model, protocols, and skills
// (id / name / description) (Req 5.2).
//
// Load failure is handled gracefully: the panel renders nothing rather than
// throwing, so a missing/unavailable backend never breaks the Build workspace
// (Req 5.1 retrieval is best-effort).
//
// _Requirements: 5.1, 5.2_

export interface AgentCardPanelProps {
  /** Backend route for the Agent_Card. Overridable for tests. */
  endpoint?: string
}

export function AgentCardPanel({ endpoint = '/api/agent-card' }: AgentCardPanelProps) {
  const { token } = useAuth()
  const [card, setCard] = useState<AgentCard | null>(null)

  useEffect(() => {
    let cancelled = false

    async function load() {
      try {
        const res = await fetch(endpoint, {
          headers: token ? { Authorization: `Bearer ${token}` } : {},
        })
        if (!res.ok) {
          if (!cancelled) setCard(null)
          return
        }
        const data = (await res.json()) as AgentCard
        if (!cancelled) setCard(data)
      } catch {
        // Load failure — render nothing rather than throwing (Req 5.1).
        if (!cancelled) setCard(null)
      }
    }

    load()
    return () => {
      cancelled = true
    }
  }, [endpoint, token])

  // Minimal fallback: render nothing when the card is unavailable so the panel
  // never interrupts the rest of the Build workspace.
  if (!card) return null

  return (
    <div className="space-y-2" aria-label="Agent card">
      <h3 className="text-xs font-medium text-brand-400 uppercase tracking-wider px-1">
        Agent Card
      </h3>

      <div className="rounded-lg border border-gray-700 bg-gray-800 p-3 space-y-3">
        {/* Name + description */}
        <div className="space-y-1">
          <p className="text-sm font-semibold text-white">{card.name}</p>
          {card.description && (
            <p className="text-xs text-gray-400 leading-relaxed">{card.description}</p>
          )}
        </div>

        {/* Framework / model / protocols */}
        <dl className="space-y-1 text-xs">
          {card.framework && (
            <div className="flex justify-between gap-2">
              <dt className="text-gray-500">Framework</dt>
              <dd className="text-gray-200 text-right">{card.framework}</dd>
            </div>
          )}
          {card.model && (
            <div className="flex justify-between gap-2">
              <dt className="text-gray-500">Model</dt>
              <dd className="text-gray-200 text-right">{card.model}</dd>
            </div>
          )}
          {card.protocols && card.protocols.length > 0 && (
            <div className="flex justify-between gap-2">
              <dt className="text-gray-500">Protocols</dt>
              <dd className="flex flex-wrap justify-end gap-1">
                {card.protocols.map((protocol) => (
                  <span
                    key={protocol}
                    className="rounded bg-gray-700 px-1.5 py-0.5 text-[10px] text-gray-200"
                  >
                    {protocol}
                  </span>
                ))}
              </dd>
            </div>
          )}
        </dl>

        {/* Skills (id / name / description) */}
        {card.skills && card.skills.length > 0 && (
          <div className="space-y-1.5">
            <p className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">
              Skills
            </p>
            <ul className="space-y-1.5">
              {card.skills.map((skill) => (
                <li key={skill.id} className="rounded bg-gray-900/50 px-2 py-1.5">
                  <p className="text-xs font-medium text-gray-100">{skill.name}</p>
                  {skill.description && (
                    <p className="text-[11px] text-gray-400 leading-snug">{skill.description}</p>
                  )}
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </div>
  )
}
