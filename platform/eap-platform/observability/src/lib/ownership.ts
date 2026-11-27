/**
 * ownership.ts — pure, AWS-free BU authorization decision for observability.
 *
 * This is the tenant-isolation gate shared by the Deep_Link_Service and the
 * Telemetry_API_Service. Given the caller's derived claims and the resolved
 * ARN↔BU ownership record (see `lifecycleStore.ts` for the thin, AWS-backed
 * lookup that produces it), it returns a structured, fail-closed authorization
 * decision.
 *
 * It is deliberately kept free of any AWS SDK import so it is a total,
 * deterministic pure function that can be exhaustively property-tested without
 * mocking (design "Property 1: Cross-BU access is always denied"; Requirements
 * 1.6, 4.1, 4.2, 4.3, 10.2). The AWS read is a separate concern.
 */

import type { AgentOwnership, CallerClaims } from './types';

// ---------------------------------------------------------------------------
// Decision shape
// ---------------------------------------------------------------------------

/**
 * A structured authorization outcome. `allowed === false` is a deny; `reason`
 * carries a short, non-sensitive tag for server-side logging only. Callers
 * (the Lambda handlers) MUST translate a deny into a generic 403 that discloses
 * no agent/BU detail to the client (design Error Handling; Requirement 4.3).
 */
export interface AuthorizationDecision {
  allowed: boolean;
  reason?: string;
}

/**
 * Stable deny reason tags (internal logging only — never surfaced verbatim to
 * clients). Kept generic so they cannot leak which agent/BU was involved.
 */
export const DenyReason = {
  /** Caller's Business_Unit could not be derived from the claims. */
  UNRESOLVED_CALLER_BU: 'caller-bu-unresolved',
  /** Ownership lookup returned nothing (or failed and was surfaced as null). */
  OWNERSHIP_NOT_FOUND: 'ownership-not-found',
  /** Ownership record carries no owning Business_Unit. */
  OWNERSHIP_BU_UNRESOLVED: 'ownership-bu-unresolved',
  /** Owning Business_Unit differs from the caller's Business_Unit. */
  CROSS_BU: 'cross-bu',
} as const;

export type DenyReasonValue = (typeof DenyReason)[keyof typeof DenyReason];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Normalize a BU value for comparison: coerce non-strings to '' and trim. */
function normalizeBu(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

// ---------------------------------------------------------------------------
// The pure authorization decision — R1.6, R4.1, R4.2, R4.3, R10.2
// ---------------------------------------------------------------------------

/**
 * Decide whether `claims` may view the Agent described by `ownership`.
 *
 * Fail-closed rules (any match denies), evaluated in order:
 *   1. The caller's Business_Unit is unresolved/empty → deny.
 *   2. Ownership is missing (lookup failed or returned nothing) → deny.
 *   3. The owning Business_Unit is unresolved/empty → deny.
 *   4. The owning Business_Unit differs from the caller's → deny (cross-BU).
 * Only when a non-empty owning BU exactly equals the caller's non-empty BU is
 * access allowed.
 *
 * The decision is independent of persona: persona gates *reaching* the
 * workspace (Requirement 10.1/10.3), but never widens the tenant boundary
 * (Requirement 10.2). Total and deterministic — never throws.
 */
export function authorizeAgentForBu(
  claims: CallerClaims | null | undefined,
  ownership: AgentOwnership | null | undefined,
): AuthorizationDecision {
  // 1. Caller BU must be resolvable (fail closed on missing/empty).
  const callerBu = normalizeBu(claims?.bu);
  if (!callerBu) {
    return { allowed: false, reason: DenyReason.UNRESOLVED_CALLER_BU };
  }

  // 2. Ownership must exist (null => lookup failed or returned nothing).
  if (!ownership) {
    return { allowed: false, reason: DenyReason.OWNERSHIP_NOT_FOUND };
  }

  // 3. Owning BU must be resolvable.
  const owningBu = normalizeBu(ownership.bu);
  if (!owningBu) {
    return { allowed: false, reason: DenyReason.OWNERSHIP_BU_UNRESOLVED };
  }

  // 4. The owning BU must match the caller's BU exactly.
  if (owningBu !== callerBu) {
    return { allowed: false, reason: DenyReason.CROSS_BU };
  }

  return { allowed: true };
}
