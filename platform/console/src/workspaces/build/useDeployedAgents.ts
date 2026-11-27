import { useCallback, useEffect, useState } from 'react'
import { useAuth } from '../../auth/CognitoProvider'
import type { DeployedAgent } from './types'

// useDeployedAgents — fetch and refresh the authoritative, application-grouped
// list of deployed agents from the Deployed_Agents_Service.
//
// On load (for an authenticated user) it requests `GET /api/my-deployed-agents`
// and exposes the resulting `DeployedAgent[]` so the Build_Workspace can render
// one tile per application (Req 8.9). A `refresh(force?)` re-fetches, passing
// `?force=1` when `force` is true to bypass the backend's 60s cache (Req 8.7) —
// this is what `useDeploymentTracker` calls after a deployment succeeds.
//
// `dismiss(appName)` hides a tile client-side only: it records the app name in a
// local dismissed set and never issues a runtime-mutating backend call, so the
// underlying AgentCore runtime is untouched (Req 8.10). Dismissals persist for
// the lifetime of the hook, so a refresh does not resurrect a dismissed tile.
//
// The route is served behind the existing API Gateway; CloudFront routes
// `/api/*` to that origin, so a relative URL is used (the same convention the
// sibling panels and `a2aClient` use). The Cognito JWT is attached as a
// `Bearer` credential so the API Gateway JWT authorizer accepts the request
// (Req 13.1).
//
// _Requirements: 8.9, 8.10_

/** Wire response shape of `GET /api/my-deployed-agents` (see design §API). */
interface DeployedAgentsResponse {
  cached?: boolean
  apps?: DeployedAgent[]
}

export interface UseDeployedAgentsResult {
  /**
   * Applications to display — the fetched list with any client-side dismissed
   * applications removed. Exactly one entry per non-dismissed application
   * (Req 8.9).
   */
  agents: DeployedAgent[]
  /** True while a fetch is in flight. */
  loading: boolean
  /** Set when the most recent fetch failed; null otherwise. */
  error: string | null
  /**
   * Re-fetch the deployed-agents list. Pass `true` to bypass the backend's
   * 60s cache via `?force=1` (Req 8.7).
   */
  refresh: (force?: boolean) => Promise<void>
  /**
   * Hide the tile for `appName` client-side without any backend mutation
   * (Req 8.10). Idempotent.
   */
  dismiss: (appName: string) => void
}

export interface UseDeployedAgentsOptions {
  /** Backend route for the Deployed_Agents_Service. Overridable for tests. */
  endpoint?: string
}

export function useDeployedAgents(
  options: UseDeployedAgentsOptions = {},
): UseDeployedAgentsResult {
  const { endpoint = '/api/my-deployed-agents' } = options
  const { token, isAuthenticated } = useAuth()

  const [fetched, setFetched] = useState<DeployedAgent[]>([])
  const [dismissed, setDismissed] = useState<Set<string>>(() => new Set())
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(
    async (force = false) => {
      // Only request the list for an authenticated user (Req 8.9).
      if (!isAuthenticated || !token) {
        setFetched([])
        return
      }

      setLoading(true)
      setError(null)
      try {
        const url = `${endpoint}${force ? '?force=1' : ''}`
        const res = await fetch(url, {
          headers: { Authorization: `Bearer ${token}` },
        })
        if (!res.ok) {
          // On read failure, do not surface partial/stale results (Req 8.8);
          // clear the list and record the error.
          setError(`Failed to load deployed agents (${res.status})`)
          setFetched([])
          return
        }
        const data = (await res.json()) as DeployedAgentsResponse
        setFetched(Array.isArray(data.apps) ? data.apps : [])
      } catch {
        setError('Failed to load deployed agents')
        setFetched([])
      } finally {
        setLoading(false)
      }
    },
    [endpoint, token, isAuthenticated],
  )

  // Fetch on load and whenever auth becomes available (Req 8.9).
  useEffect(() => {
    let cancelled = false
    if (!isAuthenticated || !token) {
      setFetched([])
      return
    }
    void (async () => {
      if (cancelled) return
      await refresh(false)
    })()
    return () => {
      cancelled = true
    }
  }, [refresh, isAuthenticated, token])

  const dismiss = useCallback((appName: string) => {
    // Purely client-side: record the app name so it is filtered out of the
    // displayed list. No backend call is made (Req 8.10).
    setDismissed((prev) => {
      if (prev.has(appName)) return prev
      const next = new Set(prev)
      next.add(appName)
      return next
    })
  }, [])

  // Displayed list = fetched apps minus client-side dismissed apps (Req 8.10).
  const agents = fetched.filter((a) => !dismissed.has(a.app_name))

  return { agents, loading, error, refresh, dismiss }
}
