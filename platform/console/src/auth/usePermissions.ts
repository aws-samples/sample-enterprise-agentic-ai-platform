import { useAuth } from './CognitoProvider'
import { isDevBypass } from '../services/awsClients'

/**
 * Workspace authorization scopes.
 * Phase 1: most scopes return granted for any authenticated user.
 * Phase 2: will enforce based on JWT claims and Cognito groups.
 *
 * The `observability` scope is persona-gated (see `canAccess` below) so the
 * Observability workspace is only presented to callers holding an authorized
 * persona (Requirements 10.1, 10.3).
 */
export const WORKSPACE_SCOPES = {
  apps: 'console:use',
  examples: 'console:use',
  build: 'console:build',
  data: 'console:data',
  quality: 'console:quality',
  admin: 'console:admin',
  governance: 'console:governance',
  platform: 'console:platform',
  observability: 'console:observability',
} as const

export type WorkspaceKey = keyof typeof WORKSPACE_SCOPES

/**
 * Personas authorized to access the Observability workspace.
 * Requirements 10.1, 10.3: presented iff the caller holds at least one of these.
 */
export const OBSERVABILITY_PERSONAS = [
  'Platform_Operator',
  'AI_Governance_Risk',
  'Developer',
] as const

export type ObservabilityPersona = (typeof OBSERVABILITY_PERSONAS)[number]

/**
 * Derive the set of observability personas carried by a caller's Cognito groups.
 *
 * Personas may appear as bare group names (e.g. `"Developer"`) or with a
 * `"persona:"` prefix (e.g. `"persona:Platform_Operator"`); matching is
 * case-insensitive and tolerant of surrounding whitespace.
 */
export function derivePersonas(groups: string[]): ObservabilityPersona[] {
  const normalized = new Set(
    (groups || []).map((g) => g.replace(/^persona:/i, '').trim().toLowerCase())
  )
  return OBSERVABILITY_PERSONAS.filter((p) => normalized.has(p.toLowerCase()))
}

/**
 * True iff the caller holds at least one observability-authorized persona
 * (Requirements 10.1, 10.3).
 */
export function hasObservabilityAccess(groups: string[]): boolean {
  return derivePersonas(groups).length > 0
}

export interface PermissionsResult {
  canAccess: (workspace: WorkspaceKey) => boolean
  allScopes: typeof WORKSPACE_SCOPES
}

/**
 * Phase 1: Returns all-granted for all scopes except `observability`, which is
 * gated to callers holding an authorized persona (Requirements 10.1, 10.3).
 * Phase 2: Will read from JWT claims and enforce scope-based access for the rest.
 */
export function usePermissions(): PermissionsResult {
  const { groups, token } = useAuth()

  const canAccess = (workspace: WorkspaceKey): boolean => {
    if (workspace === 'observability') {
      // Local dev bypass has no real Cognito groups; allow access so the
      // workspace is reachable without a configured user pool.
      if (isDevBypass(token)) return true
      return hasObservabilityAccess(groups)
    }
    // Phase 1: all other workspaces accessible to all authenticated users
    return true
  }

  return { canAccess, allScopes: WORKSPACE_SCOPES }
}
