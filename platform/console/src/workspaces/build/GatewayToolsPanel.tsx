import { useEffect, useState } from 'react'
import { useAuth } from '../../auth/CognitoProvider'

// GatewayToolsPanel — displays the MCP tools ADE can access (Gateway_Tool_List).
//
// On load (when authenticated) it calls the Gateway_Proxy with method
// `tools/list` and the user's JWT, then renders each returned tool's name and
// description. On failure or when no tools are returned it renders an empty
// state without interrupting the chat experience.
//
// The JWT is attached as an `Authorization: Bearer <token>` header (the same
// convention used by the Console's a2aClient for `/api/invoke`). The
// Gateway_Proxy reads the Bearer token from the header and forwards it to the
// AgentCore Gateway as a Bearer credential (Req 4.2, 13.4) — the token is NOT
// placed in the request body.
//
// _Requirements: 4.1, 4.3, 4.4_

/** A single MCP tool as surfaced to the UI (name + short description). */
export interface GatewayTool {
  name: string
  description: string
}

/**
 * Parse the AgentCore Gateway MCP `tools/list` JSON-RPC response into the
 * UI's {@link GatewayTool} shape. Tolerates missing/oddly-shaped payloads by
 * returning an empty list so the caller can render the empty state (Req 4.4).
 */
export function parseGatewayTools(data: unknown): GatewayTool[] {
  const tools = (data as { result?: { tools?: unknown } } | null)?.result?.tools
  if (!Array.isArray(tools)) return []
  return tools
    .map((t) => {
      const tool = t as { name?: unknown; description?: unknown }
      const name = typeof tool.name === 'string' ? tool.name : ''
      const description = typeof tool.description === 'string' ? tool.description : ''
      return { name, description }
    })
    .filter((t) => t.name.length > 0)
}

export interface GatewayToolsPanelProps {
  /** Optional override of the Gateway_Proxy endpoint (defaults to `/api/gateway`). */
  endpoint?: string
}

/**
 * Renders the list of MCP tools available to ADE.
 *
 * - Requests the Gateway_Tool_List on mount for an authenticated user via the
 *   Gateway_Proxy with method `tools/list` and the user's JWT (Req 4.1).
 * - Displays each tool's name and description (Req 4.3).
 * - On request failure or no tools, shows an empty state and never throws, so
 *   the surrounding chat experience is unaffected (Req 4.4).
 */
export function GatewayToolsPanel({ endpoint = '/api/gateway' }: GatewayToolsPanelProps) {
  const { token, isAuthenticated } = useAuth()
  const [tools, setTools] = useState<GatewayTool[]>([])
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    // Only request tools for an authenticated user (Req 4.1).
    if (!isAuthenticated || !token) {
      setTools([])
      return
    }

    let cancelled = false
    setLoading(true)

    fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // The Gateway_Proxy reads the Bearer JWT from this header and forwards
        // it to the AgentCore Gateway (Req 4.2, 13.4).
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ method: 'tools/list', params: {} }),
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (cancelled) return
        setTools(parseGatewayTools(data))
      })
      .catch(() => {
        // Failure yields an empty list without interrupting chat (Req 4.4).
        if (!cancelled) setTools([])
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [endpoint, token, isAuthenticated])

  return (
    <div className="space-y-2">
      <h3 className="text-xs font-medium text-brand-400 uppercase tracking-wider px-1">
        Gateway Tools
      </h3>

      {loading && tools.length === 0 ? (
        <p className="text-xs text-gray-500 px-1">Loading tools…</p>
      ) : tools.length === 0 ? (
        // Empty state — rendered without breaking the chat experience (Req 4.4).
        <p className="text-xs text-gray-500 px-1">No tools available.</p>
      ) : (
        <ul className="space-y-1" aria-label="Available MCP tools">
          {tools.map((tool) => (
            <li
              key={tool.name}
              className="rounded bg-gray-700 px-2 py-1.5"
            >
              <p className="text-xs font-medium text-gray-200 break-words">{tool.name}</p>
              {tool.description && (
                <p className="text-xs text-gray-400 break-words">{tool.description}</p>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
