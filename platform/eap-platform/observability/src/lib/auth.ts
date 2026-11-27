/**
 * auth.ts — pure, AWS-free authentication/identity logic for the observability
 * backend (Deep_Link_Service, Telemetry_API_Service).
 *
 * Ported/adapted from `invoke-proxy/src/index.ts` (`validateJwt`) and aligned
 * with the console claim shape produced by `console/src/auth/CognitoProvider.ts`
 * (`cognito:groups` carrying `bu:<unit>` and persona group names).
 *
 * This module performs lightweight, *structural* JWT validation only —
 * structure, expiry, and issuer — exactly like invoke-proxy. The API Gateway
 * Cognito authorizer remains the primary cryptographic gate; this is
 * defense-in-depth (Requirements 1.7, 2.7). No signature verification and no
 * AWS SDK calls happen here, so the logic is fully unit/property testable.
 */

import type { CallerClaims, Persona } from './types';

// ---------------------------------------------------------------------------
// Issuer configuration (matches invoke-proxy)
// ---------------------------------------------------------------------------

// Injected by Terraform at deploy time. No hardcoded pool-ID fallback (a stale
// literal here would silently accept tokens from a foreign pool); defaults to
// empty so the module stays import-safe for unit tests, which use COGNITO_ISSUER
// symbolically rather than asserting a specific pool.
const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID || '';
const COGNITO_REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1';

/** The expected token issuer for the platform Cognito user pool. */
export const COGNITO_ISSUER = `https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}`;

/** The personas authorized to consume observability (Requirement 10). */
export const OBSERVABILITY_PERSONAS: readonly Persona[] = [
  'Platform_Operator',
  'AI_Governance_Risk',
  'Developer',
];

// ---------------------------------------------------------------------------
// Raw JWT payload shape (only the fields we read)
// ---------------------------------------------------------------------------

/** The subset of raw Cognito JWT claims this module reads. */
export interface RawJwtPayload {
  sub?: string;
  exp?: number;
  iss?: string;
  'cognito:groups'?: string[];
  /** Optional dedicated BU claim (custom attribute), preferred when present. */
  bu?: string;
  'custom:bu'?: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// JWT validation (structure / expiry / issuer) — mirrors invoke-proxy
// ---------------------------------------------------------------------------

export interface JwtValidationResult {
  valid: boolean;
  error?: string;
  /** The decoded payload, present only when structurally decodable. */
  payload?: RawJwtPayload;
}

/**
 * Validate a bearer JWT's structure, expiry, and issuer (defense-in-depth).
 *
 * Returns `{ valid: false, error }` for missing/empty/malformed/expired/
 * wrong-issuer tokens and never throws. On success the decoded payload is
 * returned so callers can derive BU/personas without decoding twice.
 *
 * `nowSeconds` is injectable so expiry checks are deterministic under test.
 */
export function validateJwt(
  authHeader: string | undefined,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): JwtValidationResult {
  if (!authHeader) {
    return { valid: false, error: 'Missing Authorization header' };
  }

  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : authHeader;

  if (!token) {
    return { valid: false, error: 'Empty token' };
  }

  // A JWT is header.payload.signature (base64url).
  const parts = token.split('.');
  if (parts.length !== 3) {
    return { valid: false, error: 'Invalid token format' };
  }

  let payload: RawJwtPayload;
  try {
    payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString()) as RawJwtPayload;
  } catch {
    return { valid: false, error: 'Failed to decode token' };
  }

  if (!payload || typeof payload !== 'object') {
    return { valid: false, error: 'Failed to decode token' };
  }

  // Expiry.
  if (typeof payload.exp === 'number' && payload.exp < nowSeconds) {
    return { valid: false, error: 'Token expired' };
  }

  // Issuer.
  if (payload.iss && payload.iss !== COGNITO_ISSUER) {
    return { valid: false, error: 'Invalid token issuer' };
  }

  return { valid: true, payload };
}

// ---------------------------------------------------------------------------
// BU derivation — R4.1
// ---------------------------------------------------------------------------

/** Cognito group prefix carrying the caller's Business_Unit (e.g. `bu:team-bu-1`). */
const BU_GROUP_PREFIX = 'bu:';

/**
 * Derive the caller's Business_Unit from decoded claims (Requirement 4.1).
 *
 * Resolution order (first match wins):
 *   1. a dedicated `bu` claim,
 *   2. a `custom:bu` attribute,
 *   3. the first `cognito:groups` entry of the form `bu:<unit>`.
 *
 * Returns `''` when no BU can be resolved. Callers MUST fail closed (deny) on
 * an empty BU rather than proceed (see design Error Handling / Property 1).
 * Pure and deterministic.
 */
export function deriveBu(payload: RawJwtPayload | null | undefined): string {
  if (!payload || typeof payload !== 'object') return '';

  const direct = typeof payload.bu === 'string' ? payload.bu.trim() : '';
  if (direct) return direct;

  const custom = typeof payload['custom:bu'] === 'string' ? String(payload['custom:bu']).trim() : '';
  if (custom) return custom;

  const groups = Array.isArray(payload['cognito:groups']) ? payload['cognito:groups'] : [];
  for (const g of groups) {
    if (typeof g === 'string' && g.startsWith(BU_GROUP_PREFIX)) {
      const bu = g.slice(BU_GROUP_PREFIX.length).trim();
      if (bu) return bu;
    }
  }
  return '';
}

// ---------------------------------------------------------------------------
// Persona derivation — R10
// ---------------------------------------------------------------------------

const PERSONA_SET: ReadonlySet<string> = new Set(OBSERVABILITY_PERSONAS);

/**
 * Derive the caller's observability personas from decoded claims (Requirement
 * 10). A persona is recognized when a `cognito:groups` entry matches one of
 * {Platform_Operator, AI_Governance_Risk, Developer}. Duplicates are collapsed
 * and ordering follows `OBSERVABILITY_PERSONAS`. Pure and deterministic.
 */
export function derivePersonas(payload: RawJwtPayload | null | undefined): string[] {
  if (!payload || typeof payload !== 'object') return [];
  const groups = Array.isArray(payload['cognito:groups']) ? payload['cognito:groups'] : [];
  const found = new Set<string>();
  for (const g of groups) {
    if (typeof g === 'string' && PERSONA_SET.has(g)) found.add(g);
  }
  return OBSERVABILITY_PERSONAS.filter((p) => found.has(p));
}

/**
 * Whether the caller holds at least one observability persona (Requirement
 * 10.1 / 10.3). Used to gate the ObservabilityWorkspace.
 */
export function hasObservabilityPersona(personas: readonly string[]): boolean {
  return Array.isArray(personas) && personas.some((p) => PERSONA_SET.has(p));
}

// ---------------------------------------------------------------------------
// Convenience: build CallerClaims from a decoded payload
// ---------------------------------------------------------------------------

/**
 * Assemble the canonical `CallerClaims` from a decoded JWT payload by deriving
 * `bu` and `personas`. Does not re-validate the token — callers should invoke
 * `validateJwt` first and pass its returned payload.
 */
export function toCallerClaims(payload: RawJwtPayload): CallerClaims {
  return {
    sub: typeof payload.sub === 'string' ? payload.sub : '',
    bu: deriveBu(payload),
    personas: derivePersonas(payload),
    exp: typeof payload.exp === 'number' ? payload.exp : 0,
    iss: typeof payload.iss === 'string' ? payload.iss : '',
  };
}
